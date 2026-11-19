"""Match Downloader engine: library settings, database, and the download and encode pipeline."""
import json, os, re, secrets, shutil, signal, sqlite3, subprocess, sys, threading, time
from pathlib import Path
from urllib.parse import urlparse
from events import Events
from boundaries import analyze
from event_streams import media_url

ROOT = Path(__file__).resolve().parent
# MATCH_DOWNLOADER_DATA moves the library.
DATA = Path(os.environ.get('MATCH_DOWNLOADER_DATA') or ROOT / 'library').resolve()
DATA.mkdir(parents=True, exist_ok=True)
EVENTS = Events(DATA)
# The native app reads this token from <library>/.session-token; MATCH_DOWNLOADER_TOKEN overrides it.
TOKEN = os.environ.get('MATCH_DOWNLOADER_TOKEN') or secrets.token_hex(24)
TOKEN_FILE = DATA / '.session-token'
API_VERSION = 3  # bump when the Mac app needs a newer engine (2: archive/remove events, quit-when-idle; 3: livestream shift)

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
    # A trim or extension that was interrupted leaves the saved video as it was.
    for r in c.execute("SELECT id,detect_settings FROM clips WHERE clip_mode='adjust' AND status IN ('queued','downloading','processing')").fetchall():
        try:previous=json.loads(r['detect_settings'] or '{}').get('adjust') or {}
        except ValueError:previous={}
        if previous:c.execute("UPDATE clips SET start=?,end=?,clip_mode=?,detect_settings=?,status='ready',detail='Adjustment interrupted. The saved video is unchanged.' WHERE id=?",(previous.get('start'),previous.get('end'),previous.get('mode'),previous.get('detect'),r['id']))
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
LOGSEEN={}  # job id -> what has been read of the running step's log so far (see log_progress)
PROGLOCK=threading.Lock()
def log_progress(id):
    """ffmpeg's latest progress for the running step, reading only what was added to job.log since the last call
    (the library is polled every few seconds, and a long download's log grows to megabytes).
    {'time': seconds or None, 'passes': times the clock restarted, 'formats': yt-dlp format count, 'speed': x} or None."""
    log=DATA/id/'job.log';start=LOGPOS.get(id,0)
    with PROGLOCK:
        try:size=log.stat().st_size
        except OSError:return None
        seen=LOGSEEN.get(id)
        # A new step (or a log that was replaced) starts over; a first read looks at most 2 MB back.
        if not seen or seen['start']!=start or size<seen['pos']:
            seen=LOGSEEN[id]={'start':start,'pos':max(start,size-2000000),'carry':b'','time':None,'passes':0,'formats':None,'speed':None}
        if size>seen['pos']:
            try:
                with open(log,'rb') as f:f.seek(seen['pos']);data=seen['carry']+f.read(size-seen['pos'])
            except OSError:return None
            seen['pos']=size
            # Keep an unfinished last line for next time, so a progress line is never read in two halves.
            cut=max(data.rfind(b'\r'),data.rfind(b'\n'))+1
            seen['carry']=data[cut:][-4096:];text=data[:cut].decode('utf-8','replace')
            for h,m,sec in FFMPEG_TIME.findall(text):
                t=int(h)*3600+int(m)*60+float(sec)
                if seen['time'] is not None and t<seen['time']-1:seen['passes']+=1
                seen['time']=t
            if seen['formats'] is None and (found:=FORMAT_COUNT.search(text)):seen['formats']=int(found.group(1))
            if speed:=FFMPEG_SPEED.findall(text):seen['speed']=float(speed[-1])
        return dict(seen)

LASTPROG={}  # job id -> (log position, status, fraction): progress never moves backwards within a step
def job_progress(row):
    """How far the running download or encode has got, from ffmpeg's own progress lines.
    {'fraction': 0-1 or None, 'eta': seconds or None}. Reading the on-screen clock has no known length.
    yt-dlp fetches video and audio as separate passes, each counting from zero, so passes are combined:
    the video (about 85% of the work) first, then the audio."""
    if row['status'] not in ('downloading','processing'):
        LASTPROG.pop(row['id'],None)
        with PROGLOCK:LOGSEEN.pop(row['id'],None)
        return None
    try:settings=json.loads(row.get('detect_settings') or '{}')
    except ValueError:settings={}
    if row.get('clip_mode')=='dynamic' and (row['status']=='downloading' or str(row.get('detail','')).startswith('Preparing a review')):
        total=settings.get('anchor',row['start'])+settings.get('window',480)-(row.get('source_start') or 0)
    else:total=row['end']-row['start']
    result={'fraction':None,'eta':None}
    seen=log_progress(row['id'])
    if not seen or seen['time'] is None or total<=0:return result
    current=min(seen['time']/total,1)
    formats=seen['formats'] if row['status']=='downloading' and seen['formats'] else 1
    if formats>1:
        passes=min(seen['passes'],formats-1)
        rest=0.15/(formats-1)
        overall=(0.85+(passes-1)*rest if passes else 0)+(rest if passes else 0.85)*current
    else:overall=current
    key=row['status'];previous=LASTPROG.get(row['id'])  # an automatic retry restarts ffmpeg; keep the bar where it was
    if previous and previous[0]==key:overall=max(overall,previous[1])
    LASTPROG[row['id']]=(key,overall)
    result['fraction']=round(min(overall,0.99),4)
    if seen['speed'] and seen['speed']>0.05:result['eta']=round(max(total-seen['time'],0)/seen['speed'])
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
PERMANENT=re.compile(r'only works when logged-in|HTTP Error 401|Private video|Video unavailable|This video is unavailable|is not available|Sign in to confirm your age|members-only|Unsupported URL|DRM protected|Requested format is not available',re.I)
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

def section_args(folder,url,start,end):
    """yt-dlp arguments for downloading one section of a recording to folder/source.*"""
    return [sys.executable,'-m','yt_dlp','--no-playlist','--no-warnings','--newline','--retries','3','--socket-timeout','30','--js-runtimes','node',
            '-f','bv*[height<=720][vcodec^=avc1][fps<=30]+ba[ext=m4a]/bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/b',
            '--merge-output-format','mp4','--download-sections',f"*{start}-{end}",'--force-keyframes-at-cuts',
            '-o',str(folder/'source.%(ext)s'),'--',media_url(url)]

def process_adjust(id,row):
    """Trim or extend a saved clip. Inside the old range the saved file is cut; beyond it, the wider range is
    downloaded again. The old file stays until the new one is complete, and a failure puts everything back."""
    folder=DATA/id;settings=json.loads(row.get('detect_settings') or '{}');old=settings.get('adjust') or {}
    new_start,new_end=row['start'],row['end']
    def check():
        with LOCK,db() as c: current=c.execute('SELECT status FROM clips WHERE id=?',(id,)).fetchone()
        if not current or current['status']=='cancelled':raise RuntimeError('Cancelled')
    def restore(note):
        update(id,start=old.get('start',new_start),end=old.get('end',new_end),clip_mode=old.get('mode'),detect_settings=old.get('detect'),status='ready',detail=note)
    try:
        saved=folder/'clip.mp4'
        if not saved.exists():raise RuntimeError('The saved video is missing, so it cannot be adjusted.')
        out=folder/'clip.tmp.mp4'
        if new_start>=old['start'] and new_end<=old['end']:
            with LOCK:
                check();update(id,status='processing',detail='Trimming the saved video…')
            encode_mp4(id,saved,out,new_start-old['start'],new_end-new_start)
        else:
            with LOCK:
                check();update(id,status='downloading',detail='Downloading the longer clip…')
            download_with_retries(id,folder,section_args(folder,row['url'],new_start,new_end),check)
            source=downloaded_source(folder);check()
            with LOCK:
                check();update(id,status='processing',detail='Preparing a laptop-compatible MP4…')
            encode_mp4(id,source,out,None,new_end-new_start)
        with LOCK:
            check();out.replace(saved)
            update(id,clip_mode=old.get('mode'),detect_settings=old.get('detect'),status='ready',detail='Adjusted · saved offline')
        for file in folder.glob('source.*'):file.unlink(missing_ok=True)
    except Exception as e:
        (folder/'clip.tmp.mp4').unlink(missing_ok=True)
        for file in folder.glob('source.*'):file.unlink(missing_ok=True)
        cancelled=str(e)=='Cancelled'
        restore('Adjustment cancelled. The saved video is unchanged.' if cancelled else 'Adjustment failed, so the saved video is unchanged: '+str(e)[-300:])

def process_clip(id):
    folder=DATA/id; folder.mkdir(exist_ok=True)
    try:
        if not shutil.which('ffmpeg'): raise RuntimeError('FFmpeg is missing. See README for installation.')
        def check():
            with LOCK,db() as c: current=c.execute('SELECT status FROM clips WHERE id=?',(id,)).fetchone()
            if not current or current['status']=='cancelled':raise RuntimeError('Cancelled')
        with LOCK:
            with db() as c: row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
            if row['status']!='queued':return
            if row.get('clip_mode')=='adjust':update(id,status='processing',detail='Preparing the adjustment…')
            else:update(id,status='downloading',detail='Preparing the recording…')
        mode=row.get('clip_mode') or 'fixed'
        if mode=='adjust':return process_adjust(id,row)
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
            args=section_args(folder,row['url'],source_start,source_end)
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
                    with PROGLOCK:LOGSEEN.pop(row['id'],None)
                threading.Thread(target=worker,args=(row['id'],),daemon=True).start();started=True
        if not started:time.sleep(.5)
