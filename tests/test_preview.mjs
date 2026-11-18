import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFileSync} from 'node:fs';
const moduleUrl='data:text/javascript;base64,'+Buffer.from(readFileSync(new URL('../web/preview.js',import.meta.url))).toString('base64');
const {provider,recordingLink,createPreview}=await import(moduleUrl);
test('recognizes YouTube recording URLs and preserves Vimeo unlisted access hash',()=>{
  assert.deepEqual(provider('https://youtu.be/T3iBuIt4M-0?t=0'),{kind:'youtube',id:'T3iBuIt4M-0'});
  assert.equal(provider('https://www.youtube.com/live/T3iBuIt4M-0').id,'T3iBuIt4M-0');
  assert.equal(provider('https://vimeo.com/123456789/abcde').url,'https://player.vimeo.com/video/123456789?h=abcde');
  assert.equal(provider('https://player.vimeo.com/video/123456789?h=abcde').url,'https://player.vimeo.com/video/123456789?h=abcde');
});
test('external recording link uses match time instead of original stale t=0',()=>{
  assert.equal(new URL(recordingLink('https://youtube.com/watch?v=T3iBuIt4M-0&t=0',14793)).searchParams.get('t'),'14793s');
  assert.equal(new URL(recordingLink('https://vimeo.com/123456789',67)).hash,'#t=67s');
});
test('first playback explicitly seeks even if pre-play cue and seek were ignored',async()=>{
  let instance;const states=[];
  globalThis.location={origin:'http://127.0.0.1:8766'};
  globalThis.document={createElement:()=>({})};
  globalThis.window={YT:{Player:class{
    constructor(el,options){instance=this;this.options=options;this.position=0;this.state=5;queueMicrotask(()=>options.events.onReady({target:this}));}
    cueVideoById(v){this.cue=v;}
    seekTo(t){if(this.state===1)this.position=t;}
    getCurrentTime(){return this.position;}
    getDuration(){return 35000;}
    getPlayerState(){return this.state;}
    destroy(){this.destroyed=true;}
  }}};
  const container={replaceChildren(){},append(){}};
  const session=createPreview(container,{url:'https://youtube.com/watch?v=T3iBuIt4M-0&t=0',target:14793,onState:s=>states.push(s)});
  await new Promise(setImmediate);
  assert.equal(instance.position,0);assert.equal(instance.cue.startSeconds,14793);
  instance.state=1;instance.options.events.onStateChange({data:1,target:instance});
  await new Promise(setImmediate);
  assert.equal(instance.position,14793);
  assert.equal(states.at(-1).position,14793);
  await session.seekTo(50);assert.equal(await session.getCurrentTime(),50);
  instance.position=0;await session.jump();assert.equal(instance.position,14793);
  instance.options.events.onError({data:150});
  assert.match(states.at(-1).error,/owner has disabled playback inside other apps/);
  assert.match(states.at(-1).error,/Open recording at match time/);
  session.destroy();assert.equal(instance.destroyed,true);
});
