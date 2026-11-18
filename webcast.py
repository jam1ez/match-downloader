"""Read VEX webcast descriptions and Jumper stream candidates; never guess a URL."""
import re,time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlencode,urlparse,parse_qs
from html import unescape
from event_streams import video_url

def candidate(url,source,label='',**extra):
    try:url=video_url(unescape(url).strip().rstrip('.,;)'))
    except ValueError:return None
    host=(urlparse(url).hostname or '').lower()
    platform='YouTube' if host in ('youtube.com','www.youtube.com','youtu.be','m.youtube.com') else 'Vimeo' if host.endswith('vimeo.com') else 'BoxCast' if host.endswith('boxcast.tv') else 'Dailymotion' if host.endswith('dailymotion.com') else 'External'
    return dict(url=url,source=source,label=label or platform+' recording',platform=platform,**extra)

def discover(event,fetch):
    sku=event['sku'];candidates=[];description='';errors=[]
    def page():return fetch('https://openscout.ing/api/event-info?'+urlencode({'sku':sku}))
    def jumper():
        import json
        params={'sku':sku,'eventStart':event.get('start') or '', 'eventEnd':event.get('end') or '', 'divisions':json.dumps(event.get('divisions',[]))}
        return fetch('https://jumper.robostem.org/api/detect-streams?'+urlencode(params))
    with ThreadPoolExecutor(max_workers=2) as pool:
        jobs=[('page',pool.submit(page)),('jumper',pool.submit(jumper))]
        for kind,job in jobs:
            try:
                data=job.result()
                if kind=='page':
                    webcast=data.get('webcast') or {};description=webcast.get('description') or ''
                    for link in webcast.get('links') or []:
                        if isinstance(link,dict):
                            c=candidate(link.get('url',''),'VEX Events webcast',link.get('label',''))
                            if c:candidates.append(c)
                    for url in re.findall(r'https?://[^\s<>"\x27]+',description):
                        c=candidate(url,'VEX Events webcast')
                        if c:candidates.append(c)
                else:
                    for stream in data.get('streams') or []:
                        url=stream.get('url') or ('https://www.youtube.com/watch?v='+stream['videoId'] if stream.get('videoId') else '')
                        c=candidate(url,'Jumper detection',stream.get('label',''),divisionId=str(stream.get('divisionId') or '*'),dayIndex=stream.get('dayIndex'),streamStartTime=stream.get('streamStartTime'))
                        if c:candidates.append(c)
            except (ValueError,TypeError,AttributeError):errors.append('VEX webcast lookup unavailable' if kind=='page' else 'Jumper stream lookup unavailable')
    seen=set();unique=[]
    for c in candidates:
        u=urlparse(c['url']);host=(u.hostname or '').replace('www.','');video=None
        if host=='youtu.be':video=u.path.strip('/').split('/')[0]
        elif host in ('youtube.com','m.youtube.com'):
            video=(parse_qs(u.query).get('v') or [None])[0]
            if not video:
                m=re.search(r'/(?:live|embed|shorts)/([A-Za-z0-9_-]{11})',u.path)
                if m:video=m[1]
        key='youtube:'+video if video else c['url']
        if key in seen:continue
        seen.add(key);unique.append(c)
    return {'candidates':unique,'description':description,'checked':time.time(),'errors':errors}
