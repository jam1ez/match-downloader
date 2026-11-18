#!/usr/bin/env python3
"""Prepare a fresh library copy and exercise the native client without computer use."""
import sys, json, os, pathlib, shutil, socket, sqlite3, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
# Fail before starting any backend if the reserved test port is in use.
with socket.socket() as sock:
    if sock.connect_ex(('127.0.0.1', 8799)) == 0:
        raise SystemExit('Port 8799 is occupied; no process was stopped.')
copy = pathlib.Path(tempfile.mkdtemp(prefix='match-native-verify-')) / 'library'
copy.mkdir()
for name in ('events', 'ocr-tools'):
    shutil.copytree(ROOT / 'library' / name, copy / name, ignore=shutil.ignore_patterns('Watermarks Cleaned'))
with sqlite3.connect((ROOT / 'library/library.sqlite').as_uri() + '?mode=ro', uri=True) as source, sqlite3.connect(copy / 'library.sqlite') as target:
    source.backup(target)
source_id = '0' * 32
folder = copy / source_id
folder.mkdir()
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=blue:s=320x240:r=10', '-t', '8', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(folder / 'clip.mp4')], check=True)
with sqlite3.connect(copy / 'library.sqlite') as db:
    db.execute('INSERT OR REPLACE INTO clips(id,title,url,start,end,notes,status,detail,created) VALUES(?,?,?,?,?,?,?,?,?)', (source_id, 'No clock source', 'http://127.0.0.1:8799/video/' + source_id, 0, 8, '', 'ready', 'Integration source', 0))
event = dict(sku='RE-V5RC-25-9999', name='Native integration fixture', divisions=[dict(id='1', name='Main')], days=['2026-11-18'], streams=[], matches=[])
for number in (1, 2, 3, 4):
    event['matches'].append(dict(key=f'1:{number}', id=number, name=f'Qualification {number}', label=f'Q{number}', divisionId='1', division='Main', timestamp=1, url='http://127.0.0.1:8799/video/' + source_id, available=True, teams=[], alliances=[], timing='Manual calibration'))
for m in event['matches']:
    m['started'] = m['scheduled'] = '2026-11-18T09:00:00-08:00'
    if m['id'] >= 3:
        m.update(available=False, timestamp=None, url='', timing='Needs timing')
(copy / 'events' / (event['sku'] + '.json')).write_text(json.dumps(event))
(copy / 'events/RE-V5RC-25-9904.json').write_bytes((ROOT / 'mac/Tests/MatchCoreTests/Fixtures/event-schedule.json').read_bytes())
exe = ROOT / 'Match Downloader.app/Contents/MacOS/Match Downloader'
env = dict(os.environ, MATCH_DOWNLOADER_DATA=str(copy), MATCH_DOWNLOADER_PORT='8799', MATCH_DOWNLOADER_ROOT=str(ROOT))
print('Test copy:', copy, flush=True)
phase = 'RECORDINGS' if '--recordings' in sys.argv else 'SCHEDULE' if '--schedule' in sys.argv else 'DOWNLOADS'
result = subprocess.run([str(exe), '--verify-' + phase.lower()], env=env, capture_output=True, text=True, timeout=180)
print(result.stdout)
print(result.stderr[-2000:])
assert result.returncode == 0 and ('VERIFY_' + phase + '_PASS') in result.stdout, 'Native integration failed'
assert not (copy / '.session-token').exists(), 'Backend token remains after quit'
print('Native integration PASS; backend stopped. Copy retained for inspection.')
