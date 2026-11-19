import importlib.util, json, os, shutil, subprocess, sys, tempfile, threading, unittest
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
TMP=tempfile.TemporaryDirectory(); os.environ['MATCH_DOWNLOADER_DATA']=TMP.name+'/library'
spec=importlib.util.spec_from_file_location('vault',Path(__file__).resolve().parents[1]/'app.py'); app=importlib.util.module_from_spec(spec); spec.loader.exec_module(app)
import jobs, server  # loaded by jobs.py: the engine and its HTTP API
jobs.RETRY_DELAYS=(0,0)
from contextlib import contextmanager
@contextmanager
def patch_env(value):
    old=os.environ.get('MATCH_DOWNLOADER_PARALLEL');os.environ['MATCH_DOWNLOADER_PARALLEL']=value
    try:yield
    finally:
        if old is None:os.environ.pop('MATCH_DOWNLOADER_PARALLEL',None)
        else:os.environ['MATCH_DOWNLOADER_PARALLEL']=old
def uuid_hex():
    import uuid;return uuid.uuid4().hex
class Quiet(SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),server.Handler); threading.Thread(target=cls.server.serve_forever,daemon=True).start(); cls.base='http://127.0.0.1:'+str(cls.server.server_port)
    @classmethod
    def tearDownClass(cls): cls.server.shutdown(); cls.server.server_close()
    def post(self,path,data):
        with urlopen(Request(self.base+path,data=json.dumps(data).encode(),headers={'X-Scout-Token':jobs.TOKEN,'Content-Type':'application/json'})) as r:return json.load(r)
    def test_validation(self):
        self.assertEqual(jobs.seconds('1:02:03'),3723)
        for value in ('-1','nan','inf','1:2:3:4'):
            with self.assertRaises(ValueError): jobs.seconds(value)
        for value in ('file:///etc/passwd','https://user:pass@example.com/x'):
            with self.assertRaises(ValueError):jobs.source_url(value)
        with self.assertRaises(HTTPError) as e:self.post('/api/clips',{'title':'x','url':'https://example.com/a','start':10,'end':5})
        self.assertEqual(e.exception.code,400)
    def test_non_object_body_is_rejected(self):
        for body in (b'[1,2]',b'"x"',b'null',b'{bad'):
            with self.assertRaises(HTTPError) as e:urlopen(Request(self.base+'/api/clips',data=body,headers={'X-Scout-Token':jobs.TOKEN,'Content-Type':'application/json'}))
            self.assertEqual(e.exception.code,400);self.assertIn('JSON object',json.load(e.exception)['error'])
    def test_downloaded_source_ignores_fragments(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            for name in ('source.f399.mp4','source.f140.m4a','source.mp4.part'):(folder/name).write_bytes(b'x')
            with self.assertRaises(RuntimeError):jobs.downloaded_source(folder)
            (folder/'source.mp4').write_bytes(b'x');self.assertEqual(jobs.downloaded_source(folder).name,'source.mp4')
            only=Path(tmp)/'one';only.mkdir();(only/'source.webm').write_bytes(b'x');self.assertEqual(jobs.downloaded_source(only).name,'source.webm')
    def test_health_reports_api_version(self):
        with urlopen(Request(self.base+'/api/health')) as r:info=json.load(r)
        self.assertEqual(info['api'],jobs.API_VERSION)
    def test_token_file_lifecycle(self):
        with tempfile.TemporaryDirectory() as tmp:
            env=dict(os.environ,MATCH_DOWNLOADER_DATA=tmp);env.pop('MATCH_DOWNLOADER_TOKEN',None)
            proc=subprocess.Popen([sys.executable,str(Path(app.__file__)),'--port','0','--no-browser'],env=env,stdout=subprocess.PIPE,text=True)
            try:
                first=proc.stdout.readline();self.assertIn('running at',first)
                token_file=Path(tmp)/'.session-token';self.assertTrue(token_file.exists())
                self.assertEqual(token_file.stat().st_mode&0o777,0o600)
                token=token_file.read_text();self.assertGreaterEqual(len(token),32)
                base=first.split('running at ')[1].strip()
                with urlopen(base+'/api/health') as r:self.assertEqual(json.load(r)['api'],jobs.API_VERSION)
                with urlopen(Request(base+'/')) as r:self.assertIn(token,r.read().decode())
                proc.terminate();proc.wait(timeout=10)
                self.assertFalse(token_file.exists())
            finally:
                if proc.poll() is None:proc.kill()
                proc.stdout.close()
    def test_quit_when_idle_ignored_for_unmanaged_engine(self):
        r=self.post('/api/quit-when-idle',{'enabled':True})
        self.assertFalse(r['scheduled']);self.assertFalse(jobs.QUIT_WHEN_IDLE.is_set())
    def test_managed_engine_finishes_downloads_then_exits(self):
        import sqlite3, time
        from urllib.request import urlopen as uo
        with tempfile.TemporaryDirectory() as tmp:
            env=dict(os.environ,MATCH_DOWNLOADER_DATA=tmp,MATCH_DOWNLOADER_MANAGED='1');env.pop('MATCH_DOWNLOADER_TOKEN',None)
            proc=subprocess.Popen([sys.executable,str(Path(app.__file__)),'--port','0','--no-browser'],env=env,stdout=subprocess.PIPE,text=True)
            try:
                port=int(proc.stdout.readline().split('running at http://127.0.0.1:')[1].split()[0])
                token=(Path(tmp)/'.session-token').read_text()
                def call(enabled):
                    req=Request(f'http://127.0.0.1:{port}/api/quit-when-idle',data=json.dumps({'enabled':enabled}).encode(),headers={'X-Scout-Token':token,'Content-Type':'application/json'})
                    with uo(req) as r:return json.load(r)
                db=sqlite3.connect(Path(tmp)/'library.sqlite')
                db.execute("INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES('a','t','https://example.com/a',0,5,'','downloading','',0)");db.commit()
                self.assertEqual(call(True),{'scheduled':True,'active':1})
                time.sleep(2.5);self.assertIsNone(proc.poll(),'must keep running while a download is active')
                self.assertFalse(call(False)['scheduled'])
                self.assertTrue(call(True)['scheduled'])
                db.execute("UPDATE clips SET status='ready' WHERE id='a'");db.commit()
                self.assertEqual(proc.wait(timeout=10),0)
                self.assertFalse((Path(tmp)/'.session-token').exists())
            finally:
                if proc.poll() is None: proc.terminate()
                proc.stdout.close(); proc.wait()
    def test_archive_and_remove_saved_event(self):
        sku='VE-V5-26-00001';other='VE-V5-26-00002'
        jobs.EVENTS.write('catalogue',[{'sku':other,'name':'Preset','divisions':{}}])
        for k,n in ((sku,'Mine'),(other,'Preset')):jobs.EVENTS.write(k,{'sku':k,'name':n,'divisions':[],'matches':[]})
        def listing():return {e['sku']:e for e in self.post('/api/events/catalogue',{})['events']}
        self.assertFalse(listing()[sku]['archived'])
        self.assertTrue(self.post('/api/events/archive',{'sku':sku,'archived':True})['archived'])
        self.assertTrue(listing()[sku]['archived']);self.assertTrue(listing()[sku]['saved'])
        self.assertTrue(jobs.EVENTS.read(sku))  # still available offline
        self.post('/api/events/archive',{'sku':sku,'archived':False});self.assertFalse(listing()[sku]['archived'])
        # removing deletes the saved schedule; a preset returns to the catalogue, a custom event disappears
        self.post('/api/events/archive',{'sku':other,'archived':True})
        self.post('/api/events/remove',{'sku':other})
        self.assertIsNone(jobs.EVENTS.read(other));self.assertFalse(listing()[other]['saved']);self.assertFalse(listing()[other]['archived'])
        self.post('/api/events/remove',{'sku':sku});self.assertNotIn(sku,listing())
        for path in ('/api/events/archive','/api/events/remove'):
            with self.assertRaises(HTTPError) as e:self.post(path,{'sku':sku})
            self.assertEqual(e.exception.code,400)
    def test_encode_falls_back_to_software_when_hardware_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            src=Path(tmp)/'in.mp4'
            subprocess.run(['ffmpeg','-y','-loglevel','error','-f','lavfi','-i','testsrc=size=320x180:rate=15','-f','lavfi','-i','sine','-t','2','-pix_fmt','yuv420p',str(src)],check=True)
            (jobs.DATA/'enc1').mkdir(exist_ok=True)
            with jobs.db() as c: c.execute("INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES('enc1','t','u',0,1,'','processing','',0)")
            saved=jobs._ENCODERS
            try:
                jobs._ENCODERS=[['-c:v','no_such_encoder'],['-c:v','libx264','-preset','ultrafast']]
                out=Path(tmp)/'out.mp4';jobs.encode_mp4('enc1',src,out,0.5,1)
                info=subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=codec_name','-of','csv=p=0',str(out)],text=True).strip()
                self.assertEqual(info,'h264')
                jobs._ENCODERS=[['-c:v','no_such_encoder']]
                with self.assertRaises(RuntimeError):jobs.encode_mp4('enc1',src,Path(tmp)/'bad.mp4')
                self.assertFalse((Path(tmp)/'bad.mp4').exists())
            finally:jobs._ENCODERS=saved
    def test_video_encoders_always_end_with_software(self):
        self.assertIn('libx264',jobs.video_encoders()[-1])
    def test_job_progress_reads_only_the_running_step(self):
        folder=jobs.DATA/'prog1';folder.mkdir(exist_ok=True)
        log=folder/'job.log'
        log.write_text('frame=1 time=00:02:00.00 speed=2x\r')  # an earlier, finished step
        jobs.LOGPOS['prog1']=log.stat().st_size
        row={'id':'prog1','status':'downloading','clip_mode':'fixed','start':0,'end':120,'detail':'','detect_settings':'','source_start':0}
        self.assertEqual(jobs.job_progress(row),{'fraction':None,'eta':None})  # new step hasn't reported yet
        with open(log,'a') as f:f.write('frame=9 time=00:00:30.00 bitrate=1k speed=1.5x\rframe=10 time=00:00:60.00 bitrate=1k speed=1.5x\r')
        self.assertEqual(jobs.job_progress(row),{'fraction':0.5,'eta':40})
        self.assertIsNone(jobs.job_progress(dict(row,status='analyzing')))
        jobs.LASTPROG.pop('prog1',None)
        dynamic=dict(row,clip_mode='dynamic',source_start=100,detect_settings=json.dumps({'anchor':190,'window':480}))
        self.assertEqual(jobs.job_progress(dynamic)['fraction'],round(60/570,4))
    def test_job_progress_combines_video_and_audio_passes_and_never_goes_backwards(self):
        folder=jobs.DATA/'prog4';folder.mkdir(exist_ok=True);log=folder/'job.log'
        log.write_text('');jobs.LOGPOS['prog4']=0;jobs.LASTPROG.pop('prog4',None)
        row={'id':'prog4','status':'downloading','clip_mode':'fixed','start':0,'end':100,'detail':'','detect_settings':'','source_start':0}
        def add(text):
            with open(log,'a') as f:f.write(text)
        add('[info] x: Downloading 2 format(s): 136+140\nframe=1 time=00:00:50.00 speed=1x\r')
        self.assertEqual(jobs.job_progress(row)['fraction'],0.425)            # half of the video pass
        add('frame=2 time=00:01:40.00 speed=1x\r')
        self.assertEqual(jobs.job_progress(row)['fraction'],0.85)             # video done
        add('frame=3 time=00:00:10.00 speed=9x\r')                           # the audio pass counts from zero again
        self.assertEqual(jobs.job_progress(row)['fraction'],0.865)
        add('frame=4 time=00:00:05.00 speed=9x\r')                           # a glitch must not move the bar back
        self.assertEqual(jobs.job_progress(row)['fraction'],0.865)
    def test_job_progress_reads_only_new_log_output(self):
        folder=jobs.DATA/'prog5';folder.mkdir(exist_ok=True);log=folder/'job.log'
        log.write_text('');jobs.LOGPOS['prog5']=0;jobs.LASTPROG.pop('prog5',None);jobs.LOGSEEN.pop('prog5',None)
        row={'id':'prog5','status':'processing','clip_mode':'fixed','start':0,'end':100,'detail':'','detect_settings':'','source_start':0}
        def add(text):
            with open(log,'a') as f:f.write(text)
        add('frame=1 time=00:00:20.00 speed=2x\rframe=2 time=00:00:4')    # the second line is still being written
        self.assertEqual(jobs.job_progress(row),{'fraction':0.2,'eta':40})
        self.assertEqual(jobs.LOGSEEN['prog5']['pos'],log.stat().st_size)  # read up to the end, once
        add('0.00 speed=4x\r')                                              # its other half arrives
        self.assertEqual(jobs.job_progress(row),{'fraction':0.4,'eta':15})
        self.assertEqual(jobs.job_progress(row),{'fraction':0.4,'eta':15})  # nothing new: same answer
        jobs.LOGPOS['prog5']=log.stat().st_size                             # the next step starts in the same log
        self.assertEqual(jobs.job_progress(row),{'fraction':None,'eta':None})  # the new step hasn't reported yet
        self.assertIsNone(jobs.LOGSEEN['prog5']['time'])
    def test_queue_runs_two_jobs_at_once_and_no_more(self):
        import time
        from unittest.mock import patch
        ids=['par1','par2','par3','par4']
        with jobs.db() as c:
            for n,i in enumerate(ids):c.execute("INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES(?,?,?,?,?,?,?,?,?)",(i,'t','u',0,1,'','queued','',100+n))
        lock=threading.Lock();state={'now':0,'peak':0,'done':[]}
        def fake(id):
            with lock:state['now']+=1;state['peak']=max(state['peak'],state['now'])
            time.sleep(0.4)
            jobs.update(id,status='ready')
            with lock:state['now']-=1;state['done'].append(id)
        stop=threading.Event()
        with patch.object(jobs,'process_clip',fake),patch.object(jobs,'MAX_PARALLEL',2):
            thread=threading.Thread(target=jobs.queue_loop,args=(stop,),daemon=True);thread.start()
            deadline=time.time()+10
            while len(state['done'])<4 and time.time()<deadline:time.sleep(0.05)
            stop.set();thread.join(3)
        self.assertEqual(sorted(state['done']),sorted(ids));self.assertEqual(state['peak'],2)
        self.assertEqual(state['done'][:2].count('par3')+state['done'][:2].count('par4'),0)  # oldest first
    def test_parallel_limit_setting(self):
        for value,expected in (('1',1),('3',3),('9',4),('0',1),('abc',2)):
            with patch_env(value):self.assertEqual(jobs.parallel_limit(),expected)
    def test_worlds_folder_follows_season_file_and_leaves_the_general_lists(self):
        import worlds
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/'worlds.json').write_text(json.dumps({'2027':{
                'V5RC MS':{'channelId':'chan2','sku':'RE-V5RC-27-0002','eventStart':'2027-04-25','eventEnd':'2027-04-27','divisions':['Arts'],'numDays':3,'broadcastOverrides':{}},
                'V5RC HS':{'channelId':'chan1','sku':'RE-V5RC-27-0001','eventStart':'2027-04-21','eventEnd':'2027-04-24','divisions':['Arts'],'numDays':4,'broadcastOverrides':{}},
                'VURC':{'channelId':'chan3','sku':None,'eventStart':'2027-04-25','eventEnd':'2027-04-27','divisions':['Arts'],'numDays':3,'broadcastOverrides':{}}}}))
            (root/'worlds-season.json').write_text(json.dumps({'year':'2027','title':'Worlds 27'}))
            jobs.EVENTS.write('catalogue',[{'sku':'RE-V5RC-27-0001','name':'Worlds HS','divisions':{}},{'sku':'VE-V5-27-9','name':'Regional','divisions':{}}])
            with patch.object(worlds,'ROOT',root):
                season=worlds.season()
                data=self.post('/api/events/catalogue',{})
            self.assertEqual(season['title'],'Worlds 27')
            self.assertEqual([e['label'] for e in season['events']],['V5RC High School','V5RC Middle School'])  # in event order; no SKU, no entry
            self.assertEqual(data['worlds']['year'],'2027')
            self.assertNotIn('RE-V5RC-27-0001',{e['sku'] for e in data['events']})
            self.assertIn('VE-V5-27-9',{e['sku'] for e in data['events']})
            (root/'worlds-season.json').write_text(json.dumps({'year':'2099'}))
            with patch.object(worlds,'ROOT',root):self.assertIsNone(worlds.season())  # a year with no config shows no folder
    def test_quick_download_start_and_end_adjustments(self):
        sku='VE-V5-26-00077'
        jobs.EVENTS.write(sku,{'sku':sku,'name':'Adjust test','divisions':[],'matches':[
            {'key':'1:1','label':'Q1','available':True,'url':'http://127.0.0.1:9/a.mp4','timestamp':1000,'division':'Main','teams':[],'timing':'T','alliances':[]},
            {'key':'1:2','label':'Q2','available':True,'url':'http://127.0.0.1:9/a.mp4','timestamp':2000,'division':'Main','teams':[],'timing':'T','alliances':[]},
            {'key':'1:3','label':'Q3','available':True,'url':'http://127.0.0.1:9/a.mp4','timestamp':3000,'division':'Main','teams':[],'timing':'T','alliances':[]}]})
        def times(key,**extra):
            self.post('/api/events/queue',dict({'sku':sku,'keys':[key],'duration':180,'before':5},**extra))
            with jobs.db() as c:r=c.execute("SELECT start,end FROM clips WHERE match_ref=? AND event_ref=?",(key,sku)).fetchone()
            return r['start'],r['end']
        self.assertEqual(times('1:1'),(995,1175))                                              # no adjustment: as before
        self.assertEqual(times('1:2',startAdjust=-10,endAdjust=25),(1985,2200))                # 10 s earlier start, 25 s later end
        for bad in ({'startAdjust':61},{'endAdjust':121},{'endAdjust':-60,'duration':10},{'startAdjust':'x'}):
            with self.assertRaises(HTTPError) as e:self.post('/api/events/queue',dict({'sku':sku,'keys':['1:3'],'duration':180,'before':5},**bad))
            self.assertEqual(e.exception.code,400)
        # the adjustments belong to quick downloads; match detection ignores them
        self.post('/api/events/queue',{'sku':sku,'keys':['1:3'],'mode':'dynamic','startAdjust':50,'endAdjust':50})
        with jobs.db() as c:r=c.execute("SELECT start,end FROM clips WHERE match_ref='1:3' AND event_ref=?",(sku,)).fetchone()
        self.assertEqual((r['start'],r['end']),(2995,3175))
    def _ready_clip(self,tmp,seconds_long=20):
        id=uuid_hex();folder=jobs.DATA/id;folder.mkdir(parents=True,exist_ok=True)
        src=Path(tmp)/'src.mp4'
        subprocess.run(['ffmpeg','-y','-loglevel','error','-f','lavfi','-i','testsrc=size=320x180:rate=15','-f','lavfi','-i','sine','-t','60','-pix_fmt','yuv420p',str(src)],check=True)
        # the saved clip is seconds 10..10+seconds_long of a 60 s recording
        subprocess.run(['ffmpeg','-y','-loglevel','error','-ss','10','-i',str(src),'-t',str(seconds_long),'-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',str(folder/'clip.mp4')],check=True)
        with jobs.db() as c:c.execute("INSERT INTO clips(id,title,url,start,end,notes,status,detail,created,clip_mode,detect_settings) VALUES(?,?,?,?,?,?,?,?,?,?,?)",(id,'t',src.as_uri() if False else 'http://127.0.0.1:1/x.mp4',10,10+seconds_long,'','ready','Saved',1,'fixed',None))
        return id,folder
    def _duration(self,path):
        return float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(path)],text=True))
    def test_cancel_queued_adjustment_restores_saved_clip(self):
        with tempfile.TemporaryDirectory() as tmp:
            id,folder=self._ready_clip(tmp)
            before=(folder/'clip.mp4').read_bytes()
            self.post(f'/api/clips/{id}/adjust',{'start':14,'end':26})
            # A queue-loop claim can already be waiting when cancellation arrives.
            with jobs.LOCK:jobs.BUSY.add(id)
            self.post(f'/api/clips/{id}/cancel',{})
            jobs.worker(id)
            self.assertNotIn(id,jobs.BUSY)
            with jobs.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
            self.assertEqual((row['status'],row['start'],row['end'],row['clip_mode']),('ready',10,30,'fixed'))
            self.assertIsNone(row['detect_settings'])
            self.assertIn('unchanged',row['detail'])
            self.assertEqual((folder/'clip.mp4').read_bytes(),before)

    def test_manual_clip_duration_limits(self):
        for duration in (0,0.1,0.999,3600.001):
            with self.subTest(duration=duration):
                with self.assertRaises(HTTPError) as e:
                    self.post('/api/clips',{'title':'duration','url':'https://example.com/a','start':0,'end':duration})
                self.assertEqual(e.exception.code,400)
        for duration in (1,3600):
            with self.subTest(duration=duration):
                result=self.post('/api/clips',{'title':'duration','url':'https://example.com/a','start':0,'end':duration})
                self.assertIn('id',result)

    def test_adjust_trims_a_saved_clip_without_downloading(self):
        with tempfile.TemporaryDirectory() as tmp:
            id,folder=self._ready_clip(tmp)
            r=self.post(f'/api/clips/{id}/adjust',{'start':14,'end':26})
            self.assertTrue(r['ok'])
            with jobs.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
            self.assertEqual((row['status'],row['clip_mode'],row['start'],row['end']),('queued','adjust',14,26))
            jobs.worker(id)
            with jobs.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
            self.assertEqual((row['status'],row['start'],row['end'],row['clip_mode']),('ready',14,26,'fixed'))
            self.assertAlmostEqual(self._duration(folder/'clip.mp4'),12,delta=0.6)
    def test_adjust_extension_failure_keeps_the_saved_clip(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            id,folder=self._ready_clip(tmp)
            before=(folder/'clip.mp4').read_bytes()
            self.post(f'/api/clips/{id}/adjust',{'start':5,'end':40})
            with patch.object(jobs,'run',side_effect=RuntimeError('ERROR: unable to download')),patch.object(jobs,'RETRY_DELAYS',()):jobs.worker(id)
            with jobs.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
            self.assertEqual((row['status'],row['start'],row['end'],row['clip_mode']),('ready',10,30,'fixed'))
            self.assertIn('unchanged',row['detail']);self.assertEqual((folder/'clip.mp4').read_bytes(),before)
    def test_adjust_extension_downloads_the_wider_range(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            id,folder=self._ready_clip(tmp)
            wide=Path(tmp)/'wide.mp4'
            subprocess.run(['ffmpeg','-y','-loglevel','error','-f','lavfi','-i','testsrc=size=320x180:rate=15','-f','lavfi','-i','sine','-t','35','-pix_fmt','yuv420p',str(wide)],check=True)
            seen={}
            def fake_run(job,args):
                if 'yt_dlp' in args:seen['section']=[a for a in args if a.startswith('*')];shutil.copy(wide,folder/'source.mp4')
                else:subprocess.run(args,check=True,capture_output=True)
            self.post(f'/api/clips/{id}/adjust',{'start':5,'end':40})
            with patch.object(jobs,'run',side_effect=fake_run):jobs.worker(id)
            with jobs.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(id,)).fetchone())
            self.assertEqual((row['status'],row['start'],row['end']),('ready',5,40));self.assertEqual(seen['section'],['*5.0-40.0'])
            self.assertAlmostEqual(self._duration(folder/'clip.mp4'),35,delta=0.8)
    def test_adjust_rejects_bad_requests(self):
        with tempfile.TemporaryDirectory() as tmp:
            id,folder=self._ready_clip(tmp)
            for body in ({'start':12,'end':14},{'start':10,'end':30},{'start':-1000,'end':30},{'start':10,'end':700},{'start':'x','end':20}):
                with self.assertRaises(HTTPError) as e:self.post(f'/api/clips/{id}/adjust',body)
                self.assertEqual(e.exception.code,400,body)
            with jobs.db() as c:c.execute("UPDATE clips SET status='failed' WHERE id=?",(id,))
            with self.assertRaises(HTTPError) as e:self.post(f'/api/clips/{id}/adjust',{'start':12,'end':25})
            self.assertEqual(e.exception.code,400)
    def test_vimeo_event_links_point_at_the_video_not_the_event(self):
        self.assertEqual(jobs.media_url('https://vimeo.com/event/5938928/video/1193358615'),'https://vimeo.com/1193358615')
        self.assertEqual(jobs.media_url('https://vimeo.com/event/5938928/video/1193358615/abcdef1234'),'https://vimeo.com/1193358615/abcdef1234')
        self.assertEqual(jobs.media_url('https://vimeo.com/123456789/abcde'),'https://vimeo.com/123456789/abcde')
        self.assertEqual(jobs.media_url('https://vimeo.com/event/5938928'),'https://vimeo.com/event/5938928')
    def test_library_reports_progress_for_active_jobs_only(self):
        with jobs.db() as c:
            c.execute("INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES('prog2','t','u',0,10,'','downloading','',1)")
            c.execute("INSERT INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES('prog3','t','u',0,10,'','ready','',2)")
        with urlopen(Request(self.base+'/api/library')) as r:clips={x['id']:x for x in json.load(r)['clips']}
        self.assertIn('progress',clips['prog2']);self.assertNotIn('progress',clips['prog3'])
    def test_token_env_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            env=dict(os.environ,MATCH_DOWNLOADER_DATA=tmp,MATCH_DOWNLOADER_TOKEN='fixed-test-token')
            proc=subprocess.Popen([sys.executable,str(Path(app.__file__)),'--port','0','--no-browser'],env=env,stdout=subprocess.PIPE,text=True)
            try:
                proc.stdout.readline();self.assertEqual((Path(tmp)/'.session-token').read_text(),'fixed-test-token')
            finally:
                proc.terminate();proc.wait(timeout=10);proc.stdout.close()
    def test_pages_and_health(self):
        def get(path):
            with urlopen(Request(self.base+path)) as r:return r.read().decode()
        self.assertEqual(json.loads(get('/api/health'))['app'],'Match Downloader')
        home=get('/');self.assertIn('<title>Match Downloader</title>',home);self.assertIn('/mac/app.js',home);self.assertNotIn('__TOKEN__',home);self.assertIn(jobs.TOKEN,home)
        embed=get('/embed/preview');self.assertIn('/preview.js',embed);self.assertIn('messageHandlers',embed);self.assertIn(jobs.TOKEN,embed);self.assertNotIn('__TOKEN__',embed)
        for old in ('/mac','/next','/classic'):
            with self.assertRaises(HTTPError) as gone:get(old)
            self.assertEqual(gone.exception.code,404)
        self.assertIn('createPreview',get('/mac/app.js'))
    def test_data_variable_moves_library(self):
        self.assertEqual(str(jobs.DATA),str(Path(os.environ['MATCH_DOWNLOADER_DATA']).resolve()))
    def test_provider_urls(self):
        self.assertEqual(jobs.media_url('https://boxcast.tv/view/abc'), 'https://boxcast.tv/view-embed/abc')
        self.assertEqual(jobs.media_url('https://vimeo.com/123'), 'https://vimeo.com/123')
    def test_cancelled_not_started(self):
        clip=self.post('/api/clips',{'title':'Cancelled','url':'https://example.com/a.mp4','start':0,'end':3})['id']
        self.post('/api/clips/'+clip+'/cancel',{})
        jobs.worker(clip)
        with jobs.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'cancelled')
    def test_csrf(self):
        with self.assertRaises(HTTPError) as e:urlopen(Request(self.base+'/api/clips',data=b'{}'))
        self.assertEqual(e.exception.code,403)
    @unittest.skipUnless(shutil.which('ffmpeg'),'FFmpeg required')
    def test_download_offline_seek(self):
        source=Path(TMP.name)/'fixture.mp4'
        subprocess.run(['ffmpeg','-y','-f','lavfi','-i','testsrc=size=160x120:rate=10','-t','5','-c:v','libx264','-pix_fmt','yuv420p',str(source)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
        fixture=ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=TMP.name)); threading.Thread(target=fixture.serve_forever,daemon=True).start()
        clip=self.post('/api/clips',{'title':'Fixture Q42','url':f'http://127.0.0.1:{fixture.server_port}/fixture.mp4','start':1,'end':4,'notes':'123A'})['id']
        resolved=self.post('/api/preview/source',{'url':f'http://127.0.0.1:{fixture.server_port}/fixture.mp4'})
        self.assertIn('/fixture.mp4',resolved['url'])
        jobs.worker(clip);fixture.shutdown();fixture.server_close()
        with jobs.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(clip,)).fetchone())
        self.assertEqual(row['status'],'ready',row['detail'])
        with urlopen(Request(self.base+'/video/'+clip,headers={'Range':'bytes=10-29'})) as r:
            self.assertEqual(r.status,206);self.assertEqual(len(r.read()),20)
        with urlopen(Request(self.base+'/video/'+clip,headers={'Range':'bytes=-10'})) as r:self.assertEqual(len(r.read()),10)
        with self.assertRaises(HTTPError) as e:urlopen(Request(self.base+'/video/'+clip,headers={'Range':'bytes=999999999-'}))
        self.assertEqual(e.exception.code,416)
        duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(jobs.DATA/clip/'clip.mp4')]))
        self.assertAlmostEqual(duration,3,delta=.4)
        self.post('/api/clips/'+clip+'/notes',{'notes':'offline review'})
        with jobs.db() as c:self.assertEqual(c.execute('SELECT notes FROM clips WHERE id=?',(clip,)).fetchone()[0],'offline review')
    def test_event_queue(self):
        sku='RE-V5RC-25-0147'
        jobs.EVENTS.write(sku,{'sku':sku,'name':'Ignite','divisions':[], 'matches':[
            {'key':'1:67','label':'Q67','available':True,'url':'https://vimeo.com/123','timestamp':100,'division':'Volcanic','teams':['123A'],'timing':'Jumper','alliances':[]},
            {'key':'2:67','label':'Q67','available':True,'url':'https://vimeo.com/456','timestamp':200,'division':'Glacial','teams':[],'timing':'Jumper','alliances':[]},
            {'key':'1:999','label':'QF1-1','available':False}]})
        with self.assertRaises(HTTPError):self.post('/api/events/queue',{'sku':sku,'keys':['1:67','1:999']})
        with jobs.db() as c:self.assertEqual(c.execute('SELECT count(*) FROM clips WHERE event_ref=?',(sku,)).fetchone()[0],0)
        result=self.post('/api/events/queue',{'sku':sku,'keys':['1:67','2:67'],'duration':150,'before':5,'offset':2})
        self.assertEqual(len(result['added']),2)
        with jobs.db() as c:rows=list(c.execute('SELECT * FROM clips WHERE event_ref=? ORDER BY start',(sku,)))
        self.assertEqual(rows[0]['start'],97);self.assertEqual(rows[0]['end'],247)
        self.assertIn('Q67',rows[0]['title']);self.assertIn('Volcanic',rows[0]['title'])
        again=self.post('/api/events/queue',{'sku':sku,'keys':['1:67']})
        self.assertEqual(again['added'],[]);self.assertEqual(len(again['skipped']),1)
    def test_dynamic_review_and_local_trim(self):
        from unittest.mock import patch
        source=Path(TMP.name)/'review-fixture.mp4'
        subprocess.run(['ffmpeg','-y','-f','lavfi','-i','testsrc=size=160x120:rate=10','-t','5','-c:v','libx264','-pix_fmt','yuv420p',str(source)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
        fixture=ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=TMP.name));threading.Thread(target=fixture.serve_forever,daemon=True).start()
        sku='RE-V5RC-25-9999'
        jobs.EVENTS.write(sku,{'sku':sku,'name':'Review test','matches':[{'key':'1:1','label':'Q1','available':True,'url':f'http://127.0.0.1:{fixture.server_port}/review-fixture.mp4','timestamp':1,'division':'Main','teams':[],'timing':'Test','alliances':[]}]})
        queued=self.post('/api/events/queue',{'sku':sku,'keys':['1:1'],'mode':'dynamic'})
        clip=queued['added'][0]
        with patch.object(jobs,'analyze',return_value={'confidence':'review','reason':'No readable timer'}):jobs.worker(clip)
        jobs.EVENTS.write(sku,{'sku':sku,'name':'Detected test','matches':[{'key':'1:2','label':'Q2','available':True,'url':f'http://127.0.0.1:{fixture.server_port}/review-fixture.mp4','timestamp':1,'division':'Main','teams':[],'timing':'Test','alliances':[]}]})
        auto=self.post('/api/events/queue',{'sku':sku,'keys':['1:2'],'mode':'dynamic'})['added'][0]
        with patch.object(jobs,'analyze',return_value={'confidence':'high','start':1,'end':3,'pause':31}):jobs.worker(auto)
        with jobs.db() as c:detected=c.execute('SELECT * FROM clips WHERE id=?',(auto,)).fetchone()
        self.assertEqual(detected['status'],'ready',detected['detail']);self.assertEqual(detected['end']-detected['start'],2)
        fixture.shutdown();fixture.server_close()
        with jobs.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'needs_review')
        with urlopen(Request(self.base+'/review/'+clip,headers={'Range':'bytes=0-19'})) as r:self.assertEqual(r.status,206);self.assertEqual(len(r.read()),20)
        with self.assertRaises(HTTPError):self.post('/api/clips/'+clip+'/bounds',{'start':0,'end':99})
        self.post('/api/clips/'+clip+'/bounds',{'start':1,'end':4})
        jobs.worker(clip)
        with jobs.db() as c:row=c.execute('SELECT * FROM clips WHERE id=?',(clip,)).fetchone()
        self.assertEqual(row['status'],'ready',row['detail']);self.assertEqual(row['clip_mode'],'reviewed')
        duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(jobs.DATA/clip/'clip.mp4')]))
        self.assertAlmostEqual(duration,3,delta=.3)
    def test_stream_management_api(self):
        sku='VE-V5-26-65786'
        from test_streams import event,stream
        jobs.EVENTS.write(sku,event())
        data=self.post('/api/events/streams/save',{'sku':sku,'stream':stream()})
        self.assertEqual(data['matches'][0]['timestamp'],100)
        id=data['streams'][0]['id']
        with jobs.db() as c:self.assertEqual(c.execute('SELECT count(*) FROM clips WHERE event_ref=?',(sku,)).fetchone()[0],0)
        data=self.post('/api/events/streams/save',{'sku':sku,'stream':dict(stream(),label='Second recording',url='https://vimeo.com/987654321')})
        self.assertFalse(data['matches'][0]['available'])
        data=self.post('/api/events/streams/choose',{'sku':sku,'key':'1:1','id':id});self.assertEqual(data['matches'][0]['streamId'],id)
        data=self.post('/api/events/streams/delete',{'sku':sku,'id':id});self.assertEqual(len(data['streams']),1)
        from unittest.mock import patch
        with patch.object(jobs.EVENTS,'catalogue',side_effect=ValueError('offline')):
            data=self.post('/api/events/catalogue',{})
        self.assertTrue(any(e['sku']==sku and e['saved'] for e in data['events']))
    def test_transient_download_failure_retries(self):
        from unittest.mock import patch
        clip=self.post('/api/clips',{'title':'Flaky','url':'https://example.com/a.mp4','start':0,'end':3})['id']
        calls=[]
        def flaky(id,args):
            calls.append(args[0])
            if len(calls)==1:raise RuntimeError('[https @ 0x1] HTTP error 403 Forbidden\nError opening input files: Server returned 403 Forbidden (access denied)\nERROR: ffmpeg exited with code 8')
            (jobs.DATA/id/('source.mp4' if args[0]==sys.executable else 'clip.tmp.mp4')).write_bytes(b'x')
        with patch.object(jobs,'run',side_effect=flaky):jobs.worker(clip)
        with jobs.db() as c:row=c.execute('SELECT status,detail FROM clips WHERE id=?',(clip,)).fetchone()
        self.assertEqual(row['status'],'ready',row['detail']);self.assertEqual(calls[:2],[sys.executable,sys.executable])
    def test_permanent_download_failure_is_not_retried(self):
        from unittest.mock import patch
        clip=self.post('/api/clips',{'title':'Private','url':'https://example.com/a.mp4','start':0,'end':3})['id']
        with patch.object(jobs,'run',side_effect=RuntimeError('ERROR: [youtube] abc: Private video')) as r:jobs.worker(clip)
        self.assertEqual(r.call_count,1)
        with jobs.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'failed')
    def test_failure(self):
        clip=self.post('/api/clips',{'title':'Bad source','url':'http://127.0.0.1:1/missing.mp4','start':0,'end':3})['id']; jobs.worker(clip)
        with jobs.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'failed')
if __name__=='__main__':unittest.main()
