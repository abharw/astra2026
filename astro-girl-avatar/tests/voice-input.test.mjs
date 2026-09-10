import test from 'node:test';
import assert from 'node:assert/strict';
import {gateMicrophone,AUTO_VAD,turnDetection} from '../viewer/voice-input.js';
import {sessionConfig} from '../realtime-server.mjs';
import fs from 'node:fs';
const manifest=JSON.parse(fs.readFileSync(new URL('../assets/character.json',import.meta.url)));
test('protected mode cannot feed background speech into a reply in progress',()=>{
 const track={enabled:true},stream={getAudioTracks:()=>[track]};
 gateMicrophone(stream,{mode:'protected',busy:false});assert.equal(track.enabled,true);
 // The reproduced trace: response starts, then background speech arrives 149 ms later.
 gateMicrophone(stream,{mode:'protected',busy:true});assert.equal(track.enabled,false);
 gateMicrophone(stream,{mode:'protected',busy:true,holding:true});assert.equal(track.enabled,false);
 gateMicrophone(stream,{mode:'protected',busy:false});assert.equal(track.enabled,true);
});
test('hold-to-talk never forwards audio unless pressed, including after a reply ends',()=>{
 const track={enabled:true},stream={getAudioTracks:()=>[track]};
 gateMicrophone(stream,{mode:'push',holding:false,busy:false});assert.equal(track.enabled,false);
 gateMicrophone(stream,{mode:'push',holding:true,busy:false});assert.equal(track.enabled,true);
 gateMicrophone(stream,{mode:'push',holding:true,busy:true});assert.equal(track.enabled,false);
 gateMicrophone(stream,{mode:'push',holding:false,busy:false});assert.equal(track.enabled,false);
});
test('new sessions allow interruption while retaining noise reduction and low latency settings',()=>{
 const config=sessionConfig(manifest);assert.equal(config.audio.input.turn_detection.interrupt_response,true);assert.ok(config.audio.input.turn_detection.threshold>=.7);assert.ok(config.audio.input.turn_detection.silence_duration_ms<=350);assert.ok(config.audio.input.noise_reduction);assert.equal(config.reasoning.effort,'minimal');assert.deepEqual(config.audio.input.turn_detection,AUTO_VAD);
});
test('ordinary conversation keeps the microphone open while the avatar speaks',()=>{
 const track={enabled:false},stream={getAudioTracks:()=>[track]};
 gateMicrophone(stream,{mode:'auto',busy:true});assert.equal(track.enabled,true);
 assert.equal(sessionConfig(manifest).audio.input.turn_detection.interrupt_response,true);
});
test('mode changes configure server interruption consistently with microphone gating',()=>{assert.equal(turnDetection('auto').interrupt_response,true);assert.equal(turnDetection('protected').interrupt_response,false);assert.equal(turnDetection('push'),null)});
