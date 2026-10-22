// Powerdialer fuer Linkus Lite + NINA Sales Status
// Wird per Lesezeichen auf https://nina.ppedv.de/ppcompany/marketing/salesstatus geladen.
// Ablauf je Kontakt: Kontakt im Tab "pd_contact" oeffnen -> Nummer lesen -> ueber den lokalen
// Dashboard-Server waehlen (tel: -> Linkus) -> Auflegen im Linkus-Log erkennen -> Nachbearbeitung -> naechster.
(() => {
  if (window.__pd) { window.__pd.show(); return; }

  const SERVER = new URL(document.currentScript.src).origin;

  const LS_KEY = 'pd_state_v1';
  const PANEL_ID = 'pd-panel';
  const OPEN_TIMEOUT = 20000;   // ms bis Kontaktseite samt Nummer geladen sein muss
  const NO_CALL_TIMEOUT = 45000; // ms ohne erkannten Anruf -> trotzdem Nachbearbeitung

  // ------------------------------------------------------------ state
  // Einstellungen dieses PCs - der Server setzt hier den Inhalt von einstellungen.json ein
  const CONFIG = /*PD_CONFIG*/{ testNumber: '', amtPrefix: '0' }/*PD_CONFIG_END*/;

  // test: true -> statt der Kontaktnummer wird immer testNumber gewaehlt
  const S = Object.assign({ queue: [], idx: 0, wrapSec: 60, test: true }, load(), { testNumber: CONFIG.testNumber });
  let running = false;
  let phase = 'idle';           // idle | open | call | wrap | done
  let phaseT0 = 0;
  let cur = null;               // aktueller Kontakt {id, firma, name, url}
  let win = null;               // Kontakt-Tab
  let dial = null;              // {number, tsMs}
  let call = null;              // zugeordneter Anruf aus /api/state
  let serverNow = 0;
  let wrapEnd = 0;
  let msg = '';
  let polling = false, lastPoll = 0;

  function load() { try { return JSON.parse(localStorage.getItem(LS_KEY)) || {}; } catch { return {}; } }
  function save() { try { localStorage.setItem(LS_KEY, JSON.stringify(S)); } catch {} }

  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const digits = s => String(s || '').replace(/\D/g, '');
  const tsMs = s => s ? new Date(s.replace(' ', 'T')).getTime() : 0;
  const mmss = ms => { const t = Math.max(0, Math.round(ms / 1000)); return Math.floor(t / 60) + ':' + String(t % 60).padStart(2, '0'); };
  const setPhase = p => { phase = p; phaseT0 = Date.now(); };

  // Linkus braucht die Amtsholung (CONFIG.amtPrefix, meist "0"): +43... -> 00043..., 0151... -> 00151...
  // (die tel:-Links im NINA-Kontakt enthalten die Amt-0 bereits)
  function linkusNumber(n) {
    n = String(n || '').replace(/[^\d+]/g, '');
    if (n.startsWith('+')) return CONFIG.amtPrefix + '00' + n.slice(1);
    return CONFIG.amtPrefix + n;
  }

  // gleiche Nummer in verschiedenen Schreibweisen -> gleicher Schluessel (wie Get-NumKey im Server)
  const numKey = n => digits(n).replace(/^0+/, '').slice(-9);

  // ------------------------------------------------------------ queue
  // Quelle: jede Tabelle mit Links auf NINA-Ansprechpartner/-Firmen (Sales Status oder eigene Listen).
  // Hat die Zeile selbst tel:-Links (eigene Liste), wird die Nummer direkt von dort genommen.
  // Nie doppelt: pro Firma, Ansprechpartner und Nummer hoechstens ein Eintrag, und nichts, was laut
  // Anrufprotokoll (Server) schon gewaehlt wurde.
  const LIST_ROWS = 'table tbody tr';
  const AP_LINK = 'a[href*="Ansprechpartneredit/" i]', FIRMA_LINK = 'a[href*="kundenedit/" i]';
  const skipped = new Set();     // in dieser Sitzung uebersprungene Eintraege
  const idOf = a => (a?.getAttribute('href').match(/(\d+)\s*$/) || [])[1] || '';
  function rowKey(tr) {
    const apId = idOf(tr.querySelector(AP_LINK)), firmaId = idOf(tr.querySelector(FIRMA_LINK));
    return apId || (firmaId ? 'F' + firmaId : '');
  }

  // "▶"-Button vor jeder Zeile der eigenen Liste: Powerdialer ab dieser Zeile starten
  function addRowButtons() {
    for (const tr of document.querySelectorAll(LIST_ROWS)) {
      if (tr.querySelector('.pd-from') || !rowKey(tr) || !tr.cells[0]) continue;
      const b = document.createElement('button');
      b.className = 'pd-from'; b.type = 'button'; b.textContent = '▶'; b.title = 'Powerdialer ab hier starten';
      tr.cells[0].prepend(b);
    }
  }
  document.addEventListener('click', e => {
    const b = e.target.closest('.pd-from'); if (!b) return;
    e.preventDefault();
    if (running) { msg = 'Erst stoppen, dann Startzeile wählen'; render(); return; }
    const tr = b.closest('tr');
    S.startFrom = rowKey(tr);
    S.startFromLabel = (tr.querySelector(FIRMA_LINK)?.innerText || tr.cells[1]?.innerText || '').trim();
    skipped.clear(); cur = null; setPhase('idle'); save();
    buildQueue().then(render);
  });

  function canBuildQueue() { return !!document.querySelector(`${LIST_ROWS} ${AP_LINK}, ${LIST_ROWS} ${FIRMA_LINK}`); }

  async function buildQueue() {
    let called;
    try {
      called = await (await fetch(SERVER + '/api/called?test=' + (S.test ? 1 : 0), { cache: 'no-store' })).json();
      if (!called.ok) throw new Error(called.error);
    } catch (e) {
      msg = 'Anrufprotokoll nicht abrufbar – läuft das Dashboard?';
      return false;
    }
    const doneF = new Set(called.firmen), doneA = new Set(called.aps), doneN = new Set(called.nummern);
    // Zeilen mit data-retry="1" (nicht erreicht): nur gesperrt, wenn heute schon gewaehlt oder echtes Gespraech
    const rt = called.retry || { firmen: called.firmen, aps: called.aps, nummern: called.nummern };
    const rF = new Set(rt.firmen), rA = new Set(rt.aps), rN = new Set(rt.nummern);
    const seenF = new Set(), seenA = new Set(), seenN = new Set();
    const q = [];
    let nDone = 0, nDup = 0, nNoNum = 0;
    // "ab hier": alles vor der gewaehlten Startzeile auslassen (Startzeile nicht mehr in der Liste -> ab Anfang)
    const rows = [...document.querySelectorAll(LIST_ROWS)];
    let from = S.startFrom ? rows.findIndex(tr => rowKey(tr) === S.startFrom) : 0;
    if (from < 0) { from = 0; S.startFrom = ''; S.startFromLabel = ''; }
    for (const tr of rows.slice(from)) {
      if (tr.style.display === 'none') continue;   // weggefilterte Zeilen nicht waehlen
      const ap = tr.querySelector(AP_LINK), fa = tr.querySelector(FIRMA_LINK);
      if (!ap && !fa) continue;
      const apId = idOf(ap), firmaId = idOf(fa);
      const link = ap || fa;
      const url = new URL(link.getAttribute('href'), document.baseURI).href;
      const telA = [...tr.querySelectorAll('a[href^="tel:"]')].find(t => digits(t.getAttribute('href')).length >= 5);
      const number = telA ? linkusNumber(telA.getAttribute('href').slice(4)) : null;
      // Liste ohne Nummer und fremde Kontaktseite -> nicht waehlbar (belegt die Firma nicht)
      if (!number && new URL(url).origin !== location.origin) { nNoNum++; continue; }
      const nk = number ? numKey(number) : '';
      const retry = tr.dataset.retry === '1';
      const [bF, bA, bN] = retry ? [rF, rA, rN] : [doneF, doneA, doneN];
      if ((firmaId && bF.has(firmaId)) || (apId && bA.has(apId)) || (nk && bN.has(nk))) { nDone++; continue; }
      if ((firmaId && seenF.has(firmaId)) || (apId && seenA.has(apId)) || (nk && seenN.has(nk))) { nDup++; continue; }
      if (skipped.has(apId || 'F' + firmaId)) continue;
      if (firmaId) seenF.add(firmaId);
      if (apId) seenA.add(apId);
      if (nk) seenN.add(nk);
      const tds = tr.children;
      q.push({
        id: apId, firmaId, url, number, retry,
        firma: (fa?.innerText || tds[1]?.innerText || '').trim(),
        name: (ap ? (ap.querySelector('span.ms-1, span:not(.badge)')?.innerText || ap.parentElement.querySelector('span.ms-1')?.innerText
                     || ap.innerText.replace(apId, '')) : (tds[2]?.innerText || '')).trim()
      });
    }
    S.queue = q; S.idx = 0; save();
    msg = `${q.length} zu wählen` + (nDone ? ` · ${nDone} schon angerufen` : '') +
          (nDup ? ` · ${nDup} doppelt (Firma/Nummer)` : '') + (nNoNum ? ` · ${nNoNum} ohne Nummer` : '');
    return true;
  }

  // ------------------------------------------------------------ flow
  let starting = false;
  async function start() {
    if (running || starting) return;
    if (!canBuildQueue()) { msg = 'Keine Ansprechpartner-Tabelle auf dieser Seite'; render(); return; }
    // Kontakt-Fenster sofort (Klick = Nutzergeste) oeffnen, damit der Popup-Blocker nicht greift
    if (!win || win.closed) win = openContactWin('about:blank');
    if (phase === 'idle' || phase === 'done') {
      // bei jedem Start frisch: aktueller Filter minus alles, was schon angerufen wurde
      starting = true; msg = 'Lade Anrufprotokoll …'; render();
      const ok = await buildQueue();
      starting = false;
      if (!ok || !S.queue.length) {
        if (ok) msg = 'Nichts mehr zu wählen – ' + msg;
        cur = null; render(); return;
      }
      cur = null;
    }
    running = true;
    if (phase === 'idle' || phase === 'done') next();
    render();
  }

  function stop() {
    running = false;
    if (phase === 'open') { S.idx--; save(); cur = null; setPhase('idle'); msg = 'Gestoppt'; }
    else if (phase === 'wrap') { setPhase('idle'); msg = 'Gestoppt – Nachbearbeitung ohne Zeitlimit'; }
    else if (phase === 'call') msg = 'Stoppt nach diesem Gespräch';
    render();
  }

  // Eigenes Kontakt-Fenster rechts (60 % Bildschirmbreite), damit Panel und Kontakt
  // gleichzeitig sichtbar sind; jeder neue Kontakt wird darin geladen
  function openContactWin(url) {
    const sw = screen.availWidth, sh = screen.availHeight, sl = screen.availLeft || 0, st = screen.availTop || 0;
    const w = Math.round(sw * 0.6);
    return window.open(url, 'pd_contact', `popup,width=${w},height=${sh},left=${sl + sw - w},top=${st}`);
  }

  function next() {
    call = null; dial = null;
    if (S.idx >= S.queue.length) { running = false; setPhase('done'); cur = null; msg = 'Liste abgearbeitet'; render(); return; }
    cur = S.queue[S.idx];
    S.idx++; save();
    if (!win || win.closed) win = openContactWin(cur.url);
    else { win.location.href = cur.url; try { win.focus(); } catch {} }
    if (!win) { running = false; setPhase('idle'); msg = 'Popup blockiert – bitte Popups für nina.ppedv.de erlauben'; S.idx--; save(); render(); return; }
    msg = '';
    setPhase('open');
    render();
  }

  function contactDoc() {
    try {
      if (!win || win.closed) return null;
      if (!cur || !win.location.pathname.toLowerCase().endsWith('/ansprechpartneredit/' + cur.id)) return null;
      return win.document;
    } catch { return null; }
  }

  function findNumber(doc) {
    for (const a of doc.querySelectorAll('a[href^="tel:"]')) {
      const n = a.getAttribute('href').slice(4).replace(/[^\d+]/g, '');
      if (digits(n).length >= 5) return n;
    }
    return null;
  }

  async function doDial(contactNumber) {
    const number = S.test ? linkusNumber(S.testNumber) : contactNumber;
    setPhase('call');
    msg = S.test ? 'TEST: wähle ' + number + ' statt ' + contactNumber : 'Wähle ' + number + ' …';
    render();
    const p = new URLSearchParams({
      number, contact: contactNumber, test: S.test ? '1' : '0', retry: cur.retry ? '1' : '0',
      firmaId: cur.firmaId || '', apId: cur.id || '', firma: cur.firma || '', name: cur.name || ''
    });
    try {
      const r = await fetch(SERVER + '/api/dial?' + p, { cache: 'no-store' });
      const j = await r.json();
      if (j.error === 'doppelt' || j.error === 'unbekannt' || j.error === 'number') {
        // Server-Sperre (schon angerufen / Nummer nicht freigegeben) -> diesen Kontakt auslassen, weiter
        msg = 'Nicht gewählt: ' + (cur.firma ? cur.firma + ' – ' : '') + (j.detail || j.error);
        if (running) next(); else { setPhase('idle'); render(); }
        return;
      }
      if (!j.ok) throw new Error(j.detail || j.error || r.status);
      dial = { number, contactNumber, logId: j.logId, tsMs: tsMs(j.now) };
    } catch (e) {
      running = false; setPhase('idle');
      msg = 'Wählen fehlgeschlagen (' + e.message + ') – läuft das Dashboard (localhost:8765)?';
      render();
    }
  }

  function startWrap(note) {
    console.debug('[Powerdialer] Nachbearbeitung:', note);
    if (dial?.logId) {
      fetch(SERVER + '/api/result?' + new URLSearchParams({ logId: dial.logId, result: note || '' }), { cache: 'no-store' }).catch(() => {});
    }
    setPhase('wrap');
    wrapEnd = Date.now() + S.wrapSec * 1000;
    msg = note || '';
    if (!running) { setPhase('idle'); msg = 'Gestoppt – Nachbearbeitung ohne Zeitlimit'; }
    render();
  }

  async function pollCall() {
    if (polling || Date.now() - lastPoll < 900) return;
    polling = true; lastPoll = Date.now();
    try {
      const st = await (await fetch(SERVER + '/api/state', { cache: 'no-store' })).json();
      if (phase !== 'call' || !dial) return;
      serverNow = tsMs(st.now);
      const tail = digits(dial.number).slice(-8);
      let m = null;
      for (let i = st.calls.length - 1; i >= 0; i--) {
        const c = st.calls[i];
        if (tsMs(c.start) < dial.tsMs - 3000) break;
        if (c.dir === 'out' && digits(c.number).endsWith(tail)) { m = c; break; }
      }
      call = m;
      if (m && m.end) startWrap(m.answer ? 'Gespräch ' + mmss(tsMs(m.end) - tsMs(m.answer)) : 'Nicht erreicht');
      else if (!m && Date.now() - phaseT0 > NO_CALL_TIMEOUT) startWrap('Kein Anruf in Linkus erkannt');
      else render();
    } catch {
      msg = 'Dashboard-Server nicht erreichbar'; render();
    } finally { polling = false; }
  }

  function tick() {
    if (phase === 'open') {
      // Nummer aus der Liste (eigene Liste) oder von der geoeffneten Kontaktseite (Sales Status)
      const doc = cur.number ? null : contactDoc();
      const num = cur.number || (doc && findNumber(doc));
      // Kontaktseite einer fremden Origin kann nicht gelesen werden -> ohne Nummer in der Liste sofort weiter
      const unreadable = !cur.number && new URL(cur.url).origin !== location.origin;
      if (num) { render(); doDial(num); }
      else if (unreadable || Date.now() - phaseT0 > OPEN_TIMEOUT) {
        msg = 'Keine Telefonnummer bei ' + (cur.name || cur.id) + ' – übersprungen';
        if (running) next(); else setPhase('idle');
      }
    } else if (phase === 'call') {
      if (dial) pollCall();
    } else if (phase === 'wrap') {
      if (Date.now() >= wrapEnd) { if (running) next(); else setPhase('idle'); }
      else render();
    }
    ensurePanels();
  }

  // ------------------------------------------------------------ UI
  function statusText() {
    switch (phase) {
      case 'open': return 'Öffne Kontakt …';
      case 'call':
        if (!dial) return 'Wähle …';
        if (!call) return 'Wähle …';
        if (call.answer) return 'Verbunden ' + mmss(serverNow - tsMs(call.answer));
        if (call.ring) return 'Klingelt …';
        return 'Wähle …';
      case 'wrap': return 'Nachbearbeitung ' + mmss(wrapEnd - Date.now());
      case 'done': return 'Fertig';
      default: return running ? '…' : 'Gestoppt';
    }
  }

  function html() {
    const n = S.queue.length;
    const pos = cur ? S.idx : Math.min(S.idx + 1, n);
    const btn = (act, label, kind) => `<button data-pd="${act}" class="pd-b ${kind || ''}">${label}</button>`;
    const btns = [];
    btns.push(running ? btn('stop', '■ Stop', 'pd-red') : btn('start', '▶ Start', 'pd-green'));
    if (phase === 'call') btns.push(btn('hungup', 'Aufgelegt'));
    if (phase === 'wrap') btns.push(btn('more', '+30 s'), btn('go', 'Weiter ▶'));
    if (phase !== 'call' && S.idx < n) btns.push(btn('skip', 'Überspringen'));
    const upNext = !cur && S.idx < n ? S.queue[S.idx] : null;
    return `
      <div class="pd-h"><b>Powerdialer</b>${S.test ? '<em class="pd-test">TEST</em>' : ''}<span>${n ? pos + ' / ' + n : 'keine Liste'}</span><button data-pd="min" class="pd-x" title="Einklappen">–</button></div>
      <div class="pd-body">
        ${cur ? `<div class="pd-c"><div class="pd-f">${esc(cur.firma)}</div><div>${esc(cur.name)}${dial ? ' · ' + esc(dial.number) : ''}</div></div>` : ''}
        ${S.startFrom ? `<div class="pd-c">Start ab: <b>${esc(S.startFromLabel)}</b> <button data-pd="clearfrom" class="pd-x" title="Wieder ab Anfang">✕</button></div>` : ''}
        ${upNext ? `<div class="pd-c">Als Nächstes:<div class="pd-f">${esc(upNext.firma)}</div><div>${esc(upNext.name)}</div></div>` : ''}
        <div class="pd-s pd-${phase}"></div>
        ${phase === 'wrap' ? `<div class="pd-bar"><i></i></div>` : ''}
        <div class="pd-btns">${btns.join('')}</div>
        ${msg ? `<div class="pd-m">${esc(msg)}</div>` : ''}
        <div class="pd-set">
          <label>Nachbearbeitung <input data-pd="wrapsec" type="number" min="0" max="900" step="15" value="${S.wrapSec}"> s</label>
          ${btn('reload', 'Liste neu', 'pd-small')}
        </div>
        <label class="pd-set pd-testrow"><span><input data-pd="test" type="checkbox" ${S.test ? 'checked' : ''}> Testmodus: immer ${esc(S.testNumber)} wählen</span></label>
      </div>`;
  }

  const CSS = `
    #${PANEL_ID}{position:fixed;right:16px;bottom:16px;z-index:2147483647;width:300px;font:13px/1.35 system-ui,Segoe UI,sans-serif;
      background:#1a1a19;color:#fff;border-radius:10px;box-shadow:0 6px 24px rgba(0,0,0,.35);overflow:hidden}
    #${PANEL_ID}.pd-min .pd-body{display:none}
    #${PANEL_ID} .pd-h{display:flex;align-items:center;gap:8px;padding:8px 10px;background:#2a78d6}
    #${PANEL_ID} .pd-h span{margin-left:auto;opacity:.85;font-variant-numeric:tabular-nums}
    #${PANEL_ID} .pd-x{background:none;border:0;color:#fff;font-size:16px;cursor:pointer;padding:0 2px}
    #${PANEL_ID} .pd-body{padding:10px}
    #${PANEL_ID} .pd-c{margin-bottom:6px;color:#c3c2b7}
    #${PANEL_ID} .pd-f{color:#fff;font-weight:600}
    #${PANEL_ID} .pd-s{font-size:18px;font-weight:600;font-variant-numeric:tabular-nums;margin:4px 0 8px}
    #${PANEL_ID} .pd-wrap{color:#fab219} #${PANEL_ID} .pd-call{color:#5fd35f}
    #${PANEL_ID} .pd-bar{height:4px;background:#383835;border-radius:2px;margin:-4px 0 8px}
    #${PANEL_ID} .pd-bar i{display:block;height:100%;background:#fab219;border-radius:2px}
    #${PANEL_ID} .pd-btns{display:flex;flex-wrap:wrap;gap:6px}
    #${PANEL_ID} .pd-b{border:0;border-radius:6px;padding:6px 10px;background:#383835;color:#fff;cursor:pointer;font:inherit}
    #${PANEL_ID} .pd-b:hover{filter:brightness(1.2)}
    #${PANEL_ID} .pd-green{background:#0ca30c} #${PANEL_ID} .pd-red{background:#d03b3b}
    #${PANEL_ID} .pd-m{margin-top:8px;color:#c3c2b7;font-size:12px}
    #${PANEL_ID} .pd-set{display:flex;align-items:center;justify-content:space-between;margin-top:10px;padding-top:8px;border-top:1px solid #2c2c2a;color:#898781;font-size:12px}
    #${PANEL_ID} .pd-set input{width:52px;background:#0d0d0d;color:#fff;border:1px solid #383835;border-radius:4px;padding:2px 4px}
    #${PANEL_ID} .pd-small{padding:3px 8px;font-size:12px}
    #${PANEL_ID} .pd-test{font-style:normal;font-size:11px;font-weight:700;background:#fab219;color:#0b0b0b;border-radius:4px;padding:0 5px}
    #${PANEL_ID} .pd-testrow{justify-content:flex-start;margin-top:6px;padding-top:6px;cursor:pointer}
    #${PANEL_ID} .pd-testrow input{width:auto;margin:0 4px 0 0;vertical-align:-2px}
    .pd-from{border:1px solid #0ca30c;background:#fff;color:#0ca30c;border-radius:4px;font-size:10px;line-height:1;padding:2px 4px;margin-right:4px;cursor:pointer}
    .pd-from:hover{background:#0ca30c;color:#fff}`;

  let minimized = false;

  let lastAct = 0;
  function onClick(e) {
    const act = e.target.closest('[data-pd]')?.dataset.pd;
    if (!act || act === 'wrapsec' || act === 'test') return;
    // Buttons wechseln nach einem Klick ihre Position (Start -> Stop ...):
    // Doppelklicks duerfen nicht als zweite Aktion ankommen
    if (act !== 'min' && Date.now() - lastAct < 800) return;
    lastAct = Date.now();
    console.debug('[Powerdialer]', act, phase);
    switch (act) {
      case 'start': start(); break;
      case 'stop': stop(); break;
      case 'skip':
        msg = '';
        if (running) { if (cur) skipped.add(cur.id || 'F' + cur.firmaId); next(); }   // sofort zum naechsten Kontakt
        else {
          // naechsten Eintrag fuer diese Sitzung aus der Liste nehmen
          const nx = S.queue[S.idx];
          if (nx) { skipped.add(nx.id || 'F' + nx.firmaId); S.idx++; save(); }
          cur = null; setPhase('idle'); render();
        }
        break;
      case 'hungup': startWrap('Manuell als aufgelegt markiert'); break;
      case 'more': wrapEnd += 30000; render(); break;
      case 'go': if (running) next(); else setPhase('idle'); render(); break;
      case 'min': minimized = !minimized; render(); break;
      case 'clearfrom':
        if (running) { msg = 'Erst stoppen'; render(); break; }
        S.startFrom = ''; S.startFromLabel = ''; skipped.clear(); cur = null; setPhase('idle'); save();
        buildQueue().then(render); break;
      case 'reload':
        if (!canBuildQueue()) { msg = 'Keine Ansprechpartner-Tabelle auf dieser Seite'; render(); break; }
        if (running) { msg = 'Erst stoppen, dann Liste neu laden'; render(); break; }
        skipped.clear(); cur = null; setPhase('idle');
        buildQueue().then(render); break;
    }
  }
  function onChange(e) {
    if (e.target.dataset.pd === 'wrapsec') {
      const v = Math.max(0, Math.min(900, parseInt(e.target.value, 10) || 0));
      if (phase === 'wrap') wrapEnd += (v - S.wrapSec) * 1000;
      S.wrapSec = v; save(); render();
    } else if (e.target.dataset.pd === 'test') {
      // LIVE und TEST haben getrennte Sperrlisten -> Warteschlange neu berechnen
      S.test = e.target.checked; save(); render();
      if (!running && canBuildQueue()) buildQueue().then(render);
    }
  }

  function panelIn(doc) {
    let p = doc.getElementById(PANEL_ID);
    if (!p) {
      if (!doc.getElementById(PANEL_ID + '-css')) {
        const st = doc.createElement('style'); st.id = PANEL_ID + '-css'; st.textContent = CSS; doc.head.appendChild(st);
      }
      p = doc.createElement('div'); p.id = PANEL_ID;
      p.addEventListener('click', onClick);
      p.addEventListener('change', onChange);
      doc.body.appendChild(p);
    }
    return p;
  }

  function docs() {
    const d = [document];
    try { if (win && !win.closed && win.document.body && win.location.origin === location.origin) d.push(win.document); } catch {}
    return d;
  }

  function render() {
    const h = html();
    const status = statusText();
    const wrapPct = phase === 'wrap' ? Math.max(0, (wrapEnd - Date.now()) / (S.wrapSec * 1000) * 100) : 0;
    for (const doc of docs()) {
      try {
        const p = panelIn(doc);
        p.classList.toggle('pd-min', minimized);
        // Struktur nur bei Aenderung neu setzen (sonst gehen Klicks verloren) und
        // nie, solange das Eingabefeld fokussiert ist
        const editing = doc.activeElement && p.contains(doc.activeElement) && doc.activeElement.tagName === 'INPUT';
        if (p._pdHtml !== h && !editing) { p.innerHTML = h; p._pdHtml = h; }
        const s = p.querySelector('.pd-s'); if (s && s.textContent !== status) s.textContent = status;
        const bar = p.querySelector('.pd-bar i'); if (bar) bar.style.width = wrapPct + '%';
      } catch {}
    }
  }

  function ensurePanels() {
    for (const doc of docs()) { try { if (!doc.getElementById(PANEL_ID)) render(); } catch {} }
    addRowButtons();
  }

  // Worker-Takt: laeuft auch, wenn dieser Tab im Hintergrund ist (keine Timer-Drosselung)
  const ticker = new Worker(URL.createObjectURL(new Blob(['setInterval(()=>postMessage(0),500)'], { type: 'text/javascript' })));
  ticker.onmessage = tick;

  window.addEventListener('beforeunload', e => { if (running) { e.preventDefault(); e.returnValue = ''; } });

  window.__pd = {
    show() { minimized = false; render(); },
    debug: () => ({ running, phase, cur, dial, call, msg, idx: S.idx, test: S.test, queue: S.queue })
  };
  // Startzeile per Link vorgeben: liste.html#ab=<AP-ID> (oder #ab=F<Firmen-ID>)
  const hashFrom = (location.hash.match(/[#&]ab=(F?\d+)/) || [])[1];
  if (hashFrom) {
    const tr = [...document.querySelectorAll(LIST_ROWS)].find(r => rowKey(r) === hashFrom);
    if (tr) {
      S.startFrom = hashFrom;
      S.startFromLabel = (tr.querySelector(FIRMA_LINK)?.innerText || tr.cells[1]?.innerText || '').trim();
      S.idx = 0; save();
    }
  }
  render();
  if (canBuildQueue()) buildQueue().then(render);
})();
