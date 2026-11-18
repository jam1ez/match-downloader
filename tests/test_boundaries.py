import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from boundaries import detect,countdown,identities

def clock(n):return f'{int(n)//60}:{int(n)%60:02d}'
def sample(t,value,label='QUAL 67'):
    return {'time':t,'rows':[{'text':clock(value),'x':.82,'y':.85,'w':.12,'h':.05,'confidence':.95},{'text':label,'x':.8,'y':.1,'w':.15,'h':.04,'confidence':.95}]}
def match(pause=20,label='QUAL 67'):
    frames=[sample(t,15,label) for t in range(0,20,2)]
    frames += [sample(20+t,15-t,label) for t in range(0,16,2)]
    driver=35+pause
    frames += [sample(t,0,label) for t in range(36,driver,2)]
    frames += [sample(driver+t,105-t,label) for t in range(0,106,2)]
    frames += [sample(driver+106,0,label)]
    return sorted(frames,key=lambda f:f['time']),driver+105

class BoundariesTests(unittest.TestCase):
    def test_countdown(self):
        self.assertEqual(countdown('1:45'),105)
        self.assertEqual(countdown('O:15'),15)
        for s in ['5689','11:30','Q67','105','1:99']:self.assertIsNone(countdown(s))
    def test_variable_pause(self):
        for pause in (8,30,100,420):
            frames,end=match(pause);d=detect(frames,20,'Q67')
            self.assertEqual(d['confidence'],'high',d)
            self.assertAlmostEqual(d['match_start'],20,delta=1)
            self.assertAlmostEqual(d['match_end'],end,delta=1)
            self.assertAlmostEqual(d['pause'],pause,delta=1)
            self.assertAlmostEqual(d['end'],end+5,delta=1)
    def test_auto_zero_is_not_the_match_end(self):
        frames,_=match(30);d=detect([f for f in frames if f['time']<70],20,'Q67')
        self.assertEqual(d['confidence'],'review')
        self.assertNotIn('match_end',d)
    def test_occlusion_requires_review(self):
        frames,_=match();frames=[f for f in frames if f['time']<120]
        self.assertEqual(detect(frames,20,'Q67')['confidence'],'review')
    def test_wrong_match_never_auto_accepts(self):
        frames,_=match(label='QUAL 68');d=detect(frames,20,'Q67')
        self.assertEqual(d['confidence'],'review')
    def test_no_clock_is_not_fixed_length_fallback(self):
        self.assertEqual(detect([{'time':2,'rows':[]}],20,'Q67')['confidence'],'review')
    def test_missing_start_requires_review(self):
        frames,_=match();frames=[f for f in frames if f['time']>=24]
        self.assertEqual(detect(frames,20,'Q67')['confidence'],'review')
    def test_single_phase_iq(self):
        frames=[sample(-4,60),sample(-2,60)]+[sample(t,60-t) for t in range(0,61,2)];d=detect(frames,0,'Q67','single-phase')
        self.assertEqual(d['confidence'],'high')
        self.assertEqual(d['match_end'],60)
    def test_every_round_label_is_verified(self):
        for shown,want in [('Qualification 67','Q67'),('R16 1-1','R161-1'),('Round of 16 #1-1','R161-1'),('Quarterfinals 1-1','QF1-1'),('SemiFinal #2-1','SF2-1'),('Finals 1-1','F1-1'),('Practice 3','P3')]:
            self.assertEqual(identities([{'text':shown}]),{want})
            frames,_=match(label=shown);self.assertEqual(detect(frames,20,want)['confidence'],'high',shown)
        self.assertEqual(identities([{'text':'0:15'},{'text':'1:45'},{'text':'Volcanic'}]),set())
if __name__=='__main__':unittest.main()
