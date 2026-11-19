// Match Downloader, web version. Uses the engine's local JSON API, like the Mac app.
import {createPreview, recordingLink} from '/preview.js';

const token = document.querySelector('meta[name=token]').content;
const $ = id => document.getElementById(id);
const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const clock = x => { x = Math.max(0, Math.floor(Number(x) || 0)); return [Math.floor(x / 3600), Math.floor(x % 3600 / 60), x % 60].map(n => String(n).padStart(2, '0')).join(':'); };
const parseClock = v => String(v || '').split(':').reduce((n, s) => n * 60 + (Number(s) || 0), 0);
const size = b => b >= 1073741824 ? (b / 1073741824).toFixed(1) + ' GB' : b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : b ? Math.max(1, Math.round(b / 1024)) + ' KB' : '';
const plural = (n, one, many = one + 's') => n + ' ' + (n === 1 ? one : many);
const store = {get: (k, d) => { try { return JSON.parse(localStorage.getItem('md.' + k)) ?? d; } catch { return d; } }, set: (k, v) => { try { localStorage.setItem('md.' + k, JSON.stringify(v)); } catch {} }};
const ACTIVE = ['queued', 'downloading', 'analyzing', 'processing'];
const STATUS = {ready: 'Saved', needs_review: 'Needs review', queued: 'Waiting', downloading: 'Downloading', analyzing: 'Reading match clock', processing: 'Processing', failed: 'Failed', cancelled: 'Stopped'};
const stateClass = s => ACTIVE.includes(s) ? 'active' : s;
const showLabel = l => String(l).replace(/^R16(\d+-\d+)$/, 'R16 $1');
const failure = d => { const lines = String(d || '').split('\n').map(x => x.trim()).filter(Boolean); const err = lines.filter(x => /^ERROR:/.test(x)).at(-1); return (err || lines.at(-1) || 'Download failed').replace(/^ERROR:\s*(\[[^\]]+\]\s*)?/, ''); };
const SOURCE = {'Jumper': 'Event feed', 'BoxCast estimate': 'Worlds broadcast', 'Manual calibration': 'Set by you', 'Recording calibration': 'Set by you', 'Auto timing (broadcast start)': 'Broadcast start time', 'Stream sync': 'Your recording'};
const NOPOS = {'Needs timing': 'No position', 'Choose recording': 'Choose a recording', 'Needs sync or another recording': 'Recording not lined up'};
const dayName = iso => { const d = new Date(iso + 'T12:00:00'); return isNaN(d) ? iso : d.toLocaleDateString(undefined, {weekday: 'short', month: 'short', day: 'numeric'}); };

async function post(path, data = {}, signal) {
  const r = await fetch(path, {method: 'POST', signal, headers: {'Content-Type': 'application/json', 'X-Scout-Token': token}, body: JSON.stringify(data)});
  const v = await r.json();
  if (!r.ok) throw Error(v.error || 'The request failed.');
  return v;
}
const resolveSource = (url, signal) => post('/api/preview/source', {url}, signal);

/* ---------- Feedback lives in the window: the status bar (feedback.md) ---------- */
let sayTimer;
function syncHud() { $('hud').classList.toggle('on', !!($('statusLeft').textContent || $('statusRight').textContent)); }
function setInfo(text) { $('statusLeft').textContent = text; syncHud(); }
function say(message, {busy = false, error = false, sticky = false} = {}) {
  clearTimeout(sayTimer);
  $('statusRight').innerHTML = message ? (busy ? '<span class="spinner" aria-hidden="true"></span>' : '') + esc(message) : '';
  $('hud').classList.toggle('err', error); syncHud();
  if (!sticky && !busy && message) sayTimer = setTimeout(() => { $('statusRight').textContent = ''; $('hud').classList.remove('err'); syncHud(); }, error ? 9000 : 4500);
}
/* Segmented controls: a thumb that slides to the chosen segment */
function thumb(seg) {
  if (!seg || !seg.offsetParent) return;
  let t = seg.querySelector('.seg-thumb'); if (!t) { t = document.createElement('span'); t.className = 'seg-thumb'; t.setAttribute('aria-hidden', 'true'); seg.prepend(t); }
  const on = seg.querySelector('input:checked')?.closest('label'); if (!on) return;
  t.style.left = on.offsetLeft + 'px'; t.style.width = on.offsetWidth + 'px';
}
const thumbs = () => document.querySelectorAll('.segmented').forEach(thumb);
document.addEventListener('change', e => { const seg = e.target.closest('.segmented'); if (seg) thumb(seg); });
window.addEventListener('resize', thumbs);

/* ---------- Alerts and sheets ---------- */
function alertBox(title, text, action) {
  const d = $('alert'); $('alTitle').textContent = title; $('alText').textContent = text;
  $('alOk').textContent = action; $('alOk').className = 'push destructive'; d.returnValue = '';
  d.showModal(); d.querySelector('button[value=cancel]').focus();
  return new Promise(res => d.addEventListener('close', () => res(d.returnValue === 'ok'), {once: true}));
}
document.addEventListener('click', e => { const b = e.target.closest('[data-cancel]'); if (b) b.closest('dialog').close(); });

/* ---------- State ---------- */
let view = 'empty', ev = null, byKey = new Map(), catalogue = [], clips = [], loadSeq = 0, autoBusy = false, revision = 0;
const evSel = new Set(), libSel = new Set();
const evState = {focus: null, anchor: null}, libState = {focus: null, anchor: null};
let evSort = store.get('evSort', null), libSort = store.get('libSort', {key: 'added', dir: -1});
const ui = {inspector: store.get('inspector', true), sidebar: store.get('sidebar', true), inspTab: 'match', collapsed: store.get('collapsed', {})};

/* ---------- Routing ---------- */
function route() {
  const [, section = '', arg] = location.hash.match(/^#\/([a-z]+)(?:\/(.+))?/) || [];
  if (section === 'event' && arg) { const sku = decodeURIComponent(arg); if (sku !== ev?.sku) loadEvent(sku); else show('event'); }
  else if (section === 'downloads') show('downloads');
  else if (section === 'clip') show('clip');
  else show(ev ? 'event' : 'empty');
}
window.addEventListener('hashchange', route);
function show(v) {
  view = v;
  for (const [id, name] of [['paneEvent', 'event'], ['paneDownloads', 'downloads'], ['paneClip', 'clip'], ['paneEmpty', 'empty']]) $(id).hidden = name !== v;
  $('tbEventActions').hidden = $('tbDownload').hidden = v !== 'event'; $('tbLibActions').hidden = v !== 'downloads';
  $('main').classList.toggle('flat', !['event', 'downloads'].includes(v)); setInfo('');
  $('tbSearchWrap').hidden = !['event', 'downloads'].includes(v);
  $('tbSearch').placeholder = v === 'downloads' ? 'Search Downloads' : 'Match or Team';
  $('tbSearch').value = v === 'downloads' ? libQuery : evQuery;
  $('tbInspector').disabled = !['event', 'downloads'].includes(v);
  $('inspTabs').hidden = v !== 'event';
  renderSidebar(); renderTitle(); updateInspectorVisibility();
  if (v === 'downloads') renderLib();
  requestAnimationFrame(thumbs);
  if (v === 'event' && ev) renderEvent();
  if (window.matchMedia('(max-width: 1000px)').matches) $('window').classList.remove('sidebar-open');
}
function renderTitle() {
  const t = {empty: ['Match Downloader', ''], clip: ['Clip from Link', 'Save part of any recording'], downloads: ['Downloads', libSubtitle()], event: [ev?.name || 'Loading…', ev ? eventSubtitle() : '']}[view];
  $('tbTitle').textContent = t[0]; $('tbTitle').title = t[0]; $('tbSubtitle').textContent = t[1];
  document.title = view === 'event' && ev ? ev.name : view === 'downloads' ? 'Downloads' : view === 'clip' ? 'Clip from Link' : 'Match Downloader';
}
const dateRange = days => { if (!days?.length) return ''; const a = new Date(days[0] + 'T12:00:00'), b = new Date(days.at(-1) + 'T12:00:00'); try { return new Intl.DateTimeFormat(undefined, {month: 'short', day: 'numeric', year: 'numeric'}).formatRange(a, b); } catch { return days[0]; } };
const eventSubtitle = () => { const timed = ev.matches.filter(m => m.available).length; return [ev.sku, dateRange(ev.days)].filter(Boolean).join(', '); };
let libInfo = {free: 0};
const libSubtitle = () => { const ready = clips.filter(c => c.status === 'ready'); return plural(ready.length, 'saved match', 'saved matches') + ', ' + (size(ready.reduce((s, c) => s + c.bytes, 0)) || '0 MB') + ' on this Mac, ' + (libInfo.free / 1073741824).toFixed(0) + ' GB free'; };

/* ---------- Sidebar ---------- */
function renderSidebar() {
  const q = $('sbFilter').value.trim().toLowerCase();
  const match = e => !q || (e.name + ' ' + e.sku).toLowerCase().includes(q);
  const item = e => `<li><a class="sb-item" href="#/event/${encodeURIComponent(e.sku)}" ${view === 'event' && ev?.sku === e.sku ? 'aria-current="page"' : ''} title="${esc(e.name)}, ${esc(e.sku)}"><svg class="ic tint" aria-hidden="true"><use href="#i-event"/></svg><span>${esc(e.name)}</span></a></li>`;
  const saved = catalogue.filter(e => e.saved && match(e)), other = catalogue.filter(e => !e.saved && match(e));
  $('sbSaved').innerHTML = saved.map(item).join('') || `<li class="sb-note">${q ? 'No saved events match.' : 'Events you open are kept here for offline use.'}</li>`;
  $('sbCatalogue').innerHTML = other.map(item).join('') || (q ? '<li class="sb-note">No catalogue events match.</li>' : '');
  for (const [section, list] of [['saved', 'sbSaved'], ['catalogue', 'sbCatalogue']]) {
    const open = !ui.collapsed[section]; $(list).hidden = !open;
    document.querySelector(`[data-section=${section}]`).setAttribute('aria-expanded', open);
  }
  document.querySelectorAll('[data-nav]').forEach(a => a.toggleAttribute('aria-current', a.dataset.nav === view) || a.removeAttribute('aria-current'));
  document.querySelectorAll('[data-nav][aria-current]').forEach(a => a.setAttribute('aria-current', 'page'));
}
$('sbFilter').addEventListener('input', renderSidebar);
document.querySelectorAll('.disclose').forEach(b => b.addEventListener('click', () => { ui.collapsed[b.dataset.section] = !ui.collapsed[b.dataset.section]; store.set('collapsed', ui.collapsed); renderSidebar(); }));
async function loadCatalogue(force = false) {
  $('sbNote').textContent = force ? 'Updating the event catalogue…' : '';
  try { const d = await post('/api/events/catalogue', {refresh: force}); catalogue = d.events; $('sbNote').textContent = d.offline ? 'Offline. Showing the saved catalogue.' : ''; if (force) say('Event catalogue updated'); }
  catch (e) { $('sbNote').textContent = e.message; }
  renderSidebar();
}
$('sbUpdate').addEventListener('click', () => loadCatalogue(true));
function toggleSidebar() {
  const narrow = window.matchMedia('(max-width: 1000px)').matches;
  if (narrow) $('window').classList.toggle('sidebar-open'); else { ui.sidebar = !ui.sidebar; store.set('sidebar', ui.sidebar); }
  applyChrome();
}
function applyChrome() {
  const narrow = window.matchMedia('(max-width: 1000px)').matches;
  $('window').classList.toggle('no-sidebar', !narrow && !ui.sidebar);
  const visible = narrow ? $('window').classList.contains('sidebar-open') : ui.sidebar;
  $('tbSidebar').setAttribute('aria-expanded', visible); $('tbSidebar').title = (visible ? 'Hide' : 'Show') + ' Sidebar (⌃⌘S)';
}
$('tbSidebar').addEventListener('click', toggleSidebar);
window.addEventListener('resize', () => { applyChrome(); updateInspectorVisibility(); });

/* ---------- Add events sheet ---------- */
$('sbAdd').addEventListener('click', () => { $('addStatus').textContent = ''; $('addInput').value = ''; $('shAdd').showModal(); });
$('addForm').addEventListener('submit', async e => {
  e.preventDefault();
  const lines = [...new Set($('addInput').value.split('\n').map(x => x.trim()).filter(Boolean))]; if (!lines.length) return;
  $('addGo').disabled = true; let added = null; const failed = [];
  for (const [i, v] of lines.entries()) {
    $('addStatus').textContent = 'Adding ' + (i + 1) + ' of ' + lines.length + '…';
    try { const d = await post('/api/events/load', {sku: v}); remember(d); added = added || d; } catch (err) { failed.push(v + ': ' + err.message); }
  }
  $('addGo').disabled = false; renderSidebar();
  if (failed.length) { $('addStatus').textContent = (lines.length - failed.length) + ' added. Not added: ' + failed.join(' '); return; }
  $('shAdd').close(); say(plural(lines.length, 'event') + ' added');
  if (added && lines.length === 1) location.hash = '#/event/' + encodeURIComponent(added.sku);
});
function remember(d) { const e = catalogue.find(x => x.sku === d.sku); if (e) e.saved = true; else catalogue.push({sku: d.sku, name: d.name, saved: true, custom: true}); }

/* ---------- Generic macOS table selection (lists-and-tables.md, focus-and-selection.md) ---------- */
function selectable({tbody, table, ids, sel, state, changed, activate, context, remove}) {
  const rowOf = el => el.closest('tr[data-id]');
  function paint() {
    for (const tr of tbody.querySelectorAll('tr[data-id]')) {
      const on = sel.has(tr.dataset.id), f = tr.dataset.id === state.focus;
      tr.classList.toggle('sel', on); tr.setAttribute('aria-selected', on); tr.classList.toggle('focus', f); tr.tabIndex = f ? 0 : -1;
    }
    if (!tbody.querySelector('tr[tabindex="0"]')) { const first = tbody.querySelector('tr[data-id]'); if (first) first.tabIndex = 0; }
    changed();
  }
  function focusRow(id, scroll = true) { state.focus = id; paint(); const tr = tbody.querySelector(`tr[data-id="${CSS.escape(id)}"]`); if (tr) { tr.focus({preventScroll: true}); if (scroll) tr.scrollIntoView({block: 'nearest'}); } }
  function range(a, b) { const list = ids(), i = list.indexOf(a), j = list.indexOf(b); if (i < 0 || j < 0) return [b]; return list.slice(Math.min(i, j), Math.max(i, j) + 1); }
  tbody.addEventListener('mousedown', e => {
    const tr = rowOf(e.target); if (!tr || e.button !== 0 || e.target.closest('select,button,input,a')) return;
    const id = tr.dataset.id;
    if (e.metaKey || e.ctrlKey) { sel.has(id) ? sel.delete(id) : sel.add(id); state.anchor = id; }
    else if (e.shiftKey && state.anchor) { sel.clear(); range(state.anchor, id).forEach(x => sel.add(x)); }
    else { sel.clear(); sel.add(id); state.anchor = id; }
    e.preventDefault(); focusRow(id, false);
  });
  tbody.addEventListener('dblclick', e => { const tr = rowOf(e.target); if (tr) activate(tr.dataset.id); });
  tbody.addEventListener('contextmenu', e => {
    const tr = rowOf(e.target); if (!tr) return; e.preventDefault();
    const id = tr.dataset.id; if (!sel.has(id)) { sel.clear(); sel.add(id); state.anchor = id; }
    focusRow(id, false); context(e.clientX, e.clientY);
  });
  table.addEventListener('keydown', e => {
    if (e.target.closest('select,input,textarea,button,a')) return;
    const list = ids(); if (!list.length) return;
    const i = Math.max(0, list.indexOf(state.focus));
    const move = j => { const id = list[Math.max(0, Math.min(list.length - 1, j))]; if (e.shiftKey) { sel.clear(); range(state.anchor || id, id).forEach(x => sel.add(x)); } else { sel.clear(); sel.add(id); state.anchor = id; } focusRow(id); e.preventDefault(); };
    const page = Math.max(1, Math.floor((table.parentElement.clientHeight - 140) / 28) - 1);
    if (e.key === 'ArrowDown') move(state.focus ? i + 1 : 0);
    else if (e.key === 'ArrowUp') move(i - 1);
    else if (e.key === 'Home') move(0); else if (e.key === 'End') move(list.length - 1);
    else if (e.key === 'PageDown') move(i + page); else if (e.key === 'PageUp') move(i - page);
    else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') { e.preventDefault(); list.forEach(x => sel.add(x)); paint(); }
    else if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); if (state.focus) activate(state.focus); }
    else if (e.key === 'Escape') { sel.clear(); paint(); }
    else if ((e.key === 'Backspace' || e.key === 'Delete') && remove) { e.preventDefault(); remove(); }
    else if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) { e.preventDefault(); const tr = tbody.querySelector('tr.focus') || tbody.querySelector('tr[data-id]'); if (tr) { const r = tr.getBoundingClientRect(); context(r.left + 40, r.bottom); } }
  });
  table.addEventListener('focusin', () => changed());
  table.addEventListener('focusout', () => setTimeout(changed));
  return {paint, focusRow};
}

/* ---------- Sortable, resizable column headers (lists-and-tables.md › Desktop) ---------- */
function header({tr, colgroup, cols, sort, storeKey, onSort}) {
  const widths = store.get('cols.' + storeKey, {});
  colgroup.innerHTML = cols.map(c => c.flex ? `<col data-k="${c.key}" style="min-width:${c.w}px">` : `<col data-k="${c.key}" style="width:${widths[c.key] || c.w}px">`).join('');
  const total = cols.reduce((s, c) => s + (c.flex ? c.w : widths[c.key] || c.w), 0); tr.closest('table').style.minWidth = total + 'px';
  tr.innerHTML = cols.map(c => {
    const on = sort && sort.key === c.key;
    return `<th scope="col" data-k="${c.key}" class="${c.sort ? 'sortable' : ''}${c.num ? ' num' : ''}" ${on ? `aria-sort="${sort.dir > 0 ? 'ascending' : 'descending'}"` : ''} ${c.aria ? `aria-label="${esc(c.aria)}"` : ''} title="${c.sort ? 'Sort by ' + esc(c.aria || c.label) : ''}">${esc(c.label)}${on ? `<span class="sort" aria-hidden="true">${sort.dir > 0 ? '▲' : '▼'}</span>` : ''}${c.flex ? '' : '<span class="resize" aria-hidden="true"></span>'}</th>`;
  }).join('');
  tr.onclick = e => {
    const th = e.target.closest('th'); if (!th || e.target.classList.contains('resize')) return;
    const c = cols.find(x => x.key === th.dataset.k); if (!c?.sort) return;
    onSort(sort && sort.key === c.key ? {key: c.key, dir: -sort.dir} : {key: c.key, dir: 1});
  };
  tr.onpointerdown = e => {
    if (!e.target.classList.contains('resize')) return;
    e.preventDefault(); const th = e.target.closest('th'), col = colgroup.querySelector(`col[data-k="${th.dataset.k}"]`), x0 = e.clientX, w0 = th.getBoundingClientRect().width;
    const moveTo = m => { col.style.width = Math.max(40, Math.round(w0 + m.clientX - x0)) + 'px'; };
    const done = () => { widths[th.dataset.k] = parseInt(col.style.width); store.set('cols.' + storeKey, widths); window.removeEventListener('pointermove', moveTo); };
    window.addEventListener('pointermove', moveTo); window.addEventListener('pointerup', done, {once: true});
  };
}

/* ---------- Context menu (context-menus.md) ---------- */
function showMenu(x, y, items) {
  const m = $('menu');
  m.innerHTML = items.map((it, i) => it.sep ? '<div role="separator"></div>' : it.head ? `<div class="menu-head">${esc(it.head)}</div>` : `<button type="button" role="menuitem" data-i="${i}" ${it.disabled ? 'aria-disabled="true"' : ''}><span>${it.checked ? '✓ ' : ''}${esc(it.label)}</span></button>`).join('');
  m.hidden = false;
  const r = m.getBoundingClientRect();
  const left = Math.min(x, innerWidth - r.width - 8), top = Math.min(y, innerHeight - r.height - 8);
  m.style.left = left + 'px'; m.style.top = top + 'px'; m.style.setProperty('--ox', (x - left) + 'px'); m.style.setProperty('--oy', (y - top) + 'px');
  m.style.animation = 'none'; void m.offsetWidth; m.style.animation = '';
  const buttons = [...m.querySelectorAll('[role=menuitem]:not([aria-disabled])')]; buttons[0]?.focus();
  const returnTo = document.activeElement === buttons[0] ? null : document.activeElement;
  m.onclick = e => { const b = e.target.closest('[role=menuitem]'); if (!b || b.getAttribute('aria-disabled')) return; hideMenu(); items[+b.dataset.i].action(); };
  m.onkeydown = e => {
    const i = buttons.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') { e.preventDefault(); buttons[(i + 1) % buttons.length]?.focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); buttons[(i - 1 + buttons.length) % buttons.length]?.focus(); }
    else if (e.key === 'Escape') { e.preventDefault(); hideMenu(); returnTo?.focus(); }
  };
}
function hideMenu() { $('menu').hidden = true; }
document.addEventListener('mousedown', e => { if (!(e.target instanceof Element && e.target.closest('#menu'))) hideMenu(); });
window.addEventListener('blur', hideMenu);

/* ---------- Event ---------- */
let evQuery = '';
const EV_COLS = [
  {key: 'match', label: 'Match', w: 66, sort: true}, {key: 'division', label: 'Division', w: 96, sort: true}, {key: 'day', label: 'Day', w: 62, sort: true},
  {key: 'rs', label: 'Red Alliance', aria: 'Red alliance and score', w: 176, sort: true}, {key: 'bs', label: 'Blue Alliance', aria: 'Blue alliance and score', w: 176, sort: true},
  {key: 'video', label: 'Video', aria: 'Video position', w: 84, num: true, sort: true}, {key: 'source', label: 'Source', w: 84, sort: true, flex: true}, {key: 'status', label: 'Download', w: 92, sort: true}];
async function loadEvent(sku, force = false) {
  const seq = ++loadSeq; show('event');
  if (!ev || ev.sku !== sku) { $('evRows').innerHTML = '<tr class="no-rows"><td colspan="8">Loading schedule…</td></tr>'; $('tbTitle').textContent = 'Loading…'; $('tbSubtitle').textContent = ''; }
  say(force ? 'Refreshing schedule…' : 'Opening event…', {busy: true});
  try {
    const d = await post('/api/events/load', {sku, refresh: force});
    if (seq !== loadSeq) return;
    const same = ev?.sku === d.sku;
    setEvent(d); if (!same) { evSel.clear(); evState.focus = evState.anchor = null; evQuery = ''; $('tbSearch').value = ''; }
    $('fDivision').innerHTML = '<option value="all">All Divisions</option>' + d.divisions.map(x => `<option value="${esc(x.id)}">${esc(x.name)}</option>`).join('');
    $('fDay').innerHTML = '<option value="all">All Days</option>' + (d.days || []).map((x, i) => `<option value="${esc(x)}">Day ${i + 1}, ${esc(dayName(x))}</option>`).join('');
    if (!same) { $('fRound').value = 'all'; $('fVideo').checked = false; }
    remember(d); history.replaceState(null, '', '#/event/' + encodeURIComponent(d.sku)); store.set('lastEvent', d.sku);
    show('event'); say(force ? 'Schedule refreshed' : '');
    if (!d.discovery) discover().then(maybeAutoTime); else maybeAutoTime();
  } catch (e) {
    if (seq !== loadSeq) return;
    ev = null; show('empty'); $('emptyTitle').textContent = 'Can’t Open Event'; $('emptyText').textContent = e.message + ' Check the event code, or choose another event. Events you opened before work offline.';
    say(e.message, {error: true});
  }
}
function setEvent(d) { ev = d; byKey = new Map(d.matches.map(m => [m.key, m])); revision++; for (const k of [...evSel]) if (!byKey.has(k)) evSel.delete(k); }
const roundOf = l => /^Q\d+$/.test(l) ? 'Q' : /^R16/.test(l) ? 'R16' : (l.match(/^[A-Z]+/) || [''])[0];
const matchDay = m => String(m.started || m.scheduled || '').slice(0, 10);
function canonical(s) { return s.toUpperCase().replace(/[\s#_()]/g, '').replace(/[–—]/g, '-').replace(/^QUALIFICATIONS?|^QUALIFIER|^QUAL/, 'Q').replace(/^QUARTERFINALS?/, 'QF').replace(/^SEMIFINALS?/, 'SF').replace(/^ROUNDOF16/, 'R16').replace(/^FINALS?/, 'F').replace(/^PRACTICE/, 'P'); }
function matchesQuery(m, q) {
  if (!q.trim()) return true;
  return q.split(/[,;\n]+/).map(s => canonical(s.trim())).filter(Boolean).some(t => {
    const range = t.match(/^Q(\d+)-Q?(\d+)$/);
    if (range) return /^Q\d+$/.test(m.label) && +m.label.slice(1) >= +range[1] && +m.label.slice(1) <= +range[2];
    if (/^(?:Q\d+|QF\d+-\d+|SF\d+-\d+|F\d+-\d+|R16\d+-\d+|P\d+)$/.test(t)) return m.label === t;
    return canonical(m.name).includes(t) || m.teams.some(team => team.toUpperCase().includes(t));
  });
}
let clipByMatch = new Map();
function evRows() {
  if (!ev) return [];
  const div = $('fDivision').value, round = $('fRound').value, day = $('fDay').value, video = $('fVideo').checked;
  let rows = ev.matches.filter(m => (div === 'all' || m.divisionId === div) && (round === 'all' || roundOf(m.label) === round) && (day === 'all' || matchDay(m) === day) && (!video || m.available) && matchesQuery(m, evQuery));
  if (evSort) {
    const order = new Map(ev.matches.map((m, i) => [m.key, i])), dayIx = Object.fromEntries((ev.days || []).map((d, i) => [d, i]));
    // Empty values (no score, no position, not downloaded) stay last in both directions.
    const key = {match: m => order.get(m.key), division: m => m.division + String(order.get(m.key)).padStart(6, '0'), day: m => (dayIx[matchDay(m)] ?? 99) * 1e6 + order.get(m.key), rs: m => m.alliances.find(a => a.color === 'red')?.score ?? null, bs: m => m.alliances.find(a => a.color === 'blue')?.score ?? null, video: m => m.available ? m.timestamp : null, source: m => m.available ? sourceText(m) : null, status: m => STATUS[clipByMatch.get(m.key)?.status] ?? null}[evSort.key];
    rows = [...rows].sort((a, b) => { const x = key(a), y = key(b); if (x === null || y === null) return x === y ? order.get(a.key) - order.get(b.key) : x === null ? 1 : -1; return (x < y ? -1 : x > y ? 1 : order.get(a.key) - order.get(b.key)) * (x === y ? 1 : evSort.dir); });
  }
  return rows;
}
const sourceText = m => m.streamLabel || SOURCE[m.timing] || (m.timing || '').replace(' (same recording)', '');
let evTable;
function renderEvent() {
  if (!ev) return;
  clipByMatch = new Map(clips.filter(c => c.event_ref === ev.sku && c.status !== 'cancelled').map(c => [c.match_ref, c]));
  header({tr: $('evHead'), colgroup: $('evCols'), cols: EV_COLS, sort: evSort, storeKey: 'event', onSort: s => { evSort = s; store.set('evSort', s); renderEvent(); }});
  const rows = evRows(), dayIx = Object.fromEntries((ev.days || []).map((d, i) => [d, i + 1]));
  const hadFocus = $('evGrid').contains(document.activeElement);
  $('evRows').innerHTML = rows.length ? rows.map(m => {
    const red = m.alliances.find(a => a.color === 'red'), blue = m.alliances.find(a => a.color === 'blue');
    const rs = red?.score, bs = blue?.score, decided = rs != null && bs != null && rs !== bs;
    const cls = (s, o) => decided ? (s > o ? 'score win' : 'score lose') : 'score';
    const clip = clipByMatch.get(m.key);
    return `<tr data-id="${esc(m.key)}" role="row" aria-selected="false" tabindex="-1">
      <td class="lbl" title="${esc(m.name)}">${esc(showLabel(m.label))}</td>
      <td>${esc(m.division)}</td><td class="dim">${dayIx[matchDay(m)] ? 'Day ' + dayIx[matchDay(m)] : esc(matchDay(m))}</td>
      <td><div class="alc"><span class="al red" title="${esc((red?.teams || []).join(', '))}"><span>${esc((red?.teams || []).join('  ')) || 'TBD'}</span></span><span class="${cls(rs, bs)}">${rs ?? ''}</span></div></td>
      <td><div class="alc"><span class="al blue" title="${esc((blue?.teams || []).join(', '))}"><span>${esc((blue?.teams || []).join('  ')) || 'TBD'}</span></span><span class="${cls(bs, rs)}">${bs ?? ''}</span></div></td>
      <td class="num">${m.available ? clock(m.timestamp) : '<span class="faint">—</span>'}</td>
      <td class="dim" title="${esc(m.timing)}">${m.available ? esc(sourceText(m)) : esc(NOPOS[m.timing] || m.timing || 'No position')}</td>
      <td>${clip ? `<span class="st ${stateClass(clip.status)}">${esc(STATUS[clip.status] || clip.status)}</span>` : ''}</td></tr>`;
  }).join('') : `<tr class="no-rows"><td colspan="8">${ev.matches.length ? 'No matches fit these filters.' : 'This event has no published matches yet.'}</td></tr>`;
  evTable.paint();
  if (hadFocus && evState.focus) evTable.focusRow(evState.focus, false);
  renderTitle(); $('infobar').hidden = !ev.warning; $('infobar').textContent = ev.warning || '';
}
function evChanged() {
  if (!ev) return;
  const shown = evRows(), sel = [...evSel].map(k => byKey.get(k)).filter(Boolean), ok = sel.filter(m => m.available);
  const typed = evQuery.trim() && !sel.length ? shown.filter(m => m.available).length : 0;
  setInfo(sel.length ? sel.length + ' of ' + shown.length + ' selected' + (ok.length < sel.length ? ', ' + (sel.length - ok.length) + ' without video' : '') : typed ? 'Press Return to select ' + plural(typed, 'match', 'matches') + ' with video' : '');
  $('tbDownload').disabled = !ok.length;
  const f = byKey.get(evState.focus);
  $('tbPreview').disabled = !f?.available; $('tbPosition').disabled = !f;
  if (view === 'event') renderInspector();
}
evTable = selectable({tbody: $('evRows'), table: $('evGrid'), ids: () => evRows().map(m => m.key), sel: evSel, state: evState, changed: evChanged,
  activate: k => { const m = byKey.get(k); if (m?.available) openPreview(m); else if (m) openPosition(m); },
  context: (x, y) => evMenu(x, y)});
function evMenu(x, y) {
  const m = byKey.get(evState.focus); if (!m) return;
  const sel = [...evSel].map(k => byKey.get(k)).filter(Boolean), ok = sel.filter(s => s.available);
  const items = [
    {label: 'Preview', disabled: !m.available, action: () => openPreview(m)},
    {label: 'Set Video Position…', action: () => openPosition(m)},
  ];
  if (m.streamOptions?.length > (m.available ? 1 : 0)) {
    items.push({sep: true}, {head: 'Use Recording'});
    for (const o of m.streamOptions) items.push({label: o.label, checked: o.id === m.streamId, action: () => chooseRecording(m, o.id)});
  }
  items.push({sep: true}, {label: ok.length > 1 ? 'Download ' + ok.length + ' Matches…' : 'Download…', disabled: !ok.length, action: openDownload},
    {label: sel.length > 1 ? 'Copy ' + sel.length + ' Match Labels' : 'Copy Match Label', action: () => copy(sel.map(s => showLabel(s.label) + ' ' + s.division).join('\n'))});
  showMenu(x, y, items);
}
async function copy(text) { try { await navigator.clipboard.writeText(text); say('Copied'); } catch { say('Copying isn’t available here.', {error: true}); } }
async function chooseRecording(m, id) { try { applyEvent(await post('/api/events/streams/choose', {sku: ev.sku, key: m.key, id})); say('Recording chosen for ' + showLabel(m.label)); } catch (e) { say(e.message, {error: true}); } }
for (const id of ['fDivision', 'fRound', 'fDay', 'fVideo']) $(id).addEventListener('change', renderEvent);
function applyEvent(d) { setEvent(d); for (const k of [...evSel]) if (!byKey.get(k)) evSel.delete(k); renderEvent(); renderInspector(); }

/* ---------- Search field: filters as you type; Return selects the matches shown ---------- */
let libQuery = '';
$('tbSearch').addEventListener('input', () => { if (view === 'downloads') { libQuery = $('tbSearch').value; renderLib(); } else { evQuery = $('tbSearch').value; renderEvent(); evChanged(); } });
$('tbSearch').addEventListener('keydown', e => {
  if (e.key === 'Enter' && view === 'event') {
    const rows = evRows().filter(m => m.available); evSel.clear(); rows.forEach(m => evSel.add(m.key));
    evState.focus = evState.anchor = rows[0]?.key || null; evTable.paint();
    say(rows.length ? 'Choose Download… to save them.' : 'No matches with video fit this search.');
  }
  if (e.key === 'ArrowDown' && view === 'event') { const first = evRows()[0]; if (first) { e.preventDefault(); if (!evSel.size) { evSel.add(first.key); evState.anchor = first.key; } evTable.focusRow(evState.focus || first.key); } }
});

/* ---------- Toolbar actions (event) ---------- */
$('tbRefresh').addEventListener('click', () => ev && loadEvent(ev.sku, true));
$('tbPreview').addEventListener('click', () => { const m = byKey.get(evState.focus); if (m?.available) openPreview(m); });
$('tbPosition').addEventListener('click', () => { const m = byKey.get(evState.focus); if (m) openPosition(m); });
$('tbDownload').addEventListener('click', openDownload);

/* ---------- Download sheet ---------- */
const dlPrefs = store.get('dl', {mode: 'dynamic', window: '480', length: 180, before: 5, after: 5, shift: 0});
function dlMode() { return document.querySelector('input[name=dlMode]:checked').value; }
function updateDlMode() { const m = dlMode(); document.querySelectorAll('#shDownload [data-mode]').forEach(el => el.hidden = el.dataset.mode !== m); }
document.querySelectorAll('input[name=dlMode]').forEach(r => r.addEventListener('change', updateDlMode));
function openDownload() {
  const sel = [...evSel].map(k => byKey.get(k)).filter(Boolean), ok = sel.filter(m => m.available);
  if (!ok.length) return;
  const names = ok.slice(0, 6).map(m => showLabel(m.label) + (new Set(ok.map(x => x.division)).size > 1 ? ' ' + m.division : '')).join(', ') + (ok.length > 6 ? ' and ' + (ok.length - 6) + ' more' : '');
  $('dlTitle').textContent = ok.length === 1 ? 'Download ' + showLabel(ok[0].label) : 'Download ' + ok.length + ' Matches';
  $('dlSummary').textContent = names + '.' + (sel.length > ok.length ? ' ' + plural(sel.length - ok.length, 'other selected match has', 'other selected matches have') + ' no video position and will be skipped.' : '');
  document.querySelector(`input[name=dlMode][value=${dlPrefs.mode}]`).checked = true;
  $('dlWindow').value = dlPrefs.window; $('dlLength').value = dlPrefs.length; $('dlBefore').value = dlPrefs.before; $('dlAfter').value = dlPrefs.after; $('dlShift').value = dlPrefs.shift;
  $('dlError').textContent = ''; updateDlMode(); $('shDownload').showModal(); $('dlGo').focus();
}
$('dlForm').addEventListener('submit', async e => {
  e.preventDefault();
  const ok = [...evSel].map(k => byKey.get(k)).filter(m => m?.available);
  Object.assign(dlPrefs, {mode: dlMode(), window: $('dlWindow').value, length: $('dlLength').value, before: $('dlBefore').value, after: $('dlAfter').value, shift: $('dlShift').value}); store.set('dl', dlPrefs);
  $('dlGo').disabled = true;
  try {
    const d = await post('/api/events/queue', {sku: ev.sku, keys: ok.map(m => m.key), mode: dlPrefs.mode, duration: dlPrefs.length, before: dlPrefs.before, tail: dlPrefs.after, window: dlPrefs.window, offset: dlPrefs.shift});
    $('shDownload').close();
    say(plural(d.added.length, 'match', 'matches') + ' added to Downloads' + (d.skipped.length ? '. ' + d.skipped.length + ' were already there.' : '.'));
    await refresh(); renderEvent();
  } catch (err) { $('dlError').textContent = err.message; } finally { $('dlGo').disabled = false; }
});

/* ---------- Viewer (Quick Look style) and video position ---------- */
let preview = null;
function openPreview(m) {
  preview?.destroy(); const v = $('viewer');
  const target = Math.max(0, Number(m.timestamp) + Number(dlPrefs.shift || 0) - Number(dlPrefs.before || 0));
  $('vTitle').textContent = showLabel(m.label) + (m.division ? ', ' + m.division : ''); $('vFrame').hidden = false; $('vVideo').hidden = true;
  $('vJump').hidden = false; $('vJump').disabled = true; $('vOpen').hidden = false; $('vState').className = 'viewer-state'; $('vState').textContent = 'Loading player…';
  try { $('vOpen').href = recordingLink(m.url, target); } catch { $('vOpen').hidden = true; }
  v.showModal();
  try {
    preview = createPreview($('vFrame'), {url: m.url, target, resolveSource, onState: s => {
      $('vJump').disabled = !s.ready; $('vState').className = 'viewer-state' + (s.error ? ' err' : '');
      $('vState').textContent = s.error || s.loading || s.warning || (Number.isFinite(s.position) ? clock(s.position) + ' in the recording' + (s.pending ? ', moving to ' + clock(target) + '…' : '') : 'Press Play to start at ' + clock(target) + '.');
    }});
  } catch (e) { $('vState').className = 'viewer-state err'; $('vState').textContent = e.message; }
}
function openPlayer(c) {
  preview?.destroy(); preview = null; const v = $('viewer');
  $('vTitle').textContent = clipTitle(c).label + (clipTitle(c).division ? ', ' + clipTitle(c).division : ''); $('vFrame').hidden = true; $('vVideo').hidden = false; $('vJump').hidden = true; $('vOpen').hidden = true;
  $('vVideo').src = '/video/' + c.id; $('vState').className = 'viewer-state'; $('vState').textContent = clock(c.start) + ' to ' + clock(c.end) + ' in the original recording. Plays from this Mac.';
  v.showModal();
}
$('vJump').addEventListener('click', () => preview?.jump());
$('viewer').addEventListener('close', () => { preview?.destroy(); preview = null; const v = $('vVideo'); v.pause(); v.removeAttribute('src'); v.load(); });
$('viewer').addEventListener('keydown', e => { if (e.key === ' ' && !e.target.closest('video,iframe,button,a,input')) { e.preventDefault(); $('viewer').close(); } });
let positionKey = null;
function openPosition(m) {
  positionKey = m.key; $('posTitle').textContent = 'Set Video Position for ' + showLabel(m.label);
  $('posUrl').value = m.url || ''; $('posAt').value = m.timestamp == null ? '' : clock(m.timestamp); $('posError').textContent = '';
  $('shPosition').showModal(); $(m.url ? 'posAt' : 'posUrl').focus();
}
$('posForm').addEventListener('submit', async e => {
  e.preventDefault();
  try { applyEvent(await post('/api/events/calibrate', {sku: ev.sku, key: positionKey, url: $('posUrl').value, timestamp: $('posAt').value})); $('shPosition').close(); say('Video position saved'); }
  catch (err) { $('posError').textContent = err.message; }
});

/* ---------- Inspector ---------- */
const narrowInspector = () => window.matchMedia('(max-width: 1100px)').matches;
function updateInspectorVisibility() {
  const can = ['event', 'downloads'].includes(view), on = can && (narrowInspector() ? ui.inspectorNarrow : ui.inspector);
  $('inspector').hidden = !on; $('window').classList.toggle('has-inspector', on); $('tbInspector').setAttribute('aria-expanded', on); $('tbInspector').title = (on ? 'Hide' : 'Show') + ' Inspector (⌥⌘I)';
  if (on) { renderInspector(); requestAnimationFrame(thumbs); }
}
function toggleInspector() { if (narrowInspector()) ui.inspectorNarrow = !ui.inspectorNarrow; else { ui.inspector = !ui.inspector; store.set('inspector', ui.inspector); } updateInspectorVisibility(); }
$('tbInspector').addEventListener('click', toggleInspector);
document.querySelectorAll('input[name=insp]').forEach(r => r.addEventListener('change', () => { ui.inspTab = r.value; renderInspector(); }));
function renderInspector() {
  if ($('inspector').hidden) return;
  const body = $('inspBody');
  if (view === 'downloads') { body.innerHTML = libInspector(); return; }
  if (!ev) { body.innerHTML = ''; return; }
  document.querySelector(`input[name=insp][value=${ui.inspTab}]`).checked = true; thumb($('inspTabs').querySelector('.segmented'));
  body.innerHTML = ui.inspTab === 'recordings' ? recordingsInspector() : matchInspector();
}
function matchInspector() {
  const sel = [...evSel].map(k => byKey.get(k)).filter(Boolean);
  if (sel.length > 1) {
    const ok = sel.filter(m => m.available).length;
    return `<p class="insp-title">${sel.length} Matches Selected</p><p class="insp-sub">${ok} with video, ${sel.length - ok} without</p>
      <dl class="kv">${[...new Set(sel.map(m => m.division))].map(d => { const ms = sel.filter(m => m.division === d); return `<dt>${esc(d)}</dt><dd>${esc(ms.length > 12 ? showLabel(ms[0].label) + ' to ' + showLabel(ms.at(-1).label) + ', ' + ms.length + ' matches' : ms.map(m => showLabel(m.label)).join(', '))}</dd>`; }).join('')}</dl>
      <div class="insp-actions"><button type="button" class="push default" data-insp="download" ${ok ? '' : 'disabled'}>Download ${ok === 1 ? '1 Match' : ok + ' Matches'}…</button></div>`;
  }
  const m = byKey.get(evState.focus) || sel[0];
  if (!m) { const timed = ev.matches.filter(x => x.available).length; return `<p class="insp-title">${esc(ev.name)}</p><p class="insp-sub">${esc(eventSubtitle())}</p><dl class="kv"><dt>Matches</dt><dd>${ev.matches.length}</dd><dt>With video</dt><dd>${timed}</dd><dt>Divisions</dt><dd>${esc(ev.divisions.map(d => d.name).join(', '))}</dd></dl><p class="insp-note">Select a match to see its teams, video position and download. Shift-click or Command-click to select several.</p>`; }
  const dayIx = (ev.days || []).indexOf(matchDay(m)) + 1, clip = clipByMatch.get(m.key);
  const al = c => { const a = m.alliances.find(x => x.color === c), o = m.alliances.find(x => x.color !== c); const win = a?.score != null && o?.score != null && a.score > o.score; return `<div><span class="al ${c}">${esc((a?.teams || []).join(', ') || 'TBD')}</span><span class="${win ? 'score win' : 'dim'}">${a?.score ?? ''}</span></div>`; };
  const options = m.streamOptions?.length > (m.available ? 1 : 0) ? `<dt><label for="inspRec">Recording</label></dt><dd><select id="inspRec" class="popup" data-key="${esc(m.key)}">${m.available ? '' : '<option value="">Choose…</option>'}${m.streamOptions.map(o => `<option value="${esc(o.id)}" ${o.id === m.streamId ? 'selected' : ''}>${esc(o.label)}</option>`).join('')}</select></dd>` : '';
  return `<p class="insp-title">${esc(showLabel(m.label))}</p><p class="insp-sub">${esc(m.name)}</p>
    <dl class="kv"><dt>Division</dt><dd>${esc(m.division)}</dd><dt>Day</dt><dd>${dayIx ? 'Day ' + dayIx + ', ' + esc(dayName(matchDay(m))) : '—'}</dd>${m.field ? `<dt>Field</dt><dd>${esc(m.field)}</dd>` : ''}
      <dt>Started</dt><dd>${m.started ? esc(new Date(m.started).toLocaleTimeString(undefined, {hour: 'numeric', minute: '2-digit'})) : m.scheduled ? 'Scheduled ' + esc(new Date(m.scheduled).toLocaleTimeString(undefined, {hour: 'numeric', minute: '2-digit'})) : '—'}</dd></dl>
    <h3>Alliances</h3><div class="insp-alliances">${al('red')}${al('blue')}</div>
    <h3>Video</h3>
    <dl class="kv"><dt>Position</dt><dd>${m.available ? clock(m.timestamp) : 'None'}</dd><dt>Source</dt><dd>${esc(m.available ? sourceText(m) : NOPOS[m.timing] || m.timing)}</dd>${options}</dl>
    <div class="insp-actions">${m.available ? '<button type="button" class="push" data-insp="preview">Preview</button>' : ''}<button type="button" class="push" data-insp="position">Set Video Position…</button></div>
    <h3>Download</h3>
    ${clip ? `<dl class="kv"><dt>Status</dt><dd><span class="st ${stateClass(clip.status)}">${esc(STATUS[clip.status])}</span></dd>${clip.bytes ? `<dt>Size</dt><dd>${size(clip.bytes)}</dd>` : ''}</dl><div class="insp-actions"><button type="button" class="push" data-insp="show-download" data-id="${clip.id}">Show in Downloads</button></div>`
      : `<p class="insp-note">${m.available ? 'Not downloaded.' : 'Set a video position before downloading.'}</p>${m.available ? '<div class="insp-actions"><button type="button" class="push" data-insp="download">Download…</button></div>' : ''}`}`;
}
function syncText(r) {
  if (!r.enabled) return ['Not used', ''];
  if (r.syncMode === 'none') return ['Not lined up', 'state-warn'];
  if (r.syncMode === 'auto') return r.metadata?.startEstimate ? ['Broadcast began ' + new Date(r.metadata.startEstimate).toLocaleString(undefined, {dateStyle: 'medium', timeStyle: 'short'}), 'state-ok'] : ['No broadcast start found', 'state-warn'];
  if (r.syncMode === 'anchor') { const a = byKey.get(r.anchorKey); return ['Lined up on ' + (a ? showLabel(a.label) : 'a match') + ' at ' + clock(r.anchorPosition), 'state-ok']; }
  return ['Began ' + r.wallStart, 'state-ok'];
}
function recordingsInspector() {
  const s = ev.streamSummary || {}, at = ev.autoTiming, timed = ev.matches.filter(m => m.available).length;
  const recs = (ev.streams || []).map(r => {
    const div = ev.divisions.find(d => d.id === r.divisionId)?.name || 'All divisions', [state, tone] = syncText(r);
    return `<li><b>${esc(r.label)}</b><span class="dim">${esc(dayName(r.date))}, ${esc(div)}${r.field ? ', ' + esc(r.field) : ''}${r.firstMatch || r.lastMatch ? ', part of the day' : ''}${r.fillOnly ? ', fills gaps only' : ''}</span><span class="dim ${tone}">${esc(state)}${r.offset ? ', shifted ' + esc(r.offset) + ' s' : ''}</span>
      <span class="btn-row"><button type="button" class="push" data-insp="rec-edit" data-id="${esc(r.id)}">Edit…</button><button type="button" class="push" data-insp="rec-preview" data-id="${esc(r.id)}">Preview</button><button type="button" class="push" data-insp="rec-delete" data-id="${esc(r.id)}">Remove…</button></span></li>`;
  }).join('');
  const disc = ev.discovery;
  const cands = (disc?.candidates || []).map((c, i) => {
    let where = c.url, kind = c.platform + ' link';
    try { const u = new URL(c.url); where = u.hostname.replace(/^www\./, '') + u.pathname + u.search; if (c.platform === 'YouTube') kind = /^\/(@|channel|c\/|user)/.test(u.pathname) ? 'YouTube channel' : 'YouTube video'; } catch {}
    const added = (ev.streams || []).some(r => r.url === c.url);
    return `<li><b>${esc(c.label && c.label !== c.url ? c.label : where)}</b><span class="dim">${esc(kind)}, from ${c.source === 'Jumper detection' ? 'stream detection' : 'the event page'}</span><span class="btn-row">${added ? '<span class="dim state-ok">Added</span>' : `<button type="button" class="push" data-insp="cand" data-i="${i}">Add…</button>`}</span></li>`;
  }).join('');
  const discText = disc ? [disc.description && '“' + disc.description.trim() + '”', ...(disc.errors || []).map(x => ({'Jumper stream lookup unavailable': 'Stream detection is unavailable right now.', 'VEX webcast lookup unavailable': 'The event page couldn’t be checked.'}[x] || x))].filter(Boolean).join(' ') : 'Not checked yet.';
  return `<h3>Video Positions</h3>
    <p class="insp-note" style="margin-top:0">${autoBusy ? '<span class="spinner"></span>Finding positions from broadcast start times…' : esc(timed + ' of ' + ev.matches.length + ' matches have a position.' + (s.estimated ? ' ' + s.estimated + ' estimated from the same recording.' : '') + (s.ambiguous ? ' ' + s.ambiguous + ' need a recording choice.' : '') + (at?.messages?.length ? ' ' + at.messages.join(' ') : ''))}</p>
    <div class="insp-actions"><button type="button" class="push" data-insp="auto" ${autoBusy ? 'disabled' : ''}>Find Positions Again</button></div>
    <h3>Recordings</h3>${recs ? `<ul class="rec-list">${recs}</ul>` : '<p class="insp-note" style="margin-top:0">None added. Add one when the event feed has no video positions.</p>'}
    <div class="insp-actions"><button type="button" class="push" data-insp="rec-add">Add Recording…</button></div>
    <h3>Links on the Event Page</h3><p class="insp-note" style="margin-top:0">${esc(discText)}</p>
    ${cands ? `<ul class="rec-list" style="margin-top:8px">${cands}</ul>` : ''}
    <div class="insp-actions"><button type="button" class="push" data-insp="discover">Check Event Page Again</button></div>`;
}
$('inspBody').addEventListener('change', async e => { if (e.target.id === 'inspRec' && e.target.value) chooseRecording(byKey.get(e.target.dataset.key), e.target.value); });
$('inspBody').addEventListener('input', e => { if (e.target.id === 'inspNotes') $('inspNotesSave').disabled = false; });
$('inspBody').addEventListener('click', async e => {
  const b = e.target.closest('[data-insp]'); if (!b) return;
  const a = b.dataset.insp, m = byKey.get(evState.focus) || byKey.get([...evSel][0]);
  if (a === 'download') { if (m && !evSel.size) evSel.add(m.key); openDownload(); }
  else if (a === 'preview') openPreview(m);
  else if (a === 'position') openPosition(m);
  else if (a === 'show-download') { libSel.clear(); libSel.add(b.dataset.id); libState.focus = libState.anchor = b.dataset.id; location.hash = '#/downloads'; }
  else if (a === 'auto') autoTime();
  else if (a === 'discover') discover(true);
  else if (a === 'rec-add') openEditor();
  else if (a === 'rec-edit') openEditor(ev.streams.find(s => s.id === b.dataset.id));
  else if (a === 'rec-preview') { const r = ev.streams.find(s => s.id === b.dataset.id); openPreview({url: r.url, timestamp: 0, label: r.label, division: ''}); }
  else if (a === 'rec-delete') {
    const r = ev.streams.find(s => s.id === b.dataset.id);
    if (!await alertBox('Remove “' + r.label + '”?', 'Matches lose the positions this recording provided. Downloaded videos stay on this Mac.', 'Remove')) return;
    try { applyEvent(await post('/api/events/streams/delete', {sku: ev.sku, id: r.id})); say('Recording removed'); } catch (err) { say(err.message, {error: true}); }
  }
  else if (a === 'cand') {
    const c = ev.discovery.candidates[+b.dataset.i];
    const record = {url: c.url, label: c.label && c.label !== c.url ? c.label : '', divisionId: c.divisionId || '*', date: ev.days?.[c.dayIndex || 0]};
    if (c.streamStartTime) { const t = new Date(c.streamStartTime); if (!isNaN(t)) record.metadata = {startEstimate: t.toISOString()}; }
    openEditor(record);
  }
  else libAction(a, b.dataset.id);
});
async function discover(force = false) {
  if (!ev) return; const sku = ev.sku, rev = revision;
  if (force) say('Checking the event page…', {busy: true});
  try { const d = await post('/api/events/streams/discover', {sku, refresh: force}); if (ev?.sku !== sku) return; if (rev === revision) setEvent(d); else ev.discovery = d.discovery; renderInspector(); if (force) say('Event page checked'); }
  catch (e) { if (ev?.sku === sku) say(e.message, {error: true}); }
}
async function autoTime() {
  if (!ev || autoBusy) return; const sku = ev.sku; autoBusy = true; renderInspector();
  say('Finding video positions…', {busy: true});
  try { const d = await post('/api/events/auto-time', {sku, search: true}); autoBusy = false; if (ev?.sku === sku) { applyEvent(d); say(d.matches.filter(m => m.available).length + ' of ' + d.matches.length + ' matches have a video position'); } }
  catch (e) { if (ev?.sku === sku) say(e.message, {error: true}); }
  finally { autoBusy = false; renderInspector(); }
}
function maybeAutoTime() { const e = ev; if (!e || !e.matches.length || !e.matches.some(m => !m.available)) return; if (!e.autoTiming || (!e.cached && e.fetched && e.autoTiming.checked < e.fetched)) autoTime(); }

/* ---------- Recording editor sheet ---------- */
let editorPlayer = null, info = {}, channel = [];
const syncMode = () => document.querySelector('input[name=sync]:checked').value;
function setSync(v) { document.querySelector(`input[name=sync][value="${v}"]`).checked = true; updateSync(); }
function updateSync() { const m = syncMode(); $('eAnchorFields').hidden = m !== 'anchor'; $('eWallFields').hidden = m !== 'wallclock'; $('ePosition').required = $('eAnchor').required = m === 'anchor'; $('eWall').required = m === 'wallclock'; }
document.querySelectorAll('input[name=sync]').forEach(r => r.addEventListener('change', updateSync));
function scopeRows() { return ev.matches.filter(m => ($('eDivision').value === '*' || m.divisionId === $('eDivision').value) && matchDay(m) === $('eDay').value && (!$('eField').value || m.field === $('eField').value)).sort((a, b) => new Date(a.started || a.scheduled) - new Date(b.started || b.scheduled)); }
function matchOptions(rows, first) { return '<option value="">' + first + '</option>' + rows.map(m => { const t = String(($('eBasis').value === 'scheduled' ? m.scheduled : m.started) || m.scheduled || ''); const time = t ? new Date(t).toLocaleTimeString(undefined, {hour: 'numeric', minute: '2-digit'}) : ''; return `<option value="${esc(m.key)}">${esc(showLabel(m.label))}, ${esc(m.division)}${time ? ', ' + esc(time) : ''}</option>`; }).join(''); }
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
  $('edTitle').textContent = r.id ? 'Edit Recording' : 'Add Recording';
  $('eId').value = r.id || ''; $('eUrl').value = r.url || ''; $('eLabel').value = r.label || '';
  $('eDays').innerHTML = (ev.days || []).map(d => `<option value="${esc(d)}">`).join('');
  $('eDay').value = r.date || ev.days?.[0] || matchDay(ev.matches[0] || {});
  $('eDivision').innerHTML = '<option value="*">All Divisions</option>' + ev.divisions.map(d => `<option value="${esc(d.id)}">${esc(d.name)}</option>`).join('');
  $('eDivision').value = r.divisionId || ($('fDivision').value !== 'all' ? $('fDivision').value : '*');
  $('eField').innerHTML = '<option value="">All Fields</option>' + [...new Set(ev.matches.map(m => m.field).filter(Boolean))].map(f => `<option>${esc(f)}</option>`).join('');
  $('eField').value = r.field || ''; $('eBasis').value = r.basis || 'actual';
  $('eFirst').innerHTML = $('eLast').innerHTML = $('eAnchor').innerHTML = '';
  refreshScope(); $('eFirst').value = r.firstMatch || ''; $('eLast').value = r.lastMatch || ''; refreshScope();
  $('eAnchor').value = r.anchorKey || ''; $('ePosition').value = r.anchorPosition !== undefined ? clock(r.anchorPosition) : '';
  $('eWall').value = r.wallStart || ''; $('eOffset').value = r.offset || 0; $('eDuration').value = r.duration || '';
  $('eEnabled').checked = r.enabled !== false; $('eFillOnly').checked = r.fillOnly === true;
  $('eError').textContent = ''; $('eInfo').textContent = ''; document.querySelectorAll('[data-channel]').forEach(x => x.hidden = true);
  $('ePlayerWrap').hidden = true; $('eLoadPlayer').textContent = 'Show Player'; $('eCapture').disabled = true; $('eUseDetected').disabled = !info.startEstimate;
  setSync(r.syncMode || 'auto'); $('shEditor').showModal(); $(r.url ? 'eLabel' : 'eUrl').focus();
}
$('shEditor').addEventListener('close', () => { editorPlayer?.destroy(); editorPlayer = null; });
$('eUrl').addEventListener('change', () => { if ($('eId').value) { info = {}; $('eDuration').value = ''; $('ePosition').value = ''; $('eWall').value = ''; $('eUseDetected').disabled = true; $('eInfo').textContent = 'The link changed. Check its position before saving.'; } });
$('eProbe').addEventListener('click', async () => {
  $('eProbe').disabled = true; $('eInfo').textContent = 'Reading recording details…';
  try {
    const d = await post('/api/events/streams/probe', {url: $('eUrl').value}); info = d;
    $('eInfo').textContent = [d.title, d.duration ? 'Length ' + clock(d.duration) : '', d.startEstimate ? 'Broadcast start found.' : 'No broadcast start; line it up with a match.'].filter(Boolean).join('. ');
    if (!$('eLabel').value) $('eLabel').value = d.title || ''; if (d.duration) $('eDuration').value = d.duration;
    $('eUseDetected').disabled = !d.startEstimate; channel = d.recordings || [];
    document.querySelectorAll('[data-channel]').forEach(x => x.hidden = !channel.length);
    $('eChannelPick').innerHTML = channel.map((r, i) => `<option value="${i}">${esc(r.title || r.url)}</option>`).join('');
  } catch (e) { $('eInfo').textContent = e.message; } finally { $('eProbe').disabled = false; }
});
$('eChannelUse').addEventListener('click', () => { const r = channel[+$('eChannelPick').value]; if (r) { $('eUrl').value = r.url; $('eLabel').value = r.title || ''; document.querySelectorAll('[data-channel]').forEach(x => x.hidden = true); $('eProbe').click(); } });
$('eUseDetected').addEventListener('click', () => { $('eWall').value = info.startEstimate || ''; });
$('eLoadPlayer').addEventListener('click', () => {
  if (!$('ePlayerWrap').hidden) { editorPlayer?.destroy(); editorPlayer = null; $('ePlayerWrap').hidden = true; $('eLoadPlayer').textContent = 'Show Player'; $('eCapture').disabled = true; return; }
  $('ePlayerWrap').hidden = false; $('eLoadPlayer').textContent = 'Hide Player';
  try { editorPlayer = createPreview($('ePlayer'), {url: $('eUrl').value, target: parseClock($('ePosition').value), resolveSource, onState: s => { $('eCapture').disabled = !s.ready; $('ePlayerState').textContent = s.error || s.loading || (Number.isFinite(s.position) ? clock(s.position) : 'Play the recording, find a match start, then choose Use Player Time.'); }}); }
  catch (e) { $('ePlayerState').textContent = e.message; }
});
$('eCapture').addEventListener('click', async () => { try { $('ePosition').value = clock(await editorPlayer.getCurrentTime()); } catch (e) { $('eError').textContent = e.message; } });
for (const [id, step] of [['eBack', -10], ['eFwd', 10]]) $(id).addEventListener('click', async () => { try { await editorPlayer.seekTo(Math.max(0, (await editorPlayer.getCurrentTime()) + step)); } catch (e) { $('ePlayerState').textContent = e.message; } });
$('edForm').addEventListener('submit', async e => {
  e.preventDefault(); $('eSave').disabled = true; $('eError').textContent = syncMode() === 'auto' ? 'Reading the broadcast start time…' : '';
  try {
    const stream = {id: $('eId').value || undefined, label: $('eLabel').value, url: $('eUrl').value, date: $('eDay').value, divisionId: $('eDivision').value, field: $('eField').value, basis: $('eBasis').value, firstMatch: $('eFirst').value, lastMatch: $('eLast').value, syncMode: syncMode(), anchorKey: $('eAnchor').value, anchorPosition: parseClock($('ePosition').value), wallStart: $('eWall').value, offset: $('eOffset').value, duration: $('eDuration').value, enabled: $('eEnabled').checked, fillOnly: $('eFillOnly').checked, metadata: info};
    applyEvent(await post('/api/events/streams/save', {sku: ev.sku, stream})); $('shEditor').close(); say('Recording saved');
  } catch (err) { $('eError').textContent = err.message; } finally { $('eSave').disabled = false; }
});

/* ---------- Downloads ---------- */
const LIB_COLS = [
  {key: 'match', label: 'Match', w: 72, sort: true}, {key: 'division', label: 'Division', w: 92, sort: true}, {key: 'event', label: 'Event', w: 150, sort: true, flex: true},
  {key: 'status', label: 'Status', w: 168, sort: true}, {key: 'range', label: 'Part of Recording', w: 150}, {key: 'size', label: 'Size', w: 76, num: true, sort: true}, {key: 'added', label: 'Added', w: 122, sort: true}];
function clipTitle(c) { const p = c.title.split(' · '); return c.event_ref && p.length > 2 ? {label: showLabel(p.at(-1)), division: p.at(-2), event: p.slice(0, -2).join(' · ')} : {label: c.title, division: '', event: 'From a link'}; }
function libRows() {
  const scope = document.querySelector('input[name=libscope]:checked').value, q = libQuery.toLowerCase();
  let rows = clips.filter(c => (c.title + ' ' + c.notes).toLowerCase().includes(q) && (scope === 'all' || c.status === scope || (scope === 'active' && ACTIVE.includes(c.status))));
  const key = {match: c => clipTitle(c).label, division: c => clipTitle(c).division, event: c => clipTitle(c).event, status: c => STATUS[c.status], size: c => c.bytes, added: c => c.created}[libSort.key];
  return [...rows].sort((a, b) => { const x = key(a), y = key(b); return (x < y ? -1 : x > y ? 1 : 0) * libSort.dir; });
}
let libTable;
function renderLib() {
  header({tr: $('libHead'), colgroup: $('libCols'), cols: LIB_COLS, sort: libSort, storeKey: 'lib', onSort: s => { libSort = s; store.set('libSort', s); renderLib(); }});
  const counts = {all: clips.length, ready: 0, active: 0, needs_review: 0, failed: 0};
  for (const c of clips) { if (c.status in counts) counts[c.status]++; if (ACTIVE.includes(c.status)) counts.active++; }
  document.querySelectorAll('#libScope i').forEach(i => i.textContent = counts[i.dataset.n] || '');
  for (const id of [...libSel]) if (!clips.some(c => c.id === id)) libSel.delete(id);
  const rows = libRows(), hadFocus = $('libGrid').contains(document.activeElement);
  $('libRows').innerHTML = rows.length ? rows.map(c => {
    const t = clipTitle(c), act = ACTIVE.includes(c.status);
    const range = c.clip_mode === 'dynamic' && c.status !== 'ready' ? (() => { try { return 'Near ' + clock(JSON.parse(c.detect_settings).anchor); } catch { return ''; } })() : clock(c.start) + '–' + clock(c.end);
    const detail = c.status === 'failed' ? failure(c.detail) : act ? c.detail : '';
    return `<tr data-id="${c.id}" role="row" aria-selected="false" tabindex="-1">
      <td class="lbl">${esc(t.label)}</td><td>${esc(t.division)}</td><td class="dim" title="${esc(t.event)}">${esc(t.event)}</td>
      <td title="${esc(c.status === 'failed' ? failure(c.detail) : c.detail)}"><span class="st ${stateClass(c.status)}">${esc(STATUS[c.status] || c.status)}</span>${act && c.status !== 'queued' ? '<span class="bar" aria-hidden="true"></span>' : ''}${detail ? ' <span class="dim">' + esc(detail) + '</span>' : ''}</td>
      <td class="dim">${esc(range)}</td><td class="num dim">${size(c.bytes)}</td><td class="dim">${esc(new Date(c.created * 1000).toLocaleString(undefined, {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'}))}</td></tr>`;
  }).join('') : `<tr class="no-rows"><td colspan="7">${clips.length ? 'No downloads match.' : 'No downloads yet. Select matches in an event and choose Download….'}</td></tr>`;
  libTable.paint();
  if (hadFocus && libState.focus) libTable.focusRow(libState.focus, false);
  renderTitle();
}
function libChanged() {
  const sel = clips.filter(c => libSel.has(c.id));
  if (view === 'downloads') setInfo(sel.length > 1 ? sel.length + ' of ' + plural(libRows().length, 'download') + ' selected' : '');
  const one = sel.length === 1 ? sel[0] : null;
  $('tbPlay').disabled = !(one && one.status === 'ready'); $('tbSave').disabled = !(one && one.status === 'ready'); $('tbReview').disabled = !(one && one.status === 'needs_review');
  $('tbRetry').disabled = !sel.some(c => ['failed', 'cancelled'].includes(c.status)); $('tbCancel').disabled = !sel.some(c => ACTIVE.includes(c.status));
  $('tbDelete').disabled = !sel.length || sel.every(c => ACTIVE.includes(c.status));
  if (view === 'downloads') renderInspector();
}
libTable = selectable({tbody: $('libRows'), table: $('libGrid'), ids: () => libRows().map(c => c.id), sel: libSel, state: libState, changed: libChanged,
  activate: id => { const c = clips.find(x => x.id === id); if (c?.status === 'ready') openPlayer(c); else if (c?.status === 'needs_review') openBounds(c); },
  context: (x, y) => libMenu(x, y), remove: () => libBulk('delete')});
function libMenu(x, y) {
  const sel = clips.filter(c => libSel.has(c.id)), one = sel.length === 1 ? sel[0] : null;
  showMenu(x, y, [
    {label: 'Play', disabled: !(one?.status === 'ready'), action: () => openPlayer(one)},
    {label: 'Save MP4 As…', disabled: !(one?.status === 'ready'), action: () => exportClip(one)},
    {label: 'Check Start and End…', disabled: !(one?.status === 'needs_review'), action: () => openBounds(one)},
    {sep: true},
    {label: 'Retry', disabled: !sel.some(c => ['failed', 'cancelled'].includes(c.status)), action: () => libBulk('retry')},
    {label: 'Stop Download', disabled: !sel.some(c => ACTIVE.includes(c.status)), action: () => libBulk('cancel')},
    {label: 'Show in Event', disabled: !one?.event_ref, action: () => { const sku = one.event_ref, key = one.match_ref; location.hash = '#/event/' + encodeURIComponent(sku); const sel1 = () => { if (byKey.has(key)) { evSel.clear(); evSel.add(key); evState.focus = evState.anchor = key; renderEvent(); evTable.focusRow(key); } }; if (ev?.sku === sku) setTimeout(sel1); else setTimeout(function wait(n = 0) { if (ev?.sku === sku) sel1(); else if (n < 40) setTimeout(() => wait(n + 1), 100); }); }},
    {sep: true},
    {label: sel.length > 1 ? 'Delete ' + sel.length + ' Downloads…' : 'Delete…', disabled: !sel.length || sel.every(c => ACTIVE.includes(c.status)), action: () => libBulk('delete')},
  ]);
}
function exportClip(c) { const l = document.createElement('a'); l.href = '/video/' + c.id; l.download = c.title.replace(/[^a-z0-9 _-]/gi, '_') + '.mp4'; l.click(); }
async function libBulk(action) {
  const sel = clips.filter(c => libSel.has(c.id));
  const targets = sel.filter(c => action === 'delete' ? !ACTIVE.includes(c.status) : action === 'cancel' ? ACTIVE.includes(c.status) : ['failed', 'cancelled'].includes(c.status));
  if (!targets.length) return;
  if (action === 'delete' && !await alertBox(targets.length === 1 ? 'Delete “' + clipTitle(targets[0]).label + '”?' : 'Delete ' + targets.length + ' Downloads?', 'The video files and notes are removed from this Mac. You can’t undo this.', 'Delete')) return;
  if (action === 'cancel' && !await alertBox(targets.length === 1 ? 'Stop This Download?' : 'Stop ' + targets.length + ' Downloads?', 'You can retry later from Downloads.', 'Stop')) return;
  let done = 0, error = '';
  for (const c of targets) { try { await post('/api/clips/' + c.id + '/' + action, {}); done++; if (action === 'delete') libSel.delete(c.id); } catch (e) { error = e.message; } }
  say(error ? error : {retry: plural(done, 'download') + ' restarted', cancel: plural(done, 'download') + ' stopped', delete: plural(done, 'download') + ' deleted'}[action], {error: !!error});
  await refresh();
}
function libAction(a, id) {
  const c = clips.find(x => x.id === (id || libState.focus));
  if (a === 'play') openPlayer(c); else if (a === 'export') exportClip(c); else if (a === 'bounds') openBounds(c);
  else if (['retry', 'cancel', 'delete'].includes(a)) { libSel.clear(); libSel.add(c.id); libBulk(a); }
  else if (a === 'notes') saveNotes(c);
}
function libInspector() {
  const sel = clips.filter(c => libSel.has(c.id));
  if (sel.length > 1) return `<p class="insp-title">${sel.length} Downloads Selected</p><p class="insp-sub">${size(sel.reduce((s, c) => s + c.bytes, 0)) || 'No files yet'}</p>`;
  const c = clips.find(x => x.id === libState.focus) || sel[0];
  if (!c) return `<p class="insp-sub" style="margin-top:8px">Select a download to see its details and notes.</p>`;
  const t = clipTitle(c), act = ACTIVE.includes(c.status);
  const buttons = [c.status === 'ready' && '<button type="button" class="push default" data-insp="play">Play</button><button type="button" class="push" data-insp="export">Save MP4 As…</button>',
    c.status === 'needs_review' && '<button type="button" class="push default" data-insp="bounds">Check Start and End…</button>',
    ['failed', 'cancelled'].includes(c.status) && '<button type="button" class="push" data-insp="retry">Retry</button>',
    act ? '<button type="button" class="push" data-insp="cancel">Stop Download…</button>' : '<button type="button" class="push" data-insp="delete">Delete…</button>'].filter(Boolean).join('');
  return `<p class="insp-title">${esc(t.label)}${t.division ? ' <span class="dim" style="font-weight:400">' + esc(t.division) + '</span>' : ''}</p><p class="insp-sub">${esc(t.event)}</p>
    <dl class="kv"><dt>Status</dt><dd><span class="st ${stateClass(c.status)}">${esc(STATUS[c.status])}</span></dd>
      <dt>Recording</dt><dd>${esc(clock(c.start))} to ${esc(clock(c.end))}</dd>${c.bytes ? `<dt>Size</dt><dd>${size(c.bytes)}</dd>` : ''}
      <dt>Boundaries</dt><dd>${{dynamic: 'Found from match clock', fixed: 'Fixed length', reviewed: 'Checked by you'}[c.clip_mode] || 'Fixed length'}</dd>
      <dt>Added</dt><dd>${esc(new Date(c.created * 1000).toLocaleString(undefined, {dateStyle: 'medium', timeStyle: 'short'}))}</dd></dl>
    ${c.status === 'failed' ? `<p class="insp-err">${esc(failure(c.detail))}</p>` : c.detail && c.detail !== 'Saved on this laptop' ? `<p class="insp-note">${esc(c.detail)}</p>` : ''}
    <div class="insp-actions">${buttons}</div>
    <h3><label for="inspNotes">Notes</label></h3><textarea id="inspNotes" rows="5">${esc(c.notes)}</textarea>
    <div class="insp-actions"><button type="button" class="push" id="inspNotesSave" data-insp="notes" data-id="${c.id}" disabled>Save Notes</button></div>`;
}
async function saveNotes(c) { try { await post('/api/clips/' + c.id + '/notes', {notes: $('inspNotes').value}); say('Notes saved'); await refresh(); } catch (e) { say(e.message, {error: true}); } }
document.querySelectorAll('input[name=libscope]').forEach(r => r.addEventListener('change', renderLib));
$('tbPlay').addEventListener('click', () => libAction('play'));
$('tbSave').addEventListener('click', () => libAction('export'));
$('tbReview').addEventListener('click', () => libAction('bounds'));
$('tbRetry').addEventListener('click', () => libBulk('retry'));
$('tbCancel').addEventListener('click', () => libBulk('cancel'));
$('tbDelete').addEventListener('click', () => libBulk('delete'));
let reviewing = null;
function openBounds(c) {
  reviewing = c; let a = {}; try { a = JSON.parse(c.analysis_json || '{}'); } catch {}
  const start = a.start ?? Math.max(0, c.start - (c.source_start || 0)), end = a.end ?? Math.min(a.source_duration || 0, start + 180);
  $('bTitle').textContent = 'Check Start and End of ' + clipTitle(c).label; $('bReason').textContent = c.detail;
  $('bStart').value = clock(start); $('bEnd').value = clock(end); $('bError').textContent = '';
  $('bOrigin').textContent = 'This window begins at ' + clock(c.source_start || 0) + ' in the original recording. Include the autonomous start, the pause and the end of driver control.';
  const v = $('bVideo'); v.src = '/review/' + c.id; v.addEventListener('loadedmetadata', () => { v.currentTime = start; }, {once: true});
  $('shBounds').showModal();
}
$('bMarkStart').addEventListener('click', () => $('bStart').value = clock($('bVideo').currentTime));
$('bMarkEnd').addEventListener('click', () => $('bEnd').value = clock($('bVideo').currentTime));
$('shBounds').addEventListener('close', () => { const v = $('bVideo'); v.pause(); v.removeAttribute('src'); v.load(); reviewing = null; });
$('bForm').addEventListener('submit', async e => { e.preventDefault(); try { await post('/api/clips/' + reviewing.id + '/bounds', {start: $('bStart').value, end: $('bEnd').value}); $('shBounds').close(); say('Saving the clip with your start and end'); refresh(); } catch (err) { $('bError').textContent = err.message; } });

/* ---------- Polling: update only what changed ---------- */
let libSig = '', evSig = '';
async function refresh() {
  try {
    const r = await fetch('/api/library'); if (!r.ok) throw Error();
    const d = await r.json(); clips = d.clips; libInfo = d;
    const active = clips.filter(c => ACTIVE.includes(c.status)).length;
    $('sbBadge').textContent = active || '';
    const sig = JSON.stringify(clips.map(c => [c.id, c.status, c.detail, c.bytes, c.notes]));
    if (sig !== libSig) { libSig = sig; if (view === 'downloads') { const notesFocused = document.activeElement?.id === 'inspNotes'; renderLib(); if (notesFocused) $('inspNotes')?.focus(); } }
    const es = ev ? clips.filter(c => c.event_ref === ev.sku).map(c => c.match_ref + c.status + c.bytes).sort().join() : '';
    if (ev && es !== evSig) { evSig = es; if (view === 'event') renderEvent(); }
    if (!d.ffmpeg) say('FFmpeg isn’t installed, so downloads can’t run. See the README.', {error: true, sticky: true});
    if (view === 'downloads') renderTitle();
  } catch { say('Lost contact with the app. Reopen it to continue; saved videos are safe.', {error: true, sticky: true}); }
}

/* ---------- Clip from Link ---------- */
let imports = [];
$('clipForm').addEventListener('submit', async e => {
  e.preventDefault(); $('clipError').textContent = '';
  try { await post('/api/clips', {title: $('cTitle').value, url: $('cUrl').value, start: $('cStart').value, end: $('cEnd').value, notes: $('cNotes').value}); say('Added to Downloads'); $('cTitle').value = ''; $('cNotes').value = ''; refresh(); }
  catch (err) { $('clipError').textContent = err.message; }
});
$('importChoose').addEventListener('click', () => $('importFile').click());
$('importFile').addEventListener('change', async e => {
  try {
    imports = JSON.parse(await e.target.files[0].text());
    if (!Array.isArray(imports) || imports.length > 200) throw Error('The file must contain a list of up to 200 entries.');
    $('importList').innerHTML = imports.map((c, i) => `<label><input type="checkbox" checked data-i="${i}"> ${esc(c.title)} <span class="dim">${esc(c.start)} to ${esc(c.end)}</span></label>`).join('');
    $('importList').hidden = $('importActions').hidden = false;
  } catch (err) { say(err.message, {error: true}); }
});
$('importQueue').addEventListener('click', async () => {
  const b = $('importQueue'); b.disabled = true; let n = 0;
  try { for (const el of $('importList').querySelectorAll('input:checked')) { await post('/api/clips', imports[el.dataset.i]); el.checked = false; n++; } say(plural(n, 'clip') + ' added to Downloads'); refresh(); }
  catch (err) { say('Stopped after ' + n + ': ' + err.message, {error: true}); } finally { b.disabled = false; }
});

/* ---------- Window shortcuts (keyboards.md) ---------- */
document.addEventListener('keydown', e => {
  const mod = e.metaKey || e.ctrlKey;
  if (e.metaKey && e.ctrlKey && e.key.toLowerCase() === 's') { e.preventDefault(); toggleSidebar(); }
  else if (mod && e.altKey && (e.code === 'KeyI')) { e.preventDefault(); toggleInspector(); }
  else if (mod && (e.code === 'KeyF') && !$('tbSearchWrap').hidden) { e.preventDefault(); $('tbSearch').focus(); $('tbSearch').select(); }
  else if (e.key === 'Escape' && !$('menu').hidden) hideMenu();
});
$('sidebar').addEventListener('click', e => { if (e.target.closest('.sb-item') && window.matchMedia('(max-width: 1000px)').matches) { $('window').classList.remove('sidebar-open'); applyChrome(); } });

/* ---------- Start ---------- */
applyChrome();
await loadCatalogue();
await refresh();
if (!location.hash) { const last = store.get('lastEvent', null); history.replaceState(null, '', last ? '#/event/' + encodeURIComponent(last) : '#/downloads'); }
route();
setInterval(refresh, 2500);
