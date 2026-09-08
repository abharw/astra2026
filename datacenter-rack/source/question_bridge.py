"""Question-to-saved-asset bridge for the local Blender training scene.

The built-in resolver retrieves known source facts. Codex/Astra can instead send
a structured inspect intent after interpreting a broader question. HTTP accepts
only finite JSON operations; no Python/code execution endpoint is exposed.
"""
from pathlib import Path
import json,os,queue,secrets,sys,threading,time,uuid,textwrap
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import bpy
from bpy.props import StringProperty
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'source'))
import lazy_inspector
from question_context import resolve_question
JOBS=queue.Queue();SERVER=None;TOKEN=None;RESULTS={};PENDING={};LOCK=threading.Lock()

def _state():
    return {'scene':bpy.context.scene.name,'objects':len(bpy.data.objects),'meshes':len(bpy.data.meshes),'loaded_detail_collections':[c.name for c in bpy.data.collections if c.name.startswith('DETAIL')], 'active_part_id':bpy.context.object.get('part_id') if bpy.context.object else None,'last_answer':getattr(bpy.context.scene,'rack_answer','')}

def inspect_intent(intent):
    return lazy_inspector.handle_intent(intent)

def ask(question,selected_part_id=None,server_id=None):
    current=bpy.context.object;metadata={}
    if current:
        metadata={k:v for k,v in current.items() if isinstance(v,(str,int,float,bool))}
        selected_part_id=selected_part_id or current.get('part_id')
        obj=current
        while obj:
            server_id=server_id or obj.get('server_id');obj=obj.parent
    server_id=server_id or bpy.context.scene.get('lazy_selected_server_id','rack01.server01')
    result=resolve_question(question,selected_part_id=selected_part_id,server_id=server_id,selected_metadata=metadata)
    before=_state();t=time.monotonic()
    if result.get('intent'):
        result['load_result']=inspect_intent(result['intent'])
        result['execution_status']='executed' if result['load_result'].get('status')!='error' else 'failed'
        if result['load_result'].get('status')=='error':
            result['status']='load_error';result['answer']=result.get('answer','')+' Model load failed: '+result['load_result'].get('message','unknown error')
    answer=result.get('answer','No source-backed answer was found.')
    bpy.context.scene.rack_answer=answer
    bpy.context.scene.rack_question=question
    bpy.context.scene.rack_question_sources=json.dumps(result.get('sources',[]),ensure_ascii=False)
    result['seconds']=time.monotonic()-t;result['before']=before;result['after']=_state()
    return result

def process(payload):
    action=payload.get('action')
    if action=='state':return _state()
    if action=='question':return ask(str(payload.get('question',''))[:4000],payload.get('selected_part_id'),payload.get('server_id'))
    if action=='intent':
        intent=payload.get('intent',{})
        if intent.get('action') not in ['inspect','show_rack','unload']:raise ValueError('Unsupported intent action')
        return {'result':inspect_intent(intent),'state':_state()}
    raise ValueError('Supported actions are state, question and intent')

def _timer():
    for _ in range(4):
        try:item=JOBS.get_nowait()
        except queue.Empty:break
        payload,event,holder=item
        try:holder['result']=process(payload)
        except Exception as exc:holder['error']=str(exc)
        event.set()
    return .08

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        if self.path!='/action' or self.headers.get('X-RackLab-Token')!=TOKEN:
            self.send_error(403);return
        if self.headers.get('Origin'):
            self.send_error(403,'Browser origins are not enabled');return
        count=int(self.headers.get('Content-Length',0))
        if count<1 or count>16384:self.send_error(400);return
        try:payload=json.loads(self.rfile.read(count))
        except Exception:self.send_error(400);return
        request_id=payload.get('request_id') or str(uuid.uuid4())
        if request_id in RESULTS:body=RESULTS[request_id]
        else:
            with LOCK:
                if request_id not in PENDING:
                    event=threading.Event();holder={};PENDING[request_id]=(event,holder);JOBS.put((payload,event,holder))
                else:event,holder=PENDING[request_id]
            if not event.wait(180):
                self.send_error(504,'Blender is busy; retry with the same request_id');return
            body={'request_id':request_id,**holder}
            if event.is_set():
                RESULTS[request_id]=body;PENDING.pop(request_id,None)
        raw=json.dumps(body,default=str).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)

class RACKLAB_OT_ask_question(bpy.types.Operator):
    bl_idname='racklab.ask_question';bl_label='Ask / inspect';bl_description='Retrieve saved source facts and load only the matching pregenerated asset'
    def execute(self,context):
        try:
            result=ask(context.scene.rack_question)
            self.report({'INFO'},result.get('status','Question processed'));return {'FINISHED'}
        except Exception as exc:self.report({'ERROR'},str(exc));return {'CANCELLED'}

class RACKLAB_PT_question(bpy.types.Panel):
    bl_label='Ask about this equipment';bl_idname='RACKLAB_PT_question';bl_space_type='VIEW_3D';bl_region_type='UI';bl_category='Rack Lab'
    def draw(self,context):
        layout=self.layout;layout.prop(context.scene,'rack_question',text='Question');layout.operator('racklab.ask_question',icon='VIEWZOOM')
        if context.scene.rack_answer:
            box=layout.box()
            for line in textwrap.wrap(context.scene.rack_answer,55):box.label(text=line)
        layout.label(text='Saved models · source-backed facts',icon='INFO')

def register():
    global SERVER,TOKEN
    for cls in [RACKLAB_OT_ask_question,RACKLAB_PT_question]:
        old=getattr(bpy.types,cls.__name__,None)
        if old:
            try:bpy.utils.unregister_class(old)
            except RuntimeError:pass
        bpy.utils.register_class(cls)
    bpy.types.Scene.rack_question=StringProperty(name='Question',default='Show the CPU in server 1')
    bpy.types.Scene.rack_answer=StringProperty(name='Source answer')
    bpy.types.Scene.rack_question_sources=StringProperty(name='Source references')
    if not bpy.app.timers.is_registered(_timer):bpy.app.timers.register(_timer,persistent=True)
    TOKEN=secrets.token_urlsafe(32);SERVER=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=SERVER.serve_forever,name='RackLab local intent bridge',daemon=True).start()
    runtime=ROOT/'.runtime';runtime.mkdir(exist_ok=True)
    path=runtime/'bridge.json';path.write_text(json.dumps({'host':'127.0.0.1','port':SERVER.server_port,'token':TOKEN,'pid':os.getpid()}));path.chmod(0o600)
    print('RACKLAB_QUESTION_BRIDGE_READY',SERVER.server_port,flush=True)

if __name__=='__main__':register()
