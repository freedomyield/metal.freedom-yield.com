#!/usr/bin/env python3
"""Unit tests for scripts/ops/b6-enable-metal-anomalies-cron.py v2.

v2 redesign covers: separated install (B0_OLD → B0_NEW) + apply (B0_NEW
→ ACTIVE) transitions, trigger (i) split into i1 (crontab parse) + i2
(job runtime error), and primary/corroborating selection.

Run from repo root:
  python3 tests/ops/test_b6_enable_cron.py
Or via the script's --self-test entry point:
  python3 scripts/ops/b6-enable-metal-anomalies-cron.py --self-test
"""
import datetime
import hashlib
import importlib.util
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.normpath(os.path.join(HERE, '..', '..', 'scripts', 'ops', 'b6-enable-metal-anomalies-cron.py'))
_spec = importlib.util.spec_from_file_location('b6_enable_cron', SCRIPT_PATH)
b6 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(b6)


class TestEmbeddedBaselines(unittest.TestCase):

    def test_b0_old_sha(self):
        self.assertEqual(hashlib.sha256(b6.B0_OLD).hexdigest(), b6.B0_OLD_SHA)

    def test_b0_new_sha(self):
        self.assertEqual(hashlib.sha256(b6.B0_NEW).hexdigest(), b6.B0_NEW_SHA)

    def test_active_sha(self):
        self.assertEqual(hashlib.sha256(b6.ACTIVE).hexdigest(), b6.ACTIVE_SHA)

    def test_b0_old_size(self):
        self.assertEqual(len(b6.B0_OLD), 420)

    def test_b0_new_size(self):
        self.assertEqual(len(b6.B0_NEW), 461)
        self.assertEqual(len(b6.B0_NEW) - len(b6.B0_OLD), 41)  # = len('ANOMALY_STATE_DIR=/var/lib/freedom-yield\n')

    def test_active_size(self):
        self.assertEqual(len(b6.ACTIVE), 459)
        self.assertEqual(len(b6.ACTIVE) - len(b6.B0_NEW), -2)  # = remove "# "

    def test_b0_new_has_exactly_one_env_assignment(self):
        lines = b6.B0_NEW.decode().splitlines(keepends=True)
        self.assertEqual(lines.count(b6.ENV_LINE), 1)
        self.assertEqual(lines.count(b6.NTFY_ENV_LINE), 1)

    def test_b0_new_target_still_commented(self):
        lines = b6.B0_NEW.decode().splitlines(keepends=True)
        self.assertEqual(lines.count(b6.OLD_LINE), 1)
        self.assertEqual(lines.count(b6.NEW_LINE), 0)

    def test_active_target_uncommented(self):
        lines = b6.ACTIVE.decode().splitlines(keepends=True)
        self.assertEqual(lines.count(b6.OLD_LINE), 0)
        self.assertEqual(lines.count(b6.NEW_LINE), 1)


class TestIdentifyState(unittest.TestCase):

    def test_b0_old(self):
        self.assertEqual(b6.identify_state(b6.B0_OLD), 'B0_OLD')

    def test_b0_new(self):
        self.assertEqual(b6.identify_state(b6.B0_NEW), 'B0_NEW')

    def test_active(self):
        self.assertEqual(b6.identify_state(b6.ACTIVE), 'ACTIVE')

    def test_unknown(self):
        self.assertEqual(b6.identify_state(b'garbage\n'), 'UNKNOWN')

    def test_b0_new_with_extra_byte_is_unknown(self):
        # Byte-equality is strict — even a single extra byte is UNKNOWN.
        self.assertEqual(b6.identify_state(b6.B0_NEW + b'\n'), 'UNKNOWN')


class TestComputeInstallProposed(unittest.TestCase):

    def test_b0_old_yields_b0_new(self):
        c = b6.compute_install_proposed(b6.B0_OLD)
        self.assertTrue(c['precondition_ok'])
        self.assertEqual(c['proposed_bytes'], b6.B0_NEW)
        self.assertEqual(c['proposed_sha'], b6.B0_NEW_SHA)

    def test_b0_new_input_refuses(self):
        c = b6.compute_install_proposed(b6.B0_NEW)
        self.assertFalse(c['precondition_ok'])
        self.assertIsNone(c['proposed_bytes'])

    def test_active_input_refuses(self):
        c = b6.compute_install_proposed(b6.ACTIVE)
        self.assertFalse(c['precondition_ok'])

    def test_corrupt_input_refuses(self):
        c = b6.compute_install_proposed(b'random\n')
        self.assertFalse(c['precondition_ok'])


class TestComputeApplyProposed(unittest.TestCase):

    def test_old_baseline_refuses(self):
        """v2 explicitly refuses to apply from B0_OLD (= the v1 baseline)."""
        c = b6.compute_proposed(b6.B0_OLD)
        self.assertFalse(c['precondition_ok'])
        self.assertIn('B0_NEW', c['precondition_msg'])

    def test_new_baseline_yields_active(self):
        c = b6.compute_proposed(b6.B0_NEW)
        self.assertTrue(c['precondition_ok'])
        self.assertEqual(c['proposed_bytes'], b6.ACTIVE)
        self.assertEqual(c['proposed_sha'], b6.ACTIVE_SHA)
        self.assertEqual(c['old_count_before'], 1)
        self.assertEqual(c['new_count_before'], 0)
        self.assertEqual(c['env_count'], 1)

    def test_active_input_refuses(self):
        c = b6.compute_proposed(b6.ACTIVE)
        self.assertFalse(c['precondition_ok'])

    def test_missing_anomaly_state_dir_refuses(self):
        """B0_OLD lacks ANOMALY_STATE_DIR; activation must be refused."""
        c = b6.compute_proposed(b6.B0_OLD)
        self.assertFalse(c['precondition_ok'])

    def test_duplicate_env_assignment_refuses(self):
        """Two ANOMALY_STATE_DIR lines is not the canonical B0_NEW; refuse."""
        duplicated = b6.B0_NEW + b6.ENV_LINE.encode()
        c = b6.compute_proposed(duplicated)
        self.assertFalse(c['precondition_ok'])

    def test_wrong_state_dir_refuses(self):
        """ANOMALY_STATE_DIR pointed at a different path is not canonical; refuse."""
        wrong = b6.B0_NEW.replace(
            b'ANOMALY_STATE_DIR=/var/lib/freedom-yield\n',
            b'ANOMALY_STATE_DIR=/wrong/path\n',
        )
        c = b6.compute_proposed(wrong)
        self.assertFalse(c['precondition_ok'])

    def test_zero_commented_targets_refuses(self):
        """If the target line isn't present (already active or missing), refuse."""
        no_commented = b6.B0_NEW.replace(b6.OLD_LINE.encode(), b'')
        c = b6.compute_proposed(no_commented)
        self.assertFalse(c['precondition_ok'])

    def test_two_commented_targets_refuses(self):
        """Duplicate commented target lines is not canonical; refuse."""
        two_commented = b6.B0_NEW + b6.OLD_LINE.encode()
        c = b6.compute_proposed(two_commented)
        self.assertFalse(c['precondition_ok'])

    def test_active_line_coexisting_refuses(self):
        """Having BOTH commented and active forms is not canonical; refuse."""
        coexist = b6.B0_NEW + b6.NEW_LINE.encode()
        c = b6.compute_proposed(coexist)
        self.assertFalse(c['precondition_ok'])

    def test_substring_overlap_not_false_positive(self):
        """NEW_LINE substring inside OLD_LINE doesn't confuse the element count."""
        text = b6.B0_NEW.decode()
        # raw substring count would give 1 (= NEW_LINE inside OLD_LINE)
        self.assertEqual(text.count(b6.NEW_LINE), 1)
        # element count correctly gives 0
        self.assertEqual(text.splitlines(keepends=True).count(b6.NEW_LINE), 0)


class TestAtomicWrite(unittest.TestCase):

    def test_byte_equal_after_write(self):
        with tempfile.NamedTemporaryFile(delete=False) as t:
            path = t.name
        try:
            payload = b'alpha\nbeta\n'
            b6.atomic_write(path, payload, perm=0o644, uid=os.geteuid(), gid=os.getegid())
            self.assertEqual(open(path, 'rb').read(), payload)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o644)
        finally:
            os.unlink(path)

    def test_install_failure_preserves_original(self):
        """If atomic_write fails (= tmp path unwritable), original bytes survive."""
        with tempfile.NamedTemporaryFile(delete=False) as t:
            path = t.name
        try:
            original = b'original-content\n'
            with open(path, 'wb') as f:
                f.write(original)
            # Force failure by passing an invalid uid/gid. Skip if running as
            # root because root can chown anything.
            if os.geteuid() == 0:
                self.skipTest('running as root; fchown failure not reproducible')
            try:
                # fchown to a uid we don't own → PermissionError
                b6.atomic_write(path, b'new-content\n', perm=0o644, uid=0, gid=0)
            except (PermissionError, OSError):
                pass
            # Original bytes still on disk.
            self.assertEqual(open(path, 'rb').read(), original)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass


class TestWaitSecondsBoundary(unittest.TestCase):

    def test_mid_window(self):
        t = datetime.datetime(2026, 6, 24, 10, 7, 15)
        self.assertEqual(b6._next_5min_wait_seconds(t), 3 * 60 - 15 + 120)

    def test_just_after_boundary(self):
        t = datetime.datetime(2026, 6, 24, 10, 5, 1)
        self.assertEqual(b6._next_5min_wait_seconds(t), 5 * 60 - 1 + 120)

    def test_hour_wrap(self):
        t = datetime.datetime(2026, 6, 24, 10, 58, 0)
        self.assertEqual(b6._next_5min_wait_seconds(t), 240)


class TestClassifyAnomalyLog(unittest.TestCase):

    def test_normal_tick(self):
        """Normal tick = 1 success line + canonical-equal log → no error counts."""
        log = (
            '[K-2] age=12s (now=1 obs_epoch=1 max=600 skew_max=60)\n'
            '[K-4] lock acquired\n'
            '[K-3] candidate == original (canonical); no commit, mtime preserved\n'
        )
        c = b6.classify_anomaly_log(log)
        self.assertEqual(c['success_count'], 1)
        self.assertEqual(c['gate_errors_count'], 0)
        self.assertEqual(c['job_runtime_error_count'], 0)
        self.assertEqual(c['k3_equal_count'], 1)
        self.assertEqual(c['k3_commit_count'], 0)

    def test_incident_anomaly_state_dir_required(self):
        """2026-06-24 incident pattern: only the bash error, no success."""
        log = '/home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh: line 45: ANOMALY_STATE_DIR: ANOMALY_STATE_DIR is required\n'
        c = b6.classify_anomaly_log(log)
        self.assertEqual(c['success_count'], 0)
        # Both 'line 45:' and 'is required' patterns match → at least 2 hits
        self.assertGreaterEqual(c['job_runtime_error_count'], 1)
        # Crucially: NOT classified as a K-N gate error.
        self.assertEqual(c['gate_errors_count'], 0)
        self.assertIn('line 45', c['sample_error_line'])

    def test_gate_error_k1(self):
        log = '[K-1] STATUS_JSON missing: /path/to/server-status.json\n'
        c = b6.classify_anomaly_log(log)
        self.assertEqual(c['gate_errors_count'], 1)
        # 'line N:' / 'is required' / etc. not present → job_runtime stays 0.
        self.assertEqual(c['job_runtime_error_count'], 0)

    def test_k3_commit(self):
        log = '[K-4] lock acquired\n[K-3] committed candidate to /var/lib/freedom-yield/anomaly-state.json\n'
        c = b6.classify_anomaly_log(log)
        self.assertEqual(c['k3_commit_count'], 1)
        self.assertEqual(c['success_count'], 1)

    def test_empty_log(self):
        c = b6.classify_anomaly_log('')
        self.assertEqual(c['success_count'], 0)
        self.assertEqual(c['gate_errors_count'], 0)
        self.assertEqual(c['job_runtime_error_count'], 0)


class TestClassifyCronJournal(unittest.TestCase):

    def test_normal_job_launch(self):
        """A clean CMD log entry is NOT a crontab parse error."""
        log = 'Jun 24 10:00:01 host CRON[111]: (deploy) CMD (bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1)\n'
        c = b6.classify_cron_journal(log)
        self.assertEqual(c['job_start_count'], 1)
        self.assertEqual(c['crontab_load_error_count'], 0)

    def test_genuine_crontab_parse_error(self):
        """Explicit '(CRON) ERROR' pattern fires i1."""
        log = 'Jun 24 10:30:00 host cron[123]: (CRON) ERROR (failed to read crontab: bad day-of-week)\n'
        c = b6.classify_cron_journal(log)
        self.assertGreaterEqual(c['crontab_load_error_count'], 1)
        self.assertIn('ERROR', c['sample_crontab_error_line'])

    def test_session_open_close_not_misclassified(self):
        """pam_unix session open/close lines are not crontab parse errors."""
        log = (
            'Jun 24 10:05:01 host CRON[111]: pam_unix(cron:session): session opened for user deploy(uid=1000) by deploy(uid=0)\n'
            'Jun 24 10:05:02 host CRON[111]: pam_unix(cron:session): session closed for user deploy\n'
        )
        c = b6.classify_cron_journal(log)
        self.assertEqual(c['crontab_load_error_count'], 0)

    def test_no_mta_installed_not_misclassified(self):
        log = 'Jun 24 10:05:04 host CRON[111]: (CRON) info (No MTA installed, discarding output)\n'
        c = b6.classify_cron_journal(log)
        self.assertEqual(c['crontab_load_error_count'], 0)

    def test_invalid_minute_pattern(self):
        log = 'Jun 24 10:00:00 host cron[123]: (*system*) bad minute (/etc/cron.d/foo)\n'
        c = b6.classify_cron_journal(log)
        self.assertGreaterEqual(c['crontab_load_error_count'], 1)


class TestEvaluateTriggers(unittest.TestCase):

    def _empty_baselines(self):
        return dict(quar=[], marker=False, counter='absent', state_mtime=1, state_sha='x', log_size=0)

    def _clean_post(self):
        return dict(quar=[], marker=False, counter='absent', counter_delta=0, state_mtime_advanced=False)

    def test_normal_tick_no_triggers(self):
        log = '[K-4] lock acquired\n[K-3] candidate == original (canonical); no commit, mtime preserved\n'
        lc = b6.classify_anomaly_log(log)
        jc = b6.classify_cron_journal('')
        triggers, primary, corro = b6.evaluate_triggers(
            self._empty_baselines(), self._clean_post(), lc, jc, b6.ACTIVE_SHA, b6.ACTIVE_SHA
        )
        self.assertEqual(triggers, [])
        self.assertIsNone(primary)

    def test_incident_pattern_primary_h_corroborating_i2(self):
        """2026-06-24 incident replay: h primary, i2 corroborating."""
        log = '/path/check-anomalies.sh: line 45: ANOMALY_STATE_DIR: ANOMALY_STATE_DIR is required\n'
        lc = b6.classify_anomaly_log(log)
        jc = b6.classify_cron_journal('')
        triggers, primary, corro = b6.evaluate_triggers(
            self._empty_baselines(), self._clean_post(), lc, jc, b6.ACTIVE_SHA, b6.ACTIVE_SHA
        )
        h_present = any(t.startswith('h:') for t in triggers)
        i2_present = any(t.startswith('i2:') for t in triggers)
        i1_present = any(t.startswith('i1:') for t in triggers)
        self.assertTrue(h_present, f'expected h trigger in {triggers}')
        self.assertTrue(i2_present, f'expected i2 trigger in {triggers}')
        self.assertFalse(i1_present, f'i1 should NOT fire (= no crontab parse error)')
        self.assertTrue(primary.startswith('h:'), f'primary should be h, got {primary}')
        self.assertTrue(any(c.startswith('i2:') for c in corro))

    def test_genuine_crontab_parse_error_fires_i1_not_i2(self):
        lc = b6.classify_anomaly_log('')  # no anomaly log content
        jc = b6.classify_cron_journal('(CRON) ERROR (bad command in /etc/cron.d/foo)\n')
        triggers, primary, _ = b6.evaluate_triggers(
            self._empty_baselines(), self._clean_post(), lc, jc, b6.ACTIVE_SHA, b6.ACTIVE_SHA
        )
        self.assertTrue(any(t.startswith('i1:') for t in triggers))
        self.assertFalse(any(t.startswith('i2:') for t in triggers))

    def test_cron_drift_g_is_primary(self):
        lc = b6.classify_anomaly_log('[K-4] lock acquired\n')
        jc = b6.classify_cron_journal('')
        triggers, primary, _ = b6.evaluate_triggers(
            self._empty_baselines(), self._clean_post(), lc, jc, 'driftedsha123', b6.ACTIVE_SHA
        )
        self.assertTrue(primary.startswith('g:'))

    def test_state_mtime_advance_fires_f(self):
        lc = b6.classify_anomaly_log('[K-4] lock acquired\n')
        jc = b6.classify_cron_journal('')
        post = self._clean_post()
        post['state_mtime_advanced'] = True
        triggers, primary, _ = b6.evaluate_triggers(
            self._empty_baselines(), post, lc, jc, b6.ACTIVE_SHA, b6.ACTIVE_SHA
        )
        self.assertTrue(any(t == 'f:state-mtime-advanced' for t in triggers))


def _fake_atomic_write(target, data, perm=0o644, uid=0, gid=0):
    """Test-only atomic_write that skips fchown (= requires root on Linux)."""
    tmp = target + '.tmp'
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    with open(tmp, 'wb') as f:
        f.write(data)
    os.chmod(tmp, perm)
    os.rename(tmp, target)


class TestCmdRestore(unittest.TestCase):
    """Blocker 2: --restore-* fail-closed behaviour.

    All cases swap b6.CRON_PATH to a tmpfile so /etc/cron.d/ is never
    touched. atomic_write is replaced with _fake_atomic_write to skip
    fchown (= which requires root). Each test restores CRON_PATH at
    tearDown.
    """

    def setUp(self):
        self.orig_path = b6.CRON_PATH
        self.orig_atomic_write = b6.atomic_write
        fd, self.tmp = tempfile.mkstemp(suffix='.cron-test')
        os.close(fd)
        b6.CRON_PATH = self.tmp
        b6.atomic_write = _fake_atomic_write

    def tearDown(self):
        b6.CRON_PATH = self.orig_path
        b6.atomic_write = self.orig_atomic_write
        try:
            os.unlink(self.tmp)
        except OSError:
            pass

    def _write_current(self, data_bytes):
        with open(self.tmp, 'wb') as f:
            f.write(data_bytes)

    # === unknown-state cases (= both restore targets must refuse) ===
    def test_restore_b0_new_refuses_unknown_state(self):
        self._write_current(b'garbage that matches no baseline\n')
        rc = b6.cmd_restore('B0_NEW')
        self.assertEqual(rc, 1)
        # current bytes preserved.
        self.assertEqual(open(self.tmp, 'rb').read(), b'garbage that matches no baseline\n')

    def test_restore_b0_old_refuses_unknown_state(self):
        self._write_current(b'still garbage\n')
        rc = b6.cmd_restore('B0_OLD')
        self.assertEqual(rc, 1)
        self.assertEqual(open(self.tmp, 'rb').read(), b'still garbage\n')

    # === permitted transitions from each known state ===
    def test_restore_b0_new_from_b0_old(self):
        self._write_current(b6.B0_OLD)
        rc = b6.cmd_restore('B0_NEW')
        self.assertEqual(rc, 0)
        self.assertEqual(open(self.tmp, 'rb').read(), b6.B0_NEW)

    def test_restore_b0_new_from_active(self):
        self._write_current(b6.ACTIVE)
        rc = b6.cmd_restore('B0_NEW')
        self.assertEqual(rc, 0)
        self.assertEqual(open(self.tmp, 'rb').read(), b6.B0_NEW)

    def test_restore_b0_old_from_b0_new(self):
        self._write_current(b6.B0_NEW)
        rc = b6.cmd_restore('B0_OLD')
        self.assertEqual(rc, 0)
        self.assertEqual(open(self.tmp, 'rb').read(), b6.B0_OLD)

    def test_restore_b0_old_from_active_strips_both_env_and_uncomment(self):
        """ACTIVE → B0_OLD: env line AND uncommented line both reverted.

        Uses splitlines element checks (= NEW_LINE is a substring of
        OLD_LINE so byte-level "in" would false-positive).
        """
        self._write_current(b6.ACTIVE)
        rc = b6.cmd_restore('B0_OLD')
        self.assertEqual(rc, 0)
        restored = open(self.tmp, 'rb').read()
        self.assertEqual(restored, b6.B0_OLD)
        lines = restored.decode().splitlines(keepends=True)
        # explicit invariants (= element-equality, not substring):
        self.assertEqual(lines.count(b6.ENV_LINE), 0,
                         'ENV_LINE element must be absent after ACTIVE→B0_OLD restore')
        self.assertEqual(lines.count(b6.NEW_LINE), 0,
                         'NEW_LINE (active form) element must be absent after restore')
        self.assertEqual(lines.count(b6.OLD_LINE), 1,
                         'OLD_LINE (commented form) must be present exactly once')

    # === same-state no-op cases ===
    def test_restore_b0_new_from_b0_new_is_noop(self):
        self._write_current(b6.B0_NEW)
        pre_bytes = open(self.tmp, 'rb').read()
        pre_mtime_ns = os.stat(self.tmp).st_mtime_ns
        rc = b6.cmd_restore('B0_NEW')
        self.assertEqual(rc, 0)
        post_bytes = open(self.tmp, 'rb').read()
        post_mtime_ns = os.stat(self.tmp).st_mtime_ns
        self.assertEqual(pre_bytes, post_bytes)
        # no-op means no write happened (= mtime preserved).
        self.assertEqual(pre_mtime_ns, post_mtime_ns)

    def test_restore_b0_old_from_b0_old_is_noop(self):
        self._write_current(b6.B0_OLD)
        pre_mtime_ns = os.stat(self.tmp).st_mtime_ns
        rc = b6.cmd_restore('B0_OLD')
        self.assertEqual(rc, 0)
        post_mtime_ns = os.stat(self.tmp).st_mtime_ns
        self.assertEqual(pre_mtime_ns, post_mtime_ns)

    # === write failure preserves current bytes ===
    def test_write_failure_preserves_current(self):
        """If atomic_write raises, current bytes survive."""
        self._write_current(b6.ACTIVE)
        def failing_write(*a, **kw):
            raise OSError(28, 'No space left on device')
        b6.atomic_write = failing_write
        rc = b6.cmd_restore('B0_NEW')
        self.assertEqual(rc, 2)
        current = open(self.tmp, 'rb').read()
        self.assertEqual(current, b6.ACTIVE, 'current bytes must survive write failure')

    # === invariant: restore does NOT touch state/topic/lock/counter/quarantine ===
    def test_restore_does_not_invoke_journalctl_or_sleep(self):
        """cmd_restore must be pure file I/O — no subprocess, no sleep."""
        import unittest.mock
        self._write_current(b6.B0_OLD)
        # Mock subprocess.run and time.sleep — cmd_restore must call neither.
        with unittest.mock.patch.object(b6, 'subprocess') as mock_sp, \
             unittest.mock.patch.object(b6, 'time') as mock_time:
            # Mock time but allow strftime (used by now_iso_utc, though
            # restore doesn't call it; defensive).
            mock_time.strftime = __import__('time').strftime
            rc = b6.cmd_restore('B0_NEW')
            self.assertEqual(rc, 0)
            mock_sp.run.assert_not_called()
            mock_time.sleep.assert_not_called()


class TestProposedDiffIsMinimal(unittest.TestCase):

    def test_install_diff_is_only_env_line_added(self):
        """B0_OLD → B0_NEW differs by exactly one inserted env-line, in place."""
        old_lines = b6.B0_OLD.decode().splitlines(keepends=True)
        new_lines = b6.B0_NEW.decode().splitlines(keepends=True)
        # All other lines must be unchanged.
        # Find the inserted ENV_LINE and remove it; rest must match.
        new_lines_without_env = [l for l in new_lines if l != b6.ENV_LINE]
        self.assertEqual(new_lines_without_env, old_lines)

    def test_apply_diff_is_only_uncomment(self):
        """B0_NEW → ACTIVE differs by exactly one line: OLD_LINE → NEW_LINE."""
        new_lines = b6.B0_NEW.decode().splitlines(keepends=True)
        active_lines = b6.ACTIVE.decode().splitlines(keepends=True)
        self.assertEqual(len(new_lines), len(active_lines))
        diffs = [(i, n, a) for i, (n, a) in enumerate(zip(new_lines, active_lines)) if n != a]
        self.assertEqual(len(diffs), 1, f'expected exactly 1 line diff, got {diffs}')
        idx, n, a = diffs[0]
        self.assertEqual(n, b6.OLD_LINE)
        self.assertEqual(a, b6.NEW_LINE)


if __name__ == '__main__':
    unittest.main(verbosity=2)
