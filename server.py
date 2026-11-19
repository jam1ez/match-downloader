"""Match Downloader engine: the loopback HTTP API and web pages."""
import json, os, re, shutil, time, uuid
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlparse
from events import match_format
from worlds import season as worlds_season
from event_streams import media_url
from jobs import (
    ACTIVE_STATUSES,
    API_VERSION,
    BUSY,
    DATA,
    EVENTS,
    LOCK,
    MANAGED,
    PROCESSES,
    QUIT_WHEN_IDLE,
    ROOT,
    TOKEN,
    active_jobs,
    db,
    job_progress,
    seconds,
    source_url,
    terminate,
    update,
)

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def json(self, value, code=200):
        b=json.dumps(value).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Cache-Control','no-store'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def valid_host(self):
        return self.headers.get('Host') in (f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}')
    def do_GET(self):
        if not self.valid_host(): return self.json({'error':'Invalid host'},403)
        path=urlparse(self.path).path
        assets={'/preview.js':ROOT/'web/preview.js','/vendor/vimeo.js':ROOT/'web/vendor/vimeo.js','/vendor/hls.js':ROOT/'web/vendor/hls.js'}
        if path in assets:
            b=assets[path].read_bytes();self.send_response(200);self.send_header('Content-Type','text/javascript');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','no-cache');self.end_headers();self.wfile.write(b);return
        if path=='/api/health':return self.json({'app':'Match Downloader','status':'ready','api':API_VERSION})
        if path=='/api/library':
            with db() as c: rows=[dict(r) for r in c.execute('SELECT * FROM clips ORDER BY created DESC')]
            for r in rows:
                p=DATA/r['id']/'clip.mp4'; r['bytes']=p.stat().st_size if p.exists() else 0
                if r['status'] in ACTIVE_STATUSES:r['progress']=job_progress(r)
            return self.json({'clips':rows,'ffmpeg':bool(shutil.which('ffmpeg')),'storage':str(DATA),'free':shutil.disk_usage(DATA).free})
        # The web version (Settings → Advanced → Open Web Version in Browser) and the in-app video preview page.
        files={'/mac/app.js':('web/mac/app.js','text/javascript'),'/mac/app.css':('web/mac/app.css','text/css')}
        if path in files:
            file,kind=files[path];b=(ROOT/file).read_bytes();self.send_response(200);self.send_header('Content-Type',kind+'; charset=utf-8');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','no-cache');self.end_headers();self.wfile.write(b);return
        pages={'/':'web/mac/index.html','/embed/preview':'web/embed/preview.html'}
        if path in pages:
            page=pages[path]
            b=(ROOT/page).read_bytes().replace(b'__TOKEN__',TOKEN.encode())
            self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b); return
        m=re.fullmatch(r'/(video|review)/([a-f0-9]{32})',path)
        if not m: return self.json({'error':'Not found'},404)
        file=DATA/m[2]/('clip.mp4' if m[1]=='video' else 'review.mp4')
        if not file.exists(): return self.json({'error':'Video not ready'},404)
        size=file.stat().st_size; start,end=0,size-1; partial=False
        h=self.headers.get('Range')
        if h:
            match=re.fullmatch(r'bytes=(\d*)-(\d*)',h)
            if not match or not any(match.groups()): return self.range_error(size)
            a,b=match.groups()
            if a: start=int(a); end=min(int(b),end) if b else end
            else: start=max(0,size-int(b))
            if start>end or start>=size: return self.range_error(size)
            partial=True
        self.send_response(206 if partial else 200); self.send_header('Content-Type','video/mp4'); self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Length',str(end-start+1))
        if partial: self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            with file.open('rb') as f:
                f.seek(start); remaining=end-start+1
                while remaining:
                    chunk=f.read(min(1024*1024,remaining))
                    if not chunk: break
                    self.wfile.write(chunk); remaining-=len(chunk)
        except (BrokenPipeError,ConnectionResetError): pass
    def range_error(self,size):
        self.send_response(416); self.send_header('Content-Range',f'bytes */{size}'); self.end_headers()
    def do_POST(self):
        if not self.valid_host() or self.headers.get('X-Scout-Token')!=TOKEN: return self.json({'error':'Forbidden'},403)
        try:
            n=int(self.headers.get('Content-Length','0'))
            if not 0<n<=1048576: raise ValueError('Request too large or empty')
            try:body=json.loads(self.rfile.read(n))
            except (UnicodeDecodeError,json.JSONDecodeError):raise ValueError('Send a JSON object') from None
            if not isinstance(body,dict):raise ValueError('Send a JSON object')
            path=urlparse(self.path).path
            if path=='/api/quit-when-idle':
                if not MANAGED: return self.json({'scheduled':False,'active':active_jobs()})
                if body.get('enabled') is True: QUIT_WHEN_IDLE.set()
                else: QUIT_WHEN_IDLE.clear()
                return self.json({'scheduled':QUIT_WHEN_IDLE.is_set(),'active':active_jobs()})
            if path=='/api/preview/source':
                from yt_dlp import YoutubeDL
                from yt_dlp.utils import DownloadError
                try:
                    with YoutubeDL({'quiet':True,'no_warnings':True,'noplaylist':True,'socket_timeout':20,'retries':1,'format':'best[height<=720]/best','js_runtimes':{'node':{}}}) as ydl:
                        info=ydl.extract_info(media_url(source_url(body.get('url',''))),download=False)
                    resolved=info.get('url')
                    if not resolved:raise ValueError('This source has no browser-compatible preview. Download the match to watch it locally.')
                    return self.json({'url':source_url(resolved)})
                except DownloadError:
                    return self.json({'error':'The recording could not be prepared for preview. Check that it is publicly accessible.'},400)
            if path=='/api/events/auto-time':
                return self.json(EVENTS.auto_time(body.get('sku',''),body.get('search',True) is not False))
            if path=='/api/events/timing-offset':
                return self.json(EVENTS.set_timing_offset(body.get('sku',''),body.get('offset',0)))
            if path=='/api/events/streams/save':
                return self.json(EVENTS.save_stream(body.get('sku',''),body.get('stream') or {}))
            if path=='/api/events/streams/delete':
                return self.json(EVENTS.delete_stream(body.get('sku',''),body.get('id','')))
            if path=='/api/events/streams/choose':
                return self.json(EVENTS.choose_stream(body.get('sku',''),body.get('key',''),body.get('id','')))
            if path=='/api/events/streams/discover':
                return self.json(EVENTS.discover_streams(body.get('sku',''),bool(body.get('refresh'))))
            if path=='/api/events/streams/probe':
                from auto_timing import probe
                return self.json(probe(source_url(body.get('url','')),EVENTS.root/'stream-metadata'))
            if path=='/api/events/catalogue':
                saved=EVENTS.saved()
                try:data=EVENTS.catalogue(bool(body.get('refresh')))
                except ValueError:
                    if not saved:raise
                    data={'events':[],'cached':True,'offline':True}
                saved_keys={e['sku'] for e in saved};known={e['sku'] for e in data['events']};archived=EVENTS.archived()
                for e in data['events']:e['saved']=e['sku'] in saved_keys;e['custom']=False;e['archived']=e['sku'] in saved_keys and e['sku'] in archived
                data['events'] += [dict(e,saved=True,custom=True,archived=e['sku'] in archived) for e in saved if e['sku'] not in known]
                season=worlds_season()
                if season:
                    # Worlds events live in their own folder, not in the general lists.
                    keys={e['sku'] for e in season['events']}
                    data['events']=[e for e in data['events'] if e['sku'] not in keys]
                    for e in season['events']:e['saved']=e['sku'] in saved_keys
                    data['worlds']=season
                return self.json(data)
            if path=='/api/events/archive':
                return self.json(EVENTS.set_archived(body.get('sku',''),body.get('archived') is not False))
            if path=='/api/events/remove':
                return self.json(EVENTS.remove(body.get('sku','')))
            if path=='/api/events/load':
                return self.json(EVENTS.load(body.get('sku',''),bool(body.get('refresh')),os.environ.get('ROBOTEVENTS_API_KEY','')))
            if path=='/api/events/recording':
                return self.json(EVENTS.map_recording(body.get('sku',''),body.get('key',''),source_url(body.get('url','')),seconds(body.get('timestamp'))))
            if path=='/api/events/calibrate':
                return self.json(EVENTS.calibrate(body.get('sku',''),body.get('key',''),source_url(body.get('url','')),seconds(body.get('timestamp'))))
            if path=='/api/events/queue':
                event=EVENTS.read(EVENTS.sku(body.get('sku','')))
                if not event:raise ValueError('Load the event first')
                keys=body.get('keys')
                if not isinstance(keys,list) or not keys or len(keys)>500:raise ValueError('Select between 1 and 500 matches')
                keys=list(dict.fromkeys(keys)); lookup={m['key']:m for m in event['matches']}
                duration=seconds(body.get('duration',180)); before=seconds(body.get('before',5))
                mode=body.get('mode','fixed')
                if mode not in ('fixed','dynamic'):raise ValueError('Invalid clip mode')
                window=seconds(body.get('window',480));tail=seconds(body.get('tail',5))
                if not 180<=window<=1200 or tail>60:raise ValueError('Use a search window of 3–20 minutes and up to 60 seconds after the match')
                try: offset=float(body.get('offset',0))
                except (ValueError,TypeError):raise ValueError('Invalid timing adjustment')
                if not -3600<=offset<=3600 or not 1<=duration<=3600 or before>60:raise ValueError('Use a 1–3600 second clip, up to 60 seconds before, and adjustment within one hour')
                # Quick (fixed length) downloads can move each edge: negative is earlier, positive is later.
                adjust_start=adjust_end=0.0
                if mode=='fixed':
                    try:adjust_start=float(body.get('startAdjust',0));adjust_end=float(body.get('endAdjust',0))
                    except (ValueError,TypeError):raise ValueError('Invalid start or end adjustment')
                    if not (-60<=adjust_start<=60 and -60<=adjust_end<=120):raise ValueError('Move the start by up to a minute and the end by up to two minutes')
                prepared=[]
                for key in keys:
                    m=lookup.get(key)
                    if not m:raise ValueError('A selected match is no longer in the event')
                    if not m['available']:raise ValueError(m['label']+' needs a recording timestamp first')
                    base=max(0,seconds(m['timestamp'])+offset-before)
                    start=max(0,base+adjust_start);end=base+duration+adjust_end
                    if end-start<5:raise ValueError(m['label']+': with these start and end adjustments the clip would be under 5 seconds')
                    url=source_url(m['url'])
                    notes=' · '.join([event['sku'],m['division'],'Teams: '+', '.join(m['teams']) if m['teams'] else '',m['timing']]).strip(' ·')
                    scores=' / '.join(str(a['color'])+': '+str(a['score']) for a in m['alliances'] if a.get('score') is not None)
                    if scores:notes+=' · '+scores
                    prepared.append((uuid.uuid4().hex,event['name']+' · '+m['division']+' · '+m['label'],url,start,end,notes,'queued','Waiting in queue',time.time(),event['sku'],key,mode,json.dumps({
                        'anchor':max(0,seconds(m['timestamp'])+offset),
                        'lead':before,
                        'tail':tail,
                        'window':window,
                        'label':m['label'],
                        'format':match_format(event),
                    })))
                added=[];skipped=[]
                with LOCK,db() as c:
                    for item in prepared:
                        existing=c.execute("SELECT id FROM clips WHERE event_ref=? AND match_ref=? AND status!='cancelled'",(item[9],item[10])).fetchone()
                        if existing:skipped.append(item[10]);continue
                        c.execute('INSERT INTO clips(id,title,url,start,end,notes,status,detail,created,event_ref,match_ref,clip_mode,detect_settings) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',item);added.append(item[0])
                return self.json({'added':added,'skipped':skipped},201)
            if path=='/api/clips':
                url=source_url(body.get('url','')); start=seconds(body.get('start')); end=seconds(body.get('end'))
                if not 1<=end-start<=3600: raise ValueError('Choose a clip between 1 second and 1 hour')
                title=str(body.get('title','')).strip()[:200]
                if not title: raise ValueError('Enter a match name')
                id=uuid.uuid4().hex
                with LOCK,db() as c: c.execute('INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES(?,?,?,?,?,?,?,?,?)',(id,title,url,start,end,str(body.get('notes',''))[:10000],'queued','Waiting in queue',time.time()))
                return self.json({'id':id},201)
            m=re.fullmatch(r'/api/clips/([a-f0-9]{32})/(retry|cancel|delete|notes|bounds|adjust)',path)
            if not m: return self.json({'error':'Not found'},404)
            id,action=m.groups()
            with LOCK:
                with db() as c: row=c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone()
                if not row: return self.json({'error':'Not found'},404)
                if action=='bounds':
                    if id in BUSY or row['status']!='needs_review':raise ValueError('The review window is not ready yet')
                    analysis=json.loads(row['analysis_json'] or '{}')
                    start=seconds(body.get('start'));end=seconds(body.get('end'))
                    if end<=start or end>analysis.get('source_duration',0)+.1:raise ValueError('Choose start and end positions within this review window')
                    update(id,start=row['source_start']+start,end=row['source_start']+end,clip_mode='reviewed',status='queued',detail='Trimming your reviewed match bounds…')
                elif action=='adjust':
                    if id in BUSY or row['status']!='ready':raise ValueError('Only a saved video can be trimmed or extended')
                    start=seconds(body.get('start'));end=seconds(body.get('end'))
                    if end-start<5:raise ValueError('Keep at least 5 seconds of video')
                    if end-start>3600:raise ValueError('A clip can be up to one hour')
                    if start<row['start']-600 or end>row['end']+600:raise ValueError('Extend by up to 10 minutes on either side')
                    if abs(start-row['start'])<.5 and abs(end-row['end'])<.5:raise ValueError('Nothing to change')
                    if (start<row['start']-.5 or end>row['end']+.5) and not row['url']:raise ValueError('This video has no source to download more from')
                    old={'start':row['start'],'end':row['end'],'mode':row['clip_mode'],'detect':row['detect_settings']}
                    update(id,start=start,end=end,clip_mode='adjust',detect_settings=json.dumps({'adjust':old}),status='queued',detail='Waiting in queue')
                elif action=='notes': update(id,notes=str(body.get('notes',''))[:10000])
                elif action=='retry':
                    if id in BUSY: raise ValueError('Worker is stopping. Retry in a moment.')
                    if row['status'] not in ('failed','cancelled'): raise ValueError('Only failed or cancelled downloads can be retried')
                    update(id,status='queued',detail='Waiting in queue')
                elif action in ('cancel','delete'):
                    if action=='delete' and (id in BUSY or row['status'] in ('queued','downloading','analyzing','processing')): raise ValueError('Cancel first; wait for the worker to stop before deleting')
                    if id in PROCESSES:
                        terminate(PROCESSES[id])
                    if action=='cancel' and row['clip_mode']=='adjust' and row['status']=='queued':
                        old=json.loads(row['detect_settings'] or '{}').get('adjust') or {}
                        update(id,start=old.get('start',row['start']),end=old.get('end',row['end']),clip_mode=old.get('mode'),detect_settings=old.get('detect'),status='ready',detail='Adjustment cancelled. The saved video is unchanged.')
                    else:update(id,status='cancelled',detail='Cancelled')
                    if action=='delete':
                        shutil.rmtree(DATA/id,ignore_errors=True)
                        with db() as c: c.execute('DELETE FROM clips WHERE id=?',(id,))
            return self.json({'ok':True})
        except (ValueError,TypeError,KeyError) as e: return self.json({'error':str(e)},400)
        except Exception: return self.json({'error':'Local operation failed'},500)
