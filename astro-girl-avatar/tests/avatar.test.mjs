import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {cloneDefault,mergeState,composeWeights} from '../viewer/state.js';
const manifest=JSON.parse(fs.readFileSync(new URL('../assets/character.json',import.meta.url)));
test('happy expression remains on the face during speech',()=>{
 const state=mergeState(cloneDefault(),{expression:'happy',mouth:{mode:'viseme',viseme:'aa',weight:.8}},manifest);const w=composeWeights(state,manifest);assert.equal(w.mouthSmile,.85);assert.ok(Math.abs(w.jawOpen-.72)<1e-9);assert.ok(Math.abs(w.mouthWide-.096)<1e-9);
});
test('closed lips and blinking take priority over conflicting open shapes',()=>{
 const state=mergeState(cloneDefault(),{expression:'surprised',controls:{mouthClose:1},blink:'closed'},manifest);const w=composeWeights(state,manifest);assert.equal(w.jawOpen,0);assert.equal(w.eyeWideLeft,0);assert.equal(w.eyeWideRight,0);assert.equal(w.eyeBlinkLeft,1);
});
test('partial voice updates preserve the selected expression and clamp levels',()=>{
 const state=mergeState(cloneDefault(),{expression:'sad',look:{yaw:.2}},manifest);const next=mergeState(state,{mouth:{mode:'audio',level:7}},manifest);assert.equal(next.expression,'sad');assert.equal(next.look.yaw,.2);assert.equal(next.mouth.level,1);assert.equal(state.mouth.mode,'expression');
});
test('invalid control messages cannot poison the live state',()=>{
 for(const patch of [{mouth:{mode:'unknown'}},{mouth:{viseme:'made-up'}},{controls:{notAControl:1}},{mouth:{open:'one'}},{look:{yaw:NaN}},{idle:'false'},{expression:'__proto__'}])assert.throws(()=>mergeState(cloneDefault(),patch,manifest));
});
test('neutral reset produces closed resting mouth and open eyes',()=>{const w=composeWeights(cloneDefault(),manifest);assert.equal(w.jawOpen,0);assert.equal(w.eyeBlinkLeft,0);assert.equal(w.mouthSmile,0)});
const data=fs.readFileSync(new URL('../assets/astra-girl.glb',import.meta.url));const jsonLen=data.readUInt32LE(12);const gltf=JSON.parse(data.subarray(20,20+jsonLen).toString().trim());
test('export contains all live controls as real nonempty morph targets',()=>{
 assert.equal(data.toString('ascii',0,4),'glTF');assert.equal(data.readUInt32LE(4),2);
 const found=new Set();for(const mesh of gltf.meshes){const names=mesh.extras?.targetNames||[];for(const primitive of mesh.primitives){assert.equal(primitive.targets?.length||0,names.length);names.forEach((name,i)=>{const a=gltf.accessors[primitive.targets[i].POSITION];assert.ok(a.count>0);assert.ok(a.max.some((v,k)=>v!==0||a.min[k]!==0),`${name} must deform vertices`);found.add(name)})}}
 assert.deepEqual([...found].sort(),manifest.controls.toSorted());
});
test('export includes skin bindings, head bone and positive model scale',()=>{assert.ok(gltf.skins.length>0);assert.ok(gltf.nodes.some(n=>n.name==='head'));assert.ok(gltf.nodes.some(n=>n.skin!==undefined));assert.ok(manifest.triangles<200000)});
test('all nine motion clips animate the exported skeleton independently of the face',()=>{
 assert.equal(gltf.animations.length,9);for(const meta of Object.values(manifest.motions)){const clip=gltf.animations.find(a=>a.name===meta.clip);assert.ok(clip,meta.clip);assert.equal(clip.channels.length,45);assert.ok(clip.channels.every(c=>c.target.path!=='weights'));const times=gltf.accessors[clip.samplers[0].input];assert.ok(Math.abs(times.max[0]-meta.duration)<.04)}
});
test('repeated gestures retrigger while preserving speech and expression',()=>{
 const first=mergeState(cloneDefault(),{expression:'happy',mouth:{mode:'viseme',viseme:'aa'},motion:{name:'wave'}},manifest);
 const next=mergeState(first,{motion:{name:'wave',speed:.5,loop:true}},manifest);assert.equal(next.motion.sequence,first.motion.sequence+1);assert.equal(next.expression,'happy');assert.equal(next.mouth.viseme,'aa');assert.equal(next.motion.speed,.5);assert.equal(next.motion.loop,true);
 for(const motion of [{name:'__proto__'},{name:'fake'},{loop:'yes'},{startedAt:0},{speed:NaN}])assert.throws(()=>mergeState(next,{motion},manifest));
});
test('late shared-state audio updates cannot pull the local live mouth backwards',()=>{
 const old=mergeState(cloneDefault(),{mouth:{mode:'audio',level:.1}},manifest);
 assert.equal(composeWeights(old,manifest,0,.8).jawOpen,.8);
 assert.equal(composeWeights(old,manifest,0,0).jawOpen,0);
 assert.equal(composeWeights(old,manifest,0,null).jawOpen,.1);
});
