"""Local timer OCR and conservative match boundary proposals.

A timestamp locates the search window. Boundaries come from observed countdowns,
not a fixed interval. A two-phase match needs both countdowns; uncertain results
remain available for review rather than silently using a guessed duration.
"""
import csv, hashlib, json, math, os, platform, re, shutil, statistics, subprocess, sys
from pathlib import Path
from events import canonical_label

CLOCK=re.compile(r'^([0-3]?[0-9])[:.]([0-5][0-9])$')

def countdown(text):
    s=str(text).strip().replace(' ','').replace('O','0').replace('o','0')
    m=CLOCK.fullmatch(s)
    if not m:return None
    n=int(m[1])*60+int(m[2])
    return n if n<=180 else None

def identities(rows):
    # Same canonical labels as the schedule, so every round (including R16,
    # plural "Finals" and practice) can be verified against the overlay.
    return {found for row in rows if (found:=canonical_label(row.get('text','')))}

def tracks(frames):
    groups=[]
    for frame in frames:
        t=float(frame['time'])
        for row in frame.get('rows',[]):
            value=countdown(row.get('text',''))
            if value is None or row.get('confidence',1)<.35:continue
            x=row.get('x',0)+row.get('w',0)/2;y=row.get('y',0)+row.get('h',0)/2
            group=next((g for g in groups if abs(g['x']-x)<.05 and abs(g['y']-y)<.055),None)
            if group is None:group={'x':x,'y':y,'points':[]};groups.append(group)
            if group['points'] and group['points'][-1]['t']==t:continue
            group['points'].append({'t':t,'value':value})
    return groups

def runs(points):
    edges=[]
    for a,b in zip(points,points[1:]):
        elapsed=b['t']-a['t'];fall=a['value']-b['value']
        if 0<elapsed<=12 and fall>0 and abs(fall-elapsed)<=2.5:edges.append((a,b))
    segments=[]
    for a,b in edges:
        if segments and a['t']-segments[-1][-1]['t']<=12 and abs((b['t']+b['value'])-statistics.median(p['t']+p['value'] for p in segments[-1]))<=2.5:
            if a['t']!=segments[-1][-1]['t']:segments[-1].append(a)
            segments[-1].append(b)
        else:segments.append([a,b])
    result=[]
    for pts in segments:
        pts=list({p['t']:p for p in pts}.values())
        if len(pts)<4 or pts[-1]['t']-pts[0]['t']<4:continue
        end=statistics.median(p['t']+p['value'] for p in pts)
        residual=statistics.median(abs(p['t']+p['value']-end) for p in pts)
        if residual>1.5:continue
        result.append({'start':end-max(p['value'] for p in pts),'end':end,'maximum':max(p['value'] for p in pts),'minimum':min(p['value'] for p in pts),'samples':len(pts),'residual':residual})
    return result

def detect(frames,anchor,match_label='',format='two-phase',lead=5,tail=5,duration=None):
    candidates=[];all_runs=[]
    for group in tracks(frames):
        sequences=runs(group['points']);all_runs+=sequences
        for i,phase in enumerate(sequences):
            phases=[dict(phase)]
            if format=='two-phase':
                if not 5<=phase['maximum']<=60 or phase['minimum']>4:continue
                following=next((p for p in sequences[i+1:] if p['start']>=phase['end']-2 and p['start']-phase['end']<=1200 and p['maximum']>=35),None)
                if not following:continue
                phases.append(dict(following))
            if phases[-1]['minimum']>4:continue
            if format=='single-phase' and phase['maximum']<30:continue
            start=phases[0]['start'];end=phases[-1]['end']
            if abs(start-anchor)>150 or end-start<30:continue
            matching=0;conflicts=0
            for frame in frames:
                if start-4<=frame['time']<=end+2:
                    ids=identities(frame.get('rows',[]))
                    if len(ids)==1:
                        if match_label and match_label in ids:matching+=1
                        elif match_label:conflicts+=1
            initial=[p for p in group['points'] if start-45<=p['t']<=start+2 and p['value']==phases[0]['maximum']]
            start_visible=len(initial)>=2 and initial[-1]['t']-initial[0]['t']>=2
            start_uncertainty=2
            if not start_visible:
                # Some overlays show zero until the phase starts. A visible
                # zero-to-running transition brackets the real start without
                # assuming a fixed match or autonomous duration.
                zeros=[p['t'] for p in group['points'] if start-6<=p['t']<start and p['value']==0]
                if zeros:
                    last_zero=max(zeros);start_uncertainty=start-last_zero
                    start=(last_zero+start)/2;phases[0]['start']=start;start_visible=True
            confidence='high' if matching>=2 and conflicts==0 and start_visible and all(p['samples']>=4 for p in phases) else 'review'
            candidates.append({'start':max(0,start-lead),'end':min(end+tail,duration) if duration else end+tail,'match_start':start,'match_end':end,'pause':max(0,phases[1]['start']-phases[0]['end']) if len(phases)>1 else 0,'phases':phases,'start_uncertainty':start_uncertainty,'start_visible':start_visible,'identity_frames':matching,'conflicting_frames':conflicts,'confidence':confidence,'clock_position':{'x':group['x'],'y':group['y']}})
    if not candidates:return {'confidence':'review','reason':'Could not verify the full match countdown'+('s (autonomous and driver).' if format=='two-phase' else '.'),'runs':all_runs}
    candidates.sort(key=lambda c:(c['confidence']!='high',-c['identity_frames'],abs(c['match_start']-anchor)))
    best=candidates[0]
    if len(candidates)>1 and candidates[1]['confidence']=='high' and abs(candidates[1]['match_start']-best['match_start'])>10:
        best['confidence']='review';best['reason']='Multiple matches or timer tracks were detected. Check the proposed boundaries.'
    elif best['confidence']!='high':best['reason']='Countdown found, but the actual start or selected match identity could not be verified. Check the proposed boundaries.'
    else:best['reason']='Verified match label and complete countdown'+('s, including the autonomous-to-driver pause.' if format=='two-phase' else '.')
    return best

def ocr_engine(root):
    Path(root).mkdir(parents=True,exist_ok=True)
    if sys.platform=='darwin' and shutil.which('swiftc'):
        source=Path(__file__).resolve().parent/'tools/ocr.swift'
        key=hashlib.sha256(source.read_bytes()).hexdigest()[:12]
        binary=Path(root)/('vision-'+platform.machine()+'-'+key)
        if not binary.exists():
            cache=Path(root)/'swift-cache';cache.mkdir(exist_ok=True)
            subprocess.run(['swiftc','-module-cache-path',str(cache),str(source),'-o',str(binary)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=180)
        return ['vision',str(binary)]
    if shutil.which('tesseract'):return ['tesseract',shutil.which('tesseract')]
    raise RuntimeError('Automatic timer reading is unavailable on this laptop. Review this recording window to choose the match boundaries.')

def read_frames(paths,engine,run_check=None):
    if engine[0]=='vision':
        if run_check:run_check()
        result=subprocess.run([engine[1],*map(str,paths)],capture_output=True,text=True,check=True,timeout=240)
        frames=[json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        if any('error' in f for f in frames):raise RuntimeError('The local OCR engine could not read the match frames.')
        return frames
    rows=[]
    for path in paths:
        if run_check:run_check()
        result=subprocess.run([engine[1],str(path),'stdout','--psm','11','tsv'],capture_output=True,text=True,check=True,timeout=20)
        # ffmpeg produces a fixed 1280x720 analysis frame.
        tokens=[]
        for r in csv.DictReader(result.stdout.splitlines(),delimiter='\t'):
            if not r.get('text','').strip():continue
            tokens.append({'text':r['text'],'confidence':max(0,float(r['conf']))/100,'x':int(r['left'])/1280,'y':int(r['top'])/720,'w':int(r['width'])/1280,'h':int(r['height'])/720})
        rows.append({'file':str(path),'rows':tokens})
    return rows

def analyze(video,folder,anchor,match_label,format,run,check=None,lead=5,tail=5):
    folder=Path(folder);frames_dir=folder/'timer-frames';frames_dir.mkdir(exist_ok=True)
    engine=ocr_engine(folder.parent/'ocr-tools')
    run(['ffmpeg','-y','-hide_banner','-loglevel','error','-i',str(video),'-vf','fps=0.5,scale=1280:720','-fps_mode','vfr',str(frames_dir/'frame-%05d.png')])
    paths=sorted(frames_dir.glob('frame-*.png'))
    frames=[]
    for i in range(0,len(paths),20):
        raw=read_frames(paths[i:i+20],engine,check)
        for f in raw:
            index=int(Path(f['file']).stem.split('-')[-1])-1;f['time']=index*2;frames.append(f)
        if check:check()
    (folder/'timer-observations.json').write_text(json.dumps(frames))
    d=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(video)]))
    result=detect(frames,anchor,match_label,format,lead,tail,d)
    (folder/'boundaries.json').write_text(json.dumps(result,indent=2))
    shutil.rmtree(frames_dir,ignore_errors=True)
    return result
