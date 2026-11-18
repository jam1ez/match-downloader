#!/usr/bin/env python3
"""Point Match Downloader at a new VEX Worlds.

    python3 tools/new_worlds_season.py 2027 "Worlds 27"        # looks the events up and writes the config
    python3 tools/new_worlds_season.py 2027 "Worlds 27" --dry-run

It finds that year's World Championship events on RobotEvents (through the same data service the app uses),
copies each program's BoxCast channel from the latest earlier year in worlds.json, then writes the new year
into worlds.json and sets worlds-season.json, which is what the app's Worlds folder reads. Restart the app
(or its engine) afterwards. If a channel is missing it says so: take the id from vexworlds.tv, where a channel
page is https://www.vexworlds.tv/#/channels/<id>.
"""
import json, os, sys, tempfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from events import Events  # noqa: E402

STANDARD = ['Arts', 'Design', 'Engineering', 'Innovate', 'Math', 'Opportunity', 'Research', 'Science', 'Spirit', 'Technology']

def program_of(event):
    code = (event.get('program') or {}).get('code', '').upper()
    name = event.get('name', '').lower()
    if code in ('V5RC', 'VRC'):
        return 'V5RC HS' if 'high school' in name else 'V5RC MS' if 'middle school' in name else None
    if code in ('VURC', 'VEXU'):
        return 'VURC'
    if code in ('VIQRC', 'VIQC'):
        return 'VIQRC ES' if 'elementary' in name else 'VIQRC MS' if 'middle' in name else None
    return None

def division_names(event, known):
    """Worlds divisions are named for a word (Arts, Design...). Anything else, such as a finals bracket, is dropped."""
    names, dropped = set(), []
    for d in event.get('divisions', []):
        raw = d.get('name', '')
        hit = next((w for w in STANDARD + known if w.lower() in raw.lower()), None)
        if hit:
            names.add(hit)
        elif raw.lower() not in event.get('name', '').lower():  # the finals bracket is named for the program
            dropped.append(raw)
    return sorted(names), dropped

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dry = '--dry-run' in sys.argv
    if not args or not args[0].isdigit():
        sys.exit(__doc__)
    year = args[0]
    title = args[1] if len(args) > 1 else 'Worlds ' + year[-2:]
    config = json.loads((ROOT / 'worlds.json').read_text())
    earlier = sorted(y for y in config if y < year)
    with tempfile.TemporaryDirectory() as tmp:
        raw = Events(tmp).re_get('events', {'start': f'{year}-03-01', 'end': f'{year}-07-15', 'level[]': 'World', 'per_page': 50},
                                 os.environ.get('ROBOTEVENTS_API_KEY', ''))
    found = raw.get('data', raw) if isinstance(raw, dict) else raw
    block, problems = {}, []
    for event in found:
        program = program_of(event)
        if not program or 'world' not in event.get('name', '').lower():
            continue
        previous = next((config[y][program] for y in reversed(earlier) if program in config[y]), None)
        start, end = event['start'][:10], event['end'][:10]
        divisions, dropped = division_names(event, previous['divisions'] if previous else [])
        if dropped:
            problems.append(f'{program}: left out non-division names {dropped}. If one is a real division, add it to worlds.json.')
        block[program] = {
            'channelId': previous['channelId'] if previous else '',
            'sku': event['sku'],
            'eventStart': start, 'eventEnd': end,
            'divisions': divisions,
            'numDays': (date.fromisoformat(end) - date.fromisoformat(start)).days + 1,
            'broadcastOverrides': {},
        }
        if not previous:
            problems.append(f'{program}: no earlier channel to copy. Add its channelId from vexworlds.tv.')
    if not block:
        sys.exit(f'No World Championship events found for {year} yet. Try again closer to the event.')
    print(json.dumps({year: block}, indent=2))
    for p in problems:
        print('NOTE', p)
    if dry:
        print('Dry run: nothing written.')
        return
    config[year] = block
    (ROOT / 'worlds.json').write_text(json.dumps(config, indent=2) + '\n')
    (ROOT / 'worlds-season.json').write_text(json.dumps({'year': year, 'title': title}, indent=2) + '\n')
    print(f'Wrote worlds.json and worlds-season.json ({title}). Restart Match Downloader.')

if __name__ == '__main__':
    main()
