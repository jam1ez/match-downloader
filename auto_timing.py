"""Broadcast start metadata and conservative event recording discovery."""
import json,re,time,hashlib
from datetime import datetime,timezone
from pathlib import Path
from urllib.parse import urlparse,parse_qs
from concurrent.futures import ThreadPoolExecutor
from event_streams import video_url,timestamp,match_time,normalize_stream,apply_streams,recording_key,media_url

def canonical(url):
    u=urlparse(url);host=(u.hostname or '').removeprefix('www.')
    id=u.path.strip('/').split('/')[0] if host=='youtu.be' else (parse_qs(u.query).get('v') or [None])[0]
    if not id and host in ('youtube.com','m.youtube.com'):
        m=re.search(r'/(?:live|embed|shorts)/([\w-]{11})',u.path)
        if m:id=m[1]
    return 'https://www.youtube.com/watch?v='+id if id and host in ('youtu.be','youtube.com','m.youtube.com') else url

def extract(url,flat=False):
    from yt_dlp import YoutubeDL
    from yt_dlp.utils import DownloadError
    options={'quiet':True,'no_warnings':True,'skip_download':True,'noplaylist':True,'extract_flat':'in_playlist' if flat else False,'playlistend':5 if url.startswith('ytsearch') else 20,'socket_timeout':15,'retries':1,'js_runtimes':{'node':{}}}
    try:
        with YoutubeDL(options) as ydl:
            info=ydl.extract_info(url,download=False)
            if info.get('entries') is not None:info['entries']=list(info['entries'])
            return info
    except DownloadError:raise ValueError('Recording details could not be read. Try another recording link or sync to a known match.') from None

def metadata(info):
    was_live=bool(info.get('was_live') or info.get('is_live') or info.get('live_status') in ('was_live','is_live','post_live'))
    boxcast='boxcast' in str(info.get('extractor_key') or info.get('extractor') or '').lower()
    release=info.get('release_timestamp') if was_live or boxcast else None
    # Generic upload timestamps and scheduled/premiere times are not a live origin.
    start=datetime.fromtimestamp(release,timezone.utc).isoformat() if isinstance(release,(int,float)) else None
    recordings=[]
    for e in list(info.get('entries') or [])[:20]:
        if not isinstance(e,dict):continue
        url=e.get('webpage_url') or e.get('url') or ('https://www.youtube.com/watch?v='+e['id'] if e.get('id') else '')
        if not str(url).startswith('http') and e.get('id'):url='https://www.youtube.com/watch?v='+e['id']
        if str(url).startswith('http'):recordings.append({'title':e.get('title'),'url':url})
    return {'title':info.get('title'),'channel':info.get('channel') or info.get('uploader'),'duration':info.get('duration'),'wasLive':was_live or boxcast,'liveStatus':info.get('live_status'),'startEstimate':start,'startSource':'broadcast release time' if start else None,'recordings':recordings,'checked':time.time()}

def probe(url,cache_dir=None):
    url=canonical(video_url(url));key=hashlib.sha256(url.encode()).hexdigest()
    file=Path(cache_dir)/(key+'.json') if cache_dir else None
    if file and file.exists():
        try:
            data=json.loads(file.read_text())
            ttl=300 if data.get('liveStatus') in ('is_live','is_upcoming','post_live') else 86400
            if time.time()-data.get('checked',0)<ttl:return data
        except (ValueError,OSError):pass
    # BoxCast /view links and Vimeo event videos are read through the link yt-dlp understands, so a
    # Vimeo event never reports another video's title and length.
    data=metadata(extract(media_url(url),flat=True))
    if file:
        file.parent.mkdir(exist_ok=True,parents=True)
        # Each cache key can be probed concurrently without a shared temp name.
        import uuid
        tmp=file.with_suffix('.'+uuid.uuid4().hex+'.tmp');tmp.write_text(json.dumps(data));tmp.replace(file)
    return data

STOP={'vex','v5','v5rc','robotics','competition','signature','event','tournament','override','push','back','pushback','high','school','middle','blended','the','a','and','at','hs','ms'}
def title_matches(event,title):
    title=str(title or '').lower()
    if any(w in title for w in ('highlights','recap','skills only','finals only')):return False
    base=event.get('name','').split(':')[0].lower()
    tokens={w for w in re.findall(r'[a-z0-9]+',base) if w not in STOP and len(w)>2}
    words=set(re.findall(r'[a-z0-9]+',title))
    distinct={w for w in tokens if not w.isdigit()}
    return len(distinct)>=1 and len(tokens&words)/max(1,len(tokens))>=.8 and all(w in words for w in tokens if re.fullmatch(r'20\d{2}',w))

def search_recordings(event):
    title=event.get('name','').split(':')[0].strip()
    query=' '.join(re.findall(r'[\w]+',title))
    result=extract('ytsearch5:'+query,flat=True)
    urls=[]
    for e in result.get('entries') or []:
        if not isinstance(e,dict) or not title_matches(event,e.get('title')):continue
        url=e.get('webpage_url') or e.get('url') or ('https://www.youtube.com/watch?v='+e['id'] if e.get('id') else '')
        if str(url).startswith('http'):urls.append({'url':canonical(url),'label':e.get('title') or title,'source':'Event-title search'})
    return urls

def covering_days(event,info):
    origin=timestamp(info.get('startEstimate'));duration=info.get('duration')
    if not origin:return []
    days=set()
    for m in event.get('matches',[]):
        t=match_time(m)
        if not t:continue
        position=(t-origin).total_seconds()
        if 0<=position and (not duration or position<duration):days.add(str(m.get('started') or m.get('scheduled'))[:10])
    return sorted(days)

def auto_time(event,cache_dir,search=True,probe_fn=None,search_fn=None):
    probe_fn=probe_fn or (lambda url:probe(url,cache_dir));search_fn=search_fn or search_recordings
    streams=list(event.get('streams') or []);messages=[];added=updated=0
    for s in streams:
        # Explicit manual calibrations and verified wall-clock sync stay intact.
        if not s.get('enabled',True) or s.get('syncMode') not in ('none','auto'):continue
        try:
            info=probe_fn(s['url']);s['metadata']=info;s['syncMode']='auto'
            if info.get('duration'):s['duration']=info['duration']
            if info.get('startEstimate'):updated+=1
            else:messages.append(s['label']+': no broadcast start metadata; use a known match to calibrate.')
        except ValueError as e:messages.append(s['label']+': '+str(e))
    event['streams']=streams;apply_streams(event)
    # Same-recording estimates: confirm each recording's length so no match is
    # placed after the recording ends.
    durations=dict(event.get('recordingDurations') or {})
    if any(not m.get('available') for m in event.get('matches',[])):
        feed={}
        for m in event.get('matches',[]):
            base=m.get('_baseVideo') or {}
            if base.get('available') and base.get('url'):feed.setdefault(recording_key(base['url']),base['url'])
        def length(item):
            try:return item[0],probe_fn(item[1]).get('duration')
            except ValueError:return item[0],None
        with ThreadPoolExecutor(max_workers=3) as pool:
            for key,duration in pool.map(length,[i for i in feed.items() if i[0] not in durations][:12]):
                if duration:durations[key]=duration
    if durations!=(event.get('recordingDurations') or {}):event['recordingDurations']=durations;apply_streams(event)
    # Recordings found automatically only fill gaps in an event whose feed
    # already supplies positions.
    fill_only=any((m.get('_baseVideo') or {}).get('available') for m in event.get('matches',[]))
    feed_recordings={canonical(m['_baseVideo']['url']) for m in event.get('matches',[]) if (m.get('_baseVideo') or {}).get('url')}
    missing=[m for m in event.get('matches',[]) if not m.get('available')]
    if search and missing:
        candidates=list((event.get('discovery') or {}).get('candidates') or [])
        used_search=False
        # Search only when no explicit source can be timed, not over a user's links.
        if not candidates and not streams:
            try:candidates=search_fn(event);used_search=True
            except ValueError as e:messages.append(str(e))
        known={canonical(s['url']) for s in streams}|feed_recordings;seen=set();todo=[]
        for c in candidates:
            try:url=canonical(video_url(c.get('url','')))
            except ValueError:continue
            if url in known or url in seen:continue
            seen.add(url);todo.append(dict(c,url=url))
        def inspect(c):
            try:return c,probe_fn(c['url'])
            except ValueError:return c,None
        with ThreadPoolExecutor(max_workers=3) as pool:
            inspected=list(pool.map(inspect,todo[:10]))
            # Webcast pages sometimes publish a channel rather than a video.
            # Resolve recent matching recordings instead of treating the channel
            # itself as a timed source.
            expanded=[]
            for c,info in inspected:
                if not info or info.get('startEstimate'):continue
                for recording in info.get('recordings',[]):
                    if not title_matches(event,recording.get('title')):continue
                    url=canonical(recording['url'])
                    if url in known or url in seen:continue
                    seen.add(url);expanded.append(dict(recording,url=url,source='Event-title search',divisionId=c.get('divisionId','*')))
            inspected.extend(pool.map(inspect,expanded[:10]))
            # A stale webcast link must not prevent a title search for events
            # without a user-supplied recording.
            if not used_search and candidates and not streams and not any(info and info.get('startEstimate') and covering_days(event,info) for c,info in inspected):
                try:
                    fallback=[]
                    for c in search_fn(event):
                        url=canonical(video_url(c.get('url','')))
                        if url in known or url in seen:continue
                        seen.add(url);fallback.append(dict(c,url=url))
                    inspected.extend(pool.map(inspect,fallback[:5]))
                except ValueError as e:messages.append(str(e))
            for c,info in inspected:
                if not info or not info.get('startEstimate'):continue
                if c.get('source')=='Event-title search' and not title_matches(event,info.get('title')):continue
                days=covering_days(event,info)
                div=str(c.get('divisionId') or '*')
                if div=='*' and len(event.get('divisions',[]))>1:
                    matches=[d for d in event['divisions'] if re.search(r'\b'+re.escape(d['name'])+r'\b',str(info.get('title','')),re.I)]
                    if len(matches)!=1:
                        messages.append((info.get('title') or 'Recording')+': choose its division before automatic timing.');continue
                    div=matches[0]['id']
                for day in days:
                    body={'label':info.get('title') or c.get('label') or 'Recording','url':c['url'],'date':day,'divisionId':div,'syncMode':'auto','basis':'actual','duration':info.get('duration'),'metadata':info,'fillOnly':fill_only}
                    try:streams.append(normalize_stream(event,body));added+=1
                    except ValueError as e:messages.append(str(e))
    event['streams']=streams;apply_streams(event)
    count=sum(bool(m.get('available')) for m in event.get('matches',[]))
    untimed=[m for m in event.get('matches',[]) if not m.get('available') and m.get('timing')=='Needs timing']
    if count and untimed and not added:
        unplayed=sum(1 for m in untimed if not timestamp(m.get('started')));outside=len(untimed)-unplayed
        if outside:messages.append(str(outside)+' match(es) fall outside the known recordings (before the stream started or after it ended). Add a recording that covers them if one exists.')
        if unplayed:messages.append(str(unplayed)+' match(es) have no official start time, so they may not have been played or broadcast.')
    if not count and not messages:messages.append('No timed recording found. Add a recording link; its broadcast start time will be read automatically.')
    event['autoTiming']={'checked':time.time(),'added':added,'updated':updated,'available':count,'total':len(event.get('matches',[])),'messages':messages}
    return event
