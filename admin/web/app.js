'use strict';

const $ = (id) => document.getElementById(id);

// ----- API -----

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

function showMessage(text, kind = 'error', action) {
  const m = $('message');
  m.className = 'message ' + kind;
  m.textContent = text;
  if (action) {
    const b = document.createElement('button');
    b.textContent = action.label;
    b.onclick = action.run;
    m.append(b);
  }
  m.hidden = false;
}
const hideMessage = () => { $('message').hidden = true; };

// ----- grid state -----
// row.vals[i]: string, null (NULL) or undefined (column default, new rows only)

let meta = null;      // {name, readOnly, columns}
let rows = [];        // [{orig: [...] | null, vals: [...], deleted: bool}]
let fkOptions = {};   // column index -> [{value, label}]
let sel = null;       // {r, c}
let editing = null;   // {r, c, input}

const isBool = (col) => col.type === 'boolean';
const pkCols = () => meta.columns.map((c, i) => (c.pk ? i : -1)).filter((i) => i >= 0);

function cellEditable(r, c) {
  const row = rows[r];
  if (meta.readOnly || row.deleted) return false;
  if (!row.orig) return true;
  return !meta.columns[c].pk && pkCols().length > 0;
}

function cellChanged(row, c) {
  return row.orig ? row.vals[c] !== row.orig[c] : row.vals[c] !== undefined;
}

function pendingChanges() {
  let ins = 0, upd = 0, del = 0;
  for (const row of rows) {
    if (!row.orig) { if (!row.deleted) ins++; }
    else if (row.deleted) del++;
    else if (row.vals.some((_, c) => cellChanged(row, c))) upd++;
  }
  return { ins, upd, del, total: ins + upd + del };
}

// ----- table list -----

async function loadTableList() {
  const names = await api('GET', '/api/tables');
  const nav = $('tables');
  nav.innerHTML = '';
  for (const name of names) {
    const a = document.createElement('a');
    a.href = '#' + name;
    a.textContent = name;
    a.dataset.table = name;
    nav.append(a);
  }
  const wanted = location.hash.slice(1);
  if (names.includes(wanted)) openTable(wanted);
  else if (names.length) location.hash = names.includes('trunk') ? 'trunk' : names[0];
}

window.addEventListener('hashchange', () => {
  const name = location.hash.slice(1);
  if (meta && name === meta.name) return;
  if (meta && pendingChanges().total && !confirm('Discard unsaved changes of ' + meta.name + '?')) {
    history.replaceState(null, '', '#' + meta.name);
    return;
  }
  openTable(name);
});

window.addEventListener('beforeunload', (e) => {
  if (meta && pendingChanges().total) e.preventDefault();
});

async function openTable(name) {
  hideMessage();
  try {
    const data = await api('GET', '/api/tables/' + encodeURIComponent(name));
    meta = data.table;
    rows = data.rows.map((v) => ({ orig: v, vals: [...v], deleted: false }));
    fkOptions = {};
    await Promise.all(meta.columns.map(async (col, i) => {
      if (!col.fkTable) return;
      fkOptions[i] = await api('GET', `/api/options/${encodeURIComponent(col.fkTable)}/${encodeURIComponent(col.fkColumn)}`)
        .catch(() => null);
    }));
  } catch (e) {
    showMessage(e.message);
    return;
  }
  sel = rows.length ? { r: 0, c: 0 } : null;
  editing = null;
  for (const a of $('tables').children) a.classList.toggle('active', a.dataset.table === name);
  $('table-name').textContent = meta.name + (meta.readOnly ? ' (read-only)' : '');
  render();
  $('grid-wrap').focus();
}

// ----- rendering -----

function displayValue(c, v) {
  const col = meta.columns[c];
  if (v === undefined) {
    if (col.default && col.default.startsWith('nextval(')) return 'auto';
    return col.default != null ? 'default: ' + col.default : 'default';
  }
  if (v === null) return 'NULL';
  if (isBool(col)) return v === 'true' ? '☑ true' : '☐ false';
  const opts = fkOptions[c];
  if (opts) {
    const o = opts.find((o) => o.value === v);
    if (o) return o.label;
  }
  return v;
}

function render() {
  const grid = $('grid');
  grid.innerHTML = '';
  const head = grid.createTHead().insertRow();
  const th0 = document.createElement('th');
  th0.className = 'rowhead';
  th0.textContent = '#';
  head.append(th0);
  for (const col of meta.columns) {
    const th = document.createElement('th');
    if (col.pk) th.className = 'key';
    th.textContent = col.name;
    const small = document.createElement('small');
    small.textContent = col.type + (col.nullable ? '' : ' · not null') + (col.fkTable ? ` → ${col.fkTable}` : '');
    th.append(small);
    th.title = col.default ? 'default: ' + col.default : '';
    head.append(th);
  }

  const body = grid.createTBody();
  rows.forEach((row, r) => {
    const tr = body.insertRow();
    if (!row.orig) tr.className = 'new';
    if (row.deleted) tr.className = 'deleted';
    const rh = tr.insertCell();
    rh.className = 'rowhead';
    if (!meta.readOnly) {
      const del = document.createElement('button');
      del.textContent = row.deleted ? '↺' : '✕';
      del.title = row.deleted ? 'Undo delete' : 'Delete row';
      del.onclick = (e) => { e.stopPropagation(); toggleDelete(r); };
      rh.append(del);
    }
    rh.append(' ' + (r + 1));

    row.vals.forEach((v, c) => {
      const td = tr.insertCell();
      td.textContent = displayValue(c, v);
      td.title = v == null ? '' : v;
      td.dataset.r = r;
      td.dataset.c = c;
      if (!cellEditable(r, c)) td.classList.add('readonly');
      if (v === null) td.classList.add('null');
      if (v === undefined) td.classList.add('default');
      if (row.orig && !row.deleted && cellChanged(row, c)) td.classList.add('changed');
      if (sel && sel.r === r && sel.c === c) td.classList.add('sel');
    });
  });
  updateToolbar();
}

function cellEl(r, c) {
  return $('grid').querySelector(`td[data-r="${r}"][data-c="${c}"]`);
}

function updateToolbar() {
  const p = pendingChanges();
  $('changes').textContent = p.total
    ? `${p.upd} changed · ${p.ins} new · ${p.del} deleted`
    : `${rows.length} rows`;
  $('btn-save').disabled = !p.total;
  $('btn-discard').disabled = !p.total;
  $('btn-add').disabled = !meta || meta.readOnly;
  $('btn-null').disabled = !sel || !cellEditable(sel.r, sel.c) || !meta.columns[sel.c].nullable;
}

function select(r, c) {
  if (!rows.length) return;
  r = Math.max(0, Math.min(rows.length - 1, r));
  c = Math.max(0, Math.min(meta.columns.length - 1, c));
  if (sel) cellEl(sel.r, sel.c)?.classList.remove('sel');
  sel = { r, c };
  const td = cellEl(r, c);
  td.classList.add('sel');
  td.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  updateToolbar();
}

// ----- editing -----

function setValue(r, c, v) {
  rows[r].vals[c] = v;
  render();
}

function startEdit(initial) {
  if (!sel || editing || !cellEditable(sel.r, sel.c)) return;
  const { r, c } = sel;
  const col = meta.columns[c];
  const cur = rows[r].vals[c];
  if (isBool(col)) {
    setValue(r, c, cur === 'true' ? 'false' : 'true');
    return;
  }
  const td = cellEl(r, c);
  let input;
  const opts = fkOptions[c];
  if (opts) {
    input = document.createElement('select');
    const choices = [...(col.nullable ? [{ value: '\0null', label: 'NULL' }] : []), ...opts];
    for (const o of choices) input.add(new Option(o.label, o.value));
    input.value = cur == null ? (col.nullable ? '\0null' : '') : cur;
  } else {
    input = document.createElement('input');
    input.value = initial !== undefined ? initial : (cur ?? '');
  }
  td.textContent = '';
  td.classList.add('editing');
  td.append(input);
  editing = { r, c, input };
  input.focus();
  if (input.select && initial === undefined) input.select();

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); commitEdit(); select(r + 1, c); }
    else if (e.key === 'Tab') { e.preventDefault(); commitEdit(); select(r, c + (e.shiftKey ? -1 : 1)); }
    else if (e.key === 'Escape') { e.preventDefault(); cancelEdit(); }
    e.stopPropagation();
  });
  input.addEventListener('blur', () => { if (editing && editing.input === input) commitEdit(); });
}

function commitEdit() {
  if (!editing) return;
  const { r, c, input } = editing;
  editing = null;
  let v = input.value;
  if (v === '\0null') v = null;
  setValue(r, c, v);
  $('grid-wrap').focus();
}

function cancelEdit() {
  editing = null;
  render();
  $('grid-wrap').focus();
}

function clearCell(toNull) {
  if (!sel || !cellEditable(sel.r, sel.c)) return;
  const col = meta.columns[sel.c];
  if (toNull || isBool(col) || fkOptions[sel.c]) {
    if (!col.nullable) return;
    setValue(sel.r, sel.c, null);
  } else {
    setValue(sel.r, sel.c, '');
  }
}

function toggleDelete(r) {
  if (!rows[r].orig) rows.splice(r, 1);
  else rows[r].deleted = !rows[r].deleted;
  if (sel && sel.r >= rows.length) sel = rows.length ? { r: rows.length - 1, c: sel.c } : null;
  render();
}

function addRow() {
  rows.push({ orig: null, vals: meta.columns.map(() => undefined), deleted: false });
  render();
  const firstEditable = meta.columns.findIndex((col) => !(col.default && col.default.startsWith('nextval(')));
  select(rows.length - 1, Math.max(0, firstEditable));
  $('grid-wrap').focus();
}

$('grid').addEventListener('mousedown', (e) => {
  const td = e.target.closest('td[data-c]');
  if (!td || td.classList.contains('editing')) return;
  if (editing) commitEdit();
  select(+td.dataset.r, +td.dataset.c);
});
$('grid').addEventListener('dblclick', (e) => {
  if (e.target.closest('td[data-c]')) startEdit();
});

$('grid-wrap').addEventListener('keydown', (e) => {
  if (!meta || editing) return;
  if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); save(); return; }
  if (!sel) return;
  const moves = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1] };
  if (moves[e.key]) {
    e.preventDefault();
    select(sel.r + moves[e.key][0], sel.c + moves[e.key][1]);
  } else if (e.key === 'Tab') {
    e.preventDefault();
    select(sel.r, sel.c + (e.shiftKey ? -1 : 1));
  } else if (e.key === 'Enter' || e.key === 'F2') {
    e.preventDefault();
    startEdit();
  } else if (e.key === ' ' && isBool(meta.columns[sel.c])) {
    e.preventDefault();
    startEdit();
  } else if (e.key === 'Delete' || e.key === 'Backspace') {
    e.preventDefault();
    clearCell(e.shiftKey);
  } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
    e.preventDefault();
    startEdit(isBool(meta.columns[sel.c]) || fkOptions[sel.c] ? undefined : e.key);
  }
});

document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 's' && meta) { e.preventDefault(); if (editing) commitEdit(); save(); }
});

// ----- save -----

async function save() {
  if (editing) commitEdit();
  if (!pendingChanges().total) return;
  const pk = (row) => Object.fromEntries(pkCols().map((i) => [meta.columns[i].name, row.orig[i]]));
  const changes = { inserts: [], updates: [], deletes: [] };
  for (const row of rows) {
    if (!row.orig) {
      if (row.deleted) continue;
      const ins = {};
      row.vals.forEach((v, c) => { if (v !== undefined) ins[meta.columns[c].name] = v; });
      changes.inserts.push(ins);
    } else if (row.deleted) {
      changes.deletes.push({ pk: pk(row) });
    } else {
      const set = {};
      row.vals.forEach((v, c) => { if (cellChanged(row, c)) set[meta.columns[c].name] = v; });
      if (Object.keys(set).length) changes.updates.push({ pk: pk(row), set });
    }
  }
  $('btn-save').disabled = true;
  try {
    await api('POST', `/api/tables/${encodeURIComponent(meta.name)}/save`, changes);
  } catch (e) {
    showMessage('Not saved, nothing was written:\n' + e.message);
    updateToolbar();
    return;
  }
  const name = meta.name;
  const sr = sel;
  await openTable(name);
  if (sr && rows.length) select(sr.r, sr.c);
  if (name === 'trunk' || name === 'settings') {
    showMessage('Saved. Trunk registrations are cached by kamailio.', 'info', { label: 'Reload registrations', run: reload });
  } else {
    showMessage('Saved.', 'info');
    setTimeout(hideMessage, 2500);
  }
}

$('btn-save').onclick = save;
$('btn-add').onclick = addRow;
$('btn-null').onclick = () => { clearCell(true); $('grid-wrap').focus(); };
$('btn-discard').onclick = () => { if (confirm('Discard all changes?')) openTable(meta.name); };

// ----- kamailio -----

function fmtDuration(s) {
  s = Math.floor(s);
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return (d ? d + 'd ' : '') + (d || h ? h + 'h ' : '') + m + 'm ' + (s % 60) + 's';
}

async function refreshStatus() {
  const el = $('status');
  try {
    const s = await api('GET', '/api/kamailio/status');
    const parts = [];
    if (s.container) {
      const ok = s.container.status === 'running';
      parts.push(`<span class="${ok ? 'ok' : 'err'}">container ${s.container.status}</span>`);
    } else if (s.containerError) {
      parts.push(`<span class="err">docker: ${esc(s.containerError)}</span>`);
    } else if (s.uptime) {
      parts.push('<span class="ok">running</span>');
    }
    if (s.uptime) {
      parts.push('up ' + fmtDuration(s.uptime.uptime));
      if (s.version) parts.push(esc(String(s.version).split(' ').slice(0, 2).join(' ')));
      if (Array.isArray(s.registrations)) parts.push(s.registrations.length + ' trunk registrations');
    } else {
      parts.push(`<span class="err">RPC: ${esc(s.rpcError)}</span>`);
    }
    el.innerHTML = parts.join(' · ');
  } catch (e) {
    el.innerHTML = `<span class="err">${esc(e.message)}</span>`;
  }
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"]/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[ch]);
}

async function reload() {
  try {
    await api('POST', '/api/kamailio/reload');
    showMessage('Trunk registrations reloaded (uac.reg_reload).', 'info');
  } catch (e) {
    showMessage('Reload failed: ' + e.message);
  }
  refreshStatus();
}

$('btn-reload').onclick = reload;
$('btn-restart').onclick = async () => {
  if (!confirm('Restart the kamailio container? Active calls will be dropped.')) return;
  const b = $('btn-restart');
  b.disabled = true;
  b.textContent = 'Restarting…';
  try {
    const res = await api('POST', '/api/kamailio/restart');
    showMessage(`Kamailio restarted (${res.method}).`, 'info');
  } catch (e) {
    showMessage('Restart failed: ' + e.message);
  }
  b.disabled = false;
  b.textContent = 'Restart kamailio';
  setTimeout(refreshStatus, 1500);
};

// RPC console
$('btn-console').onclick = () => { $('console').hidden = !$('console').hidden; if (!$('console').hidden) $('rpc-method').focus(); };
$('btn-console-close').onclick = () => { $('console').hidden = true; };
async function runRpc() {
  const method = $('rpc-method').value.trim();
  if (!method) return;
  let params = [];
  const p = $('rpc-params').value.trim();
  if (p) {
    try { params = JSON.parse(p); } catch (e) { $('rpc-out').textContent = 'params: ' + e.message; return; }
    if (!Array.isArray(params)) params = [params];
  }
  $('rpc-out').textContent = '…';
  try {
    const res = await api('POST', '/api/kamailio/rpc', { method, params });
    $('rpc-out').textContent = JSON.stringify(res.result, null, 2);
  } catch (e) {
    $('rpc-out').textContent = 'Error: ' + e.message;
  }
}
$('btn-rpc').onclick = runRpc;
for (const id of ['rpc-method', 'rpc-params']) {
  $(id).addEventListener('keydown', (e) => { if (e.key === 'Enter') runRpc(); });
}

loadTableList().catch((e) => showMessage(e.message));
refreshStatus();
setInterval(refreshStatus, 10000);
