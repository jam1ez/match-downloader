"""Persistent stream routing and sync, scoped to division/day/field/session."""
import copy, math, re, uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import urlparse,parse_qs

VIDEO_KEYS=('timestamp','url','available','timing')
def video_url(value):
    value=str(value).strip();u=urlparse(value)
    if u.scheme not in ('http','https') or not u.hostname or u.username or u.password:raise ValueError('Enter an HTTP or HTTPS recording link')
    return value

def media_url(url):
    """The link yt-dlp should read for a recording.
    OpenScout emits BoxCast /view/<id>; yt-dlp's extractor expects /view-embed/<id>.
    A Vimeo event link is /event/<event id>/video/<video id>: the video id names the recording, while the
    event id belongs to a different Vimeo page, so point at the video itself."""
    u=urlparse(url)
    if u.hostname in ('boxcast.tv','www.boxcast.tv'):
        match=re.fullmatch(r'/(?:view|embed)/([^/]+)',u.path.rstrip('/'))
        if match:return 'https://boxcast.tv/view-embed/'+match.group(1)
    if u.hostname in ('vimeo.com','www.vimeo.com'):
        match=re.fullmatch(r'/event/\d+/video/(\d+)(?:/([0-9a-f]+))?',u.path.rstrip('/'))
        if match:return 'https://vimeo.com/'+match.group(1)+('/'+match.group(2) if match.group(2) else '')
    return url

TIMING_OFFSET_LIMIT=600  # seconds the whole event's video positions can be shifted either way

def number(value,default=0,minimum=0,maximum=604800):
    if value is None or value=='':return default
    try:n=float(value)
    except (ValueError,TypeError):raise ValueError('Enter a valid time or adjustment')
    if not math.isfinite(n) or not minimum<=n<=maximum:raise ValueError('Time or adjustment is outside the supported range')
    return n

def timestamp(value):
    if not value:return None
    try:
        d=datetime.fromisoformat(str(value).replace('Z','+00:00'))
        return d if d.tzinfo else None
    except ValueError:return None

def match_time(m,basis='actual'):
    return timestamp((m.get('scheduled') if basis=='scheduled' else m.get('started')) or m.get('scheduled'))

def match_date(m):
    return str(m.get('started') or m.get('scheduled') or '')[:10]

def event_days(event):
    start=str(event.get('start') or '')[:10];end=str(event.get('end') or start)[:10]
    result=set(match_date(m) for m in event.get('matches',[]) if match_date(m))
    try:
        a=datetime.fromisoformat(start).date();b=datetime.fromisoformat(end).date()
        for i in range(min(31,max(0,(b-a).days))+1):result.add((a+timedelta(days=i)).isoformat())
    except ValueError:pass
    return sorted(result)

def scope_matches(event,stream):
    matches=[m for m in event.get('matches',[]) if (stream['divisionId']=='*' or m['divisionId']==stream['divisionId']) and match_date(m)==stream['date'] and (not stream.get('field') or m.get('field')==stream['field'])]
    matches.sort(key=lambda m:(match_time(m,stream.get('basis','actual')) or datetime.max.replace(tzinfo=timezone.utc),str(m['key'])))
    first=stream.get('firstMatch');last=stream.get('lastMatch');keys=[m['key'] for m in matches]
    if first:
        if first not in keys:return []
        matches=matches[keys.index(first):];keys=[m['key'] for m in matches]
    if last:
        if last not in keys:return []
        matches=matches[:keys.index(last)+1]
    return matches

def normalize_stream(event,body):
    divisions={d['id'] for d in event.get('divisions',[])}
    division=str(body.get('divisionId','*'))
    if division!='*' and division not in divisions:raise ValueError('Choose a division from this event')
    date=str(body.get('date',''))
    try:datetime.strptime(date,'%Y-%m-%d')
    except ValueError:raise ValueError('Choose the event day for this recording')
    mode=body.get('syncMode','none')
    if mode not in ('none','auto','anchor','wallclock'):raise ValueError('Choose a supported synchronization method')
    basis=body.get('basis','actual')
    if basis not in ('actual','scheduled'):raise ValueError('Choose actual or scheduled match times')
    url=video_url(body.get('url',''));parsed=urlparse(url);host=(parsed.hostname or '').replace('www.','')
    if host in ('youtube.com','m.youtube.com') and not (parse_qs(parsed.query).get('v') or re.search(r'/(?:live|embed|shorts)/[A-Za-z0-9_-]{11}',parsed.path)):
        raise ValueError('Choose a specific YouTube recording. Use Read recording info to select a video from a channel or playlist.')
    stream={'id':body.get('id') or uuid.uuid4().hex,'label':str(body.get('label') or 'Recording')[:150],'url':url,'divisionId':division,'date':date,'field':str(body.get('field') or '')[:100],'syncMode':mode,'basis':basis,'offset':number(body.get('offset'),minimum=-3600,maximum=3600),'duration':number(body.get('duration'),default=None),'enabled':body.get('enabled',True) is not False,'firstMatch':str(body.get('firstMatch') or ''),'lastMatch':str(body.get('lastMatch') or ''),'anchorKey':str(body.get('anchorKey') or ''),'anchorPosition':number(body.get('anchorPosition')),'wallStart':str(body.get('wallStart') or ''),'metadata':body.get('metadata') if isinstance(body.get('metadata'),dict) else {},'fillOnly':body.get('fillOnly') is True}
    if stream['duration']==0:stream['duration']=None
    scoped=scope_matches(event,stream)
    if (stream['firstMatch'] or stream['lastMatch']) and not scoped:raise ValueError('The first/last match range does not match this division, day and field')
    if mode=='anchor':
        anchor=next((m for m in scoped if m['key']==stream['anchorKey']),None)
        if not anchor or not match_time(anchor,basis):raise ValueError('Choose a sync match with an official time in this recording’s division/day/field/range')
        if stream['duration'] and stream['anchorPosition']>=stream['duration']:raise ValueError('Sync position is beyond the end of this recording')
    if mode=='wallclock' and not timestamp(stream['wallStart']):raise ValueError('Enter the recording start date/time with a timezone, for example 2026-11-14T09:00:00-08:00')
    return stream

def stream_origin(event,stream):
    if stream.get('syncMode')=='auto':return timestamp((stream.get('metadata') or {}).get('startEstimate'))
    if stream.get('syncMode')=='wallclock':return timestamp(stream.get('wallStart'))
    if stream.get('syncMode')=='anchor':
        anchor=next((m for m in event['matches'] if m['key']==stream.get('anchorKey')),None)
        t=match_time(anchor,stream.get('basis','actual')) if anchor else None
        return t-timedelta(seconds=stream.get('anchorPosition',0)) if t else None
    return None

NEIGHBOR_GAP=3600   # seconds of official time between an untimed match and its timed neighbour

def recording_key(url):
    """Recording identity without a start-time parameter (Jumper adds &t=…)."""
    u=urlparse(str(url or ''));host=(u.hostname or '').removeprefix('www.')
    if host=='youtu.be':return 'youtube:'+u.path.strip('/').split('/')[0]
    if host in ('youtube.com','m.youtube.com'):
        v=(parse_qs(u.query).get('v') or [None])[0]
        if not v:
            found=re.search(r'/(?:live|embed|shorts)/([\w-]{11})',u.path);v=found[1] if found else None
        if v:return 'youtube:'+v
    return u._replace(fragment='').geturl()

def neighbor_estimates(event):
    """Place untimed matches using a timed match on the same recording.

    Jumper/Worlds positions are the recording start plus official match time,
    so a match the feed skipped (no actual start, a feed gap) sits at the same
    offset in the same division/day recording. Positions before the recording
    or beyond a known duration are never produced.
    """
    durations=event.get('recordingDurations') or {}
    timed={};latest={}
    for m in event.get('matches',[]):
        base=m.get('_baseVideo') or {}
        t=match_time(m)
        if base.get('available') and isinstance(base.get('timestamp'),(int,float)):
            key=recording_key(base['url']);latest[key]=max(latest.get(key,0),base['timestamp'])
            if t:timed.setdefault((m['divisionId'],match_date(m)),[]).append((t,base['timestamp'],base['url'],m))
    result={}
    for m in event.get('matches',[]):
        if (m.get('_baseVideo') or {}).get('available'):continue
        # Only a recorded actual start proves the match was played. Live check:
        # schedule-only practice matches pointed at a holding slide.
        if not timestamp(m.get('started')):continue
        t=match_time(m);pool=timed.get((m['divisionId'],match_date(m)))
        if not t or not pool:continue
        nt,npos,url,neighbor=min(pool,key=lambda p:abs((p[0]-t).total_seconds()))
        gap=(t-nt).total_seconds()
        if abs(gap)>NEIGHBOR_GAP:continue
        key=recording_key(url);position=npos+gap;duration=durations.get(key)
        # Feeds stop timing matches where a recording ends, so going past the
        # last fed position needs the recording's measured length.
        if position<0 or (duration and position>=duration) or (not duration and position>latest.get(key,0)):continue
        result[m['key']]={'timestamp':position,'url':url,'available':True,'timing':'Estimated from '+neighbor['label']+' (same recording)','estimatedFrom':neighbor['key']}
    return result

def apply_streams(event):
    streams=[s for s in event.get('streams',[]) if s.get('enabled',True)]
    eligible={s['id']:{m['key'] for m in scope_matches(event,s)} for s in streams}
    origins={s['id']:stream_origin(event,s) for s in streams}
    mapped=ambiguous=estimated=0
    for m in event.get('matches',[]):
        if '_baseVideo' not in m:
            m['_baseVideo']={k:m.get(k) for k in VIDEO_KEYS} if m.get('timing') not in ('Manual calibration','Recording calibration') else {'timestamp':None,'url':'','available':False,'timing':'Needs timing'}
    estimates=neighbor_estimates(event)
    for m in event.get('matches',[]):
        if m.get('timing') in ('Manual calibration','Recording calibration') and not m.get('_manualVideo'):
            m['_manualVideo']={k:m.get(k) for k in VIDEO_KEYS}
        m.update(m['_baseVideo']);m.pop('streamId',None);m.pop('streamLabel',None);m.pop('estimatedFrom',None)
        options=[];fill=[];scoped=False
        for s in streams:
            if m['key'] not in eligible[s['id']]:continue
            # Recordings found by automatic timing only fill gaps; they never
            # replace a position the event feed already supplied.
            if s.get('fillOnly') and m['_baseVideo'].get('available'):continue
            scoped=True;t=match_time(m,s.get('basis','actual'));origin=origins[s['id']]
            if not t or not origin:continue
            if (s.get('metadata') or {}).get('liveStatus')=='is_live' and t>datetime.now(timezone.utc):continue
            position=(t-origin).total_seconds()+s.get('offset',0)
            if position<0 or (s.get('duration') and position>=s['duration']):continue
            score=(2 if s['divisionId']!='*' else 0)+(1 if s.get('field') else 0)+(4 if s.get('firstMatch') or s.get('lastMatch') else 0)
            (fill if s.get('fillOnly') else options).append({'id':s['id'],'label':s['label'],'url':s['url'],'timestamp':position,'score':score,'automatic':s.get('syncMode')=='auto'})
        # Precedence: your recordings, the event feed, a same-recording
        # estimate, then gap-filling recordings found automatically.
        if not options and not m.get('available') and m['key'] not in estimates:options=fill
        m['streamOptions']=options
        chosen=next((o for o in options if o['id']==event.get('streamChoices',{}).get(m['key'])),None)
        if not chosen and options:
            top=max(o['score'] for o in options);best=[o for o in options if o['score']==top]
            if len(best)==1:chosen=best[0]
        if chosen:
            m.update(timestamp=chosen['timestamp'],url=chosen['url'],available=True,timing='Auto timing (broadcast start)' if chosen.get('automatic') else 'Stream sync',streamId=chosen['id'],streamLabel=chosen['label']);mapped+=1
        elif options:
            m.update(timestamp=None,url='',available=False,timing='Choose recording');ambiguous+=1
        elif not m.get('available') and m['key'] in estimates:
            m.update(estimates[m['key']]);estimated+=1
        elif scoped and not m.get('available'):m['timing']='Needs sync or another recording'
        if m.get('_manualVideo'):
            if chosen:mapped-=1
            elif options:ambiguous-=1
            elif m.get('estimatedFrom'):estimated-=1
            m.update(m['_manualVideo']);m.pop('streamId',None);m.pop('streamLabel',None);m.pop('estimatedFrom',None)
    # The event-wide livestream shift moves every found position; positions you set yourself stay put.
    shift=event.get('timingOffset') or 0
    if shift:
        for m in event.get('matches',[]):
            if m.get('_manualVideo') or not m.get('available') or not isinstance(m.get('timestamp'),(int,float)):continue
            m['timestamp']=max(0,m['timestamp']+shift)
    event['days']=event_days(event)
    event['streamSummary']={'recordings':len(event.get('streams',[])),'mapped':mapped,'ambiguous':ambiguous,'estimated':estimated}
    return event
