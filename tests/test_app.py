import importlib.util, json, os, shutil, subprocess, sys, tempfile, threading, unittest
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
TMP=tempfile.TemporaryDirectory(); os.environ['SCOUTVAULT_DATA']=TMP.name+'/library'
spec=importlib.util.spec_from_file_location('vault',Path(__file__).resolve().parents[1]/'app.py'); app=importlib.util.module_from_spec(spec); spec.loader.exec_module(app)
app.RETRY_DELAYS=(0,0)
class Quiet(SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),app.Handler); threading.Thread(target=cls.server.serve_forever,daemon=True).start(); cls.base='http://127.0.0.1:'+str(cls.server.server_port)
    @classmethod
    def tearDownClass(cls): cls.server.shutdown(); cls.server.server_close()
    def post(self,path,data):
        with urlopen(Request(self.base+path,data=json.dumps(data).encode(),headers={'X-Scout-Token':app.TOKEN,'Content-Type':'application/json'})) as r:return json.load(r)
    def test_validation(self):
        self.assertEqual(app.seconds('1:02:03'),3723)
        for value in ('-1','nan','inf','1:2:3:4'):
            with self.assertRaises(ValueError): app.seconds(value)
        for value in ('file:///etc/passwd','https://user:pass@example.com/x'):
            with self.assertRaises(ValueError):app.source_url(value)
        with self.assertRaises(HTTPError) as e:self.post('/api/clips',{'title':'x','url':'https://example.com/a','start':10,'end':5})
        self.assertEqual(e.exception.code,400)
    def test_non_object_body_is_rejected(self):
        for body in (b'[1,2]',b'"x"',b'null',b'{bad'):
            with self.assertRaises(HTTPError) as e:urlopen(Request(self.base+'/api/clips',data=body,headers={'X-Scout-Token':app.TOKEN,'Content-Type':'application/json'}))
            self.assertEqual(e.exception.code,400);self.assertIn('JSON object',json.load(e.exception)['error'])
    def test_downloaded_source_ignores_fragments(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            for name in ('source.f399.mp4','source.f140.m4a','source.mp4.part'):(folder/name).write_bytes(b'x')
            with self.assertRaises(RuntimeError):app.downloaded_source(folder)
            (folder/'source.mp4').write_bytes(b'x');self.assertEqual(app.downloaded_source(folder).name,'source.mp4')
            only=Path(tmp)/'one';only.mkdir();(only/'source.webm').write_bytes(b'x');self.assertEqual(app.downloaded_source(only).name,'source.webm')
    def test_pages_and_health(self):
        def get(path):
            with urlopen(Request(self.base+path)) as r:return r.read().decode()
        self.assertEqual(json.loads(get('/api/health'))['app'],'Match Downloader')
        home=get('/');self.assertIn('<title>Match Downloader</title>',home);self.assertIn('/mac/app.js',home);self.assertNotIn('__TOKEN__',home);self.assertIn(app.TOKEN,home)
        self.assertEqual(get('/mac'),home)
        self.assertIn('/next/app.js',get('/next'))
        self.assertIn('ScoutVault · Offline match library',get('/classic'))
        self.assertIn('createPreview',get('/mac/app.js'))
    def test_former_data_variable_still_works(self):
        self.assertEqual(str(app.DATA),str(Path(os.environ['SCOUTVAULT_DATA']).resolve()))
    def test_provider_urls(self):
        self.assertEqual(app.boxcast('https://boxcast.tv/view/abc'), 'https://boxcast.tv/view-embed/abc')
        self.assertEqual(app.boxcast('https://vimeo.com/123'), 'https://vimeo.com/123')
    def test_cancelled_not_started(self):
        clip=self.post('/api/clips',{'title':'Cancelled','url':'https://example.com/a.mp4','start':0,'end':3})['id']
        self.post('/api/clips/'+clip+'/cancel',{})
        app.worker(clip)
        with app.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'cancelled')
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
        app.worker(clip);fixture.shutdown();fixture.server_close()
        with app.db() as c:row=dict(c.execute('SELECT * FROM clips WHERE id=?',(clip,)).fetchone())
        self.assertEqual(row['status'],'ready',row['detail'])
        with urlopen(Request(self.base+'/video/'+clip,headers={'Range':'bytes=10-29'})) as r:
            self.assertEqual(r.status,206);self.assertEqual(len(r.read()),20)
        with urlopen(Request(self.base+'/video/'+clip,headers={'Range':'bytes=-10'})) as r:self.assertEqual(len(r.read()),10)
        with self.assertRaises(HTTPError) as e:urlopen(Request(self.base+'/video/'+clip,headers={'Range':'bytes=999999999-'}))
        self.assertEqual(e.exception.code,416)
        duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(app.DATA/clip/'clip.mp4')]))
        self.assertAlmostEqual(duration,3,delta=.4)
        self.post('/api/clips/'+clip+'/notes',{'notes':'offline review'})
        with app.db() as c:self.assertEqual(c.execute('SELECT notes FROM clips WHERE id=?',(clip,)).fetchone()[0],'offline review')
    def test_event_queue(self):
        sku='RE-V5RC-25-0147'
        app.EVENTS.write(sku,{'sku':sku,'name':'Ignite','divisions':[], 'matches':[
            {'key':'1:67','label':'Q67','available':True,'url':'https://vimeo.com/123','timestamp':100,'division':'Volcanic','teams':['123A'],'timing':'Jumper','alliances':[]},
            {'key':'2:67','label':'Q67','available':True,'url':'https://vimeo.com/456','timestamp':200,'division':'Glacial','teams':[],'timing':'Jumper','alliances':[]},
            {'key':'1:999','label':'QF1-1','available':False}]})
        with self.assertRaises(HTTPError):self.post('/api/events/queue',{'sku':sku,'keys':['1:67','1:999']})
        with app.db() as c:self.assertEqual(c.execute('SELECT count(*) FROM clips WHERE event_ref=?',(sku,)).fetchone()[0],0)
        result=self.post('/api/events/queue',{'sku':sku,'keys':['1:67','2:67'],'duration':150,'before':5,'offset':2})
        self.assertEqual(len(result['added']),2)
        with app.db() as c:rows=list(c.execute('SELECT * FROM clips WHERE event_ref=? ORDER BY start',(sku,)))
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
        app.EVENTS.write(sku,{'sku':sku,'name':'Review test','matches':[{'key':'1:1','label':'Q1','available':True,'url':f'http://127.0.0.1:{fixture.server_port}/review-fixture.mp4','timestamp':1,'division':'Main','teams':[],'timing':'Test','alliances':[]}]})
        queued=self.post('/api/events/queue',{'sku':sku,'keys':['1:1'],'mode':'dynamic'})
        clip=queued['added'][0]
        with patch.object(app,'analyze',return_value={'confidence':'review','reason':'No readable timer'}):app.worker(clip)
        app.EVENTS.write(sku,{'sku':sku,'name':'Detected test','matches':[{'key':'1:2','label':'Q2','available':True,'url':f'http://127.0.0.1:{fixture.server_port}/review-fixture.mp4','timestamp':1,'division':'Main','teams':[],'timing':'Test','alliances':[]}]})
        auto=self.post('/api/events/queue',{'sku':sku,'keys':['1:2'],'mode':'dynamic'})['added'][0]
        with patch.object(app,'analyze',return_value={'confidence':'high','start':1,'end':3,'pause':31}):app.worker(auto)
        with app.db() as c:detected=c.execute('SELECT * FROM clips WHERE id=?',(auto,)).fetchone()
        self.assertEqual(detected['status'],'ready',detected['detail']);self.assertEqual(detected['end']-detected['start'],2)
        fixture.shutdown();fixture.server_close()
        with app.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'needs_review')
        with urlopen(Request(self.base+'/review/'+clip,headers={'Range':'bytes=0-19'})) as r:self.assertEqual(r.status,206);self.assertEqual(len(r.read()),20)
        with self.assertRaises(HTTPError):self.post('/api/clips/'+clip+'/bounds',{'start':0,'end':99})
        self.post('/api/clips/'+clip+'/bounds',{'start':1,'end':4})
        app.worker(clip)
        with app.db() as c:row=c.execute('SELECT * FROM clips WHERE id=?',(clip,)).fetchone()
        self.assertEqual(row['status'],'ready',row['detail']);self.assertEqual(row['clip_mode'],'reviewed')
        duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(app.DATA/clip/'clip.mp4')]))
        self.assertAlmostEqual(duration,3,delta=.3)
    def test_stream_management_api(self):
        sku='VE-V5-26-65786'
        from test_streams import event,stream
        app.EVENTS.write(sku,event())
        data=self.post('/api/events/streams/save',{'sku':sku,'stream':stream()})
        self.assertEqual(data['matches'][0]['timestamp'],100)
        id=data['streams'][0]['id']
        with app.db() as c:self.assertEqual(c.execute('SELECT count(*) FROM clips WHERE event_ref=?',(sku,)).fetchone()[0],0)
        data=self.post('/api/events/streams/save',{'sku':sku,'stream':dict(stream(),label='Second recording',url='https://vimeo.com/987654321')})
        self.assertFalse(data['matches'][0]['available'])
        data=self.post('/api/events/streams/choose',{'sku':sku,'key':'1:1','id':id});self.assertEqual(data['matches'][0]['streamId'],id)
        data=self.post('/api/events/streams/delete',{'sku':sku,'id':id});self.assertEqual(len(data['streams']),1)
        from unittest.mock import patch
        with patch.object(app.EVENTS,'catalogue',side_effect=ValueError('offline')):
            data=self.post('/api/events/catalogue',{})
        self.assertTrue(any(e['sku']==sku and e['saved'] for e in data['events']))
    def test_transient_download_failure_retries(self):
        from unittest.mock import patch
        clip=self.post('/api/clips',{'title':'Flaky','url':'https://example.com/a.mp4','start':0,'end':3})['id']
        calls=[]
        def flaky(id,args):
            calls.append(args[0])
            if len(calls)==1:raise RuntimeError('[https @ 0x1] HTTP error 403 Forbidden\nError opening input files: Server returned 403 Forbidden (access denied)\nERROR: ffmpeg exited with code 8')
            (app.DATA/id/('source.mp4' if args[0]==sys.executable else 'clip.tmp.mp4')).write_bytes(b'x')
        with patch.object(app,'run',side_effect=flaky):app.worker(clip)
        with app.db() as c:row=c.execute('SELECT status,detail FROM clips WHERE id=?',(clip,)).fetchone()
        self.assertEqual(row['status'],'ready',row['detail']);self.assertEqual(calls[:2],[sys.executable,sys.executable])
    def test_permanent_download_failure_is_not_retried(self):
        from unittest.mock import patch
        clip=self.post('/api/clips',{'title':'Private','url':'https://example.com/a.mp4','start':0,'end':3})['id']
        with patch.object(app,'run',side_effect=RuntimeError('ERROR: [youtube] abc: Private video')) as r:app.worker(clip)
        self.assertEqual(r.call_count,1)
        with app.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'failed')
    def test_failure(self):
        clip=self.post('/api/clips',{'title':'Bad source','url':'http://127.0.0.1:1/missing.mp4','start':0,'end':3})['id']; app.worker(clip)
        with app.db() as c:self.assertEqual(c.execute('SELECT status FROM clips WHERE id=?',(clip,)).fetchone()[0],'failed')
if __name__=='__main__':unittest.main()
