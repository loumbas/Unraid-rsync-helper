/* rclone-jobs v{{VERSION}} - WebUI glue (jQuery provided by the Unraid webgui) */
'use strict';

function rjPost(data, cb) {
  data.csrf_token = (typeof rj_csrf !== 'undefined') ? rj_csrf : '';
  $.post('/plugins/rclone-jobs/ajax.php', data)
    .done(function (res) { cb(res); })
    .fail(function (x) { cb({ ok: false, error: 'ajax failed: ' + (x.status || '?') + ' ' + (x.responseText || '').substring(0, 200) }); });
}

function rjPanel(id, text, isError) {
  var p = $('#' + id);
  p.find('pre').text(text).css('color', isError ? '#e6867e' : '');
  p.show();
}

function rjData() {
  /* never let a malformed/missing state blob kill the ready handler */
  var d = null;
  try { d = JSON.parse($('#rj-data').text()); } catch (e) { d = null; }
  if (!d || typeof d !== 'object') d = {};
  if (!d.jobs || typeof d.jobs !== 'object') d.jobs = {};
  if (!d.quiet || typeof d.quiet !== 'object') d.quiet = { start: '23:00', end: '07:00' };
  if (!d.telegram || typeof d.telegram !== 'object') d.telegram = {};
  if (d.master === undefined) d.master = 'yes';
  return d;
}

/* docs pattern: swal (red confirm for destructive ops) with native confirm fallback */
function rjConfirm(title, text, btn, danger, cb) {
  if (typeof swal === 'function') {
    swal({ title: title, text: text, type: 'warning', showCancelButton: true,
           confirmButtonText: btn, cancelButtonText: 'Cancel',
           confirmButtonColor: danger ? '#d33' : '#2e97c2' },
         function (ok) { if (ok) cb(); });
  } else if (window.confirm(title + '\n' + text + '\n\n-> ' + btn + '?')) { cb(); }
}

$(function () {
  var D = rjData();

  /* tabbed layout: state-setting (not toggling) so it is safe alongside any
     tab js the platform itself may attach to ul.tabs; keeps #tab_rj_* deep links */
  (function rjTabs() {
    var $ul = $('ul.tabs');
    if (!$ul.length) return;
    var $links = $ul.find('a[href^="#"]');
    if (!$links.length) return;
    var ids = $links.map(function () { return this.hash; }).get();
    function activate(hash) {
      $links.each(function () { $(this).parent().toggleClass('active', this.hash === hash); });
      ids.forEach(function (id) { var $d = $(id); if ($d.length) $d.toggle(id === hash); });
    }
    $links.off('.rjtab').on('click.rjtab', function (ev) {
      ev.preventDefault();
      activate(this.hash);
      if (location.hash !== this.hash) history.replaceState(null, '', this.hash);
    });
    activate(ids.indexOf(location.hash) >= 0 ? location.hash : ids[0]);
  })();

  /* fill Alerts tab from server state */
  $('#a_master').val(D.master === 'no' ? 'no' : 'yes');
  $('#a_qstart').val(D.quiet.start);
  $('#a_qend').val(D.quiet.end);
  $('#a_tg').val(D.telegram.enabled === 'yes' ? 'yes' : 'no');
  $('#a_chatid').val(D.telegram.chat_id);
  $('#a_token_state').text(D.telegram.token_set ? 'a token is stored (leave blank to keep it)' : 'no token stored');

  /* engine-dependent form rows */
  function engRows() {
    var e = $('#f_engine').val();
    $('.rj-eng').toggle(e !== 'custom');
    $('.rj-custom').toggle(e === 'custom');
  }
  $('#f_engine').off('.rclonejobs').on('change.rclonejobs', engRows);
  engRows();

  /* storage-overlap hint: client-side mirror of the engine's overlap_check */
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

  function showForm(title, j) {
    $('#rj-form-title').text(title);
    $('#f_orig').val(j ? j.name : '');
    $('#f_name').val(j ? j.name : '').prop('disabled', !!j);
    $('#f_desc').val(j && j.conf.DESC ? j.conf.DESC : '');
    $('#f_enabled').val(j && j.conf.ENABLED === 'no' ? 'no' : 'yes');
    $('#f_schedule').val(j && j.conf.SCHEDULE ? j.conf.SCHEDULE : '');
    $('#f_engine').val(j && j.conf.ENGINE ? j.conf.ENGINE : 'rclone');
    $('#f_mode').val(j && j.conf.MODE ? j.conf.MODE : 'sync');
    $('#f_src').val(j && j.conf.SRC ? j.conf.SRC : '');
    $('#f_dst').val(j && j.conf.DST ? j.conf.DST : '');
    $('#f_script').val(j && j.conf.CUSTOM_SCRIPT ? j.conf.CUSTOM_SCRIPT : '');
    $('#f_dryrun').val(j && j.conf.DRYRUN === 'no' ? 'no' : 'yes');
    $('#f_transfers').val(j && j.conf.TRANSFERS ? j.conf.TRANSFERS : 4);
    $('#f_checkers').val(j && j.conf.CHECKERS ? j.conf.CHECKERS : 8);
    $('#f_bwlimit').val(j && j.conf.BWLIMIT ? j.conf.BWLIMIT : '');
    $('#f_maxdelete').val(j && j.conf.MAXDELETE !== undefined ? j.conf.MAXDELETE : 100);
    $('#f_warndelete').val(j && j.conf.WARN_DELETE !== undefined ? j.conf.WARN_DELETE : 100);
    $('#f_backupdir').val(j && j.conf.BACKUPDIR ? j.conf.BACKUPDIR : '');
    engRows();
    rjOvHint();
    $('#rj-form-title')[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  $('#rj-form-cancel').off('.rclonejobs').on('click.rclonejobs', function () {
    showForm('Add job', null);
    $('#rj-result').hide();
  });

  /* table buttons */
  $('.rj-btn').off('.rclonejobs').on('click.rclonejobs', function () {
    var act = $(this).data('act'), job = $(this).data('job');
    if (act === 'edit') {
      var j = D.jobs[job]; if (j) showForm('Edit job: ' + job, Object.assign({ name: job }, j));
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
    if (act === 'dry') {
      var $b = $(this); $b.val('...').prop('disabled', true);
      rjPost({ action: 'run_dry', job: job }, function (res) {
        $b.val('Dry-run').prop('disabled', false);
        rjPanel('rj-preview', (res.out || res.error || ''), !res.ok);
      });
      return;
    }
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
    if (act === 'ack') {
      var t = prompt('This dry-run wants to DELETE files.\nType the job name exactly (' + job + ') to acknowledge:');
      if (t === null) return;
      rjPost({ action: 'ack_job', job: job, confirm: t }, function (res) {
        rjPanel('rj-result', res.ok ? (res.out || 'acknowledged') : ('ERROR: ' + res.error), !res.ok);
        if (res.ok) setTimeout(function () { location.reload(); }, 900);
      });
    }
  });

  /* save job */
  $('#rj-jobform').off('.rclonejobs').on('submit.rclonejobs', function (ev) {
    ev.preventDefault();
    var job = $('#f_orig').val() || $('#f_name').val().trim();
    if (!job) return;
    var data = {
      action: 'save_job', job: job,
      desc: $('#f_desc').val(), enabled: $('#f_enabled').val(), schedule: $('#f_schedule').val(),
      engine: $('#f_engine').val(), mode: $('#f_mode').val(),
      src: $('#f_src').val().trim(), dst: $('#f_dst').val().trim(), script: $('#f_script').val().trim(),
      dryrun: $('#f_dryrun').val(), transfers: $('#f_transfers').val(), checkers: $('#f_checkers').val(),
      bwlimit: $('#f_bwlimit').val().trim(), maxdelete: $('#f_maxdelete').val(),
      warndelete: $('#f_warndelete').val(), backupdir: $('#f_backupdir').val().trim()
    };
    rjPost(data, function (res) {
      if (res.ok) {
        rjPanel('rj-preview', res.preview || res.msg, false);
        rjPanel('rj-result', res.msg, false);
        setTimeout(function () { location.reload(); }, 2500);
      } else {
        rjPanel('rj-result', 'ERROR: ' + res.error, true);
      }
    });
  });

  /* alerts tab */
  $('#rj-save-alerts').off('.rclonejobs').on('click.rclonejobs', function () {
    rjPost({
      action: 'save_alerts',
      master: $('#a_master').val(), quiet_start: $('#a_qstart').val(), quiet_end: $('#a_qend').val(),
      tg_enabled: $('#a_tg').val(), tg_chat_id: $('#a_chatid').val(), tg_token: $('#a_token').val()
    }, function (res) {
      rjPanel('rj-alerts-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
      if (res.ok) { $('#a_token').val(''); }
    });
  });
  $('#rj-tg-test').off('.rclonejobs').on('click.rclonejobs', function () {
    rjPanel('rj-alerts-result', 'sending...', false);
    rjPost({ action: 'tg_test' }, function (res) {
      rjPanel('rj-alerts-result', res.out || res.error || 'done', !res.ok);
    });
  });

  /* ---------------- path browser modal ---------------- */
  var rjB = { scope: 'local', path: '', parent: '', files: false, allowRclone: true, target: '', req: 0, built: false };

  function rjBrowseBuild() {
    if (rjB.built) return;
    var css = '#rj-browse-ov{position:fixed;left:0;top:0;right:0;bottom:0;background:rgba(0,0,0,.55);z-index:9998;display:none}'
      + '#rj-browse{position:relative;width:560px;max-width:92vw;margin:6vh auto;background:#23292e;border:1px solid #5a6570;border-radius:6px;color:#e8e8e8;box-shadow:0 6px 24px rgba(0,0,0,.6);font-size:12px}'
      + '#rj-browse-head{display:flex;align-items:center;gap:6px;padding:8px 10px;border-bottom:1px solid #444e57}'
      + '#rj-browse-title{font-weight:bold;margin-right:auto}'
      + '.rj-b-tab{padding:3px 10px;border:1px solid #5a6570;background:transparent;color:#cfd6dc;cursor:pointer;border-radius:3px}'
      + '.rj-b-tab.on{background:#2e97c2;border-color:#2e97c2;color:#fff}'
      + '#rj-browse-pathbar{display:flex;align-items:center;gap:4px;padding:6px 10px;border-bottom:1px solid #444e57;flex-wrap:wrap}'
      + '#rj-browse-crumbs{display:flex;gap:2px;flex-wrap:wrap;align-items:center}'
      + '.rj-b-crumb{cursor:pointer;color:#7fc7e8;text-decoration:underline}'
      + '#rj-browse-list{max-height:46vh;overflow:auto;padding:4px 0}'
      + '.rj-b-row{padding:3px 12px;cursor:pointer;white-space:nowrap;display:flex;gap:6px}'
      + '.rj-b-row:hover{background:#2e97c2;color:#fff}'
      + '.rj-b-row:hover .rj-b-ic{color:#fff}'
      + '.rj-b-row .rj-b-ic{width:14px;color:#9aa7b2}'
      + '.rj-b-note{padding:8px 12px;color:#9aa7b2}'
      + '#rj-browse-foot{display:flex;align-items:center;gap:8px;padding:8px 10px;border-top:1px solid #444e57}'
      + '#rj-browse-cur{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:monospace;color:#cfe3ef}'
      + '.rj-b-x{background:transparent;border:none;color:#cfd6dc;font-size:16px;cursor:pointer;line-height:1;padding:2px 6px}';
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

  /* doctor tab */
  $('#rj-doctor').off('.rclonejobs').on('click.rclonejobs', function () {
    var $b = $(this); $b.prop('disabled', true).val('running...');
    $('#rj-doctor-pre').text('running tests (~seconds)...');
    rjPost({ action: 'doctor', telegram: $('#rj-doctor-tg').is(':checked') ? 'yes' : 'no' }, function (res) {
      $b.prop('disabled', false).val('Run doctor');
      $('#rj-doctor-pre').text(res.out || res.error || 'no output');
    });
  });
});
