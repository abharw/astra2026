import test from 'node:test';
import assert from 'node:assert/strict';
import {completedBackgroundTurn,createBackgroundTurnTracker} from '../viewer/background-turns.js';
const reply={id:'reply-1',status:'completed',output:[{type:'message',content:[{type:'audio',transcript:'A calm ocean.'}]}]};
test('only completed spoken responses count as background turns',()=>{
 assert.deepEqual(completedBackgroundTurn(reply,'Describe the sea'),{context:'User: Describe the sea\nAstra: A calm ocean.',turnId:'reply-1'});
 for(const status of ['cancelled','failed','incomplete'])assert.equal(completedBackgroundTurn({...reply,status}),null);
 assert.equal(completedBackgroundTurn({...reply,output:[{type:'function_call'}]}),null);
 assert.equal(completedBackgroundTurn({...reply,output:[]}),null);
});

test('a turn counts only after response completion and audible playback finish, in either order',()=>{
 const turns=[],tracker=createBackgroundTurnTracker(turn=>turns.push(turn));tracker.complete(reply,'Ocean');assert.equal(turns.length,0);tracker.playbackFinished(reply.id);assert.equal(turns.length,1);
 tracker.playbackFinished('reply-2');tracker.complete({...reply,id:'reply-2'},'Forest');assert.equal(turns.length,2);tracker.playbackFinished('reply-2');assert.equal(turns.length,2);
});
test('interrupting playback or acknowledging an explicit scene does not advance the cadence',()=>{
 const turns=[],tracker=createBackgroundTurnTracker(turn=>turns.push(turn));tracker.complete(reply,'Ocean');tracker.cancel(reply.id);tracker.playbackFinished(reply.id);assert.equal(turns.length,0);
 tracker.complete({...reply,id:'explicit'},'Change the scene',{skip:true});tracker.playbackFinished('explicit');assert.equal(turns.length,0);
});
