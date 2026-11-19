import copy,json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from events import Events
from event_streams import apply_streams,normalize_stream
from webcast import discover

SKU='VE-V5-26-65786'
def match(key,day='2026-11-14',time='10:00:00',division='1',field='Field 1'):
    return {'key':key,'id':key.split(':')[-1],'label':'Q'+key.split(':')[-1],'name':'Qualifier #'+key.split(':')[-1],'divisionId':division,'division':'Division '+division,'field':field,'started':day+'T'+time+'-08:00','scheduled':day+'T'+time+'-08:00','timestamp':None,'url':'','available':False,'timing':'Needs timing','teams':[],'alliances':[]}
def event():
    return {'sku':SKU,'name':'Any event','start':'2026-11-14T00:00:00-08:00','end':'2026-11-15T00:00:00-08:00','divisions':[{'id':'1','name':'Division 1'},{'id':'2','name':'Division 2'}],'streams':[],'matches':[match('1:1'),match('1:2',time='10:05:00'),match('1:3',time='14:00:00'),match('2:1',division='2'),match('1:4',day='2026-11-15'),match('1:5',time='10:05:00',field='Field 2')]}
def stream(**overrides):
    return dict({'label':'Day 1 morning','url':'https://vimeo.com/123456789','divisionId':'1','date':'2026-11-14','syncMode':'anchor','anchorKey':'1:1','anchorPosition':100,'basis':'actual'},**overrides)

class StreamTests(unittest.TestCase):
    def test_new_and_old_skus_and_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp)
            for v in [SKU,'https://events.vex.com/robot-competitions/vex-robotics-competition/'+SKU+'.html#%E5%B8%B8']:
                self.assertEqual(e.sku(v),SKU)
            self.assertEqual(e.sku('RE-V5RC-25-0147'),'RE-V5RC-25-0147')
            with self.assertRaises(ValueError):e.sku('https://example.com/'+SKU)
    def test_many_custom_events_saved(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp)
            for i in range(120):
                d=event();d['sku']='VE-V5-26-'+str(60000+i);e.write(d['sku'],d)
            self.assertEqual(len(e.saved()),120)
    def test_future_event_with_no_matches_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp)
            responses=[[],{'data':[{'id':65786,'sku':SKU,'name':'Upcoming event','start':'2026-11-14T00:00:00-08:00','end':'2026-11-15T00:00:00-08:00','divisions':[{'id':1,'name':'Main'}]}]},{'data':[],'meta':{'last_page':1}}]
            with patch('events.remote',side_effect=responses):d=e.load(SKU)
            self.assertEqual(d['matches'],[]);self.assertEqual(d['divisions'][0]['name'],'Main');self.assertEqual(len(d['days']),2)
    def test_livestream_shift_moves_found_positions_but_not_ones_set_by_hand(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp);d=event()
            d['matches'][0].update(timestamp=100,url='https://youtu.be/T3iBuIt4M-0',available=True,timing='Jumper')
            d['matches'][1].update(timestamp=10,url='https://youtu.be/T3iBuIt4M-0',available=True,timing='Jumper')
            d['matches'][2].update(timestamp=500,url='https://youtu.be/T3iBuIt4M-0',available=True,timing='Manual calibration')
            apply_streams(d);e.write(SKU,d)
            out=e.set_timing_offset(SKU,-30)
            self.assertEqual([m['timestamp'] for m in out['matches'][:3]],[70,0,500])
            self.assertEqual(out['timingOffset'],-30)
            again=e.set_timing_offset(SKU,'12')  # replaces the shift, never adds to it
            self.assertEqual([m['timestamp'] for m in again['matches'][:3]],[112,22,500])
            self.assertEqual(e.load(SKU)['matches'][0]['timestamp'],112)
            for bad in (601,-601,'soon',float('nan')):
                with self.assertRaises(ValueError):e.set_timing_offset(SKU,bad)
            self.assertEqual(e.set_timing_offset(SKU,0)['matches'][0]['timestamp'],100)
    def test_division_day_and_field_scope(self):
        d=event();d['streams']=[normalize_stream(d,stream(field='Field 1',offset=3))];apply_streams(d)
        self.assertEqual(d['matches'][0]['timestamp'],103);self.assertEqual(d['matches'][1]['timestamp'],403)
        for i in [3,4,5]:self.assertFalse(d['matches'][i]['available'])
    def test_multiple_days_and_divisions_use_own_links(self):
        d=event();d['streams']=[normalize_stream(d,stream()),normalize_stream(d,stream(label='Day 2',date='2026-11-15',anchorKey='1:4',anchorPosition=200,url='https://youtube.com/watch?v=T3iBuIt4M-0')),normalize_stream(d,stream(label='Division 2',divisionId='2',anchorKey='2:1',anchorPosition=50,url='https://boxcast.tv/view/abc'))];apply_streams(d)
        self.assertEqual(d['matches'][4]['timestamp'],200);self.assertIn('youtube',d['matches'][4]['url']);self.assertEqual(d['matches'][3]['timestamp'],50)
    def test_restart_sessions_and_duration(self):
        d=event();d['streams']=[normalize_stream(d,stream(firstMatch='1:1',lastMatch='1:2',duration=1000)),normalize_stream(d,stream(label='Afternoon',anchorKey='1:3',anchorPosition=20,firstMatch='1:3',lastMatch='1:3',url='https://vimeo.com/987654321'))];apply_streams(d)
        self.assertEqual(d['matches'][2]['timestamp'],20);self.assertIn('987654321',d['matches'][2]['url']);self.assertEqual(d['matches'][1]['timestamp'],400)
    def test_overlap_requires_choice_and_persists(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp);e.write(SKU,event());d=e.save_stream(SKU,stream());d=e.save_stream(SKU,stream(label='Backup',url='https://vimeo.com/987654321'))
            self.assertFalse(d['matches'][0]['available']);self.assertEqual(len(d['matches'][0]['streamOptions']),2)
            id=d['streams'][1]['id'];d=e.choose_stream(SKU,'1:1',id);self.assertEqual(d['matches'][0]['streamId'],id)
            cached=Events(tmp).load(SKU);self.assertEqual(cached['matches'][0]['streamId'],id)
            d=e.delete_stream(SKU,id);self.assertTrue(d['matches'][0]['available']);self.assertNotEqual(d['matches'][0]['streamId'],id)
    def test_remove_restores_preset_and_manual_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp);d=event();d['matches'][0].update(url='https://vimeo.com/111111111',timestamp=7,available=True,timing='Jumper');e.write(SKU,d)
            d=e.save_stream(SKU,stream());id=d['streams'][0]['id'];self.assertEqual(d['matches'][0]['timestamp'],100)
            d=e.delete_stream(SKU,id);self.assertEqual(d['matches'][0]['timestamp'],7)
            e.calibrate(SKU,'1:1','https://vimeo.com/222222222',42);d=e.save_stream(SKU,stream());self.assertEqual(d['matches'][0]['timestamp'],42);self.assertNotIn('streamLabel',d['matches'][0])
            id=d['streams'][0]['id'];d=e.choose_stream(SKU,'1:1',id);self.assertEqual(d['matches'][0]['timestamp'],100)
    def test_wallclock_timezone_and_actual_basis(self):
        d=event();d['streams']=[normalize_stream(d,stream(syncMode='wallclock',wallStart='2026-11-14T17:59:00+00:00'))];apply_streams(d);self.assertEqual(d['matches'][0]['timestamp'],60)
    def test_negative_and_after_recording_times_not_mapped(self):
        d=event();d['streams']=[normalize_stream(d,stream(anchorKey='1:2',anchorPosition=0,duration=10))];apply_streams(d)
        self.assertFalse(d['matches'][0]['available']);self.assertFalse(d['matches'][2]['available']);self.assertTrue(d['matches'][1]['available'])
    def test_channel_must_resolve_to_a_recording(self):
        with self.assertRaises(ValueError):normalize_stream(event(),stream(url='https://www.youtube.com/@tusdrobotics9637'))
    def test_bad_anchor_scope_rejected(self):
        d=event()
        for bad in [stream(date='2026-11-15'),stream(divisionId='2'),stream(field='Field 2'),stream(anchorPosition=100,duration=50)]:
            with self.assertRaises(ValueError):normalize_stream(d,bad)
    def test_manual_streams_survive_official_refresh(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp);e.write(SKU,event());e.save_stream(SKU,stream())
            rows=[{'id':1,'name':'Qualifier #1','division':{'id':1,'name':'Main'},'started':'2026-11-14T10:00:00-08:00','alliances':[]}]
            with patch('events.remote',side_effect=[[],{'data':[{'id':65786,'sku':SKU,'name':'Official event','divisions':[{'id':1,'name':'Main'}]}]},{'data':rows,'meta':{'last_page':1}}]):d=e.load(SKU,True)
            self.assertEqual(len(d['streams']),1);self.assertEqual(d['matches'][0]['timestamp'],100)
    def test_webcast_detection_no_invented_link(self):
        responses={'info':{'webcast':{'description':'Search for TUSD Robotics on YouTube','links':[]}},'jumper':{'streams':[]}}
        result=discover(event(),lambda u:responses['info' if 'event-info' in u else 'jumper'])
        self.assertEqual(result['candidates'],[]);self.assertIn('TUSD',result['description'])
    def test_webcast_detection_deduplicates_sources(self):
        responses={'info':{'webcast':{'description':'','links':[{'url':'https://youtu.be/T3iBuIt4M-0','label':'Day 1'}]}},'jumper':{'streams':[{'url':'https://youtu.be/T3iBuIt4M-0'},{'url':'javascript:alert(1)'}]}}
        result=discover(event(),lambda u:responses['info' if 'event-info' in u else 'jumper']);self.assertEqual(len(result['candidates']),1)

def fed_event():
    """Feed (Jumper-style) timing: recording start 09:00, so position = seconds since 09:00."""
    d=event();d['matches']=[match('1:'+str(i),time=f'{10+i//6:02d}:{(i%6)*10:02d}:00') for i in range(1,13)]+[match('2:1',division='2')]
    for m in d['matches']:
        if m['key'] not in ('1:1','1:6','1:12','2:1'):
            t=int(m['started'][11:13])*3600+int(m['started'][14:16])*60-9*3600
            m.update(timestamp=t,url='https://www.youtube.com/watch?v=T3iBuIt4M-0&t='+str(t),available=True,timing='Jumper')
    return d
def key(d,k):return next(m for m in d['matches'] if m['key']==k)

class PartialTimingTests(unittest.TestCase):
    def test_feed_gap_estimated_from_same_recording(self):
        d=apply_streams(fed_event())
        gap=key(d,'1:6');self.assertTrue(gap['available']);self.assertEqual(gap['timestamp'],7200)   # 11:00 − 09:00
        self.assertIn('T3iBuIt4M-0',gap['url']);self.assertTrue(gap['timing'].startswith('Estimated from'))
        self.assertEqual(key(d,'1:1')['timestamp'],4200)   # before the first fed match, inside the recording
        self.assertEqual(d['streamSummary']['estimated'],2)
    def test_never_past_recording_end_or_before_start(self):
        d=apply_streams(fed_event())
        self.assertFalse(key(d,'1:12')['available'])  # 10800 s is after the last fed match (10200 s); length unknown
        d=fed_event();d['recordingDurations']={'youtube:T3iBuIt4M-0':12000};apply_streams(d)
        self.assertEqual(key(d,'1:12')['timestamp'],10800)
        d=fed_event();d['recordingDurations']={'youtube:T3iBuIt4M-0':10500};apply_streams(d)
        self.assertFalse(key(d,'1:12')['available'])
        d=fed_event()
        for m in d['matches']:
            if m['key']!='1:2':m.update(available=False,timestamp=None,url='',timing='Needs timing')
        key(d,'1:2')['timestamp']=100;apply_streams(d)
        self.assertFalse(key(d,'1:1')['available'])   # would be −500 s
    def test_schedule_only_match_is_not_estimated(self):
        d=fed_event();key(d,'1:6')['started']=None;apply_streams(d)
        self.assertFalse(key(d,'1:6')['available'])   # may not have been played or broadcast
    def test_other_division_and_far_neighbours_not_used(self):
        d=apply_streams(fed_event());self.assertFalse(key(d,'2:1')['available'])
        d=fed_event()
        for m in d['matches']:
            if m['key']!='1:11':m.update(available=False,timestamp=None,url='',timing='Needs timing')
        apply_streams(d)
        self.assertTrue(key(d,'1:6')['available'])    # 50 minutes away
        self.assertFalse(key(d,'1:1')['available'])   # 1 h 40 min away
    def test_estimates_survive_refresh_and_manual_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            e=Events(tmp);e.write(SKU,apply_streams(fed_event()))
            self.assertTrue(key(Events(tmp).load(SKU),'1:6')['available'])
            d=e.calibrate(SKU,'1:6','https://vimeo.com/123456789',42);d=Events(tmp).load(SKU)
            self.assertEqual(key(d,'1:6')['timestamp'],42);self.assertNotIn('estimatedFrom',key(d,'1:6'))
    def test_fill_only_recording_never_replaces_feed(self):
        d=fed_event();d['streams']=[normalize_stream(d,stream(syncMode='wallclock',wallStart='2026-11-14T16:00:00+00:00',fillOnly=True,url='https://vimeo.com/987654321'))];apply_streams(d)
        self.assertIn('T3iBuIt4M-0',key(d,'1:2')['url']);self.assertEqual(key(d,'1:2')['timing'],'Jumper')
        self.assertIn('T3iBuIt4M-0',key(d,'1:6')['url'])          # same-recording estimate preferred
        self.assertIn('987654321',key(d,'1:12')['url'])           # gap no estimate can fill
        d=fed_event();d['streams']=[normalize_stream(d,stream(syncMode='wallclock',wallStart='2026-11-14T16:00:00+00:00',url='https://vimeo.com/987654321'))];apply_streams(d)
        self.assertIn('987654321',key(d,'1:2')['url'])            # your own recording still overrides

if __name__=='__main__':unittest.main()
