// Match Downloader prototype. Same local API as the original UI (web/index.html).
import {createPreview, recordingLink} from '/preview.js';

const token = document.querySelector('meta[name=token]').content;
const $ = id => document.getElementById(id);
const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const clock = x => { x = Math.max(0, Math.floor(Number(x) || 0)); return [Math.floor(x / 3600), Math.floor(x % 3600 / 60), x % 60].map(n => String(n).padStart(2, '0')).join(':'); };
const parseClock = v => String(v || '').split(':').reduce((n, s) => n * 60 + (Number(s) || 0), 0);
const size = b => b >= 1073741824 ? (b / 1073741824).toFixed(1) + ' GB' : (b / 1048576).toFixed(1) + ' MB';
const ACTIVE = ['queued', 'downloading', 'analyzing', 'processing'];
const STATUS = {ready: 'Saved', needs_review: 'Needs review', queued: 'Queued', downloading: 'Downloading', analyzing: 'Reading match clock', processing: 'Processing', failed: 'Failed', cancelled: 'Cancelled'};
const stateClass = s => ACTIVE.includes(s) ? 'active' : s;
const showLabel = l => String(l).replace(/^R16(\d+-\d+)$/, 'R16 $1');
// Failed jobs keep the tail of the tool log; the useful part is its last ERROR line.
const failure = d => { const lines = String(d || '').split('\n').map(x => x.trim()).filter(Boolean); const err = lines.filter(x => /^ERROR:/.test(x)).at(-1); return (err || lines.at(-1) || 'Download failed').replace(/^ERROR:\s*(\[[^\]]+\]\s*)?/, ''); };

async function post(path, data = {}, signal) {
  const r = await fetch(path, {method: 'POST', signal, headers: {'Content-Type': 'application/json', 'X-Scout-Token': token}, body: JSON.stringify(data)});
  const v = await r.json();
  if (!r.ok) throw Error(v.error || 'Request failed');
  return v;
}
const resolveSource = (url, signal) => post('/api/preview/source', {url}, signal);

function toast(message, bad = false) {
  const el = document.createElement('div');
  el.className = 'toast' + (bad ? ' bad' : ''); el.textContent = message;
  $('toasts').append(el); setTimeout(() => el.remove(), bad ? 7000 : 3500);
}
function confirmBox(title, body, action) {
  $('confirmTitle').textContent = title; $('confirmBody').textContent = body; $('confirmOk').textContent = action;
  const d = $('dlgConfirm'); d.returnValue = ''; d.showModal();
  return new Promise(res => d.addEventListener('close', () => res(d.returnValue === 'ok'), {once: true}));
}
document.addEventListener('click', e => { const b = e.target.closest('[data-close]'); if (b) b.closest('dialog').close(); });

/* ---------- Routing ---------- */
let view = 'matches';
function route() {
  const [, section = 'matches', sku] = location.hash.match(/^#\/([a-z]+)(?:\/(.+))?/) || [];
  view = ['matches', 'library', 'clip'].includes(section) ? section : 'matches';
  for (const v of ['matches', 'library', 'clip']) $('view-' + v).hidden = v !== view;
  document.querySelectorAll('.tabs a').forEach(a => a.toggleAttribute('aria-current', a.dataset.view === view) && a.setAttribute('aria-current', 'page'));
  document.title = {matches: ev ? ev.name + ' – Match Downloader' : 'Match Downloader', library: 'Library – Match Downloader', clip: 'Clip from a link – Match Downloader'}[view];
  if (view === 'library') renderLibrary();
  if (view === 'matches' && sku && decodeURIComponent(sku) !== ev?.sku) loadEvent(decodeURIComponent(sku));
}
window.addEventListener('hashchange', route);
function setEventHash(sku) { const h = '#/matches/' + encodeURIComponent(sku); if (location.hash !== h) history.replaceState(null, '', h); }

/* ---------- Library state (polled) ---------- */
let clips = [], libSignature = '', matchSignature = '';
async function refresh() {
  try {
    const r = await fetch('/api/library'); if (!r.ok) throw Error();
    const d = await r.json(); clips = d.clips; $('banner').hidden = d.ffmpeg;
    if (!d.ffmpeg) $('banner').textContent = 'FFmpeg is not installed, so downloads cannot run. See the README for how to install it.';
    const ready = clips.filter(c => c.status === 'ready'), active = clips.filter(c => ACTIVE.includes(c.status));
    $('libCount').textContent = active.length ? active.length + ' active' : ready.length || '';
    const running = clips.find(c => ['downloading', 'analyzing', 'processing'].includes(c.status));
    $('sysStatus').innerHTML = (running ? '<b>' + esc(STATUS[running.status]) + '</b> ' + esc(shortTitle(running)) + (active.length > 1 ? ', ' + (active.length - 1) + ' waiting' : '') + '<span aria-hidden="true">  </span>' : '') + esc((d.free / 1073741824).toFixed(0) + ' GB free');
    $('storage').textContent = 'Saved in ' + d.storage + '. ' + ready.length + ' saved, ' + size(clips.reduce((s, c) => s + c.bytes, 0)) + ' in total.';
    const sig = JSON.stringify(clips.map(c => [c.id, c.status, c.detail, c.bytes, c.notes]));
    if (sig !== libSignature) { libSignature = sig; if (view === 'library') renderLibrary(); }
    const eventSig = ev ? clips.filter(c => c.event_ref === ev.sku).map(c => c.match_ref + c.status).sort().join() : '';
    if (ev && eventSig !== matchSignature && !$('rows').contains(document.activeElement)) { matchSignature = eventSig; renderRows(); }
    $('banner').hidden = d.ffmpeg;
  } catch { $('banner').hidden = false; $('banner').textContent = 'Lost contact with the app. Reopen Match Downloader to continue; saved videos are unaffected.'; }
}

/* ---------- Events ---------- */
let catalogue = [], ev = null, loadSeq = 0, selected = new Set();
function renderEventList(target = $('eventList')) {
  const q = $('eventFilter').value.toLowerCase(), scope = $('eventScope').value;
  const list = catalogue.filter(e => (e.name + ' ' + e.sku).toLowerCase().includes(q) && (scope === 'all' || (scope === 'saved' ? e.saved : !e.custom)));
  target.innerHTML = list.length ? list.map(e => `<li><button type="button" data-sku="${esc(e.sku)}" ${ev?.sku === e.sku ? 'aria-current="true"' : ''}>${esc(e.name)}<small>${esc(e.sku)}${e.saved ? ', saved' : ''}</small></button></li>`).join('')
    : '<li class="none">No events match. Add one by its code below.</li>';
}
async function loadCatalogue(force = false) {
  $('catalogueStatus').textContent = 'Updating…';
  try { const d = await post('/api/events/catalogue', {refresh: force}); catalogue = d.events; $('catalogueStatus').textContent = d.offline ? 'Offline list' : catalogue.length + ' events'; renderEventList(); }
  catch (e) { $('catalogueStatus').textContent = ''; $('eventList').innerHTML = '<li class="none">' + esc(e.message) + '</li>'; }
}
function rememberEvent(d) {
  const e = catalogue.find(x => x.sku === d.sku);
  if (e) e.saved = true; else catalogue.push({sku: d.sku, name: d.name, saved: true, custom: true});
}
async function loadEvent(sku, force = false) {
  const seq = ++loadSeq;
  $('eventEmpty').hidden = false; $('eventBody').hidden = true;
  $('eventEmpty').innerHTML = '<h1>Loading schedule…</h1><p>Reading matches and video positions.</p>';
  try {
    const d = await post('/api/events/load', {sku, refresh: force});
    if (seq !== loadSeq) return;
    ev = d; selected.clear(); matchSignature = '';
    $('eventEmpty').hidden = true; $('eventBody').hidden = false;
    $('fDivision').innerHTML = '<option value="all">All divisions</option>' + d.divisions.map(x => `<option value="${esc(x.id)}">${esc(x.name)}</option>`).join('');
    $('fDay').innerHTML = '<option value="all">All days</option>' + (d.days || []).map((x, i) => `<option value="${esc(x)}">Day ${i + 1}, ${esc(dayName(x))}</option>`).join('');
    $('fRound').value = 'all'; $('fQuery').value = '';
    renderHead(); renderRows(); renderRecordings();
    rememberEvent(d); renderEventList(); setEventHash(d.sku); localStorage.setItem('matchdl.lastEvent', d.sku);
    document.title = d.name + ' – Match Downloader';
    $('dlgEvents').open && $('dlgEvents').close();
    if (force) toast('Schedule refreshed');
    if (!d.discovery) discover().then(maybeAutoTime); else maybeAutoTime();
  } catch (e) {
    if (seq !== loadSeq) return;
    $('eventEmpty').innerHTML = '<h1>This event could not be loaded</h1><p>' + esc(e.message) + '</p><p>Check the event code, or pick another event. Schedules you already loaded work offline.</p>';
  }
}
const dayName = iso => { const d = new Date(iso + 'T12:00:00'); return isNaN(d) ? iso : d.toLocaleDateString(undefined, {weekday: 'short', day: 'numeric', month: 'short'}); };
function renderHead() {
  const timed = ev.matches.filter(m => m.available).length;
  $('eventName').textContent = ev.name;
  const range = ev.days?.length ? dayName(ev.days[0]) + (ev.days.length > 1 ? ' to ' + dayName(ev.days.at(-1)) : '') : '';
  const facts = [['Code', ev.sku], range && ['Dates', range], ['Matches', ev.matches.length], ['With video', timed + ' of ' + ev.matches.length], ['Schedule', ev.cached ? 'Saved on this laptop' : 'Updated just now']].filter(Boolean);
  $('eventFacts').innerHTML = facts.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('');
  $('eventNote').textContent = ev.warning || '';
  $('eventNote').classList.toggle('warn', !!ev.warning);
  $('recCount').textContent = (ev.streams || []).length || '';
}

/* ---------- Schedule table ---------- */
const roundOf = l => /^Q\d+$/.test(l) ? 'Q' : /^R16/.test(l) ? 'R16' : (l.match(/^[A-Z]+/) || [''])[0];
const matchDay = m => String(m.started || m.scheduled || '').slice(0, 10);
function canonical(s) { return s.toUpperCase().replace(/[\s#_()]/g, '').replace(/^QUALIFICATIONS?|^QUALIFIER|^QUAL/, 'Q').replace(/^QUARTERFINALS?/, 'QF').replace(/^SEMIFINALS?/, 'SF').replace(/^ROUNDOF16/, 'R16').replace(/^FINALS?/, 'F').replace(/^PRACTICE/, 'P'); }
function matchesQuery(m, q) {
  if (!q.trim()) return true;
  return q.split(/[,;\n]+/).map(s => canonical(s.trim())).filter(Boolean).some(t => {
    const range = t.match(/^Q(\d+)-Q?(\d+)$/);
    if (range) return /^Q\d+$/.test(m.label) && +m.label.slice(1) >= +range[1] && +m.label.slice(1) <= +range[2];
    if (/^(?:Q\d+|QF\d+-\d+|SF\d+-\d+|F\d+-\d+|R16\d+-\d+|P\d+)$/.test(t)) return m.label === t;
    return canonical(m.name).includes(t) || m.teams.some(team => team.toUpperCase().includes(t));
  });
}
function shown() {
  if (!ev) return [];
  const div = $('fDivision').value, round = $('fRound').value, day = $('fDay').value, q = $('fQuery').value, videoOnly = $('fVideo').checked;
  return ev.matches.filter(m => (div === 'all' || m.divisionId === div) && (round === 'all' || roundOf(m.label) === round) && (day === 'all' || matchDay(m) === day) && (!videoOnly || m.available) && matchesQuery(m, q));
}
const SOURCE = {'Jumper': 'Event feed', 'BoxCast estimate': 'Worlds broadcast', 'Manual calibration': 'Set by you', 'Recording calibration': 'Set by you', 'Auto timing (broadcast start)': 'Broadcast start time', 'Stream sync': 'Your recording'};
const NOPOS = {'Needs timing': 'No video position', 'Choose recording': 'Choose a recording', 'Needs sync or another recording': 'Recording not lined up yet'};
function alliance(a, other, color) {
  if (!a) return `<td class="al ${color}"><div class="bar"><span class="teams meta">Not published</span></div></td>`;
  const win = a.score != null && other?.score != null && a.score > other.score;
  return `<td class="al ${color}${win ? ' win' : ''}"><div class="bar"><span class="teams" title="${esc(a.teams.join(', '))}">${esc(a.teams.join('  ')) || '<span class="meta">TBD</span>'}</span><span class="score">${a.score ?? ''}</span></div></td>`;
}
function renderRows() {
  if (!ev) return;
  const rows = shown(), dayIndex = Object.fromEntries((ev.days || []).map((d, i) => [d, i + 1]));
  const byMatch = new Map(clips.filter(c => c.event_ref === ev.sku && c.status !== 'cancelled').map(c => [c.match_ref, c]));
  $('rows').innerHTML = rows.length ? rows.map(m => {
    const red = m.alliances.find(a => a.color === 'red'), blue = m.alliances.find(a => a.color === 'blue');
    const clip = byMatch.get(m.key), sel = selected.has(m.key);
    const options = m.streamOptions?.length > (m.available ? 1 : 0) ? `<select data-stream="${esc(m.key)}" aria-label="Recording for ${esc(m.label)}"><option value="">${m.available ? 'Switch recording' : 'Choose a recording'}</option>${m.streamOptions.map(o => `<option value="${esc(o.id)}" ${o.id === m.streamId ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select>` : '';
    const video = m.available
      ? `<span class="time">${clock(m.timestamp)}</span><span class="src" title="${esc(m.timing)}">${esc(m.streamLabel || SOURCE[m.timing] || m.timing)}</span>`
      : `<span class="nopos${m.timing === 'Choose recording' ? ' act' : ''}">${esc(NOPOS[m.timing] || m.timing || 'No video position')}</span>`;
    return `<tr class="${sel ? 'sel' : ''}${m.available ? '' : ' off'}" data-key="${esc(m.key)}">
      <td class="c-check"><input type="checkbox" data-key="${esc(m.key)}" aria-label="Select ${esc(m.label)}, ${esc(m.division)}" ${sel ? 'checked' : ''} ${m.available ? '' : 'disabled'}></td>
      <td><span class="m-label" title="${esc(m.name)}">${esc(showLabel(m.label))}</span>${clip ? `<span class="state ${stateClass(clip.status)}">${esc(STATUS[clip.status] || clip.status)}</span>` : ''}</td>
      <td>${esc(m.division)}<span class="sub">${dayIndex[matchDay(m)] ? 'Day ' + dayIndex[matchDay(m)] : esc(matchDay(m))}${m.field ? ', ' + esc(m.field) : ''}</span></td>
      ${alliance(red, blue, 'red')}${alliance(blue, red, 'blue')}
      <td>${video}${options}</td>
      <td><div class="row-actions">${m.available ? `<button type="button" data-act="preview" data-key="${esc(m.key)}">Preview</button>` : ''}<button type="button" data-act="timing" data-key="${esc(m.key)}">${m.available ? 'Adjust' : 'Set position'}</button></div></td></tr>`;
  }).join('') : `<tr><td colspan="7" class="no-rows">No matches fit these filters.</td></tr>`;
  const timed = rows.filter(m => m.available).length;
  $('shownCount').textContent = rows.length + ' of ' + ev.matches.length + ' matches shown' + (rows.length !== timed ? ', ' + (rows.length - timed) + ' without a video position' : '') + '.';
  updateTray();
}
function updateTray() {
  const avail = shown().filter(m => m.available), n = selected.size;
  $('selectAll').checked = avail.length > 0 && avail.every(m => selected.has(m.key));
  $('selectAll').indeterminate = !$('selectAll').checked && avail.some(m => selected.has(m.key));
  const hidden = [...selected].filter(k => !avail.some(m => m.key === k)).length;
  $('selCount').textContent = n ? n + ' selected' : 'None selected';
  $('clearSel').hidden = !n;
  $('tray').classList.toggle('has', !!n);
  $('download').disabled = !n;
  $('download').innerHTML = n ? 'Download<span class="dl-n"> ' + n + (n === 1 ? ' match' : ' matches') + '</span>' : 'Download';
  const dynamic = trimMode() === 'dynamic';
  $('trayHint').textContent = (hidden ? hidden + ' selected ' + (hidden === 1 ? 'match is' : 'matches are') + ' outside the current filters. ' : '') +
    (dynamic ? 'Reads the on-screen match clock to cut from the autonomous start to the end of driver control. Unclear results wait for you in the library.' : 'Saves a fixed length from the start position, including the time before.');
}
const trimMode = () => document.querySelector('input[name=trim]:checked').value;

for (const id of ['fDivision', 'fRound', 'fDay', 'fVideo']) $(id).addEventListener('change', renderRows);
$('fQuery').addEventListener('input', renderRows);
$('queryForm').addEventListener('submit', e => { e.preventDefault(); for (const m of shown()) if (m.available) selected.add(m.key); renderRows(); });
$('selectAll').addEventListener('change', e => { for (const m of shown()) if (m.available) e.target.checked ? selected.add(m.key) : selected.delete(m.key); renderRows(); });
$('clearSel').addEventListener('click', () => { selected.clear(); renderRows(); });
$('trayOptions').addEventListener('click', () => { const open = $('tray').classList.toggle('open'); $('trayOptions').setAttribute('aria-expanded', open); $('trayOptions').textContent = open ? 'Hide options' : 'Options'; });
document.querySelectorAll('input[name=trim]').forEach(r => r.addEventListener('change', () => {
  const dynamic = trimMode() === 'dynamic';
  document.querySelectorAll('[data-mode]').forEach(el => el.hidden = el.dataset.mode !== (dynamic ? 'dynamic' : 'fixed'));
  updateTray();
}));
$('rows').addEventListener('change', async e => {
  const t = e.target;
  if (t.dataset.stream && t.value) { try { applyEvent(await post('/api/events/streams/choose', {sku: ev.sku, key: t.dataset.stream, id: t.value})); toast('Recording chosen'); } catch (err) { toast(err.message, true); } return; }
  if (t.type === 'checkbox') { t.checked ? selected.add(t.dataset.key) : selected.delete(t.dataset.key); t.closest('tr').classList.toggle('sel', t.checked); updateTray(); }
});
$('rows').addEventListener('click', e => {
  const b = e.target.closest('[data-act]'); if (!b) return;
  const m = ev.matches.find(x => x.key === b.dataset.key);
  if (b.dataset.act === 'preview') openPreview(m); else openTiming(m);
});
$('tray').addEventListener('submit', async e => {
  e.preventDefault();
  const b = $('download'); b.disabled = true; b.textContent = 'Adding…';
  try {
    const d = await post('/api/events/queue', {sku: ev.sku, keys: [...selected], mode: trimMode(), duration: $('tLength').value, before: $('tBefore').value, tail: $('tAfter').value, window: $('tWindow').value, offset: $('tShift').value});
    toast(d.added.length + (d.added.length === 1 ? ' match' : ' matches') + ' added to downloads' + (d.skipped.length ? '. ' + d.skipped.length + ' already in the library' : ''));
    selected.clear(); await refresh(); renderRows();
  } catch (err) { toast(err.message, true); updateTray(); }
});

/* ---------- Preview and video position ---------- */
let preview = null, timingKey = null;
function openPreview(m) {
  preview?.destroy();
  const target = Math.max(0, Number(m.timestamp) + Number($('tShift').value || 0) - Number($('tBefore').value || 0));
  $('previewTitle').textContent = m.label + (m.division ? ', ' + m.division : '');
  $('previewState').textContent = 'Loading player…'; $('previewJump').disabled = true;
  try { $('previewOriginal').href = recordingLink(m.url, target); } catch { $('previewOriginal').removeAttribute('href'); }
  $('dlgPreview').showModal();
  try {
    preview = createPreview($('previewFrame'), {url: m.url, target, resolveSource, onState: s => {
      $('previewJump').disabled = !s.ready;
      $('previewState').className = s.error ? 'error' : 'meta';
      $('previewState').textContent = s.error || s.loading || s.warning || (Number.isFinite(s.position) ? 'At ' + clock(s.position) + ' of the recording' + (s.pending ? ', moving to ' + clock(target) + '…' : '') : 'Press play to start at ' + clock(target) + '.');
    }});
  } catch (e) { $('previewState').className = 'error'; $('previewState').textContent = e.message; }
}
$('previewJump').addEventListener('click', () => preview?.jump());
$('dlgPreview').addEventListener('close', () => { preview?.destroy(); preview = null; });
function openTiming(m) {
  timingKey = m.key; $('timingTitle').textContent = 'Video position for ' + m.label;
  $('timingUrl').value = m.url || ''; $('timingAt').value = m.timestamp == null ? '' : clock(m.timestamp); $('timingError').textContent = '';
  $('dlgTiming').showModal();
}
$('timingForm').addEventListener('submit', async e => {
  e.preventDefault();
  try { applyEvent(await post('/api/events/calibrate', {sku: ev.sku, key: timingKey, url: $('timingUrl').value, timestamp: $('timingAt').value})); $('dlgTiming').close(); toast('Position saved'); }
  catch (err) { $('timingError').textContent = err.message; }
});

/* ---------- Recordings ---------- */
let autoBusy = false, revision = 0;
function applyEvent(d) {
  ev = d; revision++;
  for (const k of [...selected]) if (!d.matches.some(m => m.key === k && m.available)) selected.delete(k);
  renderHead(); renderRows(); renderRecordings();
}
function syncText(r) {
  if (!r.enabled) return ['Not used', ''];
  if (r.syncMode === 'none') return ['Not lined up', 'warn'];
  if (r.syncMode === 'auto') return r.metadata?.startEstimate ? ['Broadcast start ' + new Date(r.metadata.startEstimate).toLocaleString(undefined, {dateStyle: 'medium', timeStyle: 'short'}), 'ok'] : ['No broadcast start found. Line it up with a match.', 'warn'];
  if (r.syncMode === 'anchor') { const a = ev.matches.find(m => m.key === r.anchorKey); return ['Lined up on ' + (a?.label || 'a match') + ' at ' + clock(r.anchorPosition), 'ok']; }
  return ['Started ' + r.wallStart, 'ok'];
}
function renderRecordings() {
  if (!ev) return;
  const s = ev.streamSummary || {}, at = ev.autoTiming, timed = ev.matches.filter(m => m.available).length;
  if (!autoBusy) $('recAutoStatus').textContent = timed + ' of ' + ev.matches.length + ' matches have a video position.' + (s.estimated ? ' ' + s.estimated + ' estimated from the same recording.' : '') + (s.ambiguous ? ' ' + s.ambiguous + ' need you to choose a recording.' : '') + (at?.messages?.length ? ' ' + at.messages.join(' ') : '');
  $('recList').innerHTML = (ev.streams || []).map(r => {
    const div = ev.divisions.find(d => d.id === r.divisionId)?.name || 'All divisions', [state, tone] = syncText(r);
    return `<li><b>${esc(r.label)}</b><div class="actions"><button type="button" data-rec="edit" data-id="${esc(r.id)}">Edit</button><button type="button" data-rec="preview" data-id="${esc(r.id)}">Preview</button><button type="button" data-rec="delete" data-id="${esc(r.id)}">Remove</button></div>
      <span class="meta">${esc(dayName(r.date))}, ${esc(div)}${r.field ? ', ' + esc(r.field) : ''}${r.firstMatch || r.lastMatch ? ', part of the day' : ''}${r.fillOnly ? ', fills gaps only' : ''}</span>
      <span class="tag ${tone}">${esc(state)}${r.offset ? ', shifted ' + esc(r.offset) + ' s' : ''}</span></li>`;
  }).join('') || '<li class="empty-line">No recordings added. Add one if the event feed has no video positions.</li>';
  const disc = ev.discovery;
  $('recDiscovery').textContent = disc ? [disc.description && '“' + disc.description.trim() + '”', disc.candidates?.length ? '' : 'No recording links were published.', ...(disc.errors || []).map(x => ({'Jumper stream lookup unavailable': 'Stream detection is unavailable right now.', 'VEX webcast lookup unavailable': 'The event page could not be checked.'}[x] || x))].filter(Boolean).join(' ') : 'Not checked yet.';
  $('recCandidates').innerHTML = (disc?.candidates || []).map((c, i) => {
    let where = c.url, kind = c.platform + ' link';
    try { const u = new URL(c.url); where = u.hostname.replace(/^www\./, '') + u.pathname + u.search; if (c.platform === 'YouTube') kind = /^\/(@|channel|c\/|user)/.test(u.pathname) ? 'YouTube channel' : 'YouTube video'; } catch {}
    const added = (ev.streams || []).some(r => r.url === c.url);
    return `<li><b>${esc(c.label && c.label !== c.url ? c.label : where)}</b><div class="actions">${added ? '<span class="tag ok">Added</span>' : `<button type="button" data-cand="${i}">Add</button>`}</div><span class="meta">${esc(kind)}, found by ${esc(c.source === 'Jumper detection' ? 'stream detection' : 'the event page')}</span></li>`;
  }).join('');
}
async function discover(force = false) {
  if (!ev) return;
  const sku = ev.sku, rev = revision; $('recDiscover').disabled = true; $('recDiscovery').textContent = 'Checking the event page and stream detection…';
  try { const d = await post('/api/events/streams/discover', {sku, refresh: force}); if (ev?.sku !== sku) return; if (rev === revision) ev = d; else ev.discovery = d.discovery; renderRecordings(); }
  catch (e) { if (ev?.sku === sku) $('recDiscovery').textContent = e.message + ' You can still add a recording yourself.'; }
  finally { $('recDiscover').disabled = false; }
}
async function autoTime() {
  if (!ev || autoBusy) return;
  const sku = ev.sku; autoBusy = true; $('recAuto').disabled = true;
  $('recAutoStatus').textContent = 'Finding video positions from broadcast start times…';
  $('eventNote').classList.remove('warn'); $('eventNote').textContent = 'Finding video positions…';
  try { const d = await post('/api/events/auto-time', {sku, search: true}); if (ev?.sku === sku) { autoBusy = false; applyEvent(d); } }
  catch (e) { if (ev?.sku === sku) { $('recAutoStatus').textContent = e.message; renderHead(); } }
  finally { autoBusy = false; $('recAuto').disabled = false; }
}
function maybeAutoTime() {
  const e = ev; if (!e || !e.matches.length || !e.matches.some(m => !m.available)) return;
  if (!e.autoTiming || (!e.cached && e.fetched && e.autoTiming.checked < e.fetched)) autoTime();
}
$('openRecordings').addEventListener('click', () => { renderRecordings(); $('dlgRecordings').showModal(); });
$('refreshEvent').addEventListener('click', () => loadEvent(ev.sku, true));
$('recAuto').addEventListener('click', autoTime);
$('recDiscover').addEventListener('click', () => discover(true));
$('recAdd').addEventListener('click', () => openEditor());
$('recList').addEventListener('click', async e => {
  const b = e.target.closest('[data-rec]'); if (!b) return;
  const r = ev.streams.find(s => s.id === b.dataset.id);
  if (b.dataset.rec === 'edit') return openEditor(r);
  if (b.dataset.rec === 'preview') return openPreview({url: r.url, timestamp: 0, label: r.label, division: ''});
  if (!await confirmBox('Remove this recording?', 'Matches lose the positions it provided. Downloaded videos stay in the library.', 'Remove recording')) return;
  try { applyEvent(await post('/api/events/streams/delete', {sku: ev.sku, id: r.id})); toast('Recording removed'); } catch (err) { toast(err.message, true); }
});
$('recCandidates').addEventListener('click', e => {
  const b = e.target.closest('[data-cand]'); if (!b) return;
  const c = ev.discovery.candidates[+b.dataset.cand];
  const record = {url: c.url, label: c.label && c.label !== c.url ? c.label : '', divisionId: c.divisionId || '*', date: ev.days?.[c.dayIndex || 0]};
  if (c.streamStartTime) { const t = new Date(c.streamStartTime); if (!isNaN(t)) record.metadata = {startEstimate: t.toISOString()}; }
  openEditor(record);
});

/* ---------- Recording editor ---------- */
let editorPlayer = null, info = {}, channel = [];
const syncMode = () => document.querySelector('input[name=sync]:checked').value;
function setSync(v) { document.querySelector(`input[name=sync][value="${v}"]`).checked = true; updateSync(); }
function updateSync() { const m = syncMode(); $('eAnchorFields').hidden = m !== 'anchor'; $('eWallFields').hidden = m !== 'wallclock'; $('ePosition').required = $('eAnchor').required = m === 'anchor'; $('eWall').required = m === 'wallclock'; }
document.querySelectorAll('input[name=sync]').forEach(r => r.addEventListener('change', updateSync));
function scopeRows() {
  return ev.matches.filter(m => ($('eDivision').value === '*' || m.divisionId === $('eDivision').value) && matchDay(m) === $('eDay').value && (!$('eField').value || m.field === $('eField').value))
    .sort((a, b) => new Date(a.started || a.scheduled) - new Date(b.started || b.scheduled));
}
function matchOptions(rows, first) {
  return '<option value="">' + first + '</option>' + rows.map(m => { const t = String(($('eBasis').value === 'scheduled' ? m.scheduled : m.started) || m.scheduled || ''); const time = t ? new Date(t).toLocaleTimeString(undefined, {hour: '2-digit', minute: '2-digit'}) : ''; return `<option value="${esc(m.key)}">${esc(m.label)}, ${esc(m.division)}${m.field ? ', ' + esc(m.field) : ''}${time ? ' at ' + esc(time) : ''}</option>`; }).join('');
}
function refreshScope() {
  const rows = scopeRows();
  for (const [id, first] of [['eFirst', 'Start of the day'], ['eLast', 'End of the day']]) { const v = $(id).value; $(id).innerHTML = matchOptions(rows, first); if (rows.some(m => m.key === v)) $(id).value = v; }
  let part = rows; const f = $('eFirst').value, l = $('eLast').value;
  if (f) part = part.slice(part.findIndex(m => m.key === f)); if (l) part = part.slice(0, part.findIndex(m => m.key === l) + 1);
  const a = $('eAnchor').value; $('eAnchor').innerHTML = matchOptions(part, 'Choose a match'); if (part.some(m => m.key === a)) $('eAnchor').value = a;
}
for (const id of ['eDay', 'eDivision', 'eField', 'eBasis', 'eFirst', 'eLast']) $(id).addEventListener('change', refreshScope);
function openEditor(r = {}) {
  editorPlayer?.destroy(); editorPlayer = null; info = r.metadata || {}; channel = [];
  $('editorTitle').textContent = r.id ? 'Edit recording' : 'Add recording';
  $('eId').value = r.id || ''; $('eUrl').value = r.url || ''; $('eLabel').value = r.label || '';
  $('eDays').innerHTML = (ev.days || []).map(d => `<option value="${esc(d)}">`).join('');
  $('eDay').value = r.date || ev.days?.[0] || matchDay(ev.matches[0] || {});
  $('eDivision').innerHTML = '<option value="*">All divisions</option>' + ev.divisions.map(d => `<option value="${esc(d.id)}">${esc(d.name)}</option>`).join('');
  $('eDivision').value = r.divisionId || ($('fDivision').value !== 'all' ? $('fDivision').value : '*');
  $('eField').innerHTML = '<option value="">All fields</option>' + [...new Set(ev.matches.map(m => m.field).filter(Boolean))].map(f => `<option>${esc(f)}</option>`).join('');
  $('eField').value = r.field || ''; $('eBasis').value = r.basis || 'actual';
  $('eFirst').innerHTML = $('eLast').innerHTML = $('eAnchor').innerHTML = '';
  refreshScope(); $('eFirst').value = r.firstMatch || ''; $('eLast').value = r.lastMatch || ''; refreshScope();
  $('eAnchor').value = r.anchorKey || ''; $('ePosition').value = r.anchorPosition !== undefined ? clock(r.anchorPosition) : '';
  $('eWall').value = r.wallStart || ''; $('eOffset').value = r.offset || 0; $('eDuration').value = r.duration || '';
  $('eEnabled').checked = r.enabled !== false; $('eFillOnly').checked = r.fillOnly === true;
  $('eError').textContent = ''; $('eInfo').textContent = ''; $('eChannel').hidden = true; $('ePlayerWrap').hidden = true;
  $('eCapture').disabled = true; $('eUseDetected').disabled = !info.startEstimate;
  setSync(r.syncMode || 'auto');
  $('dlgEditor').showModal();
}
$('dlgEditor').addEventListener('close', () => { editorPlayer?.destroy(); editorPlayer = null; });
$('eUrl').addEventListener('change', () => { if ($('eId').value) { info = {}; $('eDuration').value = ''; $('ePosition').value = ''; $('eWall').value = ''; $('eUseDetected').disabled = true; $('eInfo').textContent = 'The link changed. Check its position before saving.'; } });
$('eProbe').addEventListener('click', async () => {
  $('eProbe').disabled = true; $('eInfo').textContent = 'Reading recording details…';
  try {
    const d = await post('/api/events/streams/probe', {url: $('eUrl').value}); info = d;
    $('eInfo').textContent = [d.title, d.duration ? 'Length ' + clock(d.duration) : '', d.startEstimate ? 'Broadcast start found.' : 'No broadcast start; line it up with a match.'].filter(Boolean).join('. ');
    if (!$('eLabel').value) $('eLabel').value = d.title || ''; if (d.duration) $('eDuration').value = d.duration;
    $('eUseDetected').disabled = !d.startEstimate;
    channel = d.recordings || []; $('eChannel').hidden = !channel.length;
    $('eChannelPick').innerHTML = channel.map((r, i) => `<option value="${i}">${esc(r.title || r.url)}</option>`).join('');
  } catch (e) { $('eInfo').textContent = e.message; } finally { $('eProbe').disabled = false; }
});
$('eChannelUse').addEventListener('click', () => { const r = channel[+$('eChannelPick').value]; if (r) { $('eUrl').value = r.url; $('eLabel').value = r.title || ''; $('eChannel').hidden = true; $('eProbe').click(); } });
$('eUseDetected').addEventListener('click', () => { $('eWall').value = info.startEstimate || ''; });
$('eLoadPlayer').addEventListener('click', () => {
  editorPlayer?.destroy(); $('ePlayerWrap').hidden = false; $('eCapture').disabled = true;
  try {
    editorPlayer = createPreview($('ePlayer'), {url: $('eUrl').value, target: parseClock($('ePosition').value), resolveSource, onState: s => {
      $('eCapture').disabled = !s.ready;
      $('ePlayerState').textContent = s.error || s.loading || (Number.isFinite(s.position) ? 'At ' + clock(s.position) : 'Press play, find a match start, then choose Use player time.');
    }});
  } catch (e) { $('ePlayerState').textContent = e.message; }
});
$('eCapture').addEventListener('click', async () => { try { $('ePosition').value = clock(await editorPlayer.getCurrentTime()); } catch (e) { $('eError').textContent = e.message; } });
for (const [id, step] of [['eBack', -10], ['eFwd', 10]]) $(id).addEventListener('click', async () => { try { await editorPlayer.seekTo(Math.max(0, (await editorPlayer.getCurrentTime()) + step)); } catch (e) { $('ePlayerState').textContent = e.message; } });
$('editorForm').addEventListener('submit', async e => {
  e.preventDefault(); $('eSave').disabled = true; $('eError').textContent = syncMode() === 'auto' ? 'Reading the broadcast start time…' : '';
  try {
    const stream = {id: $('eId').value || undefined, label: $('eLabel').value, url: $('eUrl').value, date: $('eDay').value, divisionId: $('eDivision').value, field: $('eField').value, basis: $('eBasis').value, firstMatch: $('eFirst').value, lastMatch: $('eLast').value, syncMode: syncMode(), anchorKey: $('eAnchor').value, anchorPosition: parseClock($('ePosition').value), wallStart: $('eWall').value, offset: $('eOffset').value, duration: $('eDuration').value, enabled: $('eEnabled').checked, fillOnly: $('eFillOnly').checked, metadata: info};
    applyEvent(await post('/api/events/streams/save', {sku: ev.sku, stream})); $('dlgEditor').close(); toast('Recording saved');
  } catch (err) { $('eError').textContent = err.message; } finally { $('eSave').disabled = false; }
});

/* ---------- Library ---------- */
function shortTitle(c) { if (!c.event_ref) return c.title; const p = c.title.split(' · '); return p.at(-1) + (p.length > 2 ? ', ' + p.at(-2) : ''); }
// Event downloads start with generated notes ("SKU · Division · Teams: … · Jumper · red: 3").
// Show the teams and score; anything the user typed is kept as is.
function readableNotes(c, parts) {
  if (!c.event_ref) return c.notes;
  const known = new Set([c.event_ref, parts.at(-2), ...Object.keys(SOURCE), 'Needs timing']);
  return c.notes.split(' · ').filter(x => !known.has(x) && !/^Estimated from /.test(x)).map(x => x.replace(/^Teams: /, 'Teams ').replace(/\b(red|blue): (\d+)/g, (_, col, n) => col[0].toUpperCase() + col.slice(1) + ' ' + n).replace(' / ', ', ')).join('. ');
}
function renderLibrary() {
  const filter = document.querySelector('input[name=lib]:checked').value, q = $('libSearch').value.toLowerCase();
  const counts = {all: clips.length, ready: 0, active: 0, needs_review: 0, failed: 0};
  for (const c of clips) { if (c.status in counts) counts[c.status]++; if (ACTIVE.includes(c.status)) counts.active++; }
  document.querySelectorAll('#libFilter i').forEach(i => i.textContent = counts[i.dataset.n] || '');
  const rows = clips.filter(c => (c.title + ' ' + c.notes).toLowerCase().includes(q) && (filter === 'all' || c.status === filter || (filter === 'active' && ACTIVE.includes(c.status))));
  $('clips').innerHTML = rows.length ? rows.map(c => {
    const p = c.title.split(' · '), eventClip = c.event_ref && p.length > 2;
    const head = eventClip ? `<b>${esc(showLabel(p.at(-1)))}</b><span class="div">${esc(p.at(-2))}</span><span class="sub">${esc(p.slice(0, -2).join(' · '))}</span>` : `<b>${esc(c.title)}</b><span class="sub">From a link</span>`;
    const timing = c.clip_mode === 'dynamic' && c.status !== 'ready' ? (() => { try { return 'Searching near ' + clock(JSON.parse(c.detect_settings).anchor); } catch { return ''; } })() : clock(c.start) + ' to ' + clock(c.end);
    const act = ACTIVE.includes(c.status);
    const buttons = [
      c.status === 'ready' && `<button type="button" data-clip="play" data-id="${c.id}">Play</button><button type="button" data-clip="export" data-id="${c.id}">Save MP4…</button>`,
      c.status === 'needs_review' && `<button type="button" class="primary" data-clip="bounds" data-id="${c.id}">Check start and end</button>`,
      ['failed', 'cancelled'].includes(c.status) && `<button type="button" data-clip="retry" data-id="${c.id}">Retry</button>`,
      `<button type="button" data-clip="notes" data-id="${c.id}">Notes</button>`,
      act ? `<button type="button" data-clip="cancel" data-id="${c.id}">Cancel</button>` : `<button type="button" data-clip="delete" data-id="${c.id}">Delete</button>`,
    ].filter(Boolean).join('');
    return `<li class="clip"><div class="clip-title">${head}</div>
      <div class="clip-status"><span class="state ${stateClass(c.status)}">${esc(STATUS[c.status] || c.status)}</span> <span class="meta">${esc(timing)}</span>
        <span class="detail${c.status === 'failed' ? ' err' : ''}" title="${esc(c.detail)}">${esc(c.status === 'failed' ? failure(c.detail) : c.status === 'ready' && c.detail === 'Saved on this laptop' ? '' : c.detail)}</span>${act && c.status !== 'queued' ? '<div class="progress" aria-hidden="true"></div>' : ''}</div>
      <div class="clip-size">${c.bytes ? size(c.bytes) : ''}</div><div class="clip-actions">${buttons}</div>
      ${c.notes ? `<p class="clip-notes" title="${esc(c.notes)}">${esc(readableNotes(c, p))}</p>` : ''}</li>`;
  }).join('') : `<li class="lib-empty">${clips.length ? 'Nothing matches this filter.' : 'No downloads yet. Select matches on the Matches page, or clip from a link.'}</li>`;
}
document.querySelectorAll('input[name=lib]').forEach(r => r.addEventListener('change', renderLibrary));
$('libSearch').addEventListener('input', renderLibrary);
let notesId = null, reviewing = null;
$('clips').addEventListener('click', async e => {
  const b = e.target.closest('[data-clip]'); if (!b) return;
  const c = clips.find(x => x.id === b.dataset.id), a = b.dataset.clip;
  if (a === 'play') { $('playerTitle').textContent = shortTitle(c); $('playerNotes').textContent = c.notes; $('playerVideo').src = '/video/' + c.id; $('dlgPlayer').showModal(); return; }
  if (a === 'export') { const l = document.createElement('a'); l.href = '/video/' + c.id; l.download = c.title.replace(/[^a-z0-9 _-]/gi, '_') + '.mp4'; l.click(); return; }
  if (a === 'notes') { notesId = c.id; $('notesTitle').textContent = 'Notes for ' + shortTitle(c); $('notesText').value = c.notes; $('dlgNotes').showModal(); return; }
  if (a === 'bounds') return openBounds(c);
  if (a === 'delete' && !await confirmBox('Delete ' + shortTitle(c) + '?', 'The video and its notes are removed from this laptop. This cannot be undone.', 'Delete')) return;
  if (a === 'cancel' && !await confirmBox('Cancel this download?', 'You can retry it later from the library.', 'Cancel download')) return;
  try { await post('/api/clips/' + c.id + '/' + a, {}); toast({retry: 'Download restarted', cancel: 'Download cancelled', delete: 'Deleted'}[a]); refresh(); } catch (err) { toast(err.message, true); }
});
$('notesForm').addEventListener('submit', async e => { e.preventDefault(); try { await post('/api/clips/' + notesId + '/notes', {notes: $('notesText').value}); $('dlgNotes').close(); toast('Notes saved'); refresh(); } catch (err) { toast(err.message, true); } });
$('dlgPlayer').addEventListener('close', () => { const v = $('playerVideo'); v.pause(); v.removeAttribute('src'); v.load(); });
function openBounds(c) {
  reviewing = c; let a = {}; try { a = JSON.parse(c.analysis_json || '{}'); } catch {}
  const start = a.start ?? Math.max(0, c.start - (c.source_start || 0)), end = a.end ?? Math.min(a.source_duration || 0, start + 180);
  $('boundsTitle').textContent = 'Check start and end: ' + shortTitle(c);
  $('boundsReason').textContent = c.detail; $('bStart').value = clock(start); $('bEnd').value = clock(end); $('boundsError').textContent = '';
  $('boundsOrigin').textContent = 'This window begins at ' + clock(c.source_start || 0) + ' in the original recording. Times here are within the window. Include the autonomous start, the pause and the end of driver control.';
  const v = $('boundsVideo'); v.src = '/review/' + c.id; v.addEventListener('loadedmetadata', () => { v.currentTime = start; }, {once: true});
  $('dlgBounds').showModal();
}
$('bMarkStart').addEventListener('click', () => $('bStart').value = clock($('boundsVideo').currentTime));
$('bMarkEnd').addEventListener('click', () => $('bEnd').value = clock($('boundsVideo').currentTime));
$('dlgBounds').addEventListener('close', () => { const v = $('boundsVideo'); v.pause(); v.removeAttribute('src'); v.load(); reviewing = null; });
$('boundsForm').addEventListener('submit', async e => { e.preventDefault(); try { await post('/api/clips/' + reviewing.id + '/bounds', {start: $('bStart').value, end: $('bEnd').value}); $('dlgBounds').close(); toast('Saving clip with your start and end'); refresh(); } catch (err) { $('boundsError').textContent = err.message; } });

/* ---------- Clip from a link ---------- */
let imports = [];
$('clipForm').addEventListener('submit', async e => {
  e.preventDefault(); $('clipError').textContent = '';
  try { await post('/api/clips', {title: $('cTitle').value, url: $('cUrl').value, start: $('cStart').value, end: $('cEnd').value, notes: $('cNotes').value}); toast('Added to downloads'); $('cTitle').value = ''; $('cNotes').value = ''; refresh(); }
  catch (err) { $('clipError').textContent = err.message; }
});
$('importFile').addEventListener('change', async e => {
  try {
    imports = JSON.parse(await e.target.files[0].text());
    if (!Array.isArray(imports) || imports.length > 200) throw Error('The file must contain a list of up to 200 entries.');
    $('importList').className = 'import-list';
    $('importList').innerHTML = imports.map((c, i) => `<label><input type="checkbox" checked data-i="${i}"> ${esc(c.title)} <span class="meta">${esc(c.start)} to ${esc(c.end)}</span></label>`).join('');
    $('importQueue').hidden = false;
  } catch (err) { toast(err.message, true); }
});
$('importQueue').addEventListener('click', async () => {
  const b = $('importQueue'); b.disabled = true; let n = 0;
  try { for (const el of $('importList').querySelectorAll('input:checked')) { await post('/api/clips', imports[el.dataset.i]); el.checked = false; n++; } toast(n + ' added to downloads'); refresh(); }
  catch (err) { toast('Stopped after ' + n + ': ' + err.message, true); } finally { b.disabled = false; }
});

/* ---------- Event rail, bulk add, mobile picker ---------- */
$('eventFilter').addEventListener('input', () => renderEventList());
$('eventScope').addEventListener('change', () => renderEventList());
$('refreshCatalogue').addEventListener('click', () => loadCatalogue(true));
$('eventList').addEventListener('click', e => { const b = e.target.closest('[data-sku]'); if (b) location.hash = '#/matches/' + encodeURIComponent(b.dataset.sku); });
$('addEventForm').addEventListener('submit', e => { e.preventDefault(); loadEvent($('addEventInput').value).then(() => { if (ev) $('addEventInput').value = ''; }); });
$('openBulk').addEventListener('click', () => { $('bulkStatus').textContent = ''; $('dlgBulk').showModal(); });
$('bulkGo').addEventListener('click', async () => {
  const lines = [...new Set($('bulkInput').value.split('\n').map(x => x.trim()).filter(Boolean))]; if (!lines.length) return;
  $('bulkGo').disabled = true; let ok = 0; const failed = [];
  for (const [i, v] of lines.entries()) { $('bulkStatus').textContent = 'Adding ' + (i + 1) + ' of ' + lines.length + '…'; try { rememberEvent(await post('/api/events/load', {sku: v})); ok++; renderEventList(); } catch (e) { failed.push(v + ': ' + e.message); } }
  $('bulkStatus').textContent = ok + ' added.' + (failed.length ? ' Not added: ' + failed.join('; ') : ''); $('bulkGo').disabled = false;
});
$('pickEvent').addEventListener('click', () => {
  const body = $('eventsSheetBody'); body.replaceChildren($('eventFilter').closest('.rail-head'), $('eventList'), $('addEventForm'));
  $('dlgEvents').showModal();
});
$('dlgEvents').addEventListener('close', () => { const rail = document.querySelector('.rail'); rail.append($('eventFilter').closest('.rail-head'), $('eventList'), $('addEventForm')); });

/* ---------- Start ---------- */
await loadCatalogue();
if (!location.hash) { const last = localStorage.getItem('matchdl.lastEvent'); history.replaceState(null, '', last ? '#/matches/' + encodeURIComponent(last) : '#/matches'); }
route();
updateTray();
refresh(); setInterval(refresh, 2500);
