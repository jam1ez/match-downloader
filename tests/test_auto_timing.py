import copy,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from auto_timing import metadata,auto_time,title_matches
from test_streams import event,stream
from event_streams import normalize_stream

INFO={'title':'Excalibur Robotics Challenge 2026 - Override','startEstimate':'2026-11-14T17:59:00+00:00','duration':30000,'wasLive':True,'liveStatus':'was_live'}
class AutoTimingTests(unittest.TestCase):
    def test_upload_date_is_not_broadcast_start(self):
        self.assertIsNone(metadata({'timestamp':1794709036,'release_timestamp':1794673979,'was_live':False})['startEstimate'])
        self.assertIsNotNone(metadata({'release_timestamp':1794673979,'was_live':True})['startEstimate'])
    def test_saved_auto_stream_times_all_in_scope(self):
        e=event();e['streams']=[normalize_stream(e,stream(syncMode='auto'))]
        result=auto_time(e,None,False,probe_fn=lambda u:dict(INFO))
        self.assertEqual(result['matches'][0]['timestamp'],60)
        self.assertEqual(result['matches'][1]['timestamp'],360)
        self.assertEqual(result['matches'][0]['timing'],'Auto timing (broadcast start)')
        self.assertFalse(result['matches'][4]['available'])
    def test_manual_anchor_preserved(self):
        e=event();e['streams']=[normalize_stream(e,stream())]
        def forbidden(u):raise AssertionError('Manual anchor must not be replaced')
        result=auto_time(e,None,False,probe_fn=forbidden)
        self.assertEqual(result['matches'][0]['timestamp'],100)
    def test_missing_metadata_never_sets_zero(self):
        e=event();e['streams']=[normalize_stream(e,stream(syncMode='auto'))]
        result=auto_time(e,None,False,probe_fn=lambda u:{'startEstimate':None})
        self.assertFalse(result['matches'][0]['available']);self.assertIsNone(result['matches'][0]['timestamp'])
    def test_discovery_times_single_division_recording(self):
        e=event();e['divisions']=e['divisions'][:1];e['matches']=[m for m in e['matches'] if m['divisionId']=='1'];e['discovery']={'candidates':[{'url':'https://youtube.com/watch?v=T3iBuIt4M-0','source':'VEX Events webcast'}]}
        result=auto_time(e,None,True,probe_fn=lambda u:dict(INFO));self.assertGreater(result['autoTiming']['added'],0);self.assertTrue(result['matches'][0]['available'])
    def test_search_does_not_accept_wrong_title(self):
        e=event();e['name']='Excalibur Robotics Challenge 2026';e['divisions']=e['divisions'][:1]
        result=auto_time(e,None,True,probe_fn=lambda u:dict(INFO,title='Unrelated Event'),search_fn=lambda e:[{'url':'https://youtube.com/watch?v=T3iBuIt4M-0','source':'Event-title search'}])
        self.assertEqual(result['autoTiming']['added'],0)
    def test_matching_event_title(self):
        e=event();e['name']='Excalibur Robotics Challenge 2026 - Override: VEX V5 Robotics Competition'
        self.assertTrue(title_matches(e,INFO['title']))
        self.assertFalse(title_matches(e,'Excalibur Robotics Challenge 2025'))
        self.assertFalse(title_matches(e,'Excalibur Robotics Challenge 2026 Highlights'))
    def test_channel_link_resolves_matching_archive(self):
        e=event();e['name']='Excalibur Robotics Challenge 2026';e['divisions']=e['divisions'][:1]
        channel='https://www.youtube.com/@TUSDRobotics/streams';video='https://youtube.com/watch?v=T3iBuIt4M-0'
        e['discovery']={'candidates':[{'url':channel,'source':'VEX Events webcast'}]}
        def probe(url):
            return {'recordings':[{'title':INFO['title'],'url':video},{'title':'Other event','url':'https://youtube.com/watch?v=otherother1'}]} if url==channel else dict(INFO)
        result=auto_time(e,None,True,probe_fn=probe,search_fn=lambda e:[])
        self.assertTrue(result['matches'][0]['available']);self.assertEqual(len(result['streams']),1)
    def test_stale_webcast_falls_back_to_title_search(self):
        e=event();e['name']='Excalibur Robotics Challenge 2026';e['divisions']=e['divisions'][:1]
        e['discovery']={'candidates':[{'url':'https://example.com/stale'}]}
        result=auto_time(e,None,True,probe_fn=lambda u:dict(INFO) if 'youtube.com' in u else {},search_fn=lambda e:[{'url':'https://youtube.com/watch?v=T3iBuIt4M-0','source':'Event-title search'}])
        self.assertTrue(result['matches'][0]['available'])
    def test_partly_timed_event_probes_feed_length_and_only_fills_gaps(self):
        from test_streams import fed_event
        from event_streams import apply_streams
        e=apply_streams(fed_event());e['divisions']=e['divisions'][:1];e['matches']=[m for m in e['matches'] if m['divisionId']=='1']
        e['name']='Excalibur Robotics Challenge 2026';e['discovery']={'candidates':[{'url':'https://youtube.com/watch?v=otherother1','source':'VEX Events webcast'}]}
        probed=[]
        def probe(url):
            probed.append(url)
            return {'duration':10500} if 'T3iBuIt4M-0' in url else dict(INFO,startEstimate='2026-11-14T17:00:00+00:00')
        result=auto_time(e,None,True,probe_fn=probe,search_fn=lambda e:[])
        self.assertEqual(result['recordingDurations'],{'youtube:T3iBuIt4M-0':10500})
        self.assertTrue(all(m['available'] for m in result['matches']))
        self.assertTrue(result['streams'][0]['fillOnly'])
        fed=next(m for m in result['matches'] if m['key']=='1:2');self.assertEqual(fed['timing'],'Jumper')
        late=next(m for m in result['matches'] if m['key']=='1:12');self.assertIn('otherother1',late['url']);self.assertEqual(late['timestamp'],10800)
if __name__=='__main__':unittest.main()
