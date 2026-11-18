import json, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from events import Events,label,normalize,match_format

class EventTests(unittest.TestCase):
    def test_labels(self):
        for raw,want in [('Qualifier #67','Q67'),('Qualification #067','Q67'),('q67','Q67'),('QF #1-1','QF1-1'),('SF #2-1','SF2-1'),('Final #1-2','F1-2'),('R16 #8-1','R168-1')]:
            self.assertEqual(label(raw),want)
    def test_match_format_uses_program(self):
        self.assertEqual(match_format({'sku':'VE-V5-26-65786','program':{'code':'V5RC'}}),'two-phase')
        self.assertEqual(match_format({'sku':'VE-XX-26-1','program':{'code':'VIQRC'}}),'single-phase')
        self.assertEqual(match_format({'sku':'RE-VIQRC-25-1'}),'single-phase')
        self.assertEqual(match_format({'sku':'RE-VURC-25-1','program':{'code':'VURC'}}),'two-phase')
    def test_missing_timing(self):
        for time in (None,-1,float('nan')):
            self.assertFalse(normalize({'id':1,'name':'Q67','timestamp':time,'livestreamLink':'https://vimeo.com/1'})['available'])
        self.assertFalse(normalize({'id':1,'name':'Q67','timestamp':0,'outside':'beforeStart','livestreamLink':'https://vimeo.com/1'})['available'])
    def test_offline_schedule_and_calibration(self):
        with tempfile.TemporaryDirectory() as tmp:
            events=Events(tmp)
            routes=[{'sku':'RE-V5RC-25-0147','label':'Ignite','divisionNames':{'1':'Volcanic','2':'Glacial'}}]
            rows=[{'id':1,'name':'Qualifier #67','divisionId':1,'timestamp':100,'livestreamLink':'https://youtube.com/watch?v=abc'},{'id':2,'name':'Qualifier #67','divisionId':2,'timestamp':200,'livestreamLink':'https://youtube.com/watch?v=xyz'},{'id':3,'name':'QF #1-1','divisionId':1,'timestamp':None}]
            with patch('events.remote',side_effect=[routes,rows,ValueError('official unavailable')]):
                self.assertEqual(len(events.catalogue()['events']),1)
                d=events.load('https://events.vex.com/RE-V5RC-25-0147.html')
            self.assertEqual(len(d['matches']),3)
            self.assertEqual({m['division'] for m in d['matches']},{'Volcanic','Glacial'})
            with patch('events.remote',side_effect=ValueError('offline')):
                self.assertTrue(Events(tmp).load(d['sku'])['cached'])
                self.assertTrue(events.catalogue(True)['offline'])
            events.calibrate(d['sku'],'1:3','https://vimeo.com/123',600)
            self.assertTrue(next(m for m in events.load(d['sku'])['matches'] if m['key']=='1:3')['available'])
            with patch('events.remote',side_effect=[rows,ValueError('official unavailable')]):
                refreshed=events.load(d['sku'],True)
            calibrated=next(m for m in refreshed['matches'] if m['key']=='1:3')
            self.assertEqual(calibrated['timestamp'],600)
            self.assertEqual(calibrated['timing'],'Manual calibration')
    def test_recording_anchor_respects_division_and_day(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp);sku='RE-V5RC-25-0147'
            def m(id,div,started):return {'key':str(div)+':'+str(id),'divisionId':str(div),'started':started,'scheduled':None,'available':False}
            e.write(sku,{'sku':sku,'matches':[m(1,1,'2026-11-01T10:00:00Z'),m(2,1,'2026-11-01T10:05:00Z'),m(3,2,'2026-11-01T10:05:00Z'),m(4,1,'2026-11-02T10:05:00Z')]})
            result=e.map_recording(sku,'1:1','https://vimeo.com/123',100)
            self.assertEqual(result['changed'],2)
            rows=result['event']['matches']
            self.assertEqual(rows[1]['timestamp'],400)
            self.assertFalse(rows[2]['available']);self.assertFalse(rows[3]['available'])
    def test_pagination(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp)
            responses=[[],{'data':[{'id':99,'name':'Example','divisions':[{'id':1,'name':'Main'}]}]}, {'data':[{'id':1,'name':'Qualifier #1','round':2,'matchnum':1}],'meta':{'last_page':2}}, {'data':[{'id':2,'name':'QF #1-1'}],'meta':{'last_page':2}}]
            with patch('events.remote',side_effect=responses) as r:
                d=e.load('RE-V5RC-25-0147',token='test-token')
            self.assertEqual(len(d['matches']),2)
            self.assertIn('page=2',r.call_args[0][0])
            self.assertIn('events.vex.com',r.call_args[0][0])

class WorldsTests(unittest.TestCase):
    def test_boxcast_mapping(self):
        from worlds import timestamps
        event={'sku':'RE-V5RC-24-8909','start':'2025-05-06T00:00:00-05:00','divisions':[{'id':1,'name':'Arts'}]}
        rows=[{'id':42,'divisionId':1,'started':'2025-05-06T10:10:00-05:00'}]
        def fetch(url):return [{'id':'abc','name':'Qualification Matches (Arts)','starts_at':'2025-05-06T10:00:00-05:00','stops_at':'2025-05-06T18:00:00-05:00'}]
        result=timestamps(event,rows,fetch)
        self.assertEqual(result[0]['timestamp'],600)
        self.assertEqual(result[0]['livestreamLink'],'https://boxcast.tv/view/abc')

if __name__=='__main__':unittest.main()
