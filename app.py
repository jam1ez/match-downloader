#!/usr/bin/env python3
"""Match Downloader: single-user, loopback-only match video library."""
import argparse, json, os, re, secrets, shutil, signal, sqlite3, subprocess, sys, threading, time, uuid, webbrowser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from events import Events, match_format
from boundaries import analyze
from worlds import season as worlds_season

ROOT = Path(__file__).resolve().parent
# MATCH_DOWNLOADER_DATA moves the library; SCOUTVAULT_DATA (the app's former name) still works.
DATA = Path(os.environ.get('MATCH_DOWNLOADER_DATA') or os.environ.get('SCOUTVAULT_DATA') or ROOT / 'library').resolve()
DATA.mkdir(parents=True, exist_ok=True)
EVENTS = Events(DATA)
# The native app reads this token from <library>/.session-token; MATCH_DOWNLOADER_TOKEN overrides it.
TOKEN = os.environ.get('MATCH_DOWNLOADER_TOKEN') or secrets.token_hex(24)
TOKEN_FILE = DATA / '.session-token'
API_VERSION = 2  # bump when the Mac app needs a newer engine (2: archive/remove events, quit-when-idle)

def write_token_file():
    TOKEN_FILE.unlink(missing_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f: f.write(TOKEN)

def remove_token_file():
    # Only remove our own token; another server may have replaced it.
    try:
        if TOKEN_FILE.read_text() == TOKEN: TOKEN_FILE.unlink()
    except OSError: pass
LOCK = threading.RLock()
PROCESSES = {}
BUSY = set()

class ClosingConnection(sqlite3.Connection):
    def __exit__(self,*args):
        try: return super().__exit__(*args)
        finally: self.close()

def db():
    c = sqlite3.connect(DATA / 'library.sqlite',factory=ClosingConnection); c.row_factory = sqlite3.Row
    return c
with db() as c:
    c.execute('CREATE TABLE IF NOT EXISTS clips(id TEXT PRIMARY KEY, title TEXT, url TEXT, start REAL, end REAL, notes TEXT, status TEXT, detail TEXT, created REAL)')
    columns={r[1] for r in c.execute('PRAGMA table_info(clips)')}
    for col in ('event_ref','match_ref'):
        if col not in columns:c.execute('ALTER TABLE clips ADD COLUMN '+col+' TEXT')
    for col,kind in [('clip_mode',"TEXT DEFAULT 'fixed'"),('source_start','REAL'),('analysis_json','TEXT'),('detect_settings','TEXT')]:
        if col not in columns:c.execute('ALTER TABLE clips ADD COLUMN '+col+' '+kind)
    c.execute("UPDATE clips SET status='failed',detail='App stopped. Retry to continue.' WHERE status IN ('queued','downloading','analyzing','processing')")

def update(id, **fields):
    with LOCK, db() as c:
        c.execute('UPDATE clips SET '+','.join(k+'=?' for k in fields)+' WHERE id=?', [*fields.values(),id])

def seconds(value):
    parts = str(value or '0').split(':')
    if len(parts)>3: raise ValueError('Use seconds or HH:MM:SS')
    n = 0
    for p in parts: n = n*60 + float(p)
    if not 0 <= n < 604800: raise ValueError('Time is outside the supported range')
    return n

def source_url(value):
    u = urlparse(str(value))
    if u.scheme not in ('http','https') or not u.hostname or u.username or u.password:
        raise ValueError('Enter an HTTP or HTTPS recording URL')
    return value

def boxcast(url):
    # OpenScout emits /view/<broadcast-id>; yt-dlp's native extractor expects
    # /view-embed/<id>. Preserve provider-supported channel/video-portal URLs.
    u=urlparse(url)
    if u.hostname in ('boxcast.tv','www.boxcast.tv'):
        match=re.fullmatch(r'/(?:view|embed)/([^/]+)',u.path.rstrip('/'))
        if match: return 'https://boxcast.tv/view-embed/'+match.group(1)
    return url

LOGPOS={}  # where the running command's output starts in job.log, so progress never reads an earlier step
def run(id, args):
    log = DATA / id / 'job.log'
    with open(log,'a') as out:
        LOGPOS[id]=os.fstat(out.fileno()).st_size
        with LOCK:
            with db() as c: row=c.execute('SELECT status FROM clips WHERE id=?',(id,)).fetchone()
            if not row or row['status']=='cancelled': raise RuntimeError('Cancelled')
            p = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT,start_new_session=(os.name=='posix'))
            PROCESSES[id]=p
        try: code=p.wait()
        finally:
            with LOCK: PROCESSES.pop(id,None)
    if code:
        tail=log.read_text(errors='replace')[-1600:]
        raise RuntimeError(tail or 'Download failed')

def terminate(proc):
    try:
        if os.name=='posix':os.killpg(proc.pid,signal.SIGTERM)
        elif os.name=='nt':subprocess.run(['taskkill','/PID',str(proc.pid),'/T','/F'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        else:proc.terminate()
    except ProcessLookupError:pass

FFMPEG_TIME=re.compile(r'time=(\d+):(\d\d):(\d\d(?:\.\d+)?)')
FFMPEG_SPEED=re.compile(r'speed=\s*([\d.]+)x')
FORMAT_COUNT=re.compile(r'Downloading (\d+) format\(s\)')
LASTPROG={}  # job id -> (log position, status, fraction): progress never moves backwards within a step
def job_progress(row):
    """How far the running download or encode has got, from ffmpeg's own progress lines.
    {'fraction': 0-1 or None, 'eta': seconds or None}. Reading the on-screen clock has no known length.
    yt-dlp fetches video and audio as separate passes, each counting from zero, so passes are combined:
    the video (about 85% of the work) first, then the audio."""
    if row['status'] not in ('downloading','processing'):
        LASTPROG.pop(row['id'],None);return None
    try:settings=json.loads(row.get('detect_settings') or '{}')
    except ValueError:settings={}
    if row.get('clip_mode')=='dynamic' and (row['status']=='downloading' or str(row.get('detail','')).startswith('Preparing a review')):
        total=settings.get('anchor',row['start'])+settings.get('window',480)-(row.get('source_start') or 0)
    else:total=row['end']-row['start']
    result={'fraction':None,'eta':None}
    log=DATA/row['id']/'job.log'
    start=LOGPOS.get(row['id'],0)
    try:
        size=log.stat().st_size
        with open(log,'rb') as f:
            f.seek(max(start,size-2000000));text=f.read().decode('utf-8','replace')
    except OSError:return result
    times=[int(h)*3600+int(m)*60+float(sec) for h,m,sec in FFMPEG_TIME.findall(text)]
    if not times or total<=0:return result
    current=min(times[-1]/total,1)
    formats=int(FORMAT_COUNT.search(text).group(1)) if row['status']=='downloading' and FORMAT_COUNT.search(text) else 1
    if formats>1:
        passes=min(sum(1 for a,b in zip(times,times[1:]) if b<a-1),formats-1)
        rest=0.15/(formats-1)
        overall=(0.85+(passes-1)*rest if passes else 0)+(rest if passes else 0.85)*current
    else:overall=current
    key=row['status'];previous=LASTPROG.get(row['id'])  # an automatic retry restarts ffmpeg; keep the bar where it was
    if previous and previous[0]==key:overall=max(overall,previous[1])
    LASTPROG[row['id']]=(key,overall)
    result['fraction']=round(min(overall,0.99),4)
    speed=FFMPEG_SPEED.findall(text)
    if speed and float(speed[-1])>0.05:result['eta']=round(max(total-times[-1],0)/float(speed[-1]))
    return result

_ENCODERS=None
def video_encoders():
    """H.264 encoder settings, fastest first. A Mac's VideoToolbox encoder is several times quicker than
    libx264; libx264 stays as the fallback (other systems, or if the hardware encoder fails)."""
    global _ENCODERS
    if _ENCODERS is None:
        software=['-c:v','libx264','-preset','fast','-crf','23']
        _ENCODERS=[software]
        if sys.platform=='darwin':
            try:
                found='h264_videotoolbox' in subprocess.run(['ffmpeg','-hide_banner','-encoders'],capture_output=True,text=True,timeout=20).stdout
            except (OSError,subprocess.SubprocessError):found=False
            if found:_ENCODERS.insert(0,['-c:v','h264_videotoolbox','-b:v','2800k','-maxrate','4M','-profile:v','high'])
    return _ENCODERS

def encode_mp4(id,source,output,start=None,length=None):
    """Re-encodes to a laptop-compatible H.264/AAC MP4, falling back to software if hardware encoding fails."""
    encoders=video_encoders()
    for i,codec in enumerate(encoders):
        args=['ffmpeg','-y']+(['-ss',str(start)] if start is not None else [])+['-i',str(source)]+(['-t',str(length)] if length is not None else [])
        args+=codec+['-pix_fmt','yuv420p','-c:a','aac','-movflags','+faststart',str(output)]
        try:return run(id,args)
        except RuntimeError as e:
            Path(output).unlink(missing_ok=True)
            if i==len(encoders)-1 or str(e)=='Cancelled':raise

def downloaded_source(folder):
    """The merged yt-dlp output, never a leftover per-format fragment."""
    files=[p for p in folder.glob('source.*') if p.is_file() and p.suffix not in ('.part','.ytdl','.tmp') and not re.search(r'\.(?:part|temp)',p.name)]
    merged=[p for p in files if re.fullmatch(r'source\.[A-Za-z0-9]+',p.name)]
    if merged:return sorted(merged,key=lambda p:(p.suffix!='.mp4',p.name))[0]
    if len(files)==1:return files[0]
    raise RuntimeError('No complete video file was produced' if not files else 'The download produced separate video/audio parts that were not merged. Retry the download.')

# Only content problems are permanent. HTTP 403s on signed media URLs
# (googlevideo, CDN tokens) are routinely temporary; a new attempt re-extracts
# fresh URLs.
PERMANENT=re.compile(r'Private video|Video unavailable|This video is unavailable|is not available|Sign in to confirm your age|members-only|Unsupported URL|DRM protected|Requested format is not available',re.I)
RETRY_DELAYS=(5,15)

def download_with_retries(id,folder,args,check):
    # Section downloads go through ffmpeg, which yt-dlp's --retries does not
    # cover; a brief media-server error would otherwise fail the whole job.
    for attempt in range(len(RETRY_DELAYS)+1):
        # A failed attempt can leave per-format fragments (source.f399.mp4
        # has no audio) or an interval from other settings.
        for stale in folder.glob('source.*'):stale.unlink(missing_ok=True)
        try:return run(id,args)
        except RuntimeError as e:
            check()
            if attempt==len(RETRY_DELAYS) or PERMANENT.search(str(e)):raise
            update(id,detail=f'Download interrupted. Retrying automatically ({attempt+2}/{len(RETRY_DELAYS)+1})…')
            for _ in range(RETRY_DELAYS[attempt]*2):time.sleep(.5);check()

def process_clip(id):
    folder=DATA/id; folder.mkdir(exist_ok=True)
    try:
        with db() as c: row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
        if not shutil.which('ffmpeg'): raise RuntimeError('FFmpeg is missing. See README for installation.')
        def check():
            with LOCK,db() as c: current=c.execute('SELECT status FROM clips WHERE id=?',(id,)).fetchone()
            if not current or current['status']=='cancelled':raise RuntimeError('Cancelled')
        with LOCK:
            if row['status']!='queued':return
            update(id,status='downloading',detail='Preparing the recording…')
        mode=row.get('clip_mode') or 'fixed'
        source_start=row.get('source_start') or 0
        if mode=='reviewed':
            source=folder/'review.mp4'
            if not source.exists():raise RuntimeError('The review recording is missing. Queue the match again.')
            relative_start=max(0,row['start']-source_start);relative_end=row['end']-source_start
        else:
            settings=json.loads(row.get('detect_settings') or '{}')
            dynamic=mode=='dynamic'
            source_start=max(0,settings.get('anchor',row['start'])-90) if dynamic else row['start']
            source_end=settings.get('anchor',row['start'])+settings.get('window',480) if dynamic else row['end']
            update(id,source_start=source_start,status='downloading',detail='Downloading a wider window for actual match detection…' if dynamic else 'Downloading selected interval…')
            # A failed earlier attempt can leave per-format fragments
            # (source.f399.mp4 has no audio) or an interval from other settings.
            args=[sys.executable,'-m','yt_dlp','--no-playlist','--no-warnings','--newline','--retries','3','--socket-timeout','30','--js-runtimes','node','-f','bv*[height<=720][vcodec^=avc1][fps<=30]+ba[ext=m4a]/bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/b','--merge-output-format','mp4','--download-sections',f"*{source_start}-{source_end}",'--force-keyframes-at-cuts','-o',str(folder/'source.%(ext)s'),'--',boxcast(row['url'])]
            download_with_retries(id,folder,args,check)
            source=downloaded_source(folder);check()
            relative_start=0;relative_end=row['end']-row['start']
            if dynamic:
                update(id,status='analyzing',detail='Reading the on-screen match clock. Following autonomous, the pause, and driver control…')
                try:
                    result=analyze(source,folder,settings['anchor']-source_start,settings.get('label',''),settings.get('format','two-phase'),lambda args:run(id,args),check,settings.get('lead',5),settings.get('tail',5))
                except Exception as e:
                    check();result={'confidence':'review','reason':str(e)[-500:]}
                check()
                result['source_start']=source_start
                result['source_duration']=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(source)]))
                update(id,analysis_json=json.dumps(result))
                if result.get('confidence')!='high':
                    update(id,status='processing',detail='Preparing a review window. No final match clip has been marked ready.')
                    if source.suffix=='.mp4':source.replace(folder/'review.mp4')
                    else:encode_mp4(id,source,folder/'review.mp4')
                    check();update(id,status='needs_review',detail=result.get('reason','Check the actual match bounds before saving.'))
                    return
                relative_start=result['start'];relative_end=result['end']
                update(id,start=source_start+relative_start,end=source_start+relative_end)
        check();update(id,status='processing',detail='Trimming to the actual match boundaries…' if mode!='fixed' else 'Preparing a laptop-compatible MP4…')
        encode_mp4(id,source,folder/'clip.tmp.mp4',relative_start,relative_end-relative_start)
        with LOCK:
            check();(folder/'clip.tmp.mp4').replace(folder/'clip.mp4')
            detail='Saved on this laptop'
            if mode=='dynamic':detail='Detected actual match bounds · '+str(round(result.get('pause',0)))+'s autonomous-to-driver pause · saved offline'
            elif mode=='reviewed':detail='Reviewed match bounds · saved offline'
            update(id,status='ready',detail=detail)
        for file in folder.glob('source.*'):file.unlink(missing_ok=True)
        (folder/'review.mp4').unlink(missing_ok=True)
    except Exception as e:
        with LOCK, db() as c:
            row=c.execute('SELECT status FROM clips WHERE id=?',(id,)).fetchone()
            if row and row['status']!='cancelled': update(id,status='failed',detail=str(e)[-1800:])

def worker(id):
    """Runs one job. The queue loop has already claimed it in BUSY."""
    try: process_clip(id)
    finally:
        with LOCK: BUSY.discard(id)

ACTIVE_STATUSES=('queued','downloading','analyzing','processing')
QUIT_WHEN_IDLE=threading.Event()
MANAGED=os.environ.get('MATCH_DOWNLOADER_MANAGED')=='1'  # started by the Mac app

def active_jobs():
    with db() as c: return c.execute("SELECT COUNT(*) FROM clips WHERE status IN (%s)"%','.join('?'*len(ACTIVE_STATUSES)),ACTIVE_STATUSES).fetchone()[0]

def idle_exit_watch(server):
    """After the Mac app quits, keep downloading, then exit once nothing is left to do."""
    while True:
        time.sleep(1)
        if QUIT_WHEN_IDLE.is_set() and not active_jobs():
            server.shutdown(); return

def parallel_limit():
    try:return max(1,min(4,int(os.environ.get('MATCH_DOWNLOADER_PARALLEL','2'))))
    except ValueError:return 2
MAX_PARALLEL=parallel_limit()  # downloads running at the same time

def queue_loop(stop=None):
    while not (stop and stop.is_set()):
        started=False
        with LOCK: free=MAX_PARALLEL-len(BUSY)
        if free>0:
            with db() as c: rows=c.execute("SELECT id FROM clips WHERE status='queued' ORDER BY created LIMIT ?",(MAX_PARALLEL,)).fetchall()
            for row in rows:
                with LOCK:
                    if len(BUSY)>=MAX_PARALLEL:break
                    if row['id'] in BUSY:continue
                    BUSY.add(row['id']);LASTPROG.pop(row['id'],None)
                threading.Thread(target=worker,args=(row['id'],),daemon=True).start();started=True
        if not started:time.sleep(.5)

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
        # Redesign prototype (Match Downloader): same API, separate files.
        # Pages: the macOS 27 interface is the default; earlier interfaces stay available.
        prototype={'/next/app.js':('web/next/app.js','text/javascript'),'/next/app.css':('web/next/app.css','text/css'),'/mac/app.js':('web/mac/app.js','text/javascript'),'/mac/app.css':('web/mac/app.css','text/css')}
        if path in prototype:
            file,kind=prototype[path];b=(ROOT/file).read_bytes();self.send_response(200);self.send_header('Content-Type',kind+'; charset=utf-8');self.send_header('Content-Length',str(len(b)));self.send_header('Cache-Control','no-cache');self.end_headers();self.wfile.write(b);return
        pages={'/embed/preview':'web/embed/preview.html','/':'web/mac/index.html','/mac':'web/mac/index.html','/mac/':'web/mac/index.html','/next':'web/next/index.html','/next/':'web/next/index.html','/classic':'web/index.html','/classic/':'web/index.html'}
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
                        info=ydl.extract_info(boxcast(source_url(body.get('url',''))),download=False)
                    resolved=info.get('url')
                    if not resolved:raise ValueError('This source has no browser-compatible preview. Download the match to watch it locally.')
                    return self.json({'url':source_url(resolved)})
                except DownloadError:
                    return self.json({'error':'The recording could not be prepared for preview. Check that it is publicly accessible.'},400)
            if path=='/api/events/auto-time':
                return self.json(EVENTS.auto_time(body.get('sku',''),body.get('search',True) is not False))
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
                    prepared.append((uuid.uuid4().hex,event['name']+' · '+m['division']+' · '+m['label'],url,start,end,notes,'queued','Waiting in queue',time.time(),event['sku'],key,mode,json.dumps({'anchor':max(0,seconds(m['timestamp'])+offset),'lead':before,'tail':tail,'window':window,'label':m['label'],'format':match_format(event)})))
                added=[];skipped=[]
                with LOCK,db() as c:
                    for item in prepared:
                        existing=c.execute("SELECT id FROM clips WHERE event_ref=? AND match_ref=? AND status!='cancelled'",(item[9],item[10])).fetchone()
                        if existing:skipped.append(item[10]);continue
                        c.execute('INSERT INTO clips(id,title,url,start,end,notes,status,detail,created,event_ref,match_ref,clip_mode,detect_settings) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',item);added.append(item[0])
                return self.json({'added':added,'skipped':skipped},201)
            if path=='/api/clips':
                url=source_url(body.get('url','')); start=seconds(body.get('start')); end=seconds(body.get('end'))
                if end<=start or end-start>3600: raise ValueError('Choose a clip between 1 second and 1 hour')
                title=str(body.get('title','')).strip()[:200]
                if not title: raise ValueError('Enter a match name')
                id=uuid.uuid4().hex
                with LOCK,db() as c: c.execute('INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES(?,?,?,?,?,?,?,?,?)',(id,title,url,start,end,str(body.get('notes',''))[:10000],'queued','Waiting in queue',time.time()))
                return self.json({'id':id},201)
            m=re.fullmatch(r'/api/clips/([a-f0-9]{32})/(retry|cancel|delete|notes|bounds)',path)
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
                elif action=='notes': update(id,notes=str(body.get('notes',''))[:10000])
                elif action=='retry':
                    if id in BUSY: raise ValueError('Worker is stopping. Retry in a moment.')
                    if row['status'] not in ('failed','cancelled'): raise ValueError('Only failed or cancelled downloads can be retried')
                    update(id,status='queued',detail='Waiting in queue')
                elif action in ('cancel','delete'):
                    if action=='delete' and (id in BUSY or row['status'] in ('queued','downloading','analyzing','processing')): raise ValueError('Cancel first; wait for the worker to stop before deleting')
                    if id in PROCESSES:
                        terminate(PROCESSES[id])
                    update(id,status='cancelled',detail='Cancelled')
                    if action=='delete':
                        shutil.rmtree(DATA/id,ignore_errors=True)
                        with db() as c: c.execute('DELETE FROM clips WHERE id=?',(id,))
            return self.json({'ok':True})
        except (ValueError,TypeError,KeyError) as e: return self.json({'error':str(e)},400)
        except Exception: return self.json({'error':'Local operation failed'},500)

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--port',type=int,default=8766); p.add_argument('--no-browser',action='store_true'); args=p.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    write_token_file()
    threading.Thread(target=queue_loop,daemon=True).start()
    threading.Thread(target=idle_exit_watch,args=(server,),daemon=True).start()
    url=f'http://127.0.0.1:{server.server_port}'
    print('Match Downloader running at '+url+'\nLibrary: '+str(DATA),flush=True)
    if not args.no_browser: webbrowser.open(url)
    def stop_server(*_):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop_server)
    try: server.serve_forever()
    except KeyboardInterrupt:
        with LOCK:
            for proc in PROCESSES.values(): terminate(proc)
    finally: remove_token_file()
