import test from 'node:test';import assert from 'node:assert/strict';
import {groundResearch,groundAssembly} from '../research.mjs';
import {validateMesh} from '../schema.mjs';
const identity={label:'Speaker',brand:'',model:'',identifiersVisible:false};
const response={output:[{type:'web_search_call',action:{sources:[{url:'https://maker.example/manual.pdf',title:'Manual'}]}}]};
test('discards fabricated URLs and downgrades exact match without readable identity',()=>{
 const r=groundResearch(identity,{summary:'notes',sources:[{url:'https://maker.example/manual.pdf',match:'exact',kind:'service_manual',findings:'Two drivers'},{url:'https://fake.example',match:'exact'}]},response);
 assert.equal(r.sources.length,1);assert.equal(r.sources[0].match,'similar');assert.equal(r.searchPerformed,true);
});
test('allows exact-model evidence only with visible brand/model',()=>{
 const r=groundResearch({...identity,brand:'Brand',model:'M1',identifiersVisible:true},{sources:[{url:'https://maker.example/manual.pdf',match:'exact'}]},response);
 assert.equal(r.sources[0].match,'exact');
});
test('similar schematics cannot verify this object’s hidden components',()=>{
 const a=groundAssembly({parts:[{evidence:'documented',sourceIds:['S1','invented']}]},{sources:[{id:'S1',match:'similar'}]});
 assert.equal(a.parts[0].evidence,'inferred');assert.deepEqual(a.parts[0].sourceIds,['S1']);
});
test('mesh accepts a triangle and rejects bad indices and degenerate faces',()=>{
 const m={vertices:[[0,0,0],[.5,0,0],[0,.5,0]],triangles:[0,1,2]};assert.equal(validateMesh(m),m);
 assert.throws(()=>validateMesh({...m,triangles:[0,1,3]}));assert.throws(()=>validateMesh({...m,triangles:[0,0,0]}));assert.throws(()=>validateMesh({...m,vertices:[[0,0,0],[1,0,0],[0,.5,0]]}));
});
