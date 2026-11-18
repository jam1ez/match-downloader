"""BoxCast Worlds recording positions using OpenScout's published configuration."""
import json
from pathlib import Path
from datetime import datetime
from urllib.parse import urlencode
ROOT=Path(__file__).resolve().parent
CONFIG=json.loads((ROOT/'worlds.json').read_text())
# The Worlds folder in the app. To follow a new Worlds, run tools/new_worlds_season.py (see README).
PROGRAM_LABELS={'V5RC HS':'V5RC High School','V5RC MS':'V5RC Middle School','VURC':'VEX U','VIQRC MS':'VIQRC Middle School','VIQRC ES':'VIQRC Elementary'}
PROGRAM_ORDER=list(PROGRAM_LABELS)
HS_OFFSETS={'Arts':0,'Design':-47,'Engineering':-50,'Innovate':-55,'Math':-51,'Opportunity':-50,'Research':-49,'Science':-41,'Spirit':-47,'Technology':-48}

def dt(value):
    return datetime.fromisoformat(value.replace('Z','+00:00'))

def resolve(event):
    for year,programs in CONFIG.items():
        for program,cfg in programs.items():
            if cfg.get('sku') and cfg['sku']==event.get('sku'):return year,program,cfg
    if str(event.get('level','')).lower()!='world' or 'world' not in event.get('name','').lower():return None
    year=str(event.get('start',''))[:4]; choices=[]
    code=(event.get('program') or {}).get('code','').upper()
    allowed={'V5RC HS':['VRC','V5RC'],'V5RC MS':['VRC','V5RC'],'VIQRC ES':['VIQC','VIQRC'],'VIQRC MS':['VIQC','VIQRC'],'VURC':['VEXU','VURC']}
    for program,cfg in CONFIG.get(year,{}).items():
        if code not in allowed[program]:continue
        overlap=sum(any(d.lower() in v.get('name','').lower() for v in event.get('divisions',[])) for d in cfg['divisions'])
        if not overlap:continue
        grade={'V5RC HS':'high school','V5RC MS':'middle school','VIQRC ES':'elementary','VIQRC MS':'middle school'}.get(program,'')
        choices.append((overlap*10+(5 if grade and grade in event.get('name','').lower() else 0),program,cfg))
    if not choices:return None
    _,program,cfg=max(choices,key=lambda c:c[0]);return year,program,cfg

def timestamps(event,rows,fetch):
    found=resolve(event)
    if not found:return []
    year,program,cfg=found
    raw=fetch('https://jumper.robostem.org/api/worlds-broadcasts?'+urlencode({'channelId':cfg['channelId'],'year':year}))
    broadcasts=raw if isinstance(raw,list) else raw.get('data',[])
    groups={}
    for b in broadcasts:
        if not b.get('starts_at','').startswith(year):continue
        division=next((d for d in cfg['divisions'] if d.lower() in b.get('name','').lower()),None)
        if not division:continue
        key=(division,b['starts_at'][:10]); previous=groups.get(key)
        def duration(x):
            try:return (dt(x['stops_at'])-dt(x['starts_at'])).total_seconds()
            except (KeyError,ValueError,TypeError):return 0
        if not previous or duration(b)>duration(previous):groups[key]=b
    names={str(d['id']):next((n for n in cfg['divisions'] if n.lower() in d['name'].lower()),None) for d in event.get('divisions',[])}
    out=[]
    for m in rows:
        division=names.get(str(m.get('divisionId',(m.get('division') or {}).get('id',1))))
        started=m.get('started');scheduled=m.get('scheduled');when=started or scheduled
        if not when or not division:continue
        try:
            if started and scheduled and abs((dt(started)-dt(scheduled)).total_seconds())>1800:when=scheduled
            day=(dt(when).date()-dt(event['start']).date()).days
            dates=sorted(date for name,date in groups if name==division)
            if not 0<=day<len(dates):continue
            b=groups[(division,dates[day])]
            seek=(dt(when)-dt(b['starts_at'])).total_seconds()
            if year=='2026' and program=='V5RC HS':seek-=HS_OFFSETS.get(division,0)
            if seek<0:continue
            out.append({'id':m['id'],'timestamp':int(seek),'livestreamLink':'https://boxcast.tv/view/'+b['id'],'timing':'BoxCast estimate'})
        except (ValueError,KeyError,TypeError):continue
    return out

def season():
    """The Worlds shown in the app's Worlds folder: {'title','year','events':[{sku,label,program,start,end,channelId}]}.
    Which Worlds it is comes only from worlds-season.json; nothing in the interface changes it."""
    try:cfg=json.loads((ROOT/'worlds-season.json').read_text())
    except (OSError,ValueError):return None
    year=str(cfg.get('year',''));programs=json.loads((ROOT/'worlds.json').read_text()).get(year)
    if not programs:return None
    events=[{'sku':c['sku'],'label':PROGRAM_LABELS.get(p,p),'program':p,'start':c.get('eventStart'),'end':c.get('eventEnd'),'channelId':c['channelId']}
            for p,c in programs.items() if c.get('sku')]
    events.sort(key=lambda e:(e['start'] or '',PROGRAM_ORDER.index(e['program']) if e['program'] in PROGRAM_ORDER else 99))
    return {'title':str(cfg.get('title') or 'Worlds '+year[-2:]),'year':year,'events':events} if events else None
