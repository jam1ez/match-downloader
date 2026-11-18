// Provider players must explicitly seek once ready and on the first play event.
const loads = new Map();
function script(url, ready) {
  if (ready()) return Promise.resolve();
  if (!loads.has(url)) loads.set(url, new Promise((resolve,reject) => {
    const el=document.createElement('script'); el.src=url; el.onload=resolve;
    el.onerror=()=>reject(Error('Player library could not load. Check your connection.'));
    document.head.append(el);
  }).catch(e=>{loads.delete(url);throw e;}));
  return loads.get(url);
}
let youtubeReady;
function youtube() {
  if (window.YT?.Player) return Promise.resolve();
  if (!youtubeReady) youtubeReady=new Promise((resolve,reject)=>{
    const prior=window.onYouTubeIframeAPIReady;
    const timeout=setTimeout(()=>{youtubeReady=null;reject(Error('YouTube player did not load. Check your connection.'));},20000);
    window.onYouTubeIframeAPIReady=()=>{clearTimeout(timeout);prior?.();resolve();};
    script('https://www.youtube.com/iframe_api',()=>!!window.YT?.Player).catch(e=>{clearTimeout(timeout);youtubeReady=null;reject(e);});
  });
  return youtubeReady;
}
export function provider(url) {
  const u=new URL(url);
  if (!['http:','https:'].includes(u.protocol)) throw Error('Invalid recording URL');
  const host=u.hostname.replace(/^www\./,'');
  if (['youtube.com','m.youtube.com','youtube-nocookie.com','youtu.be'].includes(host)) {
    const id=host==='youtu.be'?u.pathname.slice(1).split('/')[0]:u.searchParams.get('v')||u.pathname.split('/').filter(Boolean).pop();
    if (!/^[\w-]{11}$/.test(id||'')) throw Error('Use a link to one YouTube recording.');
    return {kind:'youtube',id};
  }
  if (['vimeo.com','player.vimeo.com'].includes(host)) {
    const parts=u.pathname.split('/').filter(Boolean);
    // vimeo.com/event/<event id>/video/<video id>: the number after "video" is the recording, not the first number.
    const afterVideo=parts.lastIndexOf('video')+1,index=afterVideo>0&&/^\d+$/.test(parts[afterVideo]||'')?afterVideo:parts.findIndex(p=>/^\d+$/.test(p));
    if(index<0||(parts[0]==='event'&&afterVideo===0)) throw Error('Use a link to one Vimeo recording, not an event page.');
    const id=parts[index],hash=u.searchParams.get('h')||(parts[index+1]||'');
    return {kind:'vimeo',url:'https://player.vimeo.com/video/'+id+(hash?'?h='+encodeURIComponent(hash):'')};
  }
  return {kind:'native'};
}
export function recordingLink(url,target) {
  const u=new URL(url),p=provider(url),t=Math.max(0,Math.floor(target));
  if(p.kind==='youtube'){u.searchParams.delete('start');u.searchParams.set('t',t+'s');}
  else if(p.kind==='vimeo'){
    // Event pages ignore a time; the video's own page takes it.
    const id=/\/video\/(\d+)/.exec(u.pathname)?.[1]||/^\/(\d+)/.exec(u.pathname)?.[1];
    if(/^\/event\//.test(u.pathname)&&id){u.pathname='/'+id;u.search='';}
    u.hash='t='+t+'s';
  }
  else if(/\.(mp4|webm|m3u8)(?:$|\?)/i.test(u.pathname))u.hash='t='+t;
  return u.href;
}
export function createPreview(container,{url,target,resolveSource,onState=()=>{}}) {
  if (!Number.isFinite(target)||target<0) throw Error('The match has no valid preview time.');
  let stopped=false,failed=false,player=null,hls=null,timer=null,adapter=null,firstPlay=true,pending=true,attempts=0;
  const abort=new AbortController();
  container.replaceChildren();
  function emit(state){if(!stopped)onState(state);}
  function fail(e){failed=true;emit({ready:false,error:e?.message||String(e)});}
  async function jump(){
    if(stopped||!adapter)return;
    try {
      const duration=await adapter.duration();
      if(duration>0&&target>=duration)throw Error('Match time is beyond the end of this recording. Adjust its timing or choose another recording.');
      pending=true;attempts=0;await adapter.seek(target);emit({ready:true,pending:true,target});
    }catch(e){fail(e);}
  }
  async function tick(){
    if(stopped||failed||!adapter)return;
    try {
      const position=await adapter.time();
      if(stopped||!Number.isFinite(position))return;
      const playing=await adapter.playing();
      if(pending&&Math.abs(position-target)<3)pending=false;
      if(pending&&playing&&++attempts<=4)await adapter.seek(target);
      emit({ready:true,position,target,pending,warning:pending&&attempts>4?'The player has not reached the match yet. Use Jump to match to retry.':''});
    }catch(e){if(!stopped)fail(e);}
  }
  async function played(){if(firstPlay){firstPlay=false;await jump();}await tick();}
  function ready(value){if(stopped)return;adapter=value;emit({ready:true,pending:true,target});jump();timer=setInterval(tick,750);}
  async function setup(){
    const p=provider(url);
    if(p.kind==='youtube'){
      await youtube();if(stopped)return;
      const el=document.createElement('div');container.append(el);
      player=new window.YT.Player(el,{width:'100%',height:'100%',videoId:p.id,
        playerVars:{enablejsapi:1,origin:location.origin,playsinline:1,start:Math.floor(target),autoplay:0,rel:0},
        events:{onReady:event=>{
          if(stopped)return;
          const yt=event.target;
          yt.cueVideoById({videoId:p.id,startSeconds:target});
          ready({seek:t=>yt.seekTo(t,true),time:()=>yt.getCurrentTime(),duration:()=>yt.getDuration(),playing:()=>yt.getPlayerState()===1});
        },onStateChange:event=>{if(!stopped&&event.data===1)played();},onError:event=>{
          const code=Number(event.data);
          const reason=code===101||code===150?'The video owner has disabled playback inside other apps.':code===100?'This video was removed or is private.':code===153?'YouTube rejected this player’s identification.':'YouTube cannot play this recording.';
          fail(Error(reason+' (YouTube error '+code+'). Use “Open recording at match time” below to watch on YouTube.'));
        }}});
    }else if(p.kind==='vimeo'){
      await script('/vendor/vimeo.js',()=>!!window.Vimeo?.Player);if(stopped)return;
      const frame=document.createElement('iframe');frame.src=p.url;frame.title='Match recording';frame.allow='autoplay; fullscreen; picture-in-picture';frame.allowFullscreen=true;container.append(frame);
      player=new window.Vimeo.Player(frame);await player.ready();if(stopped)return;
      player.on('play',played);player.on('error',fail);
      ready({seek:t=>player.setCurrentTime(t),time:()=>player.getCurrentTime(),duration:()=>player.getDuration(),playing:async()=>!(await player.getPaused())});
    }else{
      emit({ready:false,loading:'Preparing recording…'});
      let src=url;
      if(!/\.(mp4|webm|m3u8)$/i.test(new URL(url).pathname)){
        const resolved=await resolveSource(url,abort.signal);src=resolved.url;
      }
      if(stopped)return;
      const video=document.createElement('video');video.controls=true;video.playsInline=true;video.preload='metadata';container.append(video);player=video;
      const attach=()=>ready({seek:t=>{video.currentTime=t;},time:()=>video.currentTime,duration:()=>video.duration,playing:()=>!video.paused});
      video.addEventListener('loadedmetadata',attach,{once:true});
      video.addEventListener('play',played);video.addEventListener('seeked',tick);
      video.addEventListener('error',()=>fail(Error('This recording could not play in the browser. Try the original recording or download it for offline playback.')));
      if(/\.m3u8(?:$|[?#])/i.test(src)&&!video.canPlayType('application/vnd.apple.mpegurl')){
        await script('/vendor/hls.js',()=>!!window.Hls);if(stopped)return;
        if(!window.Hls.isSupported())throw Error('This browser does not support HLS previews.');
        hls=new window.Hls({startPosition:target});hls.loadSource(src);hls.attachMedia(video);
        hls.on(window.Hls.Events.ERROR,(_,data)=>{if(data.fatal)fail(Error('The HLS preview failed. The source may block browser playback.'));});
      }else video.src=src;
    }
  }
  setup().catch(e=>{if(e.name!=='AbortError')fail(e);});
  return {jump,async getCurrentTime(){if(!adapter||stopped)throw Error('Wait for the recording player to load.');return await adapter.time();},async seekTo(time){if(!adapter||stopped)throw Error('Wait for the recording player to load.');pending=false;await adapter.seek(Math.max(0,time));},destroy(){stopped=true;abort.abort();clearInterval(timer);hls?.destroy();try{if(player?.destroy)player.destroy();else if(player?.pause){player.pause();player.removeAttribute('src');player.load();}}catch{}container.replaceChildren();}};
}
