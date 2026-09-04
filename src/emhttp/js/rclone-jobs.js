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
  try { return JSON.parse($('#rj-data').text()); } catch (e) { return { jobs: {} }; }
}

$(function () {
  var D = rjData();

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
  $('#f_engine').on('change', engRows);
  engRows();

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
    $('#rj-form-title')[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  $('#rj-form-cancel').on('click', function () {
    showForm('Add job', null);
    $('#rj-result').hide();
  });

  /* table buttons */
  $('.rj-btn').on('click', function () {
    var act = $(this).data('act'), job = $(this).data('job');
    if (act === 'edit') {
      var j = D.jobs[job]; if (j) showForm('Edit job: ' + job, Object.assign({ name: job }, j));
      return;
    }
    if (act === 'del') {
      if (!confirm('Delete job "' + job + '"?\nIts schedule line is removed; config file is kept as a .removed-* backup; transfer data is never deleted here.')) return;
      rjPost({ action: 'delete_job', job: job }, function (res) {
        rjPanel('rj-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
        if (res.ok) setTimeout(function () { location.reload(); }, 1200);
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
      if (D.master !== 'no') {
        if (!confirm('Master dry-run switch is ON, so this will only simulate.\n(Turn it off on the Alerts & Safety tab for real transfers.)\n\nRun simulated now?')) return;
      } else if (!confirm('Run "' + job + '" FOR REAL now?\nScheduled safety still applies (dry-run gate + delete limits).')) return;
      rjPost({ action: 'run_job', job: job }, function (res) {
        rjPanel('rj-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
      });
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
  $('#rj-jobform').on('submit', function (ev) {
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
  $('#rj-save-alerts').on('click', function () {
    rjPost({
      action: 'save_alerts',
      master: $('#a_master').val(), quiet_start: $('#a_qstart').val(), quiet_end: $('#a_qend').val(),
      tg_enabled: $('#a_tg').val(), tg_chat_id: $('#a_chatid').val(), tg_token: $('#a_token').val()
    }, function (res) {
      rjPanel('rj-alerts-result', res.ok ? res.msg : ('ERROR: ' + res.error), !res.ok);
      if (res.ok) { $('#a_token').val(''); }
    });
  });
  $('#rj-tg-test').on('click', function () {
    rjPanel('rj-alerts-result', 'sending...', false);
    rjPost({ action: 'tg_test' }, function (res) {
      rjPanel('rj-alerts-result', res.out || res.error || 'done', !res.ok);
    });
  });

  /* doctor tab */
  $('#rj-doctor').on('click', function () {
    var $b = $(this); $b.prop('disabled', true).val('running...');
    $('#rj-doctor-pre').text('running tests (~seconds)...');
    rjPost({ action: 'doctor', telegram: $('#rj-doctor-tg').is(':checked') ? 'yes' : 'no' }, function (res) {
      $b.prop('disabled', false).val('Run doctor');
      $('#rj-doctor-pre').text(res.out || res.error || 'no output');
    });
  });
});
