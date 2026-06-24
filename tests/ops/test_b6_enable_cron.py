#!/usr/bin/env python3
"""Unit tests for scripts/ops/b6-enable-metal-anomalies-cron.py.

Run from repo root:
  python3 tests/ops/test_b6_enable_cron.py
or via the script's --self-test entry point:
  python3 scripts/ops/b6-enable-metal-anomalies-cron.py --self-test

These tests exercise the pure helpers (= compute_proposed, atomic_write,
_next_5min_wait_seconds) plus the B0_BASELINE byte / SHA invariants. They
do NOT touch /etc/cron.d/ or any production path.
"""
import datetime
import hashlib
import importlib.util
import os
import stat
import sys
import tempfile
import unittest

# Load the script as a module despite its hyphenated filename.
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.normpath(os.path.join(HERE, '..', '..', 'scripts', 'ops', 'b6-enable-metal-anomalies-cron.py'))
_spec = importlib.util.spec_from_file_location('b6_enable_cron', SCRIPT_PATH)
b6 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(b6)


class TestB0Baseline(unittest.TestCase):

    def test_b0_sha_matches_documented(self):
        self.assertEqual(hashlib.sha256(b6.B0_BASELINE).hexdigest(), b6.B0_SHA)

    def test_b0_size_is_420_bytes(self):
        self.assertEqual(len(b6.B0_BASELINE), 420)

    def test_b0_contains_exactly_one_commented_cron_line(self):
        lines = b6.B0_BASELINE.decode().splitlines(keepends=True)
        self.assertEqual(lines.count(b6.OLD_LINE), 1)
        self.assertEqual(lines.count(b6.NEW_LINE), 0)


class TestComputeProposed(unittest.TestCase):

    def test_b0_baseline_yields_ready_proposed(self):
        c = b6.compute_proposed(b6.B0_BASELINE)
        self.assertTrue(c['precondition_ok'], c['precondition_msg'])
        self.assertIsNotNone(c['proposed_bytes'])
        # Expected proposed SHA is the value verified during the B6 dry-run
        # against the actual file on Hetzner. Fixing it here pins the
        # script's contract.
        self.assertEqual(c['proposed_sha'], '494a825cc8743b3a84c28d02a52358123bad033406d409b8cc2412ffa74f1e1c')
        self.assertEqual(c['old_count_before'], 1)
        self.assertEqual(c['new_count_before'], 0)
        self.assertEqual(c['old_count_after'], 0)
        self.assertEqual(c['new_count_after'], 1)
        self.assertEqual(len(c['proposed_bytes']), 418)
        self.assertTrue(c['proposed_bytes'].endswith(b'\n'))

    def test_already_uncommented_file_is_not_ready(self):
        already = b6.B0_BASELINE.decode().replace(b6.OLD_LINE, b6.NEW_LINE, 1).encode()
        c = b6.compute_proposed(already)
        self.assertFalse(c['precondition_ok'])
        self.assertEqual(c['old_count_before'], 0)
        # NEW_LINE present as element AND OLD_LINE absent → old=0 fails first.
        self.assertIn('old_line', c['precondition_msg'])

    def test_substring_overlap_does_not_false_positive(self):
        """NEW_LINE is a substring of OLD_LINE; element count must NOT confuse them."""
        # B0 baseline contains OLD_LINE element only. NEW_LINE substring is
        # present (inside OLD_LINE) but NEW_LINE as an element is not.
        # If we used .count() on the string itself we'd get 1 for both;
        # the script uses splitlines+count which correctly returns 1 / 0.
        text = b6.B0_BASELINE.decode()
        self.assertEqual(text.count(b6.NEW_LINE), 1)  # substring match (= the bug we avoid)
        lines = text.splitlines(keepends=True)
        self.assertEqual(lines.count(b6.NEW_LINE), 0)  # element match (= correct)

    def test_corrupt_no_cron_line_returns_not_ready(self):
        bad = b'# just a comment\n# nothing here\n'
        c = b6.compute_proposed(bad)
        self.assertFalse(c['precondition_ok'])
        self.assertEqual(c['old_count_before'], 0)
        self.assertIsNone(c['proposed_bytes'])

    def test_duplicate_old_line_returns_not_ready(self):
        dup = b6.B0_BASELINE + b6.OLD_LINE.encode()
        c = b6.compute_proposed(dup)
        self.assertFalse(c['precondition_ok'])
        self.assertEqual(c['old_count_before'], 2)


class TestAtomicWrite(unittest.TestCase):

    def test_writes_byte_equal_content(self):
        fd, path = tempfile.mkstemp()
        os.close(fd)
        try:
            payload = b'alpha\nbeta\ngamma\n'
            b6.atomic_write(path, payload, perm=0o644, uid=os.geteuid(), gid=os.getegid())
            self.assertEqual(open(path, 'rb').read(), payload)
            st = os.stat(path)
            self.assertEqual(stat.S_IMODE(st.st_mode), 0o644)
        finally:
            os.unlink(path)

    def test_atomic_rename_overwrites_existing_target(self):
        fd, path = tempfile.mkstemp()
        os.write(fd, b'old content\n')
        os.close(fd)
        try:
            new_payload = b'new content\n'
            b6.atomic_write(path, new_payload, perm=0o600, uid=os.geteuid(), gid=os.getegid())
            self.assertEqual(open(path, 'rb').read(), new_payload)
        finally:
            os.unlink(path)


class TestWaitSecondsBoundary(unittest.TestCase):

    def test_mid_window(self):
        # At HH:07:15, next */5 is HH:10. wait_min = 10-7 = 3.
        # Wait = 3*60 - 15 + 120 = 285 sec.
        t = datetime.datetime(2026, 6, 24, 10, 7, 15)
        self.assertEqual(b6._next_5min_wait_seconds(t), 3 * 60 - 15 + 120)

    def test_just_after_boundary(self):
        # At HH:05:01, next */5 is HH:10. wait_min = 10-5 = 5.
        # Wait = 5*60 - 1 + 120 = 419 sec.
        t = datetime.datetime(2026, 6, 24, 10, 5, 1)
        self.assertEqual(b6._next_5min_wait_seconds(t), 5 * 60 - 1 + 120)

    def test_hour_wrap(self):
        # At HH:58:00, next */5 is (HH+1):00. wait_min = 60-58 = 2.
        # wait = 2*60 - 0 + 120 = 240 sec.
        t = datetime.datetime(2026, 6, 24, 10, 58, 0)
        self.assertEqual(b6._next_5min_wait_seconds(t), 240)


if __name__ == '__main__':
    unittest.main(verbosity=2)
