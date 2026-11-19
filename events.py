"""Event catalogue, canonical match labels, persistent offline schedules."""
import json, os, re, threading, time
from pathlib import Path
from urllib.parse import urlencode, urlparse, parse_qs
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
from worlds import timestamps as worlds_timestamps
from event_streams import apply_streams, normalize_stream, video_url, event_days, number, TIMING_OFFSET_LIMIT, timestamp as stream_timestamp

HEADERS={'User-Agent':'Mozilla/5.0 (Match Downloader local match library)','Accept':'application/json','Origin':'https://openscout.ing','Referer':'https://openscout.ing/'}

def remote(url, token=None):
    headers=dict(HEADERS)
    if token: headers['Authorization']='Bearer '+token
    try:
        with urlopen(Request(url,headers=headers),timeout=40) as r:
            return json.load(r)
    except HTTPError as e:
        raise ValueError(f'Event service returned HTTP {e.code}. Try again later or use a RobotEvents API key in event settings.') from None
    except (URLError,TimeoutError,ValueError):
        raise ValueError('Cannot reach the event service. Saved events remain available offline.') from None

LABEL_PATTERNS=[(r'^(?:QUALIFICATION|QUALIFIER|QUALIFICATIONS|QUAL|Q)(\d+)$','Q'),(r'^(?:QUARTERFINALS?|QF)(\d+)-(\d+)$','QF'),(r'^(?:SEMIFINALS?|SF)(\d+)-(\d+)$','SF'),(r'^(?:ROUND(?:OF)?16|R16)(\d+)-(\d+)$','R16'),(r'^(?:FINALS?|F)(\d+)-(\d+)$','F'),(r'^(?:PRACTICE|P)(\d+)$','P')]

def canonical_label(text):
    """Canonical match label (Q67, QF1-1, R161-1…) or None for other text."""
    text=re.sub(r'[\s#_:]+','',str(text)).upper()
    for pattern,prefix in LABEL_PATTERNS:
        m=re.fullmatch(pattern,text)
        if m:return prefix+'-'.join(str(int(n)) for n in m.groups())
    return None

def label(name, match=None):
    found=canonical_label(name)
    if found:return found
    if match and match.get('round')==2:return 'Q'+str(match['matchnum'])
    return re.sub(r'[\s#_]+','',str(name)).upper()

def match_format(event):
    """VEX IQ uses one teamwork countdown; V5RC and VURC use autonomous + driver."""
    code=str(((event or {}).get('program') or {}).get('code') or '').upper()
    if code:return 'single-phase' if code.startswith(('VIQ','IQ')) else 'two-phase'
    sku=str((event or {}).get('sku') or '').upper()
    return 'single-phase' if 'VIQ' in sku or sku.startswith('VE-IQ-') else 'two-phase'

def match_order(m):
    key=m['label']; prefix=re.match(r'[A-Z]+\d*?(?=\d|$)',key)
    nums=tuple(map(int,re.findall(r'\d+',key)))
    rank=0 if key.startswith('P') else 1 if re.fullmatch(r'Q\d+',key) else 2 if key.startswith('R16') else 3 if key.startswith('QF') else 4 if key.startswith('SF') else 5
    return (int(m['divisionId']) if str(m['divisionId']).isdigit() else 999,rank,nums,key)

def normalize(row, divisions=None):
    div=row.get('divisionId', (row.get('division') or {}).get('id',1))
    timestamp=row.get('timestamp')
    good=isinstance(timestamp,(float,int)) and not isinstance(timestamp,bool) and 0<=timestamp<604800 and not row.get('outside')
    url=row.get('livestreamLink') or row.get('url') or (('https://www.youtube.com/watch?v='+row['videoId']) if row.get('videoId') else '')
    teams=[]; scores=[]
    for alliance in row.get('alliances') or []:
        group=[str((t.get('team') or {}).get('name','')) for t in alliance.get('teams',[])]
        teams+=group;scores.append({'color':alliance.get('color'),'teams':group,'score':alliance.get('score')})
    return {'key':str(div)+':'+str(row['id']),'id':row['id'],'name':row.get('name',''),'label':label(row.get('name',''),row),'divisionId':str(div),'division':(divisions or {}).get(str(div),(row.get('division') or {}).get('name','Division '+str(div))),'timestamp':timestamp if good else None,'url':url,'available':bool(good and url),'teams':teams,'alliances':scores,'field':row.get('field') or '', 'scheduled':row.get('scheduled'),'started':row.get('started'),'timing':row.get('timing','Jumper') if good else 'Needs timing'}

class Events:
    def __init__(self, root):
        self.root=Path(root)/'events'; self.root.mkdir(exist_ok=True); self.lock=threading.RLock()
    def write(self,key,value):
        with self.lock:
            p=self.root/(key+'.json'); tmp=p.with_suffix('.tmp'); tmp.write_text(json.dumps(value)); tmp.replace(p)
    def read(self,key):
        with self.lock:
            p=self.root/(key+'.json')
            return json.loads(p.read_text()) if p.exists() else None
    def sku(self,value):
        from urllib.parse import unquote
        raw=unquote(str(value)).strip()
        if '://' in raw:
            u=urlparse(raw)
            if u.scheme not in ('http','https') or u.hostname not in ('events.vex.com','www.events.vex.com','robotevents.com','www.robotevents.com'):raise ValueError('Paste a VEX Events page link or its event code')
            raw=u.path
        m=re.search(r'(?<![A-Z0-9-])(?:RE|VE)-[A-Z0-9]+-\d{2}-\d+(?![A-Z0-9-])',raw.upper())
        if not m:raise ValueError('Enter a VEX event code such as VE-V5-26-65786 or RE-V5RC-25-0147, or paste its event page link')
        return m.group()
    def catalogue(self,refresh=False):
        cached=self.read('catalogue')
        if cached and not refresh:return {'events':cached,'offline':False,'cached':True}
        try:
            routes=remote('https://jumper.robostem.org/api/get-all-routes')
            if not isinstance(routes,list):raise ValueError('Invalid event catalogue')
            data=[{'sku':self.sku(r['sku']),'name':r.get('label') or r['sku'],'divisions':r.get('divisionNames') or {}} for r in routes if r.get('sku')]
            self.write('catalogue',data);return {'events':data,'cached':False,'offline':False}
        except ValueError:
            if cached:return {'events':cached,'offline':True,'cached':True}
            raise
    def re_get(self,path,query=None,token=''):
        base='https://events.vex.com/api/v2/' if token else 'https://openscout.ing/api/re/'
        return remote(base+path+('?' + urlencode(query,doseq=True) if query else ''),token)
    def load(self,value,refresh=False,token=''):
        sku=self.sku(value); cached=self.read(sku)
        if cached and not refresh:return dict(apply_streams(cached),cached=True)
        catalogue=self.read('catalogue') or []
        preset=next((e for e in catalogue if e['sku']==sku),None)
        rows=[]; warning=''; event=None
        try:
            rows=remote('https://jumper.robostem.org/api/match-timestamp?'+urlencode({'sku':sku,'offsetSeconds':0}))
            if not isinstance(rows,list): rows=[]
        except ValueError as e:warning=str(e)
        # The official schedule supplies every match, alliance and score.
        # Jumper adds video positions by stable match ID.
        try:
            payload=self.re_get('events',{'sku[]':sku,'per_page':250},token)
            event=next(iter(payload.get('data',[])),None)
            if not event:raise ValueError('Event was not found')
            merged=[]; byid={str(r['id']):r for r in rows}
            for div in event.get('divisions') or [{'id':1,'name':'Default'}]:
                page=1
                while True:
                    batch=self.re_get(f"events/{event['id']}/divisions/{div['id']}/matches",{'page':page,'per_page':250},token)
                    for m in batch.get('data',[]):
                        merged.append(dict(m,divisionId=div['id'],**{k:v for k,v in byid.get(str(m['id']),{}).items() if k not in ('id','name','divisionId')}))
                    if page>=int(batch.get('meta',{}).get('last_page',1)):break
                    page+=1
                    if page>100:raise ValueError('Event schedule is unexpectedly large')
            rows=merged;warning=''
        except ValueError as e:
            if not rows:
                if cached:return dict(cached,cached=True,warning='Refresh failed: '+str(e))
                raise
            warning='Match times loaded; official team/score details could not be refreshed. '+str(e)
        if not rows and not event:raise ValueError('Event was not found')
        if event and not any(isinstance(r.get('timestamp'),(int,float)) and r['timestamp']>=0 for r in rows):
            try:
                resolved={str(t['id']):t for t in worlds_timestamps(event,rows,remote)}
                rows=[dict(r,**{k:v for k,v in resolved.get(str(r['id']),{}).items() if k!='id'}) for r in rows]
            except ValueError as e:warning+=' Worlds video lookup: '+str(e)
        divs={str(d['id']):d['name'] for d in (event or {}).get('divisions',[])} or (preset or {}).get('divisions',{})
        matches=[normalize(r,divs) for r in rows]
        for m in matches:m['_baseVideo']={k:m.get(k) for k in ('timestamp','url','available','timing')}
        cached=self.read(sku) or cached
        if cached:
            old={r['key']:r for r in cached['matches']}
            for m in matches:
                previous=old.get(m['key'],{})
                if previous.get('timing') in ('Manual calibration','Recording calibration'):
                    for k in ('timestamp','url','available','timing'):m[k]=previous[k]
                    m['_manualVideo']={k:previous[k] for k in ('timestamp','url','available','timing')}
        data={'sku':sku,'name':(event or {}).get('name') or (preset or {}).get('name') or sku,'divisions':[{'id':id,'name':name} for id,name in sorted(({m['divisionId']:m['division'] for m in matches} or divs).items())],'matches':sorted(matches,key=match_order),'fetched':time.time(),'warning':warning, 'cached':False,'id':(event or {}).get('id'),'start':(event or {}).get('start') or (cached or {}).get('start'),'end':(event or {}).get('end') or (cached or {}).get('end'),'program':(event or {}).get('program'),'location':(event or {}).get('location'),'sourceUrl':'https://events.vex.com/robot-competitions/'+('vex-iq-competition/' if any(t in sku for t in ('VIQ','VE-IQ')) else 'vex-robotics-competition/')+sku+'.html','streams':(cached or {}).get('streams',[]),'streamChoices':(cached or {}).get('streamChoices',{}),'discovery':(cached or {}).get('discovery'),'autoTiming':(cached or {}).get('autoTiming'),'recordingDurations':(cached or {}).get('recordingDurations',{}),'timingOffset':(cached or {}).get('timingOffset',0)}
        apply_streams(data);self.write(sku,data);return data
    def calibrate(self,sku,key,url,timestamp):
        data=self.read(self.sku(sku))
        if not data:raise ValueError('Load the event first')
        row=next((m for m in data['matches'] if m['key']==key),None)
        if not row:raise ValueError('Match not found')
        row.setdefault('_baseVideo',{k:row.get(k) for k in ('timestamp','url','available','timing')})
        row.update(timestamp=timestamp,url=url,available=True,timing='Manual calibration');row['_manualVideo']={k:row[k] for k in ('timestamp','url','available','timing')};self.write(data['sku'],data);return data
    def map_recording(self,sku,key,url,timestamp):
        from datetime import datetime
        data=self.read(self.sku(sku))
        if not data:raise ValueError('Load the event first')
        anchor=next((m for m in data['matches'] if m['key']==key),None)
        def match_time(m):
            started=m.get('started');scheduled=m.get('scheduled')
            if started and scheduled:
                if abs((datetime.fromisoformat(started.replace('Z','+00:00'))-datetime.fromisoformat(scheduled.replace('Z','+00:00'))).total_seconds())>1800:return scheduled
            return started or scheduled
        if not anchor or not match_time(anchor):raise ValueError('Choose a match with an official start or scheduled time')
        try:
            when=match_time(anchor);origin=datetime.fromisoformat(when.replace('Z','+00:00'));changed=0
            for m in data['matches']:
                moment=match_time(m)
                if m['divisionId']!=anchor['divisionId'] or not moment or moment[:10]!=when[:10]:continue
                position=timestamp+(datetime.fromisoformat(moment.replace('Z','+00:00'))-origin).total_seconds()
                if not 0<=position<604800:continue
                m.update(timestamp=position,url=url,available=True,timing='Recording calibration');changed+=1
        except (TypeError,ValueError):raise ValueError('Official match dates could not be used for this recording') from None
        self.write(data['sku'],data);return {'event':data,'changed':changed}
    def archived(self):
        """SKUs the user has put away. The schedule stays on this Mac, just out of the main list."""
        with self.lock:
            try:
                value=json.loads((self.root/'archived.json').read_text())
                return {x for x in value if isinstance(x,str)} if isinstance(value,list) else set()
            except (OSError,ValueError):return set()
    def set_archived(self,value,archived):
        sku=self.sku(value)
        with self.lock:
            if not (self.root/(sku+'.json')).exists():raise ValueError('That event is not saved on this Mac')
            keys=self.archived();(keys.add if archived else keys.discard)(sku);self.write('archived',sorted(keys))
        return {'ok':True,'sku':sku,'archived':bool(archived)}
    def remove(self,value):
        """Deletes the saved schedule and recordings. Downloaded clips are separate and stay."""
        sku=self.sku(value)
        with self.lock:
            p=self.root/(sku+'.json')
            if not p.exists():raise ValueError('That event is not saved on this Mac')
            p.unlink();keys=self.archived()
            if sku in keys:keys.discard(sku);self.write('archived',sorted(keys))
        return {'ok':True,'sku':sku}
    def saved(self):
        result=[]
        for p in [*self.root.glob('RE-*.json'),*self.root.glob('VE-*.json')]:
            d=self.read(p.stem);result.append({'sku':d['sku'],'name':d.get('name',d['sku']),'divisions':{x['id']:x['name'] for x in d.get('divisions',[])}})
        return result

    def save_stream(self,sku,body):
        if body.get('syncMode')=='auto':
            from auto_timing import probe
            body=dict(body)
            try:
                info=probe(body.get('url',''),self.root/'stream-metadata');body['metadata']=info
                if info.get('duration'):body['duration']=info['duration']
            except ValueError as e:body['metadata']={'autoError':str(e)}
        with self.lock:
            data=self.read(self.sku(sku))
            if not data:raise ValueError('Load the event first')
            streams=data.setdefault('streams',[])
            if body.get('id') and not any(s['id']==body['id'] for s in streams):raise ValueError('Recording was not found')
            stream=normalize_stream(data,body)
            data['streams']=[s for s in streams if s['id']!=stream['id']]+[stream];data.pop('autoTiming',None)
            apply_streams(data);self.write(data['sku'],data);return data
    def set_timing_offset(self,sku,offset):
        """Shifts every found video position in the event (seconds; negative is earlier). Positions set by hand stay."""
        offset=round(number(offset,minimum=-TIMING_OFFSET_LIMIT,maximum=TIMING_OFFSET_LIMIT),1)
        with self.lock:
            data=self.read(self.sku(sku))
            if not data:raise ValueError('Load the event first')
            data['timingOffset']=offset
            apply_streams(data);self.write(data['sku'],data);return data
    def delete_stream(self,sku,id):
        with self.lock:
            data=self.read(self.sku(sku))
            if not data:raise ValueError('Load the event first')
            data['streams']=[s for s in data.get('streams',[]) if s['id']!=id]
            data['streamChoices']={k:v for k,v in data.get('streamChoices',{}).items() if v!=id}
            apply_streams(data);self.write(data['sku'],data);return data
    def choose_stream(self,sku,key,id):
        with self.lock:
            data=self.read(self.sku(sku))
            if not data:raise ValueError('Load the event first')
            apply_streams(data);m=next((m for m in data['matches'] if m['key']==key),None)
            if not m or not any(o['id']==id for o in m.get('streamOptions',[])):raise ValueError('This recording does not cover the selected match')
            data.setdefault('streamChoices',{})[key]=id
            m.pop('_manualVideo',None);m.update(m['_baseVideo'])
            apply_streams(data);self.write(data['sku'],data);return data
    def discover_streams(self,sku,refresh=False):
        from webcast import discover
        sku=self.sku(sku);data=self.read(sku)
        if not data:raise ValueError('Load the event first')
        if data.get('discovery') and not refresh:return data
        result=discover(data,remote)
        with self.lock:
            data=self.read(sku);data['discovery']=result;self.write(sku,data)
        return data

    def auto_time(self,sku,search=True):
        from auto_timing import auto_time
        sku=self.sku(sku);data=self.read(sku)
        if not data:raise ValueError('Load the event first')
        original_streams=json.dumps(data.get('streams',[]),sort_keys=True)
        result=auto_time(data,self.root/'stream-metadata',search)
        with self.lock:
            latest=self.read(sku)
            if json.dumps(latest.get('streams',[]),sort_keys=True)!=original_streams:
                raise ValueError('Recordings changed while automatic timing ran. Try Auto time matches again.')
            result['streamChoices']=latest.get('streamChoices',{})
            for m in result.get('matches',[]):
                old=next((x for x in latest.get('matches',[]) if x['key']==m['key']),{})
                if old.get('_manualVideo'):m['_manualVideo']=old['_manualVideo']
            apply_streams(result);self.write(sku,result)
        return result
