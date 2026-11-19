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
test('a Vimeo event link names its recording by the video id, not the event id',()=>{
  assert.equal(provider('https://vimeo.com/event/5938928/video/1193358615').url,'https://player.vimeo.com/video/1193358615');
  assert.equal(provider('https://vimeo.com/event/5938928/video/1193358615/abcdef123').url,'https://player.vimeo.com/video/1193358615?h=abcdef123');
  assert.throws(()=>provider('https://vimeo.com/event/5938928/embed/interaction'),/not an event page/);
  assert.equal(provider('https://vimeo.com/123456789').url,'https://player.vimeo.com/video/123456789');
  assert.equal(recordingLink('https://vimeo.com/event/5938928/video/1193358615',3058),'https://vimeo.com/1193358615#t=3058s');
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
const {nextRate}=await import(moduleUrl);
test('keyboard commands play, skip, change volume and speed in a YouTube player',async()=>{
  let yt;const states=[];
  globalThis.location={origin:'http://127.0.0.1:8766'};
  globalThis.document={createElement:()=>({})};
  globalThis.window={YT:{Player:class{
    constructor(el,options){yt=this;this.position=100;this.state=2;this.volume=50;this.muted=false;this.rate=1;queueMicrotask(()=>options.events.onReady({target:this}));}
    cueVideoById(){} seekTo(t){this.position=t;} getCurrentTime(){return this.position;} getDuration(){return 1000;}
    getPlayerState(){return this.state;} playVideo(){this.state=1;} pauseVideo(){this.state=2;}
    getVolume(){return this.volume;} setVolume(v){this.volume=v;} unMute(){this.muted=false;} mute(){this.muted=true;} isMuted(){return this.muted;}
    getPlaybackRate(){return this.rate;} setPlaybackRate(r){this.rate=r;} destroy(){}
  }}};
  const session=createPreview({replaceChildren(){},append(){}},{url:'https://youtube.com/watch?v=T3iBuIt4M-0',target:100,onState:s=>states.push(s)});
  await new Promise(setImmediate);
  await session.control('toggle');assert.equal(yt.state,1);
  await session.control('toggle');assert.equal(yt.state,2);
  await session.control('skip',5);assert.equal(yt.position,105);
  await session.control('skip',-10);assert.equal(yt.position,95);
  await session.control('skip',-500);assert.equal(yt.position,0);
  await session.control('skip',5000);assert.equal(yt.position,1000);
  await session.control('volume',0.1);assert.equal(yt.volume,60);
  await session.control('volume',-1);assert.equal(yt.volume,0);
  await session.control('mute');assert.equal(yt.muted,true);
  await session.control('rate',1);assert.equal(yt.rate,1.25);
  await session.control('rate',-1);await session.control('rate',-1);assert.equal(yt.rate,0.75);
  await session.control('restart');assert.equal(yt.position,0);
  assert.equal(states.at(-1).error,undefined,'keys never report a playback error');
  session.destroy();
});
test('speed steps stay within the available speeds',()=>{
  assert.equal(nextRate(1,1),1.25);assert.equal(nextRate(2,1),2);assert.equal(nextRate(0.5,-1),0.5);assert.equal(nextRate(1,-1),0.75);
});
