#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung: Webseite (PWA) - HTML, Design, Skript, Service Worker, Manifest.
.DESCRIPTION
    Get-HMRemoteWebFiles liefert alle Dateien fuer den Webserver (Pfad -> Typ + Bytes). Die Seite setzt Daten nur als
    Text ein (textContent), nie als HTML; Skript und Design kommen aus eigenen Dateien (strenge CSP ohne Inline-Code).
.NOTES
    Zielmaschine: der PC, auf dem HUMig laeuft. Wird in der Oberflaeche und im Webserver-Runspace geladen.
#>

$script:HMRemoteHtml = @'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#1e1e2e">
<meta name="color-scheme" content="dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="HUMig">
<meta name="referrer" content="no-referrer">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon-192.png">
<link rel="apple-touch-icon" href="/icon-192.png">
<link rel="stylesheet" href="/app.css">
<title>HUMig</title>
<script src="/app.js" defer></script>
</head>
<body>
<header class="top">
  <img class="logo" src="/icon-192.png" alt="">
  <div class="ttl"><div class="name">HUMig</div><div class="sub" id="pcName">Fernbedienung</div></div>
  <span class="dot" id="conn" title="Verbindung"></span>
</header>
<div class="banner hidden" id="banner"></div>

<main>
  <!-- Koppeln -->
  <section class="view hidden" id="vPair">
    <div class="card hero">
      <h1>Mit HUMig koppeln</h1>
      <p class="muted">Code aus HUMig eingeben (Knopf <b>Handy</b> in der Statusleiste). Das Handy bleibt gekoppelt, bis du es in HUMig entfernst.</p>
      <label class="lbl" for="pCode">Kopplungscode</label>
      <input id="pCode" class="code" inputmode="numeric" autocomplete="one-time-code" maxlength="7" placeholder="000000">
      <label class="lbl" for="pName">Name dieses Geraets</label>
      <input id="pName" class="txt" maxlength="40" placeholder="Handy">
      <button class="btn primary wide" id="pBtn">Koppeln</button>
      <p class="err hidden" id="pErr"></p>
    </div>
    <div class="card">
      <div class="row between"><h2>Zertifikat</h2><span class="pill" id="certState">wird geprueft ...</span></div>
      <p class="muted">Damit die Verbindung ohne Warnung laeuft und HUMig als App auf den Startbildschirm kann, einmal das Zertifikat dieses PCs installieren.</p>
      <a class="btn wide" href="/ca.cer" download="HUMig-CA.cer">Zertifikat laden</a>
      <details><summary>Android</summary><ol>
        <li><b>Zertifikat laden</b> antippen.</li>
        <li>Einstellungen &rsaquo; Sicherheit &rsaquo; (Weitere Einstellungen &rsaquo;) Verschluesselung &amp; Anmeldedaten &rsaquo; <b>Zertifikat installieren</b> &rsaquo; <b>CA-Zertifikat</b> &rsaquo; Datei <i>HUMig-CA.cer</i> waehlen (Pfad je nach Hersteller etwas anders).</li>
        <li>Diese Seite neu laden, dann im Browser-Menue <b>App installieren</b> bzw. <b>Zum Startbildschirm</b>.</li>
      </ol></details>
      <details><summary>iPhone / iPad</summary><ol>
        <li>In <b>Safari</b> &rsaquo; <b>Zertifikat laden</b> &rsaquo; <i>Zulassen</i>.</li>
        <li>Einstellungen &rsaquo; <b>Profil geladen</b> &rsaquo; <i>Installieren</i>.</li>
        <li>Einstellungen &rsaquo; Allgemein &rsaquo; Info &rsaquo; <b>Zertifikatsvertrauenseinstellungen</b> &rsaquo; <i>HUMig Fernbedienung CA</i> einschalten.</li>
        <li>Seite neu laden, dann <b>Teilen</b> &rsaquo; <b>Zum Home-Bildschirm</b>. In der App den Code noch einmal eingeben.</li>
      </ol></details>
      <p class="muted small">Sicherheit: Nach dem Installieren in den Zertifikatsdetails am Handy den <b>SHA-256-Fingerabdruck</b> mit dem im HUMig-Fenster <b>Handy</b> am PC vergleichen. Stimmt er nicht, das Zertifikat sofort wieder entfernen.</p>
    </div>
  </section>

  <!-- Status -->
  <section class="view hidden" id="vStatus">
    <div class="row between"><h1>Status</h1><button class="btn small" id="sRefresh">Aktualisieren</button></div>
    <p class="muted small" id="sTime"></p>
    <div id="sBody"></div>
  </section>

  <!-- Vorgang -->
  <section class="view hidden" id="vJob">
    <div class="card job">
      <div class="ring">
        <svg viewBox="0 0 120 120" aria-hidden="true">
          <circle class="track" cx="60" cy="60" r="52"></circle>
          <circle class="bar" id="jBar" cx="60" cy="60" r="52"></circle>
        </svg>
        <div class="pct" id="jPct">-</div>
      </div>
      <div class="jinfo">
        <div class="jtitle" id="jTitle">Kein Vorgang</div>
        <div class="muted" id="jStatus"></div>
        <div class="muted small" id="jTime"></div>
      </div>
    </div>
    <button class="btn danger wide hidden" id="jCancel">Abbrechen</button>
    <div class="card mon hidden" id="jMon">
      <div class="mt"><div><div class="ml">KOPIEREN (Lesen / Schreiben)</div><div class="mv" id="mIo">-</div><div class="ms" id="mIoS"></div></div>
        <svg class="spark" viewBox="0 0 120 36" preserveAspectRatio="none" aria-hidden="true"><polyline class="rd" id="pRd"></polyline><polyline class="wr" id="pWr"></polyline></svg></div>
      <div class="mt"><div><div class="ml">CPU</div><div class="mv" id="mCpu">-</div><div class="ms" id="mCpuS"></div></div>
        <svg class="spark" viewBox="0 0 120 36" preserveAspectRatio="none" aria-hidden="true"><polyline class="cpu" id="pCpu"></polyline></svg></div>
      <div class="mt"><div><div class="ml">ARBEITSSPEICHER</div><div class="mv" id="mRam">-</div><div class="ms" id="mRamS"></div></div>
        <svg class="spark" viewBox="0 0 120 36" preserveAspectRatio="none" aria-hidden="true"><polyline class="ram" id="pRam"></polyline></svg></div>
    </div>
    <div class="row between"><h2>Konsole</h2><label class="muted small"><input type="checkbox" id="jFollow" checked> mitlaufen</label></div>
    <div class="console" id="jCon"></div>
  </section>

  <!-- Mehr -->
  <section class="view hidden" id="vMore">
    <h1>Dieses Geraet</h1>
    <div class="card">
      <div class="kv"><span>Gekoppelt als</span><b id="mDev">-</b></div>
      <div class="kv"><span>PC</span><b id="mPc">-</b></div>
      <div class="kv"><span>HUMig</span><b id="mVer">-</b></div>
      <div class="kv"><span>Fernbedienung bis</span><b id="mUntil">-</b></div>
      <div class="kv"><span>Verbindung</span><b id="mCert">-</b></div>
    </div>
    <div class="card">
      <div class="kv"><span>Benachrichtigungen</span><b id="nState">-</b></div>
      <p class="muted small" id="nHint"></p>
      <button class="btn primary wide hidden" id="nBtn">Einschalten</button>
    </div>
    <a class="btn wide" href="/ca.cer" download="HUMig-CA.cer">Zertifikat erneut laden</a>
    <button class="btn danger wide" id="mUnpair">Dieses Handy entkoppeln</button>
    <p class="muted small">Ansehen und Abbrechen laufender Vorgaenge. Daten bleiben im lokalen Netz (Push-Meldungen kommen ohne Inhalt), HUMig muss am PC offen sein.</p>
  </section>
</main>

<nav class="tabs hidden" id="tabs">
  <button data-tab="vStatus" class="on"><span class="ico">&#9673;</span>Status</button>
  <button data-tab="vJob"><span class="ico">&#9654;</span>Vorgang<span class="badge hidden" id="tJob"></span></button>
  <button data-tab="vMore"><span class="ico">&#8942;</span>Mehr</button>
</nav>

<div class="modal hidden" id="modal">
  <div class="mbox">
    <h2 id="mTitle">Abbrechen?</h2>
    <p id="mText"></p>
    <div class="row end"><button class="btn" id="mNo">Nein</button><button class="btn danger" id="mYes">Ja, abbrechen</button></div>
  </div>
</div>
</body>
</html>
'@

$script:HMRemoteCss = @'
:root{--bg:#1e1e2e;--mantle:#181825;--crust:#11111b;--s0:#313244;--s1:#45475a;--s2:#585b70;--tx:#cdd6f4;--sub:#a6adc8;--ov:#6c7086;
--blue:#89b4fa;--green:#a6e3a1;--peach:#fab387;--red:#f38ba8;--yellow:#f9e2af;--mauve:#cba6f7;--teal:#94e2d5;
--r:16px;--safe-b:env(safe-area-inset-bottom,0px);--safe-t:env(safe-area-inset-top,0px)}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--tx);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
body{min-height:100vh;padding-bottom:calc(76px + var(--safe-b))}
h1{font-size:22px;margin:6px 0 10px}h2{font-size:16px;margin:4px 0 8px}
.hidden{display:none!important}.muted{color:var(--sub)}.small{font-size:13px}
.top{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;padding:calc(10px + var(--safe-t)) 16px 10px;
background:linear-gradient(180deg,var(--mantle),rgba(24,24,37,.92));backdrop-filter:blur(10px);border-bottom:1px solid var(--s0)}
.logo{width:38px;height:38px;border-radius:50%}
.ttl{flex:1;min-width:0}.name{font-weight:700;letter-spacing:.3px}.sub{color:var(--sub);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:12px;height:12px;border-radius:50%;background:var(--ov);box-shadow:0 0 0 3px rgba(108,112,134,.25);transition:background .3s}
.dot.ok{background:var(--green);box-shadow:0 0 0 3px rgba(166,227,161,.25)}.dot.bad{background:var(--red);box-shadow:0 0 0 3px rgba(243,139,168,.25)}
.banner{margin:10px 16px 0;padding:10px 14px;border-radius:12px;background:rgba(243,139,168,.15);border:1px solid rgba(243,139,168,.4);color:var(--red);font-size:14px}
main{padding:8px 16px}
.view{animation:fade .25s ease}@keyframes fade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.card{background:var(--mantle);border:1px solid var(--s0);border-radius:var(--r);padding:14px 16px;margin:12px 0;box-shadow:0 6px 18px rgba(0,0,0,.25)}
.hero{background:radial-gradient(120% 140% at 0% 0%,rgba(137,180,250,.18),transparent 55%),var(--mantle)}
.row{display:flex;align-items:center;gap:10px}.between{justify-content:space-between}.end{justify-content:flex-end}
.lbl{display:block;font-size:13px;color:var(--sub);margin:12px 0 6px}
input.txt,input.code{width:100%;padding:12px 14px;border-radius:12px;border:1px solid var(--s1);background:var(--crust);color:var(--tx);font-size:17px;outline:none}
input.code{font-size:28px;letter-spacing:10px;text-align:center;font-variant-numeric:tabular-nums}
input:focus{border-color:var(--blue);box-shadow:0 0 0 3px rgba(137,180,250,.25)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;padding:11px 16px;border-radius:12px;border:1px solid var(--s1);
background:var(--s0);color:var(--tx);font-size:15px;font-weight:600;text-decoration:none;cursor:pointer;transition:transform .08s,filter .2s}
.btn:active{transform:scale(.97)}.btn.small{padding:7px 12px;font-size:13px}.btn.wide{width:100%;margin-top:12px}
.btn.primary{background:linear-gradient(135deg,var(--blue),var(--mauve));color:var(--crust);border:0}
.btn.danger{background:rgba(243,139,168,.15);border-color:rgba(243,139,168,.5);color:var(--red)}
.btn[disabled]{opacity:.5}
.err{color:var(--red);margin:10px 0 0}
.pill{font-size:12px;padding:4px 10px;border-radius:99px;background:var(--s0);color:var(--sub)}
.pill.ok{background:rgba(166,227,161,.15);color:var(--green)}.pill.warn{background:rgba(250,179,135,.15);color:var(--peach)}
details{margin-top:12px;border-top:1px solid var(--s0);padding-top:8px}summary{cursor:pointer;font-weight:600;padding:6px 0}
ol{margin:6px 0 4px 18px;padding:0;color:var(--sub)}li{margin:6px 0}
.sec{margin:18px 0 6px;font-size:12px;letter-spacing:1.2px;color:var(--ov);font-weight:700;text-transform:uppercase}
.item{display:flex;gap:12px;align-items:flex-start;background:var(--mantle);border:1px solid var(--s0);border-radius:14px;padding:12px 14px;margin:8px 0}
.lv{flex:none;width:10px;height:10px;border-radius:50%;margin-top:7px;background:var(--ov)}
.lv.OK{background:var(--green)}.lv.Warning{background:var(--peach)}.lv.Error{background:var(--red)}.lv.Info{background:var(--blue)}
.item .t{font-weight:600}.item .s{color:var(--sub);font-size:13px;margin-top:2px;word-break:break-word}
.item.Error{border-color:rgba(243,139,168,.45);background:linear-gradient(90deg,rgba(243,139,168,.10),var(--mantle) 40%)}
.item.Warning{border-color:rgba(250,179,135,.35)}
.empty{color:var(--ov);font-size:14px;padding:6px 2px}
.job{display:flex;align-items:center;gap:18px}
.ring{position:relative;width:118px;height:118px;flex:none}.ring svg{width:100%;height:100%;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:10}.ring .track{stroke:var(--s0)}
.ring .bar{stroke:var(--green);stroke-linecap:round;stroke-dasharray:326.7;stroke-dashoffset:326.7;transition:stroke-dashoffset .6s ease}

.pct{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:24px;font-weight:700;font-variant-numeric:tabular-nums}
.mt{display:flex;align-items:center;gap:12px;padding:8px 0;border-bottom:1px solid var(--s0)}.mt:last-child{border:0}
.mt>div{flex:1;min-width:0}.ml{font-size:11px;font-weight:600;color:var(--sub);letter-spacing:.03em}
.mv{font-size:17px;font-weight:700;font-variant-numeric:tabular-nums;word-break:break-word}.ms{font-size:12px;color:var(--ov);word-break:break-word}
.spark{flex:none;width:120px;height:36px;background:var(--crust);border-radius:6px}.spark polyline{fill:none;stroke-width:1.5;vector-effect:non-scaling-stroke}
.spark .wr{stroke:var(--blue)}.spark .rd{stroke:var(--ov)}.spark .cpu{stroke:var(--green)}.spark .ram{stroke:var(--mauve)}
.jinfo{min-width:0}.jtitle{font-size:18px;font-weight:700;word-break:break-word}
.console{background:var(--crust);border:1px solid var(--s0);border-radius:14px;padding:10px 12px;height:46vh;overflow:auto;
font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word}
.console .ln{color:var(--tx)}.console .z{color:var(--ov);margin-right:6px}
.console .Success{color:var(--green)}.console .Warning{color:var(--peach)}.console .Error{color:var(--red)}.console .Debug{color:var(--ov)}.console .Header{color:var(--blue);font-weight:700}
.kv{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid var(--s0)}.kv:last-child{border:0}.kv span{color:var(--sub)}
.kv b{text-align:right;word-break:break-word}
.tabs{position:fixed;left:0;right:0;bottom:0;z-index:6;display:flex;padding:6px 8px calc(6px + var(--safe-b));
background:rgba(17,17,27,.92);backdrop-filter:blur(12px);border-top:1px solid var(--s0)}
.tabs button{flex:1;position:relative;display:flex;flex-direction:column;align-items:center;gap:2px;padding:8px 0;border:0;background:none;color:var(--ov);font-size:12px;font-weight:600;border-radius:12px}
.tabs button .ico{font-size:20px;line-height:1}.tabs button.on{color:var(--blue);background:rgba(137,180,250,.10)}
.badge{position:absolute;top:4px;right:calc(50% - 26px);min-width:9px;height:9px;border-radius:9px;background:var(--green);animation:pulse 1.4s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(166,227,161,.6)}70%{box-shadow:0 0 0 8px rgba(166,227,161,0)}100%{box-shadow:0 0 0 0 rgba(166,227,161,0)}}
.modal{position:fixed;inset:0;z-index:10;background:rgba(17,17,27,.7);backdrop-filter:blur(4px);display:flex;align-items:flex-end;justify-content:center;padding:16px}
.mbox{width:100%;max-width:440px;background:var(--mantle);border:1px solid var(--s1);border-radius:20px;padding:18px;margin-bottom:var(--safe-b);animation:up .2s ease}
@keyframes up{from{transform:translateY(30px);opacity:0}to{transform:none;opacity:1}}
.mbox .row{margin-top:14px}.mbox .btn{flex:1}
@media (min-width:700px){main{max-width:720px;margin:0 auto}}
'@

$script:HMRemoteJs = @'
'use strict';
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var S = { token: null, seq: 0, tab: 'vStatus', timer: null, busy: false, running: false, follow: true, lastOk: 0, secure: null, info: {} };
  try { S.token = localStorage.getItem('hm_token'); } catch (e) { S.token = null; }

  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) { e.className = cls; } if (text !== undefined && text !== null) { e.textContent = String(text); } return e; }
  function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }
  function show(id, on) { $(id).classList.toggle('hidden', !on); }
  function banner(t) { var b = $('banner'); if (t) { b.textContent = t; b.classList.remove('hidden'); } else { b.classList.add('hidden'); } }
  function setConn(ok) { var d = $('conn'); d.classList.toggle('ok', ok === true); d.classList.toggle('bad', ok === false); }
  function lvl(l) { return ({ OK: 'OK', Warning: 'Warning', Error: 'Error', Info: 'Info' })[l] || 'Grey'; }
  function guessName() { var u = navigator.userAgent || ''; if (/iPhone/.test(u)) { return 'iPhone'; } if (/iPad/.test(u)) { return 'iPad'; } if (/Android/.test(u)) { return 'Android-Handy'; } return 'Handy'; }
  function fmtDur(s) { s = Math.max(0, s | 0); var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60; return (h ? h + ':' + String(m).padStart(2, '0') : String(m)) + ':' + String(x).padStart(2, '0'); }

  function api(method, path, body) {
    var o = { method: method, headers: {}, cache: 'no-store', credentials: 'omit' };
    if (S.token) { o.headers.Authorization = 'Bearer ' + S.token; }
    if (body !== undefined) { o.headers['Content-Type'] = 'application/json'; o.body = JSON.stringify(body); }
    return fetch(path, o).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) { j.__status = r.status; return j; });
    });
  }

  // --- Ansicht
  function setView(v) {
    ['vPair', 'vStatus', 'vJob', 'vMore'].forEach(function (x) { show(x, x === v); });
    show('tabs', v !== 'vPair');
    S.tab = v;
    Array.prototype.forEach.call(document.querySelectorAll('.tabs button'), function (b) { b.classList.toggle('on', b.getAttribute('data-tab') === v); });
    if (v === 'vJob' && S.follow) { var c = $('jCon'); c.scrollTop = c.scrollHeight; }
    if (v === 'vMore') { pushState(); }
    schedule(50);
  }
  function needPair(msg) {
    S.token = null; try { localStorage.removeItem('hm_token'); } catch (e) { }
    kv('readwrite', function (st) { st.clear(); }).catch(function () { });
    pushSub().then(function (s) { if (s) { s.unsubscribe(); } }).catch(function () { });
    clearTimeout(S.timer);
    setView('vPair');
    if (msg) { $('pErr').textContent = msg; show('pErr', true); }
  }

  // --- Koppeln
  function pair() {
    var code = ($('pCode').value || '').replace(/\D/g, '');
    if (code.length !== 6) { $('pErr').textContent = 'Bitte den 6-stelligen Code aus HUMig eingeben.'; show('pErr', true); return; }
    $('pBtn').disabled = true; show('pErr', false);
    api('POST', '/api/pair', { code: code, name: ($('pName').value || '').trim() || guessName() }).then(function (j) {
      $('pBtn').disabled = false;
      if (j.ok && j.token) {
        S.token = j.token; try { localStorage.setItem('hm_token', j.token); } catch (e) { }
        $('pCode').value = ''; S.seq = 0; clear($('jCon'));
        setView('vStatus'); poll();
      } else { $('pErr').textContent = j.error || 'Kopplung fehlgeschlagen.'; show('pErr', true); }
    }).catch(function () { $('pBtn').disabled = false; $('pErr').textContent = 'HUMig nicht erreichbar.'; show('pErr', true); });
  }

  // --- Daten holen
  function schedule(ms) {
    clearTimeout(S.timer);
    if (!S.token || document.hidden) { return; }
    S.timer = setTimeout(poll, ms);
  }
  function poll() {
    if (!S.token || S.busy) { return; }
    S.busy = true;
    api('GET', '/api/state?since=' + S.seq).then(function (j) {
      S.busy = false;
      if (j.__status === 401) { needPair('Dieses Handy ist nicht (mehr) gekoppelt - Code aus HUMig eingeben.'); return; }
      if (!j.ok) { setConn(false); banner(j.error || 'Fehler beim Lesen'); schedule(10000); return; }
      setConn(true); banner(''); S.lastOk = Date.now();
      render(j);
      schedule(S.running || S.tab === 'vJob' ? 1500 : 15000);
    }).catch(function () {
      S.busy = false; setConn(false);
      banner('Keine Verbindung zu HUMig - ist HUMig am PC offen und die Fernbedienung aktiv?');
      schedule(8000);
    });
  }

  // --- Anzeige
  function render(j) {
    S.info = j;
    $('pcName').textContent = (j.pc || '') + (j.version ? '  ·  v' + j.version : '');
    document.title = 'HUMig - ' + (j.pc || '');
    $('mDev').textContent = j.device || '-'; $('mPc').textContent = j.pc || '-'; $('mVer').textContent = j.version || '-';
    $('mUntil').textContent = j.until ? j.until + ' Uhr' : 'solange HUMig laeuft';
    renderStatus(j.status);
    renderJob(j.job || {});
    var lines = j.lines || [];
    if (lines.length) {
      var c = $('jCon'), atEnd = c.scrollTop + c.clientHeight >= c.scrollHeight - 30;
      lines.forEach(function (l) {
        var d = el('div', 'ln ' + (l.l || ''));
        d.appendChild(el('span', 'z', l.z || '')); d.appendChild(document.createTextNode(l.t || ''));
        c.appendChild(d);
      });
      while (c.childNodes.length > 400) { c.removeChild(c.firstChild); }
      if (S.follow && (atEnd || S.tab !== 'vJob')) { c.scrollTop = c.scrollHeight; }
    }
    if (typeof j.seq === 'number') { S.seq = j.seq; }
  }
  function item(level, title, sub) {
    var d = el('div', 'item ' + lvl(level));
    d.appendChild(el('span', 'lv ' + lvl(level)));
    var b = el('div'); b.appendChild(el('div', 't', title)); if (sub) { b.appendChild(el('div', 's', sub)); }
    d.appendChild(b); return d;
  }
  function sec(body, title) { body.appendChild(el('div', 'sec', title)); }
  function renderStatus(st) {
    var body = $('sBody'); clear(body);
    if (!st) { body.appendChild(el('p', 'empty', 'Noch keine Daten - Aktualisieren tippen.')); return; }
    $('sTime').textContent = st.time ? 'Stand ' + st.time : '';
    sec(body, 'Wichtig');
    if ((st.warnings || []).length) { st.warnings.forEach(function (w) { body.appendChild(item(w.level, w.text, w.area)); }); }
    else { body.appendChild(item('OK', 'Alles in Ordnung', 'keine offenen Hinweise')); }
    sec(body, 'Backup-Zeitplaene');
    if ((st.schedules || []).length) {
      st.schedules.forEach(function (s) {
        var sub = [s.when, s.last ? 'zuletzt ' + s.last + ' ' + (s.result || '') : 'noch nie gelaufen', (s.age !== null && s.age !== undefined) ? 'Erfolg vor ' + s.age + ' Tag(en)' : '', s.next ? 'naechster ' + s.next : '', s.note].filter(Boolean).join(' · ');
        body.appendChild(item(s.level, s.name, sub));
      });
    } else { body.appendChild(el('p', 'empty', 'Kein Zeitplan angelegt')); }
    if ((st.server || []).length) {
      sec(body, 'Server-Backup');
      st.server.forEach(function (s) {
        var dk = (s.disks || []).map(function (d) { return d.label + (d.archive ? '' : ': ' + (d.age === null || d.age === undefined ? 'nie' : (d.age <= 0 ? 'heute' : 'vor ' + d.age + ' T.'))) + (d.health === 'Error' ? ' (defekt?)' : d.health === 'Warning' ? ' (pruefen)' : ''); }).join(', ');
        var sub = [s.lastOk ? 'zuletzt erfolgreich ' + s.lastOk + (s.lastDisk ? ' auf ' + s.lastDisk : '') : 'noch keine erfolgreiche Sicherung', dk, s.archiveDue ? 'Archiv faellig' : ''].filter(Boolean).join(' · ');
        body.appendChild(item(s.level, s.name, sub));
      });
    }
    sec(body, 'Letzte Backups');
    if ((st.backups || []).length) {
      st.backups.forEach(function (b) {
        var lv = b.level; if (lv === 'OK' && b.age > 30) { lv = 'Grey'; }
        var sub = [b.date ? b.date + (b.age !== null && b.age !== undefined ? ' (vor ' + b.age + ' T.)' : '') : '', b.status, b.mass ? 'MASSENLOESCHUNG' : ''].filter(Boolean).join(' · ');
        body.appendChild(item(lv, b.pc + ' \\ ' + b.user, sub));
      });
      if (st.backupsMore) { body.appendChild(el('p', 'empty', '... und ' + st.backupsMore + ' weitere')); }
    } else { body.appendChild(el('p', 'empty', 'Keine Backups im Backup-Ordner')); }
    if ((st.apps || []).length) {
      sec(body, 'App-Updates (7 Tage)');
      st.apps.forEach(function (a) { body.appendChild(item(a.level, a.pc, a.ok + ' aktualisiert' + (a.failed ? ', ' + a.failed + ' Fehler: ' + (a.failedNames || []).join(', ') : ''))); });
    }
  }
  function renderJob(job) {
    S.running = !!job.running;
    show('tJob', S.running);
    var ring = document.querySelector('.ring');
    ring.classList.toggle('run', S.running);
    var p = S.running ? Math.max(0, Math.min(100, job.progress | 0)) : 0;
    $('jBar').style.strokeDashoffset = String(326.7 * (1 - p / 100));
    $('jPct').textContent = S.running ? p + '%' : '-';
    if (S.running) {
      $('jTitle').textContent = job.title || 'Vorgang laeuft';
      $('jStatus').textContent = job.cancel ? 'Abbruch angefordert ...' : (job.status || '');
      $('jTime').textContent = 'laeuft seit ' + fmtDur(job.elapsed);
    } else {
      $('jTitle').textContent = 'Kein Vorgang';
      $('jStatus').textContent = job.lastTitle ? 'zuletzt: ' + job.lastTitle + (job.lastResult ? ' - ' + job.lastResult : '') : '';
      $('jTime').textContent = job.lastTime || '';
    }
    show('jCancel', S.running && !job.cancel);
    renderMon(job.mon);
  }
  // Live-Anzeige wie am PC: Durchsatz, CPU, RAM mit Verlauf (letzte 60 s)
  function nums(a) { return Array.isArray(a) ? a.slice(-60).map(function (v) { v = Number(v); return isFinite(v) && v > 0 ? v : 0; }) : []; }
  function spark(id, a, max) {
    var n = a.length, pts = [];
    if (!(max > 0)) { max = 1; }
    for (var i = 0; i < n; i++) { pts.push((120 - (n - 1 - i) * 120 / 59).toFixed(1) + ',' + (35 - Math.min(1, a[i] / max) * 34).toFixed(1)); }
    $(id).setAttribute('points', pts.join(' '));
  }
  function renderMon(m) {
    var on = !!(m && typeof m === 'object');
    show('jMon', on);
    if (!on) { return; }
    $('mIo').textContent = m.io || '-'; $('mIoS').textContent = m.ioSub || '';
    $('mCpu').textContent = m.cpu || '-'; $('mCpuS').textContent = m.cpuSub || '';
    $('mRam').textContent = m.ram || '-'; $('mRamS').textContent = m.ramSub || '';
    var wr = nums(m.wr), rd = nums(m.rd), mx = Math.max.apply(null, [1].concat(wr, rd));
    spark('pWr', wr, mx); spark('pRd', rd, mx);
    spark('pCpu', nums(m.cpuH), 100); spark('pRam', nums(m.ramH), 100);
  }

  // --- Push-Meldungen (ohne Inhalt): Service Worker zeigt die Meldung und holt die Details selbst vom PC
  function pushOk() { return ('serviceWorker' in navigator) && ('PushManager' in window) && ('Notification' in window) && S.secure === true; }
  function kv(mode, fn) {
    return new Promise(function (res, rej) {
      if (!window.indexedDB) { rej(new Error('kein IndexedDB')); return; }
      var o = indexedDB.open('humig', 1);
      o.onupgradeneeded = function () { o.result.createObjectStore('kv'); };
      o.onerror = function () { rej(o.error); };
      o.onsuccess = function () {
        var db = o.result, tx = db.transaction('kv', mode), r = fn(tx.objectStore('kv'));
        tx.oncomplete = function () { db.close(); res(r ? r.result : undefined); };
        tx.onerror = function () { db.close(); rej(tx.error); };
      };
    });
  }
  function pushSub() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) { return Promise.resolve(null); }
    return navigator.serviceWorker.getRegistration('/').then(function (r) { return r ? r.pushManager.getSubscription() : null; });
  }
  function b64u(s) {
    s = String(s || '').replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) { s += '='; }
    var b = atob(s), a = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) { a[i] = b.charCodeAt(i); } return a;
  }
  // Abo passt zum Schluessel dieses PCs? (neuer Schluessel am PC -> neu einschalten)
  function sameKey(s, key) {
    try {
      var k = s.options && s.options.applicationServerKey; if (!k) { return true; }
      var a = new Uint8Array(k), b = b64u(key); if (a.length !== b.length) { return false; }
      for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
      return true;
    } catch (e) { return true; }
  }
  function pushUi(state, hint, btn) {
    $('nState').textContent = state; $('nHint').textContent = hint || '';
    show('nBtn', !!btn); if (btn) { $('nBtn').textContent = btn; $('nBtn').disabled = false; }
  }
  function pushState() {
    if (!S.token) { return; }
    if (!pushOk()) {
      var ios = /iPhone|iPad/.test(navigator.userAgent || '');
      pushUi('nicht moeglich', S.secure !== true ? 'Erst das Zertifikat installieren (App-Modus), dann geht es.' :
        (ios ? 'iPhone/iPad: HUMig ueber Teilen > "Zum Home-Bildschirm" hinzufuegen und von dort oeffnen (ab iOS 16.4).' : 'Dieser Browser kann keine Push-Meldungen.'), '');
      return;
    }
    api('GET', '/api/push').then(function (j) {
      S.pushKey = j.key || '';
      if (!j.ok || !S.pushKey) { pushUi('nicht verfuegbar', 'Am PC nicht verfuegbar.', ''); return; }
      if (Notification.permission === 'denied') { pushUi('blockiert', 'In den Website-Einstellungen des Browsers Benachrichtigungen fuer diese Adresse erlauben.', ''); return; }
      pushSub().then(function (s) {
        S.pushOn = !!(j.on && s && sameKey(s, S.pushKey));
        if (S.pushOn) { kv('readwrite', function (st) { st.put(S.token, 'tok'); st.put(S.info.pc || '', 'pc'); }).catch(function () { }); }
        if (S.pushOn) { pushUi('an', 'Meldung, wenn ein laengerer Vorgang am PC endet - auch wenn die App zu ist. Inhalt kommt nur im selben Netz direkt vom PC.', 'Ausschalten'); }
        else { pushUi('aus', 'Meldung aufs Handy, wenn ein laengerer Vorgang am PC endet. Laeuft ueber den Push-Dienst des Browsers (ohne Inhalt).', 'Einschalten'); }
      });
    }).catch(function () { pushUi('-', 'HUMig nicht erreichbar.', ''); });
  }
  function pushToggle() {
    $('nBtn').disabled = true;
    if (S.pushOn) {
      pushSub().then(function (s) { return s ? s.unsubscribe() : true; }).catch(function () { })
        .then(function () { return api('POST', '/api/push/off', {}); })
        .then(function () { return kv('readwrite', function (st) { st.clear(); }).catch(function () { }); })
        .then(pushState, pushState);
      return;
    }
    Notification.requestPermission().then(function (p) {
      if (p !== 'granted') { pushState(); return; }
      return navigator.serviceWorker.ready.then(function (reg) {
        var opt = { userVisibleOnly: true, applicationServerKey: b64u(S.pushKey) };
        return reg.pushManager.getSubscription().then(function (o) { return (o && !sameKey(o, S.pushKey)) ? o.unsubscribe() : true; })
          .then(function () { return reg.pushManager.subscribe(opt); }).catch(function () {
          // altes Abo mit anderem Schluessel (z. B. anderer PC/Konto): abmelden und neu
          return reg.pushManager.getSubscription().then(function (o) { return o ? o.unsubscribe() : true; }).then(function () { return reg.pushManager.subscribe(opt); });
        });
      }).then(function (sub) {
        return kv('readwrite', function (st) { st.put(S.token, 'tok'); st.put(S.info.pc || '', 'pc'); }).catch(function () { })
          .then(function () { return api('POST', '/api/push', { endpoint: sub.endpoint }); });
      }).then(function (j) {
        if (j && !j.ok) { banner(j.error || 'Einschalten nicht moeglich'); }
        pushState();
      });
    }).catch(function () { banner('Benachrichtigungen konnten nicht eingeschaltet werden'); pushState(); });
  }

  // --- Aktionen
  function ask(title, text) {
    return new Promise(function (res) {
      $('mTitle').textContent = title; $('mText').textContent = text; show('modal', true);
      var done = function (v) { show('modal', false); $('mYes').onclick = null; $('mNo').onclick = null; res(v); };
      $('mYes').onclick = function () { done(true); }; $('mNo').onclick = function () { done(false); };
    });
  }
  function cancelJob() {
    var t = (S.info.job && S.info.job.title) || 'den laufenden Vorgang';
    ask('Abbrechen?', '"' + t + '" am PC ' + (S.info.pc || '') + ' abbrechen? Bereits kopierte Daten bleiben erhalten.').then(function (ok) {
      if (!ok) { return; }
      $('jCancel').disabled = true;
      api('POST', '/api/cancel', { confirm: true }).then(function (j) {
        $('jCancel').disabled = false;
        if (j.__status === 401) { needPair('Nicht mehr gekoppelt.'); return; }
        if (!j.ok) { banner(j.error || 'Abbrechen nicht moeglich'); }
        schedule(300);
      }).catch(function () { $('jCancel').disabled = false; banner('HUMig nicht erreichbar'); });
    });
  }
  function refresh() {
    $('sRefresh').disabled = true;
    api('POST', '/api/refresh', {}).then(function () { setTimeout(function () { $('sRefresh').disabled = false; poll(); }, 2500); })
      .catch(function () { $('sRefresh').disabled = false; });
  }
  function unpair() {
    ask('Entkoppeln?', 'Dieses Handy von HUMig entkoppeln? Danach ist wieder ein Code aus HUMig noetig.').then(function (ok) {
      if (!ok) { return; }
      api('POST', '/api/unpair', {}).then(function () { needPair(''); }).catch(function () { needPair(''); });
    });
  }

  // --- Zertifikat / App: Service Worker nur mit vertrauenswuerdigem Zertifikat
  function certState(ok) {
    S.secure = ok;
    var p = $('certState');
    p.textContent = ok ? 'vertrauenswuerdig' : 'noch nicht installiert';
    p.className = 'pill ' + (ok ? 'ok' : 'warn');
    $('mCert').textContent = ok ? 'verschluesselt, Zertifikat vertraut' : 'verschluesselt, Zertifikat nicht installiert';
  }
  function initSw() {
    if (!('serviceWorker' in navigator) || !window.isSecureContext) { certState(false); return; }
    navigator.serviceWorker.register('/sw.js', { scope: '/' }).then(function () { certState(true); }).catch(function () { certState(false); });
  }

  // --- Start
  document.addEventListener('DOMContentLoaded', function () {
    $('pName').value = guessName();
    var m = /[#&]c=(\d{6})/.exec(location.hash || '');
    if (m) { $('pCode').value = m[1]; try { history.replaceState(null, '', location.pathname); } catch (e) { } }
    $('pBtn').addEventListener('click', pair);
    $('pCode').addEventListener('keydown', function (e) { if (e.key === 'Enter') { pair(); } });
    $('sRefresh').addEventListener('click', refresh);
    $('jCancel').addEventListener('click', cancelJob);
    $('mUnpair').addEventListener('click', unpair);
    $('nBtn').addEventListener('click', pushToggle);
    $('jFollow').addEventListener('change', function () { S.follow = $('jFollow').checked; });
    Array.prototype.forEach.call(document.querySelectorAll('.tabs button'), function (b) { b.addEventListener('click', function () { setView(b.getAttribute('data-tab')); }); });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) { schedule(50); } else { clearTimeout(S.timer); } });
    initSw();
    if (S.token) { setView('vStatus'); poll(); } else { setView('vPair'); }
  });
})();
'@

$script:HMRemoteSw = @'
'use strict';
var CACHE = 'humig-{{VERSION}}';
var SHELL = ['/', '/app.js', '/app.css', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
// Push ohne Inhalt: Stand beim PC nachfragen (nur im selben Netz erreichbar), sonst allgemeine Meldung
function kvGet(k) {
  return new Promise(function (res) {
    try {
      var o = indexedDB.open('humig', 1);
      o.onupgradeneeded = function () { o.result.createObjectStore('kv'); };
      o.onerror = function () { res(''); };
      o.onsuccess = function () {
        var db = o.result, r;
        try { r = db.transaction('kv', 'readonly').objectStore('kv').get(k); } catch (x) { db.close(); res(''); return; }
        r.onsuccess = function () { db.close(); res(r.result || ''); };
        r.onerror = function () { db.close(); res(''); };
      };
    } catch (x) { res(''); }
  });
}
self.addEventListener('push', function (e) {
  var pc = '';
  var shown = Promise.all([kvGet('tok'), kvGet('pc')]).then(function (v) {
    pc = v[1] || '';
    if (!v[0]) { throw new Error('kein Token'); }
    var ctl = ('AbortController' in self) ? new AbortController() : null;
    var t = setTimeout(function () { if (ctl) { ctl.abort(); } }, 6000);
    return fetch('/api/state?since=2147483647', { headers: { Authorization: 'Bearer ' + v[0] }, cache: 'no-store', credentials: 'omit', signal: ctl ? ctl.signal : undefined })
      .then(function (r) { clearTimeout(t); return r.json(); });
  }).then(function (j) {
    var job = (j && j.job) || {};
    var body = job.running ? (String(job.title || 'Vorgang') + ' laeuft') : (job.lastTitle ? String(job.lastTitle) + ' - ' + String(job.lastResult || 'fertig') : 'Vorgang beendet');
    return self.registration.showNotification('HUMig ' + String((j && j.pc) || pc), { body: body, icon: '/icon-192.png', tag: 'humig-job', renotify: true });
  }).catch(function () {
    return self.registration.showNotification('HUMig ' + pc, { body: 'Vorgang am PC beendet - Details in der App (im selben Netz wie der PC)', icon: '/icon-192.png', tag: 'humig-job', renotify: true });
  });
  e.waitUntil(shown);
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cs) {
    for (var i = 0; i < cs.length; i++) { if ('focus' in cs[i]) { return cs[i].focus(); } }
    return self.clients.openWindow('/');
  }));
});
self.addEventListener('fetch', function (e) {
  var u = new URL(e.request.url);
  // Daten nie zwischenspeichern; nur die Seitenhuelle (zuerst Netz, offline aus dem Speicher)
  if (u.origin !== location.origin || u.pathname.indexOf('/api/') === 0 || u.pathname === '/ca.cer' || e.request.method !== 'GET') { return; }
  e.respondWith(fetch(e.request).then(function (r) {
    if (r && r.ok && SHELL.indexOf(u.pathname) >= 0) { var cp = r.clone(); caches.open(CACHE).then(function (c) { c.put(e.request, cp); }); }
    return r;
  }).catch(function () { return caches.match(e.request).then(function (m) { return m || caches.match('/'); }); }));
});
'@

# Alle Dateien der Webseite. Icons: PNG-Bytes (192/512), Ca: CA-Zertifikat (DER) oder leer
function Get-HMRemoteWebFiles {
    param([string]$Version = '', [string]$Pc = '', [byte[]]$Icon192 = $null, [byte[]]$Icon512 = $null, [byte[]]$Ca = $null)
    $u8 = New-Object System.Text.UTF8Encoding $false
    $man = [ordered]@{
        name = "HUMig $Pc".Trim(); short_name = 'HUMig'; description = 'HUMig Fernbedienung'; id = '/'; start_url = '/'; scope = '/'
        display = 'standalone'; orientation = 'portrait'; background_color = '#1e1e2e'; theme_color = '#1e1e2e'; lang = 'de'
        icons = @(
            [ordered]@{ src = '/icon-192.png'; sizes = '192x192'; type = 'image/png'; purpose = 'any' }
            [ordered]@{ src = '/icon-512.png'; sizes = '512x512'; type = 'image/png'; purpose = 'any' }
            [ordered]@{ src = '/icon-512.png'; sizes = '512x512'; type = 'image/png'; purpose = 'maskable' }
        )
    }
    $f = @{
        '/index.html'           = @{ Type = 'text/html; charset=utf-8'; Bytes = $u8.GetBytes($script:HMRemoteHtml) }
        '/app.css'              = @{ Type = 'text/css; charset=utf-8'; Bytes = $u8.GetBytes($script:HMRemoteCss) }
        '/app.js'               = @{ Type = 'application/javascript; charset=utf-8'; Bytes = $u8.GetBytes($script:HMRemoteJs) }
        '/sw.js'                = @{ Type = 'application/javascript; charset=utf-8'; Bytes = $u8.GetBytes(($script:HMRemoteSw -replace '\{\{VERSION\}\}', ($Version -replace '[^0-9A-Za-z.\-]', ''))); NoStore = $true }
        '/manifest.webmanifest' = @{ Type = 'application/manifest+json; charset=utf-8'; Bytes = $u8.GetBytes((ConvertTo-Json -InputObject $man -Depth 4)) }
    }
    if ($Icon192) { $f['/icon-192.png'] = @{ Type = 'image/png'; Bytes = $Icon192 } }
    if ($Icon512) { $f['/icon-512.png'] = @{ Type = 'image/png'; Bytes = $Icon512 } }
    if ($Ca) { $f['/ca.cer'] = @{ Type = 'application/x-x509-ca-cert'; Bytes = $Ca; NoStore = $true; Disposition = 'attachment; filename="HUMig-CA.cer"' } }
    return $f
}
