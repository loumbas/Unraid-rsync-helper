/* rclone-jobs v{{VERSION}} - WebUI glue (jQuery provided by the Unraid webgui) */
'use strict';

/* ==========================================================================
   1. Core AJAX & State Helpers
   ========================================================================== */

/**
 * Execute an AJAX POST request to the plugin backend (ajax.php).
 * Automatically injects the Unraid CSRF token and standardizes error responses.
 */
function rjPost(data, cb) {
  data.csrf_token = (typeof rj_csrf !== 'undefined') ? rj_csrf : '';
  $.post('/plugins/rclone-jobs/ajax.php', data)
    .done(function (res) { cb(res); })
    .fail(function (x) { cb({ ok: false, error: 'ajax failed: ' + (x.status || '?') + ' ' + (x.responseText || '').substring(0, 200) }); });
}

/**
 * Update and display a pre-formatted feedback panel (e.g. #rj-result, #rj-preview).
 */
function rjPanel(id, text, isError) {
  var p = $('#' + id);
  p.find('pre').text(text).css('color', isError ? '#e6867e' : '');
  p.show();
}

/**
 * Retrieve and parse the server-embedded configuration and status state from #rj-data.
 * Provides resilient fallbacks for jobs, quiet hours, and retention policies.
 */
function rjData() {
  /* never let a malformed/missing state blob kill the ready handler */
  var d = null;
  try { d = JSON.parse($('#rj-data').text()); } catch (e) { d = null; }
  if (!d || typeof d !== 'object') d = {};
  if (!d.jobs || typeof d.jobs !== 'object') d.jobs = {};
  if (!d.quiet || typeof d.quiet !== 'object') d.quiet = { start: '23:00', end: '07:00' };
  if (!d.retention || typeof d.retention !== 'object') d.retention = {};
  var rdefs = { rawHours: 24, rawMax: 500, hourDays: 7, days: 90, logDays: 3, failDays: 14, logMax: 300 };
  Object.keys(rdefs).forEach(function (k) {
    if (typeof d.retention[k] !== 'number' || d.retention[k] <= 0) d.retention[k] = rdefs[k];
  });
  if (d.master === undefined) d.master = 'yes';
  return d;
}

/* ==========================================================================
   2. Dynamic Theme & Luminance Resolution
   ==========================================================================
   Solid panel background for self-built dialogs and modals. The webGui --background
   variable is unreliable: it can carry alpha (page bleeds through the modal)
   or be 'transparent'/unset. A probe element makes the browser resolve and
   normalize var() to rgb()/rgba(); alpha is then flattened to a solid color
   (over white for light themes, black for dark). Never returns a transparent
   value. */
function rjRgb(s) {
  var m = /rgba?\(([^)]+)\)/.exec(String(s));
  if (!m) return null;
  var p = m[1].split(/[\s,\/]+/).filter(function (x) { return x !== ''; }).map(parseFloat);
  if (p.length < 3 || isNaN(p[0]) || isNaN(p[1]) || isNaN(p[2])) return null;
  var a = p.length > 3 && !isNaN(p[3]) ? p[3] : 1;
  return [p[0], p[1], p[2], a < 0 ? 0 : a > 1 ? 1 : a];
}

function rjSolidBg() {
  var probe = document.createElement('span');
  probe.style.cssText = 'display:none;position:fixed;right:0';
  probe.style.setProperty('background-color', 'var(--background,#23292e)');
  document.body.appendChild(probe);
  var c = rjRgb(getComputedStyle(probe).backgroundColor);
  document.body.removeChild(probe);
  if (!c || c[3] === 0) {
    /* variable absent/transparent -> pick the classic panel color by the
       actual page luminance so light themes stay readable */
    var b = rjRgb(getComputedStyle(document.body).backgroundColor);
    if (!b || b[3] === 0) b = rjRgb(getComputedStyle(document.documentElement).backgroundColor);
    return (b && b[3] > 0 && (b[0] + b[1] + b[2]) > 384) ? '#f4f4f4' : '#23292e';
  }
  if (c[3] >= 1) return 'rgb(' + Math.round(c[0]) + ',' + Math.round(c[1]) + ',' + Math.round(c[2]) + ')';
  var base = (c[0] + c[1] + c[2]) > 384 ? 255 : 0, w = 1 - c[3];
  return 'rgb(' + Math.round(c[0] * c[3] + base * w) + ',' + Math.round(c[1] * c[3] + base * w) + ',' + Math.round(c[2] * c[3] + base * w) + ')';
}

/* ==========================================================================
   3. Schedule Builder Helpers & Cron Calculations
   ========================================================================== */
var RJ_DOWS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
var RJ_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
var RJ_NMIN = [1, 2, 3, 5, 10, 15, 20, 30];

function rjPad2(n) { return (n < 10 ? '0' : '') + n; }

function rjFieldSet(spec, lo, hi) {
  /* '3', '1-5', '1,3,10' and step specs -> {v:true} map; null when malformed
     or out of range. Vixie semantics: no wrap-around ranges; 'N/step' means N..hi/step. */
  var map = {}, parts = String(spec).split(',');
  if (!parts.length) return null;
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i], step = 1, base = p;
    if (p.indexOf('/') >= 0) {
      var sp = p.split('/');
      if (sp.length !== 2 || !/^\d{1,2}$/.test(sp[1])) return null;
      step = parseInt(sp[1], 10); base = sp[0];
      if (step < 1 || step > hi) return null;
    }
    var a, b;
    if (base === '*') { a = lo; b = hi; }
    else if (base.indexOf('-') >= 0) {
      var rp = base.split('-');
      if (rp.length !== 2 || !/^\d{1,2}$/.test(rp[0]) || !/^\d{1,2}$/.test(rp[1])) return null;
      a = parseInt(rp[0], 10); b = parseInt(rp[1], 10);
    } else {
      if (!/^\d{1,2}$/.test(base)) return null;
      a = b = parseInt(base, 10);
      if (step > 1) b = hi;
    }
    if (a < lo || b > hi || a > b) return null;
    for (var v = a; v <= b; v += step) map[v] = true;
  }
  return map;
}

function rjNextRuns(cron, n) {
  /* next n fire times in local tz; day match follows Vixie's OR rule when both
     day-of-month and day-of-week are restricted. Coarse jumps keep it instant. */
  var f = String(cron || '').trim().split(/\s+/);
  if (f.length !== 5) return [];
  var sMin = rjFieldSet(f[0], 0, 59), sHr = rjFieldSet(f[1], 0, 23),
      sDom = rjFieldSet(f[2], 1, 31), sMon = rjFieldSet(f[3], 1, 12), sDow = rjFieldSet(f[4], 0, 7);
  if (sDow && sDow[7]) { sDow[0] = true; delete sDow[7]; } /* Vixie: 7 = Sunday = 0 */
  if (!sMin || !sHr || !sDom || !sMon || !sDow) return [];
  var domStar = f[2] === '*', dowStar = f[4] === '*';
  var d = new Date(); d.setSeconds(0, 0); d.setMinutes(d.getMinutes() + 1);
  var out = [], guard = 0;
  while (out.length < n && guard++ < 3000) {
    if (!sMon[d.getMonth() + 1]) { d = new Date(d.getFullYear(), d.getMonth() + 1, 1); continue; }
    var domOk = !!sDom[d.getDate()], dowOk = !!sDow[d.getDay()];
    var dayOk = (!domStar && !dowStar) ? (domOk || dowOk) : (domStar && dowStar) ? true : (domStar ? dowOk : domOk);
    if (!dayOk) { d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1); continue; }
    if (!sHr[d.getHours()]) { d = new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours() + 1); continue; }
    if (!sMin[d.getMinutes()]) { d.setMinutes(d.getMinutes() + 1); continue; }
    out.push(new Date(d));
    d.setMinutes(d.getMinutes() + 1);
  }
  return out;
}

function rjFmtRun(d) {
  return RJ_DOWS[d.getDay()] + ' ' + rjPad2(d.getDate()) + ' ' + RJ_MONTHS[d.getMonth()] + ' ' + rjPad2(d.getHours()) + ':' + rjPad2(d.getMinutes());
}

function rjRelativeCountdown(d) {
  var diffMs = d.getTime() - Date.now();
  if (diffMs <= 0) return 'due now';
  var totalMins = Math.round(diffMs / 60000);
  if (totalMins < 60) return 'in ' + totalMins + 'm';
  var hrs = Math.floor(totalMins / 60);
  var mins = totalMins % 60;
  if (hrs < 24) return 'in ' + hrs + 'h' + (mins > 0 ? ' ' + mins + 'm' : '');
  var days = Math.floor(hrs / 24);
  var remHrs = hrs % 24;
  return 'in ' + days + 'd' + (remHrs > 0 ? ' ' + remHrs + 'h' : '');
}

function rjParseCron(cron) {
  /* reverse-map to a builder preset; null = keep as Custom */
  var f = String(cron || '').trim().split(/\s+/);
  if (f.length !== 5) return null;
  var iv = function (x, lo, hi) { return /^\d{1,2}$/.test(x) && +x >= lo && +x <= hi; };
  if (f[3] !== '*') return null;
  if (f[1] === '*' && f[2] === '*' && f[4] === '*' && /^\*\/\d{1,2}$/.test(f[0]) && RJ_NMIN.indexOf(+f[0].slice(2)) >= 0) {
    return { freq: 'minutely', nmin: +f[0].slice(2) };
  }
  if (iv(f[0], 0, 59) && f[1] === '*' && f[2] === '*' && f[4] === '*') return { freq: 'hourly', hmin: +f[0] };
  if (iv(f[0], 0, 59) && iv(f[1], 0, 23) && f[2] === '*' && f[4] === '*') return { freq: 'daily', hour: +f[1], min: +f[0] };
  if (iv(f[0], 0, 59) && iv(f[1], 0, 23) && f[2] === '*' && /^\d(?:,\d)*$/.test(f[4])) {
    var ds = f[4].split(',').map(function (x) { return +x === 7 ? 0 : +x; }); /* 7 = Sunday */
    if (ds.every(function (x) { return x >= 0 && x <= 6; }) &&
        ds.length === ds.filter(function (x, i) { return ds.indexOf(x) === i; }).length) {
      return { freq: 'weekly', hour: +f[1], min: +f[0], dow: ds };
    }
  }
  if (iv(f[0], 0, 59) && iv(f[1], 0, 23) && iv(f[2], 1, 31) && f[4] === '*') return { freq: 'monthly', hour: +f[1], min: +f[0], dom: +f[2] };
  return null;
}

function rjHumanize(cron) {
  var p = rjParseCron(cron);
  if (!p) return '';
  var t = function () { return rjPad2(p.hour) + ':' + rjPad2(p.min); };
  if (p.freq === 'minutely') return p.nmin === 1 ? 'Every minute' : 'Every ' + p.nmin + ' minutes';
  if (p.freq === 'hourly') return 'Every hour at :' + rjPad2(p.hmin);
  if (p.freq === 'daily') return 'Every day at ' + t();
  if (p.freq === 'weekly') return 'Every ' + p.dow.map(function (d) { return RJ_DOWS[d]; }).join(', ') + ' at ' + t();
  return 'Monthly on day ' + p.dom + ' at ' + t();
}

/* ==========================================================================
   4. Async Dry-Run Preview (preview_start + 1s Polling)
   ==========================================================================
   Long dry-runs are detached on the box (engine task files), so the php
   request never hangs on a big remote. task_status output is single-consume;
   cancel is a best-effort group kill. A post-save preview survives the table
   reload via a sessionStorage flag that the fresh page consumes. */
var rjP = { timer: null, polls: 0, job: '' };

function rjPreviewStop() { if (rjP.timer) { clearInterval(rjP.timer); rjP.timer = null; } }

function rjPreviewShow(txt, isError, cancellable) {
  rjPanel('rj-preview', txt, isError);
  $('#rj-preview-ctl').toggle(!!cancellable);
}

function rjPreviewPoll() {
  rjP.polls++;
  if (rjP.polls > 120) {
    rjPreviewStop();
    rjPreviewShow('Preview is still running after 120 s.\nThe task continues on the server - reload this page later and press Dry-run again to collect its result.', false, true);
    return;
  }
  rjPost({ action: 'task_status', job: rjP.job }, function (res) {
    if (!rjP.timer) return; /* cancelled or replaced while the request was in flight */
    if (res.running) { rjPreviewShow('dry-run "' + rjP.job + '" running... ' + rjP.polls + 's', false, true); return; }
    rjPreviewStop();
    if (res.none) { rjPreviewShow('(no preview task on record - start one with the Dry-run button)', false, false); return; }
    if (res.error) { rjPreviewShow('ERROR: ' + res.error, true, false); return; }
    rjPreviewShow('exit code ' + res.rc + '\n\n' + (res.out || '(no output)'), res.rc !== 0, false);
  });
}

function rjRunPreview(job) {
  rjPreviewStop();
  rjP.job = job; rjP.polls = 0;
  rjPreviewShow('starting dry-run for "' + job + '" ...', false, false);
  rjPost({ action: 'preview_start', job: job }, function (res) {
    if (res.busy) { rjPreviewShow('Busy: ' + (res.error || 'a preview or run is already in progress for this job'), true, false); return; }
    if (!res.ok) { rjPreviewShow('ERROR: ' + (res.error || '?'), true, false); return; }
    rjP.timer = setInterval(rjPreviewPoll, 1000);
    rjPreviewPoll();
  });
}

/* ==========================================================================
   5. Live Status (nchan SSE & 60s Polling Fallback)
   ==========================================================================
   The engine POSTs /pub/rclone-jobs at run start/end; this page subscribes
   with EventSource('/sub/rclone-jobs') (same-origin, Unraid 7 ships nchan)
   and patches the Jobs table in place from the engine's status-json.
   EventSource missing or failing twice => plain 60 s auto-refresh instead
   (there was none before this feature - keep it as the degraded mode). */
var rjLive = { es: null, errs: 0, timer: null, pending: false };

function rjLiveInd(mode) {
  var $i = $('#rj-live-ind'), $sub = $('#rj-live-sub');
  if (!$i.length) return;
  if (mode === 'on') {
    $i.html('<span class="rj-live-dot on"></span><span style="color:#7dcf7d;font-weight:bold;font-size:13px">Live SSE</span>').attr('title', 'nchan SSE: status updates arrive the moment a run starts or ends');
    if ($sub.length) $sub.text('Instant updates active');
  } else if (mode === 'poll') {
    $i.html('<span class="rj-live-dot poll"></span><span style="color:#9aa7b2;font-size:13px">Polling (60s)</span>').attr('title', 'EventSource unavailable on this box; the table still refreshes once a minute');
    if ($sub.length) $sub.text('Fallback refresh mode');
  } else {
    $i.html('<span class="rj-live-dot wait"></span><span style="color:#9aa7b2;font-size:13px">Connecting...</span>');
    if ($sub.length) $sub.text('Establishing live stream');
  }
}

/* Dry-run summaries - badge chips and tooltip text matching server-rendered cells */
function rjDryChips(d) {
  var ts = String(d.stamp || '?');
  var s = ts.length >= 16 ? ts.substring(5, 10) + ' ' + ts.substring(11, 16) : ts;
  return '<span class="rj-dry-ts">' + rjEsc(s) + '</span>' +
    '<span class="rj-chip-diff rj-chip-add" title="Files copied/added">+' + (d.copies || 0) + '</span>' +
    '<span class="rj-chip-diff rj-chip-del" title="Files deleted">-' + (d.deletes || 0) + '</span>' +
    '<span class="rj-chip-diff rj-chip-err" title="Errors">!' + (d.fails || 0) + '</span>';
}
function rjDryFull(d) {
  return (d.stamp || '?') + ' copy+' + (d.copies || 0) + ' del-' + (d.deletes || 0) + ' fail:' + (d.fails || 0);
}

function rjApplyStatus(jobs) {
  $('#tab_rj_jobs tbody tr[data-job]').each(function () {
    var name = String($(this).data('job')), j = jobs[name], $tr = $(this);
    if (!j) return;
    var rcTxt = (j.rc === null || j.rc === undefined) ? '-' : String(j.rc);
    var running = !!j.running;
    var ok = /^(0|24)$/.test(rcTxt) && !running;
    var rcDisplay = (ok && (rcTxt === '0' || rcTxt === 0)) ? 'OK' : rcTxt;
    var iconHtml = '';
    if (ok) iconHtml = '<i class="fa fa-check-circle"></i> ';
    else if (running) iconHtml = '<i class="fa fa-refresh fa-spin"></i> ';
    else if (rcTxt !== '-' && rcTxt !== 'RUN') iconHtml = '<i class="fa fa-times-circle"></i> ';

    var trAmt = (j.transferred && j.transferred !== '0' && j.transferred !== '0 B') ? (' · ' + j.transferred) : '';
    $tr.find('.rj-rc')
      .html(iconHtml + rjEsc(rcDisplay + (j.run ? ' (' + (j.secs === null || j.secs === undefined ? '?' : j.secs) + 's' + trAmt + ')' : '')))
      .toggleClass('ok', ok).toggleClass('bad', !ok && !running && rcTxt !== '-' && rcTxt !== 'RUN').toggleClass('run', running);
    $tr.find('.rj-lastok').text('last OK: ' + (j.last_ok_run || 'never'));
    var d = j.dry, needAck = false;
    if (d) {
      /* same rule as the engine's gate_check and the server-rendered badge */
      needAck = (d.deletes || 0) > (d.warnDelete || 0) && !d.ack;
      $tr.find('.rj-dry').attr('title', rjDryFull(d))
        .html(rjDryChips(d) + (needAck ? " <span class=\"rj-needsack\">needs ack</span>" : ''));
    } else {
      $tr.find('.rj-dry').text('-').removeAttr('title');
    }
    var $ack = $tr.find("[data-act='ack']");
    if (needAck && $ack.length === 0) {
      $tr.find("[data-act='run']").after(" <button type='button' class='rj-btn rj-warn' data-act='ack' data-job='" + name + "' title='This dry-run wants to delete files - acknowledge before a real run'><i class='fa fa-exclamation-triangle'></i><span class='rj-btn-lbl'> Ack</span></button>");
    } else if (!needAck && $ack.length) {
      $ack.remove();
    }
    /* Run<->Stop swap (both buttons are server-rendered, one hidden): a
       running row shows red Stop; the rc=143 exit + SSE (or the 60 s
       fallback) flips the pair back */
    var $run = $tr.find("[data-act='run']"), $stop = $tr.find("[data-act='stop']");
    if (running) {
      $run.hide();
      $stop.show().prop('disabled', false).html('<i class="fa fa-stop"></i><span class="rj-btn-lbl"> Stop</span>');
    } else {
      $stop.hide();
      $run.show().prop('disabled', false).html('<i class="fa fa-play"></i><span class="rj-btn-lbl"> Run</span>');
    }
    /* refresh the row cue: running > needs-ack > ok / failed (rj-off is config-side, untouched) */
    $tr.removeClass('rj-st-ok rj-st-bad rj-st-ack rj-st-run');
    if (running) $tr.addClass('rj-st-run');
    else if (needAck) $tr.addClass('rj-st-ack');
    else if (ok) $tr.addClass('rj-st-ok');
    else if (rcTxt !== '-' && rcTxt !== 'RUN') $tr.addClass('rj-st-bad');
  });
}

function rjStatusRefresh() {
  rjPost({ action: 'status_json' }, function (res) {
    if (res && res.ok && res.jobs) rjApplyStatus(res.jobs);
  });
}

function rjLiveFallback() {
  if (rjLive.es) { try { rjLive.es.close(); } catch (e) { /* already gone */ } rjLive.es = null; }
  if (!rjLive.timer) rjLive.timer = setInterval(rjStatusRefresh, 60000);
  rjLiveInd('poll');
}

function rjLiveStart() {
  if (typeof EventSource === 'undefined') { rjLiveFallback(); return; }
  rjLiveInd('init');
  try { rjLive.es = new EventSource('/sub/' + 'rclone-jobs'); } catch (e) { rjLiveFallback(); return; }
  rjLive.es.onopen = function () {
    rjLive.errs = 0;
    rjLiveInd('on');
  };
  rjLive.es.onmessage = function () {
    rjLive.errs = 0;
    rjLiveInd('on');
    if (rjLive.pending) return; /* debounce: a watchdog sweep + real run can fire together */
    rjLive.pending = true;
    setTimeout(function () { rjLive.pending = false; rjStatusRefresh(); }, 500);
  };
  rjLive.es.onerror = function () {
    /* EventSource retries on its own; two consecutive failures mean the
       channel does not exist here (old nginx, dev box) -> degrade */
    if (++rjLive.errs >= 2) rjLiveFallback();
  };
}

/* ==========================================================================
   6. Run History & Size Trend Visualization
   ========================================================================== */
function rjEsc(s) { var d = document.createElement('div'); d.textContent = String(s === null || s === undefined ? '' : s); return d.innerHTML; }

function rjHistBytes(b) {
  if (b === null || b === undefined) return 'n/a';
  var u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], i = 0, v = b;
  while (v >= 1024 && i < 4) { v /= 1024; i++; }
  return (i === 0 || v >= 100 ? Math.round(v) : v.toFixed(1)) + ' ' + u[i];
}

function rjCloseHistory() {
  var $p = $('#rj-history');
  $p.hide();
  $('#rj-history-slot-bottom').append($p);
  $('#rj-inline-hist-tr').remove();
  $('.rj-row-hist').removeClass('rj-row-hist');
}

function rjAttachHistory(job) {
  var $p = $('#rj-history');
  $('#rj-history-slot-bottom').append($p);
  $('#rj-inline-hist-tr').remove();
  $('.rj-row-hist').removeClass('rj-row-hist');

  if (job) {
    var $row = $('#tab_rj_jobs tbody tr[data-job="' + job + '"]');
    if ($row.length) {
      $row.addClass('rj-row-hist');
      var $tr = $('<tr id="rj-inline-hist-tr" class="rj-inline-hist-tr"><td colspan="7"></td></tr>');
      $row.after($tr);
      $tr.find('td').append($p);
      return;
    }
  }
  $('#rj-history-slot-bottom').append($p).show();
}

/* top-level (not ready-closure scoped) so rjShowHistory can call it */
function rjCloseForm() {
  var $wrap = $('#rj-form-wrap');
  $wrap.hide();
  $('#rj-form-slot-bottom').append($wrap).show();
  $('#rj-inline-form-tr').remove();
  $('.rj-row-editing').removeClass('rj-row-editing');
  $('#rj-form-chev').attr('class', 'fa fa-chevron-down');
  $('#rj-form-toggle').attr('aria-expanded', 'false');
  $('#rj-form-title-accordion').text('Add job');
  $('#rj-result').hide();
}

function rjShowHistory(job) {
  /* toggle off if already open for this job */
  if ($('#rj-inline-hist-tr').length && $('.rj-row-hist').data('job') === job && $('#rj-history').is(':visible')) {
    rjCloseHistory();
    return;
  }
  /* close edit form if open to prevent visual clutter */
  rjCloseForm();
  rjAttachHistory(job);

  /* tiered view: 24h summary + hourly sparkline (raw runs merged with hourly
     buckets) + daily rollup table + raw per-run detail with a failures-only
     filter. A job on a minutes-schedule stays readable this way. */
  rjPost({ action: 'history', job: job, n: 600 }, function (res) {
    var $p = $('#rj-history').empty();
    if (!res.ok) {
      $p.append($('<div class="rj-hist-card"><div class="rj-hist-top"><div class="rj-hist-title"><i class="fa fa-history" style="color:#e6867e"></i> History Error</div><button type="button" class="rj-form-close-x" id="rj-hist-close">&times;</button></div><pre style="color:#e6867e"></pre></div>'));
      $p.find('pre').text('ERROR: ' + (res.error || '?'));
      $p.find('#rj-hist-close').on('click', rjCloseHistory);
      $p.show();
      return;
    }
    var e = res.entries || [], roll = res.rollups || [];
    var nowMs = Date.now(), HR = 3600000;
    var $wrap = $('<div class="rj-hist-card"></div>');
    var $hdr = $('<div class="rj-hist-top">' +
      '<div class="rj-hist-title"><i class="fa fa-history" style="color:#06b6d4"></i> Run History &amp; Trend: <span style="color:#22d3ee">"' + rjEsc(job) + '"</span></div>' +
      '<div><button type="button" class="rj-form-close-x" id="rj-hist-close" title="Close history">&times;</button></div>' +
      '</div>');
    $wrap.append($hdr);
    $hdr.find('#rj-hist-close').on('click', function () { rjCloseHistory(); });

    if (!e.length && !roll.length) {
      $wrap.append('<div class="gray" style="padding:12px 0">No live runs recorded yet - history counts real runs, not dry-runs.</div>');
      $p.append($wrap).show();
      $p[0].scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      return;
    }
    /* last-24h summary (raw entries + hourly buckets inside the window) */
    var s24r = 0, s24f = 0, s24b = 0;
    e.forEach(function (x) {
      if ((x.ts || 0) * 1000 >= nowMs - 24 * HR) { s24r++; if (!(x.rc === 0 || x.rc === 24)) s24f++; s24b += (x.bytes || 0); }
    });
    roll.forEach(function (b) {
      if (b.rollup === 'h' && (b.ts || 0) * 1000 >= nowMs - 24 * HR) { s24r += (b.runs || 0); s24f += (b.fails || 0); s24b += (b.bytes || 0); }
    });
    $wrap.append($('<div style="display:flex;gap:12px;flex-wrap:wrap;margin:4px 0 12px"></div>').html(
      '<div class="rj-card" style="padding:8px 12px;min-width:130px"><div class="rj-card-title">24h Runs</div><div class="rj-card-val" style="font-size:15px">' + s24r + '</div></div>' +
      '<div class="rj-card" style="padding:8px 12px;min-width:130px"><div class="rj-card-title">24h Failed</div><div class="rj-card-val" style="font-size:15px;color:' + (s24f > 0 ? '#e6867e' : '#7dcf7d') + '">' + s24f + '</div></div>' +
      '<div class="rj-card" style="padding:8px 12px;min-width:130px"><div class="rj-card-title">24h Transferred</div><div class="rj-card-val" style="font-size:15px">' + (s24b > 0 ? rjHistBytes(s24b) : '0 B') + '</div></div>' +
      '<div class="rj-card" style="padding:8px 12px;min-width:130px"><div class="rj-card-title">Entries Window</div><div class="rj-card-val" style="font-size:15px">' + e.length + ' <span style="font-size:11px;font-weight:normal;color:#8b98a3">(' + roll.length + ' buckets)</span></div></div>'
    ));
    /* hourly sparkline, last 48h: raw runs folded by hour + hourly buckets */
    var hmap = {};
    function hourAdd(ts, runs, fails, bytes, secs) {
      var kk = Math.floor(ts / 3600);
      if (!hmap[kk]) hmap[kk] = { runs: 0, fails: 0, bytes: 0, secs: 0 };
      hmap[kk].runs += runs; hmap[kk].fails += fails; hmap[kk].bytes += (bytes || 0); hmap[kk].secs += (secs || 0);
    }
    e.forEach(function (x) { hourAdd(x.ts || 0, 1, (x.rc === 0 || x.rc === 24) ? 0 : 1, x.bytes, x.secs); });
    roll.forEach(function (b) { if (b.rollup === 'h') hourAdd(b.ts || 0, b.runs || 0, b.fails || 0, b.bytes, b.secs_sum); });
    var keys = Object.keys(hmap).map(Number)
      .filter(function (kk) { return kk * 3600 * 1000 >= nowMs - 48 * HR; })
      .sort(function (a, b) { return a - b; });
    if (keys.length > 1) {
      var hmax = 1;
      keys.forEach(function (kk) { var v = hmap[kk].bytes > 0 ? hmap[kk].bytes : hmap[kk].secs; if (v > hmax) hmax = v; });
      var $sp = $('<div class="rj-hist-spark"></div>');
      keys.forEach(function (kk) {
        var h = hmap[kk], v = h.bytes > 0 ? h.bytes : h.secs;
        var d = new Date(kk * 3600 * 1000);
        $sp.append($('<div class="rj-spark-bar"></div>')
          .attr('title', ('0' + d.getHours()).slice(-2) + ':00 - ' + h.runs + ' run(s)' +
            (h.fails ? ', ' + h.fails + ' FAILED' : '') + ', ' +
            (h.bytes > 0 ? rjHistBytes(h.bytes) : '0 B') + (h.secs ? ', ' + h.secs + 's busy' : ''))
          .css('height', Math.max(4, Math.round(36 * v / hmax)) + 'px')
          .css('background', h.fails > 0 ? '#e6867e' : '#2e97c2'));
      });
      $wrap.append($('<div class="gray" style="font-size:11px;margin-top:6px;font-weight:600">Hourly trend, last 48h (bar = transferred, fallback busy seconds; red = hour with failures)</div>').append($sp));
    }
    /* daily rollup buckets, last 14 days */
    var days = roll.filter(function (b) { return b.rollup === 'd'; }).slice(-14).reverse();
    if (days.length) {
      var dmax = 1;
      days.forEach(function (b) { if (b.bytes && b.bytes > dmax) dmax = b.bytes; });
      var $dtb = $('<tbody></tbody>');
      days.forEach(function (b) {
        var avg = b.runs ? Math.round((b.secs_sum || 0) / b.runs) : 0;
        var w = b.bytes ? Math.max(2, Math.round(100 * b.bytes / dmax)) : 0;
        var day = b.iso ? String(b.iso).slice(0, 10) : new Date((b.ts || 0) * 1000).toISOString().slice(0, 10);
        $dtb.append('<tr><td style="white-space:nowrap">' + rjEsc(day) + '</td>'
          + '<td>' + (b.runs || 0) + '</td>'
          + '<td style="color:' + (b.fails > 0 ? '#e6867e' : '#7dcf7d') + '">' + (b.fails || 0) + '</td>'
          + '<td>' + avg + 's</td><td>' + (b.secs_max || 0) + 's</td><td>' + (b.errors || 0) + '</td>'
          + '<td>' + rjHistBytes(b.bytes) + '</td>'
          + '<td style="width:160px"><div style="height:8px;background:#2e97c2;border-radius:3px;width:' + w + '%"></div></td></tr>');
      });
      var $dtbWrap = $('<div class="rj-daily-scroll"></div>');
      $dtbWrap.append($('<table class="view-table" style="width:100%;margin:0"><thead><tr><th>Day</th><th>Runs</th><th>Failed</th><th>Avg run</th><th>Max run</th><th>Errors</th><th>Transferred</th><th>Trend</th></tr></thead></table>').append($dtb));
      $wrap.append($('<div class="gray" style="font-size:11px;margin:12px 0 4px;font-weight:600">Daily rollups (hourly detail kept 7 days, raw 24 h - retention on the Safety tab)</div>'), $dtbWrap);
    }
    /* raw per-run detail (newest first) with a failures-only filter */
    var $tb = $('<tbody></tbody>');
    var failsOnly = false;
    function renderRaw() {
      $tb.empty();
      var list = [], i;
      for (i = e.length - 1; i >= 0; i--) {
        if (failsOnly && (e[i].rc === 0 || e[i].rc === 24)) continue;
        list.push(e[i]);
      }
      var shown = list.slice(0, 100), rmax = 1;
      shown.forEach(function (x) { if (x.bytes && x.bytes > rmax) rmax = x.bytes; });
      if (!list.length) $tb.append('<tr><td colspan="6" style="text-align:center;padding:10px">' +
        (failsOnly ? 'No failed runs in the loaded window.' : 'No live runs recorded yet - history counts real runs, not dry-runs.') + '</td></tr>');
      shown.forEach(function (x) {
        var ok = (x.rc === 0 || x.rc === 24);
        var res2 = x.rc === 0 ? 'OK' : (x.rc === 24 ? 'OK (24)' : (x.rc === 143 ? 'interrupted' : 'rc ' + x.rc));
        var w = x.bytes ? Math.max(2, Math.round(100 * x.bytes / rmax)) : 0;
        $tb.append('<tr><td style="white-space:nowrap">' + rjEsc(x.iso) + '</td>'
          + '<td style="color:' + (ok ? '#7dcf7d' : '#e6867e') + ';font-weight:bold">' + rjEsc(res2) + '</td>'
          + '<td>' + (x.secs === null || x.secs === undefined ? '-' : x.secs + 's') + '</td>'
          + '<td>' + (x.errors || 0) + '</td>'
          + '<td>' + rjEsc(x.transferred || rjHistBytes(x.bytes)) + '</td>'
          + '<td style="width:180px"><div style="height:8px;background:#2e97c2;border-radius:3px;width:' + w + '%"></div></td></tr>');
      });
      if (list.length > shown.length) $tb.append('<tr><td colspan="6" class="gray" style="text-align:center;padding:6px">+ ' +
        (list.length - shown.length) + ' older run(s) not shown - see the rollups above</td></tr>');
    }
    renderRaw();
    var $ff = $('<div class="rj-tb-pills" style="margin-left:14px;display:inline-flex;gap:4px">' +
      '<button type="button" class="rj-filter-pill active" data-hist-filter="all">All runs <span class="rj-pill-cnt">' + e.length + '</span></button>' +
      '<button type="button" class="rj-filter-pill" data-hist-filter="fail">Failures only' + (s24f > 0 ? ' <span class="rj-pill-cnt">' + s24f + '</span>' : '') + '</button>' +
    '</div>');
    $ff.find('.rj-filter-pill').on('click', function () {
      $ff.find('.rj-filter-pill').removeClass('active');
      $(this).addClass('active');
      failsOnly = ($(this).data('hist-filter') === 'fail');
      renderRaw();
    });
    var $rawWrap = $('<div class="rj-hist-scroll"></div>');
    $rawWrap.append($('<table class="view-table" style="width:100%;margin:0"><thead><tr><th>When</th><th>Result</th><th>Duration</th><th>Errors</th><th>Transferred</th><th>Size trend</th></tr></thead></table>').append($tb));
    $wrap.append($('<div class="gray" style="font-size:11px;margin:12px 0 6px;font-weight:600;display:flex;align-items:center;flex-wrap:wrap;gap:8px"><span>Raw per-run detail (newest first)</span></div>').append($ff), $rawWrap);
    $p.append($wrap).show();
    $p[0].scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  });
}

/* ==========================================================================
   7. Confirmation & Safety Dialogs
   ========================================================================== */

/* docs pattern: swal (red confirm for destructive ops) with native confirm fallback */
function rjConfirm(title, text, btn, danger, cb) {
  if (typeof swal === 'function') {
    swal({ title: title, text: text, type: 'warning', showCancelButton: true,
           confirmButtonText: btn, cancelButtonText: 'Cancel',
           confirmButtonColor: danger ? '#d33' : '#2e97c2' },
         function (ok) { if (ok) cb(); });
  } else if (window.confirm(title + '\n' + text + '\n\n-> ' + btn + '?')) { cb(); }
}

/* typed-confirmation dialog for the deletion Ack - self-contained (like the
   browse modal) instead of openBox/swal: no dependency on webGui box APIs,
   styled with theme variables + dark fallbacks */
function rjAckDialog(job) {
  function send(t) {
    rjPost({ action: 'ack_job', job: job, confirm: t }, function (res) {
      rjPanel('rj-result', res.ok ? (res.out || 'acknowledged') : ('ERROR: ' + res.error), !res.ok);
      if (res.ok) setTimeout(function () { location.reload(); }, 900);
    });
  }
  if ($('#rj-ack-ov').length === 0) {
    var ov = $('<div id="rj-ack-ov" role="dialog" aria-modal="true"></div>').css({ position: 'fixed', left: 0, top: 0, right: 0, bottom: 0, background: 'rgba(0,0,0,.55)', zIndex: 9998, display: 'none' });
    var box = $('<div></div>').css({ position: 'relative', width: '440px', maxWidth: '92vw', margin: '12vh auto', background: rjSolidBg(), border: '1px solid var(--border,#5a6570)', borderRadius: '6px', color: 'var(--text,#e8e8e8)', padding: '14px', fontSize: '12px' });
    box.append($('<div id="rj-ack-text" style="margin:0 0 10px"></div>'));
    box.append($('<input type="text" id="rj-ack-in" autocomplete="off">').css({ width: '100%', boxSizing: 'border-box', marginBottom: '12px' }));
    box.append($('<input type="button" id="rj-ack-ok" value="Acknowledge" class="rj-btn rj-del">')).append($('<input type="button" id="rj-ack-cancel" value="Cancel">'));
    ov.append(box).appendTo('body');
    ov.on('click', function (ev) { if (ev.target === this) ov.fadeOut(60); });
    $('#rj-ack-cancel').on('click', function () { ov.fadeOut(60); });
    $('#rj-ack-in').on('keydown', function (ev) { if (ev.key === 'Enter') { ev.preventDefault(); $('#rj-ack-ok').trigger('click'); } });
    $(document).on('keydown.rjack', function (ev) { if (ev.key === 'Escape' && $('#rj-ack-ov').is(':visible')) $('#rj-ack-ov').fadeOut(60); });
  }
  $('#rj-ack-text').text('This dry-run wants to DELETE files for job "' + job + '". Type the job name exactly (' + job + ') to acknowledge:');
  $('#rj-ack-in').val('');
  $('#rj-ack-ok').off('.rjack').on('click.rjack', function () {
    var t = $('#rj-ack-in').val();
    $('#rj-ack-ov').fadeOut(60);
    send(t); /* server re-checks the typed name - a wrong one is refused there */
  });
  $('#rj-ack-ov').stop(true, true).fadeIn(80);
  $('#rj-ack-in').trigger('focus');
}

/* ==========================================================================
   8. Document Ready Initialization
   ========================================================================== */
$(function () {
  var D = rjData();

  /* --- 8.1 Tabbed Layout Navigation & Deep Linking ---
     Headers are href-less <a class="rj-tab"> on purpose - Unraid's
     a[href] click interceptor would treat a bare "#hash" as a navigation and show
      the 'External link' dialog. Delegated binding; URL keeps #tab_rj_* for deep links. */
  (function rjTabs() {
    var tabs = [];
    $('ul.tabs a.rj-tab').each(function () { tabs.push(String($(this).data('tab'))); });
    if (!tabs.length) return;
    function activate(id) {
      $('ul.tabs a.rj-tab').each(function () {
        $(this).parent().toggleClass('active', String($(this).data('tab')) === id);
      });
      tabs.forEach(function (t) { var $d = $('#' + t); if ($d.length) $d.toggle(t === id); });
    }
    function open(id) {
      if (tabs.indexOf(id) < 0) return;
      activate(id);
      if (location.hash !== '#' + id) history.replaceState(null, '', '#' + id);
    }
    $(document).on('click.rjtab', 'ul.tabs a.rj-tab', function () { open(String($(this).data('tab'))); });
    $(document).on('keydown.rjtab', 'ul.tabs a.rj-tab', function (ev) {
      if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); open(String($(this).data('tab'))); }
    });
    var start = location.hash.replace(/^#/, '');
    activate(tabs.indexOf(start) >= 0 ? start : tabs[0]);
  })();

  /* --- 8.2 Populate Settings / Alerts Tab State --- */
  $('#a_master').val(D.master === 'no' ? 'no' : 'yes');
  $('#a_qstart').val(D.quiet.start);
  $('#a_qend').val(D.quiet.end);
  $('#a_rawhours').val(D.retention.rawHours);
  $('#a_rawmax').val(D.retention.rawMax);
  $('#a_hourdays').val(D.retention.hourDays);
  $('#a_hdays').val(D.retention.days);
  $('#a_logdays').val(D.retention.logDays);
  $('#a_faildays').val(D.retention.failDays);
  $('#a_logmax').val(D.retention.logMax);

  /* --- 8.3 Engine-Dependent Form Row Visibility --- */
  function engRows() {
    var e = $('#f_engine').val();
    $('.rj-eng').toggle(e !== 'custom');
    $('.rj-custom').toggle(e === 'custom');
    $('.rj-rclone-adv').toggle(e === 'rclone');
  }
  $('#f_engine').off('.rclonejobs').on('change.rclonejobs', engRows);
  engRows();

  /* --- 8.4 Interactive Schedule Builder --- */
  (function rjSchedInit() {
    var i, $w = $('#f_s_weekday');
    $w.empty();
    for (i = 0; i < 24; i++) $('#f_sched_hour').append($('<option></option>').val(i).text(rjPad2(i)));
    for (i = 0; i < 60; i++) {
      $('#f_sched_min').append($('<option></option>').val(i).text(rjPad2(i)));
      $('#f_sched_hmin').append($('<option></option>').val(i).text(rjPad2(i)));
    }
    for (i = 1; i <= 31; i++) $('#f_sched_dom').append($('<option></option>').val(i).text(i));
    RJ_NMIN.forEach(function (n) { $('#f_sched_nmin').append($('<option></option>').val(n).text(n)); });
    RJ_DOWS.forEach(function (nm, d) {
      var $btn = $('<button type="button" class="rj-wd-btn" data-dow="' + d + '">' + nm + '<input type="checkbox" class="rj-wd-cb" value="' + d + '"></button>');
      $w.append($btn);
    });
    $('#f_sched_hour').val(3); $('#f_sched_min').val(30); /* sensible new-job default */
  })();

  $(document).off('click.rjwd', '.rj-wd-btn').on('click.rjwd', '.rj-wd-btn', function (e) {
    e.preventDefault();
    var $cb = $(this).find('.rj-wd-cb');
    var chk = !$cb.prop('checked');
    $cb.prop('checked', chk);
    $(this).toggleClass('active', chk);
    schedSummary();
  });

  function schedRows() {
    var f = $('#f_sched_freq').val();
    $('#f_s_minutely').toggle(f === 'minutely');
    $('#f_s_hourly').toggle(f === 'hourly');
    $('#f_s_dom').toggle(f === 'monthly');
    $('#f_s_weekday').toggle(f === 'weekly');
    $('#f_s_clock').toggle(f === 'daily' || f === 'weekly' || f === 'monthly');
    $('#f_s_at').toggle(f === 'weekly' || f === 'monthly');
    $('#dl_f_schedule').toggle(f === 'custom');
    schedSummary();
  }

  function rjCheckedDows() {
    var a = [];
    $('.rj-wd-cb:checked').each(function () { a.push(+$(this).val()); });
    return a;
  }

  function rjBuildCron() {
    var f = $('#f_sched_freq').val();
    if (f === 'minutely') return '*/' + $('#f_sched_nmin').val() + ' * * * *';
    if (f === 'hourly') return $('#f_sched_hmin').val() + ' * * * *';
    if (f === 'daily') return $('#f_sched_min').val() + ' ' + $('#f_sched_hour').val() + ' * * *';
    if (f === 'weekly') {
      var d = rjCheckedDows();
      if (!d.length) return '';
      return $('#f_sched_min').val() + ' ' + $('#f_sched_hour').val() + ' * * ' + d.join(',');
    }
    if (f === 'monthly') return $('#f_sched_min').val() + ' ' + $('#f_sched_hour').val() + ' ' + $('#f_sched_dom').val() + ' * *';
    return String($('#f_schedule').val() || '').trim().replace(/\s+/g, ' ');
  }

  function schedSummary() {
    var f = $('#f_sched_freq').val();
    if (f === 'custom' && !$('#f_schedule').val().trim()) { $('#rj-sched-summary').removeClass('rj-warn').html('<i class="fa fa-info-circle"></i> Enter a 5-field cron expression, e.g. <code>30 3 * * *</code>'); return; }
    var cron = rjBuildCron();
    if (!cron) { $('#rj-sched-summary').addClass('rj-warn').html('<i class="fa fa-exclamation-triangle"></i> Pick at least one weekday.'); return; }
    var fields = cron.split(/\s+/);
    if (f === 'custom') {
      var lim = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]], bad = fields.length !== 5;
      if (!bad) for (var i = 0; i < 5; i++) if (!rjFieldSet(fields[i], lim[i][0], lim[i][1])) { bad = true; break; }
      if (bad) { $('#rj-sched-summary').addClass('rj-warn').html('<i class="fa fa-exclamation-triangle"></i> Not a valid 5-field cron expression (minute 0-59, hour 0-23, day 1-31, month 1-12, weekday 0-7; 7 = Sunday).'); return; }
    }
    var human = rjHumanize(cron) || 'Custom cron';
    var msgs = ['<strong style="color:#e8eef3"><i class="fa fa-calendar-check-o" style="color:#ff8c2f"></i> ' + rjEsc(human) + '</strong>', 'cron: <code>' + rjEsc(cron) + '</code>'];
    var runs = rjNextRuns(cron, 3);
    if (runs.length) msgs.push('next: ' + runs.map(function (r) { return rjEsc(rjFmtRun(r)); }).join(' · '));
    if (fields[2] !== '*' && fields[4] !== '*') msgs.push('<em>note: with both day-of-month and day-of-week set, cron fires when EITHER matches.</em>');
    if (f === 'monthly' && +fields[2] > 28) msgs.push('<em>note: months without day ' + fields[2] + ' are skipped.</em>');
    $('#rj-sched-summary').removeClass('rj-warn').html(msgs.join('&nbsp;&nbsp;|&nbsp;&nbsp;'));
  }

  function rjFormSetSchedule(cron) {
    var p = cron ? rjParseCron(cron) : null;
    if (!cron) {
      $('#f_sched_freq').val('daily');
      $('#f_sched_hour').val(3);
      $('#f_sched_min').val(30);
      $('.rj-wd-cb').prop('checked', false);
      $('.rj-wd-btn').removeClass('active');
    } else if (p) {
      $('#f_sched_freq').val(p.freq);
      if (p.freq === 'minutely') $('#f_sched_nmin').val(p.nmin);
      if (p.freq === 'hourly') $('#f_sched_hmin').val(p.hmin);
      if (p.freq === 'weekly') {
        $('.rj-wd-cb').prop('checked', false);
        $('.rj-wd-btn').removeClass('active');
        p.dow.forEach(function (d) {
          $('.rj-wd-cb').filter('[value="' + d + '"]').prop('checked', true);
          $('.rj-wd-btn[data-dow="' + d + '"]').addClass('active');
        });
      }
      if (p.freq !== 'minutely' && p.freq !== 'hourly') { $('#f_sched_hour').val(p.hour); $('#f_sched_min').val(p.min); }
      if (p.freq === 'monthly') $('#f_sched_dom').val(p.dom);
    } else {
      $('#f_sched_freq').val('custom');
      $('#f_schedule').val(cron);
      $('.rj-wd-cb').prop('checked', false);
      $('.rj-wd-btn').removeClass('active');
    }
    schedRows();
  }

  $('#f_sched_freq').off('.rjsched').on('change.rjsched', schedRows);
  $('#f_sched_hour, #f_sched_min, #f_sched_hmin, #f_sched_dom, #f_sched_nmin').off('.rjsched').on('change.rjsched', schedSummary);
  $('#f_schedule, .rj-wd-cb').off('.rjsched').on('input.rjsched change.rjsched', schedSummary);
  schedRows();

  /* --- 8.5 Jobs Table Schedule Column Humanization & Next Run Preview ---
     Humanize the jobs-table Schedule column (raw cron stays in the tooltip),
     with a small gray "next:" line computed from the same cron builder */
  $('#tab_rj_jobs tbody tr[data-job]').each(function () {
    var j = D.jobs[$(this).data('job')];
    if (!j || !j.conf || !j.conf.SCHEDULE) return;
    var cron = String(j.conf.SCHEDULE);
    var runs = rjNextRuns(cron, 1);
    var html = rjEsc(rjHumanize(cron) || cron);
    if (runs.length) html += '<br><span class="rj-next">Next: ' + rjEsc(rjRelativeCountdown(runs[0])) + ' (' + rjEsc(rjFmtRun(runs[0])) + ')</span>';
    $(this).find('td.rj-sched').html(html).attr('title', cron);
  });

  /* --- 8.6 Storage Overlap Validation & Safety Warnings --- */
  function rjNorm(p) { return p.length > 1 ? p.replace(/\/+$/, '') : p; }
  function rjOverlap(p) {
    var s = D.storage ? rjNorm(D.storage) : '';
    if (!s || !p || p.charAt(0) !== '/' || /^[A-Za-z0-9._-]+:/.test(p)) return '';
    p = rjNorm(p);
    if (p === s || p.indexOf(s + '/') === 0) return 'inside';
    if (s.indexOf(p + '/') === 0) return 'ancestor';
    if (p === '/mnt/user' && /^\/mnt\/disk\d+\/\./.test(s)) return 'ancestor';
    return '';
  }
  function rjOvHint() {
    var msgs = [], warn = false, top = '';
    if (D.storage) top = '/' + D.storage.split('/').filter(Boolean).pop();
    [['source', $('#f_src').val().trim()], ['destination', $('#f_dst').val().trim()]].forEach(function (x) {
      var kind = rjOverlap(x[1]);
      if (kind === 'inside') { warn = true; msgs.push('WARNING: ' + x[0] + ' is inside the plugin storage folder - runs will be REFUSED.'); }
      else if (kind === 'ancestor') {
        if ($('#f_engine').val() === 'custom') { warn = true; msgs.push('WARNING: a custom script cannot receive an auto-exclude - ' + top + ' is NOT shielded inside this ' + x[0] + '.'); }
        else msgs.push('Note: this ' + x[0] + ' contains the plugin storage folder - ' + top + ' is auto-excluded on runs.');
      }
    });
    var $n = $('#rj-ov-note');
    if (!msgs.length) { $n.hide(); return; }
    $n.text(msgs.join(' ')).css('color', warn ? '#e6867e' : '#9aa7b2').show();
  }
  $('#f_src, #f_dst').off('.rjov').on('input.rjov change.rjov', rjOvHint);
  $('#f_engine').off('.rjov').on('change.rjov', rjOvHint);
  /* --- 8.7 Inline Job Editor Form Management --- */
  function rjAttachForm(jobName) {
    var $wrap = $('#rj-form-wrap');
    // Safely park in bottom slot first so it is never destroyed by remove()
    $('#rj-form-slot-bottom').append($wrap);
    $('#rj-inline-form-tr').remove();
    $('.rj-row-editing').removeClass('rj-row-editing');

    if (jobName) {
      var $row = $('#tab_rj_jobs tbody tr[data-job="' + jobName + '"]');
      if ($row.length) {
        $row.addClass('rj-row-editing');
        var $tr = $('<tr id="rj-inline-form-tr" class="rj-inline-form-tr"><td colspan="7"></td></tr>');
        $row.after($tr);
        $tr.find('td').append($wrap);
        $('#rj-form-slot-bottom').hide();
        return;
      }
    }
    var $tbody = $('#tab_rj_jobs table.rclone-jobs tbody');
    if ($tbody.length && $('#tab_rj_jobs tbody tr[data-job]').length) {
      var $tr = $('<tr id="rj-inline-form-tr" class="rj-inline-form-tr"><td colspan="7"></td></tr>');
      $tbody.prepend($tr);
      $tr.find('td').append($wrap);
      $('#rj-form-slot-bottom').hide();
      return;
    }
    $('#rj-form-slot-bottom').append($wrap).show();
  }

  function rjSetFormOpen(open) {
    if (!open) {
      rjCloseForm();
    } else {
      $('#rj-form-wrap').show();
      $('#rj-form-chev').attr('class', 'fa fa-chevron-up');
      $('#rj-form-toggle').attr('aria-expanded', 'true');
    }
  }

  $('#rj-form-toggle').off('.rjform').on('click.rjform', function () {
    if ($('#rj-form-wrap').is(':visible') && $('#rj-inline-form-tr').length === 0) {
      rjCloseForm();
    } else {
      showForm('Add job', null);
    }
  }).on('keydown.rjform', function (ev) {
    if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); $(this).trigger('click'); }
  });

  $('#rj-btn-add-top').off('.rjadd').on('click.rjadd', function () {
    showForm('Add job', null);
  });
  if (!Object.keys(D.jobs).length) showForm('Add job', null);

  function showForm(title, j) {
    rjCloseHistory();
    $('#rj-form-title').text(title);
    $('#rj-form-title-accordion').text(title);
    $('#f_orig').val(j ? j.name : '');
    $('#f_name').val(j ? j.name : '').prop('disabled', !!j);
    $('#f_desc').val(j && j.conf.DESC ? j.conf.DESC : '');
    $('#f_enabled').val(j && j.conf.ENABLED === 'no' ? 'no' : 'yes');
    rjFormSetSchedule(j && j.conf.SCHEDULE ? j.conf.SCHEDULE : '');
    $('#f_engine').val(j && j.conf.ENGINE ? j.conf.ENGINE : 'rclone');
    $('#f_mode').val(j && j.conf.MODE ? j.conf.MODE : 'sync');
    $('#f_src').val(j && j.conf.SRC ? j.conf.SRC : '');
    $('#f_dst').val(j && j.conf.DST ? j.conf.DST : '');
    $('#f_script').val(j && j.conf.CUSTOM_SCRIPT ? j.conf.CUSTOM_SCRIPT : '');
    $('#f_dryrun').val(j && j.conf.DRYRUN === 'no' ? 'no' : 'yes');
    $('#f_notify').val(j && ['always', 'failures', 'off'].indexOf(j.conf.NOTIFY) >= 0 ? j.conf.NOTIFY
                 : (j && j.conf.HEARTBEAT === 'no' ? 'failures' : 'always'));
    $('#f_transfers').val(j && j.conf.TRANSFERS ? j.conf.TRANSFERS : 4);
    $('#f_checkers').val(j && j.conf.CHECKERS ? j.conf.CHECKERS : 8);
    $('#f_bwlimit').val(j && j.conf.BWLIMIT ? j.conf.BWLIMIT : '');
    $('#f_maxdelete').val(j && j.conf.MAXDELETE !== undefined ? j.conf.MAXDELETE : 100);
    $('#f_warndelete').val(j && j.conf.WARN_DELETE !== undefined ? j.conf.WARN_DELETE : 100);
    $('#f_backupdir').val(j && j.conf.BACKUPDIR ? j.conf.BACKUPDIR : '');
    $('#f_buffersize').val(j && j.conf.BUFFER_SIZE ? j.conf.BUFFER_SIZE : '');
    $('#f_fastlist').val(j && j.conf.FAST_LIST === 'yes' ? 'yes' : 'no');
    $('#f_onedrive_chunksize').val(j && j.conf.ONEDRIVE_CHUNK_SIZE ? j.conf.ONEDRIVE_CHUNK_SIZE : '');
    $('#f_args').val(j && j.conf.ARGS ? j.conf.ARGS : '');
    engRows();
    rjOvHint();
    rjAttachForm(j ? j.name : null);
    rjSetFormOpen(true);
    var el = $('#rj-inline-form-tr').length ? $('#rj-inline-form-tr')[0] : $('#rj-form-wrap')[0];
    if (el && el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  $('#rj-form-cancel, #rj-form-close').off('.rclonejobs').on('click.rclonejobs', function () {
    rjCloseForm();
  });

  /* In-form Test (Dry-run) button: initiates preview for current job */
  $('#rj-form-test').off('.rclonejobs').on('click.rclonejobs', function () {
    var orig = $('#f_orig').val(), name = $('#f_name').val().trim();
    var job = orig || name;
    if (!job) {
      rjPanel('rj-result', 'Please enter a valid job Name first to test.', true);
      return;
    }
    if (orig && D.jobs[orig]) {
      rjPanel('rj-result', 'Running preview test for "' + orig + '"...', false);
      rjRunPreview(orig);
      var $p = $('#rj-preview');
      if ($p.length) $p[0].scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    } else {
      rjPanel('rj-result', 'Saving "' + job + '" to start dry-run preview...', false);
      $('#rj-jobform').data('test_preview', true).trigger('submit');
    }
  });

  /* --- 8.8 Remote & Share Autocomplete Datalist --- */
  (function rjInitPathDatalist() {
    var $dl = $('#rj-paths-dl').empty();
    var rems = D.remotes || [], shares = D.shares || [];
    rems.forEach(function (r) {
      $dl.append($('<option></option>').val(r).text(r + ' (rclone remote)'));
    });
    shares.forEach(function (sh) {
      $dl.append($('<option></option>').val(sh).text(sh + ' (user share)'));
    });
  })();

  /* --- 8.9 Fleet Toolbar Filtering (Search Input & Status Pills) --- */
  var rjFilter = { text: '', status: 'all' };
  function rjApplyFilter() {
    var q = rjFilter.text.toLowerCase();
    $('#tab_rj_jobs tbody tr.rj-row').each(function () {
      var $tr = $(this), name = String($tr.data('job') || '');
      var j = D.jobs[name] || {};
      var en = (j.conf && j.conf.ENABLED !== 'no');
      var rc = (j.status && j.status.rc !== undefined && j.status.rc !== null && j.status.rc !== '') ? +j.status.rc : null;
      var failed = rc !== null && rc !== 0 && !(j.status && j.status.running);

      var matchStatus = true;
      if (rjFilter.status === 'active') matchStatus = en;
      else if (rjFilter.status === 'failed') matchStatus = failed;

      var matchText = true;
      if (q) {
        var hay = (name + ' ' + (j.conf ? (j.conf.SRC || '') + ' ' + (j.conf.DST || '') + ' ' + (j.conf.DESC || '') : '')).toLowerCase();
        matchText = hay.indexOf(q) >= 0;
      }
      $tr.toggle(matchStatus && matchText);
    });
  }
  $('#rj-filter-search').off('.rjfilter').on('input.rjfilter', function () {
    rjFilter.text = $(this).val().trim();
    rjApplyFilter();
  });
  $('.rj-filter-pill').off('.rjfilter').on('click.rjfilter', function () {
    $('.rj-filter-pill').removeClass('active');
    $(this).addClass('active');
    rjFilter.status = $(this).data('filter') || 'all';
    rjApplyFilter();
  });

  /* --- 8.10 Job Table Quick Switches & Action Buttons --- */

  /* Toggle job enabled/disabled directly from table switch */
  $(document).off('change.rjtoggle', '.rj-toggle-en').on('change.rjtoggle', '.rj-toggle-en', function () {
    var $chk = $(this);
    var job = $chk.data('job') || $chk.attr('data-job');
    var isChecked = $chk.is(':checked');
    var newEn = isChecked ? 'yes' : 'no';
    var $wrap = $chk.closest('.rj-switch');
    var $cell = $chk.closest('td');
    var $row = $chk.closest('tr');
    var $label = $cell.find('.rj-switch-text');

    $wrap.addClass('rj-busy');
    rjPost({ action: 'toggle_job', job: job, enabled: newEn }, function (res) {
      $wrap.removeClass('rj-busy');
      if (res && res.ok) {
        if (D.jobs && D.jobs[job] && D.jobs[job].conf) {
          D.jobs[job].conf.ENABLED = newEn;
        }
        if (newEn === 'yes') {
          $row.removeClass('rj-off');
          $label.text('ON').removeClass('off').addClass('on');
          $wrap.attr('title', 'Click to disable job');
        } else {
          $row.addClass('rj-off');
          $label.text('OFF').removeClass('on').addClass('off');
          $wrap.attr('title', 'Click to enable job');
        }
        var nEn = 0, total = 0;
        $('.rj-toggle-en').each(function () {
          total++;
          if ($(this).is(':checked')) nEn++;
        });
        $('button[data-filter="active"] .rj-pill-cnt').text(nEn);
        $('.rj-card:first .rj-card-sub').text(nEn + ' of ' + total + ' active');
        rjPanel('rj-result', 'Job "' + job + '" ' + (newEn === 'yes' ? 'enabled' : 'disabled') + '. Cron schedule updated.');
        setTimeout(function () { $('#rj-result').fadeOut(); }, 4000);
      } else {
        $chk.prop('checked', !isChecked);
        rjPanel('rj-result', 'ERROR: ' + (res && res.error ? res.error : 'Failed to toggle job'), true);
      }
    });
  });

  /* Toggle job dry-run mode directly from table switch */
  $(document).off('change.rjtoggle-dry', '.rj-toggle-dry').on('change.rjtoggle-dry', '.rj-toggle-dry', function () {
    var $chk = $(this);
    var job = $chk.data('job') || $chk.attr('data-job');
    var isChecked = $chk.is(':checked');
    var newDry = isChecked ? 'yes' : 'no';
    var $wrap = $chk.closest('.rj-switch');
    var $cell = $chk.closest('td');
    var $label = $cell.find('.rj-dry-text');

    $wrap.addClass('rj-busy');
    rjPost({ action: 'toggle_dryrun', job: job, dryrun: newDry }, function (res) {
      $wrap.removeClass('rj-busy');
      if (res && res.ok) {
        if (D.jobs && D.jobs[job] && D.jobs[job].conf) {
          D.jobs[job].conf.DRYRUN = newDry;
        }
        if (newDry === 'yes') {
          $label.text('DRY').removeClass('live').addClass('dry');
          $wrap.attr('title', 'Dry-run active (simulated) - click to toggle');
        } else {
          $label.text('LIVE').removeClass('dry').addClass('live');
          $wrap.attr('title', 'Live transfers active - click to toggle');
        }
        if ($('#rj-form-wrap').is(':visible') && $('.rj-row-editing').data('job') === job) {
          $('#f_dryrun').val(newDry);
        }
        rjPanel('rj-result', 'Job "' + job + '" dry-run mode set to ' + (newDry === 'yes' ? 'DRY (simulated)' : 'LIVE (real transfers)') + '.');
        setTimeout(function () { $('#rj-result').fadeOut(); }, 4000);
      } else {
        $chk.prop('checked', !isChecked);
        rjPanel('rj-result', 'ERROR: ' + (res && res.error ? res.error : 'Failed to toggle dry-run mode'), true);
      }
    });
  });

  /* Table row action buttons (Edit, Delete, Dry-run, Run, Stop, Log, History, Ack) */
  $(document).off('click.rjbtn', '.rj-btn').on('click.rjbtn', '.rj-btn', function () {
    var act = $(this).data('act') || $(this).attr('data-act');
    var job = $(this).data('job') || $(this).attr('data-job');
    if (act === 'edit') {
      var isEditingThis = $('#rj-form-wrap').is(':visible') && $('.rj-row-editing').data('job') === job;
      if (isEditingThis) {
        rjCloseForm();
        return;
      }
      var j = D.jobs[job];
      if (j) showForm('Edit job: ' + job, Object.assign({ name: job }, j));
      return;
    }
    if (act === 'del') {
      rjConfirm('Delete job "' + job + '"?',
                'Its schedule line is removed; config file is kept as a .removed-* backup; transfer data is never deleted here.',
                'Delete', true, function () {
        rjPost({ action: 'delete_job', job: job }, function (res) {
          rjPanel('rj-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
          if (res.ok) setTimeout(function () { location.reload(); }, 1200);
        });
      });
      return;
    }
    if (act === 'dry') { rjRunPreview(job); return; }
    if (act === 'run') {
      var doRun = function () {
        rjPost({ action: 'run_job', job: job }, function (res) {
          rjPanel('rj-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
        });
      };
      if (D.master !== 'no') {
        rjConfirm('Simulate "' + job + '"?',
                  'Master dry-run switch is ON, so this will only simulate.\n(Turn it off on the Alerts & Safety tab for real transfers.)',
                  'Run simulated', false, doRun);
      } else {
        rjConfirm('Run "' + job + '" FOR REAL now?',
                  'Scheduled safety still applies (dry-run gate + delete limits).',
                  'Run for real', true, doRun);
      }
      return;
    }
    if (act === 'stop') {
      var $btn = $(this);
      rjConfirm('Stop "' + job + '"?',
                'Terminates the live transfer now (recorded as rc=143, the log is kept).\nPartial progress stays on disk - the next run re-checks and resumes.',
                'Stop', true, function () {
        rjPost({ action: 'stop_job', job: job }, function (res) {
          if (res.ok) {
            $btn.prop('disabled', true).html('<i class="fa fa-spinner fa-spin"></i> stopping...');
            rjPanel('rj-result', 'Stop requested for "' + job + '" - the row returns to idle when the run records rc=143.');
            setTimeout(rjStatusRefresh, 1500);
          } else {
            rjPanel('rj-result', 'ERROR: ' + res.error, true);
            setTimeout(rjStatusRefresh, 400);
          }
        });
      });
      return;
    }
    if (act === 'log') {
      /* dedicated window, live-tailing via log.php; named so repeat clicks
         reuse the same window. Confinement + redaction stay in the engine. */
      var w = window.open('/plugins/rclone-jobs/log.php?job=' + encodeURIComponent(job),
                          'rjlog_' + job, 'width=1000,height=720,resizable,scrollbars');
      if (!w) rjPanel('rj-result', 'the log window was blocked by the browser - allow popups for this site', true);
      return;
    }
    if (act === 'hist') { rjShowHistory(job); return; }
    if (act === 'ack') { rjAckDialog(job); }
  });

  /* --- 8.12 Job Editor Form Submission (Save Job) --- */
  $('#rj-jobform').off('.rclonejobs').on('submit.rclonejobs', function (ev) {
    ev.preventDefault();
    var job = $('#f_orig').val() || $('#f_name').val().trim();
    if (!job) return;
    var cron = rjBuildCron();
    if (!cron) { schedSummary(); return; }
    var wantsPreview = $('#rj-jobform').data('test_preview') === true;
    $('#rj-jobform').data('test_preview', false);
    var data = {
      action: 'save_job', job: job,
      desc: $('#f_desc').val(), enabled: $('#f_enabled').val(), schedule: cron,
      engine: $('#f_engine').val(), mode: $('#f_mode').val(),
      src: $('#f_src').val().trim(), dst: $('#f_dst').val().trim(), script: $('#f_script').val().trim(),
      dryrun: $('#f_dryrun').val(), notify: $('#f_notify').val(),
      transfers: $('#f_transfers').val(), checkers: $('#f_checkers').val(),
      bwlimit: $('#f_bwlimit').val().trim(), maxdelete: $('#f_maxdelete').val(),
      warndelete: $('#f_warndelete').val(), backupdir: $('#f_backupdir').val().trim(),
      buffer_size: $('#f_buffersize').val().trim(),
      fast_list: $('#f_fastlist').val(),
      onedrive_chunk_size: $('#f_onedrive_chunksize').val().trim(),
      args: $('#f_args').val().trim()
    };
    var $sub = $('#rj-jobform input[type=submit]');
    if ($sub.prop('disabled')) return; /* double-submit guard (save previews take seconds) */
    $sub.prop('disabled', true).val('Saving...');
    rjPost(data, function (res) {
      $sub.prop('disabled', false).val('Save job');
      if (res.ok) {
        rjPanel('rj-result', res.msg, false);
        if (wantsPreview) {
          try { sessionStorage.setItem('rj_autopreview', job); } catch (e) { /* private mode: skip auto-preview */ }
        }
        setTimeout(function () { location.reload(); }, 1000);
      } else {
        rjPanel('rj-result', 'ERROR: ' + res.error, true);
      }
    });
  });

  /* --- 8.13 Alerts & Safety Settings Save & Notification Test --- */
  $('#rj-save-alerts').off('.rclonejobs').on('click.rclonejobs', function () {
    var $b = $(this);
    if ($b.prop('disabled')) return;
    $b.prop('disabled', true).val('Saving...');
    function numv(id, def) { var v = parseInt($('#' + id).val(), 10); return isNaN(v) ? def : v; }
    rjPost({
      action: 'save_alerts',
      master: $('#a_master').val(), quiet_start: $('#a_qstart').val(), quiet_end: $('#a_qend').val(),
      raw_hours: numv('a_rawhours', 24), raw_max: numv('a_rawmax', 500),
      hour_days: numv('a_hourdays', 7), hist_days: numv('a_hdays', 90),
      log_days: numv('a_logdays', 3), fail_days: numv('a_faildays', 14), log_max: numv('a_logmax', 300)
    }, function (res) {
      $b.prop('disabled', false).val('Save settings');
      rjPanel('rj-alerts-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
    });
  });
  $('#rj-nt-test').off('.rclonejobs').on('click.rclonejobs', function () {
    rjPanel('rj-alerts-result', 'sending test notification...', false);
    rjPost({ action: 'notify_test', level: $('#a_ntlevel').val() }, function (res) {
      rjPanel('rj-alerts-result', res.out || res.error || 'done', !res.ok);
    });
  });

  /* --- 8.14 Job Portability: Archive Export & Import ---
     Export builds a Blob download client-side; import sends
     the archive as base64 inside the urlencoded body (never multipart - the
     ajax CSRF path cannot read one) and the engine re-validates everything */
  $('#rj-export').off('.rclonejobs').on('click.rclonejobs', function () {
    var $b = $(this);
    if ($b.prop('disabled')) return;
    $b.prop('disabled', true).val('exporting...');
    rjPost({ action: 'export_jobs' }, function (res) {
      $b.prop('disabled', false).val('Download job set (.tgz)');
      if (!res.ok) { rjPanel('rj-alerts-result', 'ERROR: ' + (res.error || '?'), true); return; }
      try {
        var bin = atob(res.archive), arr = new Uint8Array(bin.length), i;
        for (i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
        var url = URL.createObjectURL(new Blob([arr], { type: 'application/gzip' }));
        var a = document.createElement('a');
        a.href = url; a.download = res.name || 'rclone-jobs-jobs.tgz';
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(function () { URL.revokeObjectURL(url); }, 5000);
        rjPanel('rj-alerts-result', 'Exported ' + res.count + ' job(s) -> ' + (res.name || 'archive') +
                '\nThe file holds job names, paths, schedules and script locations (no credentials).', false);
      } catch (e) { rjPanel('rj-alerts-result', 'ERROR: the browser could not build the download: ' + e, true); }
    });
  });
  $('#rj-import-btn').off('.rclonejobs').on('click.rclonejobs', function () { $('#a_import_file').trigger('click'); });
  $('#a_import_file').off('.rclonejobs').on('change.rclonejobs', function () {
    var f = this.files && this.files[0], self = this;
    self.value = ''; /* the File handle stays valid for the read */
    if (!f) return;
    if (f.size > 1048576) { rjPanel('rj-alerts-result', 'ERROR: archive is larger than 1 MiB - refusing.', true); return; }
    var rd = new FileReader();
    rd.onerror = function () { rjPanel('rj-alerts-result', 'ERROR: could not read the file', true); };
    rd.onload = function () {
      var b64 = String(rd.result).split(',').pop();
      var $b = $('#rj-import-btn');
      $b.prop('disabled', true).val('importing...');
      rjPost({ action: 'import_jobs', archive: b64, mode: $('#a_importmode').val() }, function (res) {
        $b.prop('disabled', false).val('Choose archive...');
        if (!res.ok) { rjPanel('rj-alerts-result', 'ERROR: ' + (res.error || '?'), true); return; }
        var msg = 'Import (' + res.mode + '): ' + res.added + ' added, ' + res.replaced + ' replaced, ' + res.skipped + ' kept.';
        if (res.conflicts && res.conflicts.length) msg += '\nConflicts left untouched (ask mode): ' + res.conflicts.join(', ') + '\nPick overwrite/keep and re-import if you want them changed.';
        if (res.rejected && res.rejected.length) msg += '\nRejected (never written): ' + res.rejected.join(', ');
        rjPanel('rj-alerts-result', msg, !!(res.rejected && res.rejected.length));
        if (res.added || res.replaced) setTimeout(function () { location.reload(); }, 1800);
      });
    };
    rd.readAsDataURL(f);
  });

  /* --- 8.15 Interactive Server & Remote Path Browser Modal --- */
  var rjB = { scope: 'local', path: '', parent: '', files: false, allowRclone: true, target: '', req: 0, built: false };

  function rjBrowseBuild() {
    if (rjB.built) return;
    /* solid panel color (theme-tinted, alpha flattened) + dark fallbacks */
    var css = '#rj-browse-ov{position:fixed;left:0;top:0;right:0;bottom:0;background:rgba(0,0,0,.55);z-index:9998;display:none}'
      + '#rj-browse{position:relative;width:560px;max-width:92vw;margin:6vh auto;background:' + rjSolidBg() + ';border:1px solid var(--border,#5a6570);border-radius:6px;color:var(--text,#e8e8e8);box-shadow:0 6px 24px rgba(0,0,0,.6);font-size:12px}'
      + '#rj-browse-head{display:flex;align-items:center;gap:6px;padding:8px 10px;border-bottom:1px solid var(--border,#444e57)}'
      + '#rj-browse-title{font-weight:bold;margin-right:auto}'
      + '.rj-b-tab{padding:3px 10px;border:1px solid var(--border,#5a6570);background:transparent;color:var(--text,#cfd6dc);cursor:pointer;border-radius:3px}'
      + '.rj-b-tab.on{background:#2e97c2;border-color:#2e97c2;color:#fff}'
      + '#rj-browse-pathbar{display:flex;align-items:center;gap:4px;padding:6px 10px;border-bottom:1px solid var(--border,#444e57);flex-wrap:wrap}'
      + '#rj-browse-crumbs{display:flex;gap:2px;flex-wrap:wrap;align-items:center}'
      + '.rj-b-crumb{cursor:pointer;color:#7fc7e8;text-decoration:underline}'
      + '#rj-browse-list{max-height:46vh;overflow:auto;padding:4px 0}'
      + '.rj-b-row{padding:5px 12px;cursor:pointer;white-space:nowrap;display:flex;gap:6px}'
      + '.rj-b-row:hover{background:#2e97c2;color:#fff}'
      + '.rj-b-row:hover .rj-b-ic{color:#fff}'
      + '.rj-b-row .rj-b-ic{width:14px;color:#c3ced8}'
      + '.rj-b-note{padding:8px 12px;color:#9aa7b2}'
      + '#rj-browse-foot{display:flex;align-items:center;gap:8px;padding:8px 10px;border-top:1px solid var(--border,#444e57)}'
      + '#rj-browse-cur{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:monospace;color:var(--text,#cfe3ef)}'
      + '.rj-b-x{background:transparent;border:none;color:var(--text,#cfd6dc);font-size:16px;cursor:pointer;line-height:1;padding:2px 6px}';
    $('<style>').text(css).appendTo('head');
    var ov = $('<div id="rj-browse-ov"></div>');
    var box = $('<div id="rj-browse" role="dialog" aria-modal="true"></div>');
    var head = $('<div id="rj-browse-head"></div>');
    head.append($('<span id="rj-browse-title">Select path</span>'));
    head.append($('<button type="button" class="rj-b-tab" id="rj-b-tab-local">Server</button>'));
    head.append($('<button type="button" class="rj-b-tab" id="rj-b-tab-rclone">Rclone remotes</button>'));
    head.append($('<button type="button" class="rj-b-x" id="rj-b-close" aria-label="Close">&#10005;</button>'));
    var pb = $('<div id="rj-browse-pathbar"></div>');
    pb.append($('<input type="button" value="&#8593; Up" id="rj-b-up">'));
    pb.append($('<span id="rj-browse-crumbs"></span>'));
    pb.append($('<input type="button" value="Refresh" id="rj-b-refresh" style="margin-left:auto">'));
    box.append(head, pb, $('<div id="rj-browse-list"></div>'));
    var foot = $('<div id="rj-browse-foot"></div>');
    foot.append($('<span id="rj-browse-cur"></span>'));
    foot.append($('<input type="button" value="Select this folder" id="rj-b-select" class="rj-btn">'));
    box.append(foot);
    ov.append(box).appendTo('body');
    rjB.built = true;
  }

  function rjBrowseOpen(target, opts) {
    rjBrowseBuild();
    opts = opts || {};
    rjB.target = target; rjB.files = !!opts.files; rjB.allowRclone = opts.rclone !== false;
    $('#rj-b-tab-rclone').toggle(rjB.allowRclone);
    var v = $('#' + target).val() || '';
    if (rjB.allowRclone && /^[A-Za-z0-9._-]+:/.test(v)) { rjB.scope = 'rclone'; rjB.path = v; }
    else { rjB.scope = 'local'; rjB.path = v.charAt(0) === '/' ? v : ''; }
    rjB.parent = '';
    $('#rj-browse-ov').fadeIn(80);
    $('#rj-b-close').trigger('focus');
    rjBrowseLoad(rjB.scope, rjB.path);
  }

  function rjBrowseClose() { rjB.req++; $('#rj-browse-ov').fadeOut(60); }

  function rjBrowseLoad(scope, path) {
    var req = ++rjB.req;
    rjB.scope = scope;
    $('#rj-b-tab-local').toggleClass('on', scope === 'local');
    $('#rj-b-tab-rclone').toggleClass('on', scope === 'rclone');
    $('#rj-browse-list').empty().append($('<div class="rj-b-note"></div>').text('loading ' + (path || '(roots)') + ' ...'));
    rjPost({ action: 'browse', scope: scope, path: path, files: rjB.files ? '1' : '' }, function (res) {
      if (req !== rjB.req) return;
      if (!res.ok) {
        $('#rj-browse-list').empty().append($('<div class="rj-b-note" style="color:#e6867e"></div>')
          .text('ERROR: ' + (res.error || '?') + ' - use Up / tabs / crumbs to go back, or type the path manually.'));
        return;
      }
      rjBrowseRender(res);
    });
  }

  function rjBrowseCrumb(c, label, scope, path) {
    if (c.children().length) c.append($('<span style="color:#9aa7b2">/</span>'));
    c.append($('<span class="rj-b-crumb"></span>').text(label).data({ scope: scope, path: path }));
  }

  function rjBrowseCrumbs(res) {
    var c = $('#rj-browse-crumbs').empty(), acc;
    if (res.scope === 'local') {
      rjBrowseCrumb(c, 'roots', 'local', '');
      acc = '';
      (res.path || '').split('/').filter(Boolean).forEach(function (p) {
        acc += '/' + p; rjBrowseCrumb(c, p, 'local', acc);
      });
    } else {
      rjBrowseCrumb(c, 'remotes', 'rclone', '');
      if (res.path) {
        var m = /^([^:]+):(.*)$/.exec(res.path);
        rjBrowseCrumb(c, m[1] + ':', 'rclone', m[1] + ':');
        acc = m[1] + ':';
        (m[2] || '').split('/').filter(Boolean).forEach(function (p) {
          acc += '/' + p; rjBrowseCrumb(c, p, 'rclone', acc);
        });
      }
    }
  }

  function rjBrowseRender(res) {
    rjB.path = res.path || ''; rjB.parent = res.parent || ''; rjB.scope = res.scope;
    rjBrowseCrumbs(res);
    $('#rj-browse-cur').text(rjB.path || (res.scope === 'rclone' ? '(pick a remote first)' : '(pick a root)'));
    var $l = $('#rj-browse-list').empty();
    var ents = res.entries || [];
    if (!ents.length) $l.append($('<div class="rj-b-note"></div>').text('empty folder'));
    ents.forEach(function (en) {
      var isFile = rjB.files && res.scope === 'local' && /\.sh$/i.test(en.name);
      var $row = $('<div class="rj-b-row"></div>');
      $('<span class="rj-b-ic"></span>').text(isFile ? '-' : '>').appendTo($row);
      $('<span></span>').text(en.name).appendTo($row);
      $row.data('path', en.path).data('file', isFile);
      $row.on('click', function () {
        if ($(this).data('file')) rjBrowsePick($(this).data('path'));
        else rjBrowseLoad(rjB.scope, $(this).data('path'));
      }).on('dblclick', function () { rjBrowsePick($(this).data('path')); });
      $l.append($row);
    });
    if (res.truncated) $l.append($('<div class="rj-b-note"></div>').text('listing truncated at 500 entries - narrow down or type the path manually'));
  }

  function rjBrowsePick(p) {
    $('#' + rjB.target).val(p).focus();
    rjBrowseClose();
  }

  $(document).on('click.rclonejobs', '.rj-browse-btn', function () {
    var t = String($(this).data('target'));
    rjBrowseOpen(t, { files: t === 'f_script', rclone: t !== 'f_script' });
  });
  $(document).on('click.rclonejobs', '#rj-browse-ov', function (ev) { if (ev.target === this) rjBrowseClose(); });
  $(document).on('click.rclonejobs', '#rj-b-close', rjBrowseClose);
  $(document).on('click.rclonejobs', '#rj-b-tab-local', function () { if (rjB.scope !== 'local') rjBrowseLoad('local', ''); });
  $(document).on('click.rclonejobs', '#rj-b-tab-rclone', function () { if (rjB.scope !== 'rclone') rjBrowseLoad('rclone', ''); });
  $(document).on('click.rclonejobs', '#rj-b-up', function () { rjBrowseLoad(rjB.scope, rjB.parent || ''); });
  $(document).on('click.rclonejobs', '#rj-b-refresh', function () { rjBrowseLoad(rjB.scope, rjB.path); });
  $(document).on('click.rclonejobs', '#rj-b-select', function () { if (rjB.path) rjBrowsePick(rjB.path); });
  $(document).on('click.rclonejobs', '.rj-b-crumb', function () { var d = $(this).data(); rjBrowseLoad(d.scope, d.path); });
  $(document).on('keydown.rclonejobs', function (ev) {
    if (!rjB.built || !$('#rj-browse-ov').is(':visible')) return;
    if (ev.key === 'Escape') { rjBrowseClose(); return; }
    if (ev.key === 'Tab') { /* focus trap inside the dialog */
      var $f = $('#rj-browse').find('button:visible,input[type="button"]:visible');
      if (!$f.length) return;
      ev.preventDefault();
      var i = $f.index(document.activeElement);
      var n = ev.shiftKey ? (i <= 0 ? $f.length - 1 : i - 1) : (i >= $f.length - 1 ? 0 : i + 1);
      $f.eq(n).trigger('focus');
    }
  });

  /* --- 8.16 Preview Cancel & Post-Save Auto-Preview Trigger --- */
  $('#rj-preview-cancel').off('.rclonejobs').on('click.rclonejobs', function () {
    var $b = $(this);
    if ($b.prop('disabled')) return;
    $b.prop('disabled', true).val('cancelling...');
    rjPost({ action: 'task_cancel', job: rjP.job }, function (res) {
      $b.prop('disabled', false).val('Cancel preview');
      if (!res.ok) rjPreviewShow('ERROR: ' + (res.error || '?'), true, false);
      /* the running poll picks up the 143 exit and reports the partial output */
    });
  });
  var rjAutoPreview = null;
  try { rjAutoPreview = sessionStorage.getItem('rj_autopreview'); if (rjAutoPreview) sessionStorage.removeItem('rj_autopreview'); } catch (e) { rjAutoPreview = null; }
  if (rjAutoPreview && D.jobs[rjAutoPreview]) rjRunPreview(rjAutoPreview);

  /* --- 8.17 Hourly Transfer Chart Accordion Toggle --- */
  $('#rj-chart-toggle').off('.rclonejobs').on('click.rclonejobs', function () {
    var $body = $('#rj-chart-body');
    var $icon = $(this).find('i');
    if ($body.is(':visible')) {
      $body.slideUp(180);
      $icon.removeClass('fa-chevron-up').addClass('fa-chevron-down');
    } else {
      $body.slideDown(180);
      $icon.removeClass('fa-chevron-down').addClass('fa-chevron-up');
    }
  });

  /* --- 8.18 Doctor Diagnostic Tool --- */
  $('#rj-doctor').off('.rclonejobs').on('click.rclonejobs', function () {
    var $b = $(this); $b.prop('disabled', true).val('running...');
    $('#rj-doctor-pre').text('running tests (~seconds)...');
    rjPost({ action: 'doctor', notify: $('#rj-doctor-notify').is(':checked') ? 'yes' : 'no' }, function (res) {
      $b.prop('disabled', false).val('Run doctor');
      $('#rj-doctor-pre').text(res.out || res.error || 'no output');
    });
  });

  /* --- 8.19 Live Status SSE Connection Startup & Teardown ---
     Opened only after everything else is bound and rendered -
     a dead socket must never delay or break the page */
  rjLiveStart();
  $(window).on('beforeunload.rjlive', function () { if (rjLive.es) { try { rjLive.es.close(); } catch (e) { /* noop */ } } });
});
