#!/usr/bin/env python3
"""
b6-enable-metal-anomalies-cron.py

Repo-managed atomic uncomment for the metal-anomalies cron entry. Replaces
the previously-attempted sed-based mutation that produced a malformed
concatenation through unescaped `&` in the sed replacement. See
docs/MONITORING_OPS.md §11 (resume-from-pause checklist).

Design (= B6 re-design gate, per operator authorisation):
  - sed is BANNED. Mutation uses Python str list-element replace only.
  - Mode is explicit: --dry-run (default) READS only, --apply WRITES.
  - The proposed replacement uses splitlines(keepends=True) elements so
    a line is matched only as a whole line, not as a substring (= the
    NEW_LINE happens to be a substring of OLD_LINE; substring count
    would falsely report new_count_before=1 and gate the apply away).
  - On --apply, post-write byte-equal verification compares the file's
    raw bytes against the in-memory proposed bytes; mismatch triggers
    immediate full-baseline restore.
  - Rollback (= during or after apply) is full baseline atomic restore
    only. The B0 baseline bytes are embedded in this module and the
    embedded bytes' SHA-256 is asserted at import to catch corruption.
  - Rollback triggers (= any one fires after first tick):
      a. K-1/K-2/K-3.5/K-4-open-fail/K-3-permanent-fail line in
         /var/log/anomalies.log delta
      b. /var/lib/freedom-yield/quarantine listing changed
      c. /var/lib/freedom-yield/.missing-notified.marker appeared
      d. /var/lib/freedom-yield/anomaly-contention-counter grew by ≥ 2
      e. K-3 committed candidate line in log (= unexplained transition)
      f. /var/lib/freedom-yield/anomaly-state.json mtime advanced
      g. cron file SHA != proposed SHA after wait (= drift / corruption)
      h. zero ticks in T+5-10 min observation window (= silent skip)
      i. cron daemon log (journalctl -u cron --since uncomment_ts)
         contains "error|bad|parse|skipped|invalid"

Usage:
  python3 b6-enable-metal-anomalies-cron.py                  # dry-run report
  python3 b6-enable-metal-anomalies-cron.py --dry-run        # same
  python3 b6-enable-metal-anomalies-cron.py --apply          # writes + waits + reports
  python3 b6-enable-metal-anomalies-cron.py --restore-baseline
                                                             # full B0 restore (= manual)
  python3 b6-enable-metal-anomalies-cron.py --self-test      # in-process unit checks

Exit codes:
   0 success (dry-run READY / apply OK / restore OK / self-test PASS)
   1 dry-run NOT-READY (= preconditions not met)
   2 apply: write failed or post-write verification failed (auto-restored to baseline)
   3 apply: rollback trigger fired (auto-restored to baseline)
  10 self-test failed
  20 file SHA changed during dry-run (= unexpected concurrent writer)
  64 invalid argument
"""
import argparse
import datetime
import hashlib
import os
import re
import stat
import subprocess
import sys
import time

CRON_PATH = '/etc/cron.d/metal-anomalies'

# --- literal exact-line constants ----------------------------------------
# Trailing \n included so each is exactly one element of
# splitlines(keepends=True). Matching is element-equality, not substring.
OLD_LINE = '# */5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1\n'
NEW_LINE = '*/5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1\n'

# --- B0 baseline bytes (= exact file as recorded by B0 evidence) ---------
B0_BASELINE = (
    b'# === MAINTENANCE PAUSE ===\n'
    b'# anomaly input is invalid; see incident record.\n'
    b'# Resume only after server-status and anomaly validation gates pass.\n'
    b'\n'
    b'# notify.sh uses a sanitized placeholder by default.\n'
    b'# Production topic path must be provided explicitly.\n'
    b'NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic\n'
    b'# */5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1\n'
)
B0_SHA = '1d7d6e2f07fc20e77593cb523364503bf3770d0c43cf9c69805bb6e5dae8b74e'

# Hard module-load guard: corrupted embedded baseline must fail loud.
_actual_b0_sha = hashlib.sha256(B0_BASELINE).hexdigest()
if _actual_b0_sha != B0_SHA:
    raise RuntimeError(
        f'B0_BASELINE embedded bytes SHA mismatch: got {_actual_b0_sha}, '
        f'expected {B0_SHA}. Module refusing to load — possible tamper or '
        f'mis-edit.'
    )

# --- production paths used for rollback-trigger checks ------------------
ANOMALY_LOG = '/var/log/anomalies.log'
PROD_STATE = '/var/lib/freedom-yield/anomaly-state.json'
PROD_QUAR = '/var/lib/freedom-yield/quarantine'
PROD_COUNTER = '/var/lib/freedom-yield/anomaly-contention-counter'
PROD_MARKER = '/var/lib/freedom-yield/.missing-notified.marker'


# ========================================================================
# pure helpers (= side-effect-free, unit-testable)
# ========================================================================
def compute_proposed(current_bytes):
    """Return dict describing the proposed file given current bytes.

    Keys:
      proposed_bytes : bytes or None when preconditions fail
      proposed_sha   : str or None
      old_count_before, new_count_before : int (element count in current)
      old_count_after,  new_count_after  : int or None (element count in
                                            proposed; None if not computed)
      precondition_ok: bool
      precondition_msg: str (empty if OK)
    """
    text = current_bytes.decode('utf-8')
    lines = text.splitlines(keepends=True)
    old_before = lines.count(OLD_LINE)
    new_before = lines.count(NEW_LINE)
    if old_before != 1:
        return dict(
            proposed_bytes=None, proposed_sha=None,
            old_count_before=old_before, new_count_before=new_before,
            old_count_after=None, new_count_after=None,
            precondition_ok=False,
            precondition_msg=f'old_line element count in current must be exactly 1, got {old_before}',
        )
    if new_before != 0:
        return dict(
            proposed_bytes=None, proposed_sha=None,
            old_count_before=old_before, new_count_before=new_before,
            old_count_after=None, new_count_after=None,
            precondition_ok=False,
            precondition_msg=f'new_line element count in current must be exactly 0, got {new_before}',
        )
    idx = lines.index(OLD_LINE)
    proposed_lines = lines[:idx] + [NEW_LINE] + lines[idx + 1:]
    proposed_text = ''.join(proposed_lines)
    proposed_bytes = proposed_text.encode('utf-8')
    return dict(
        proposed_bytes=proposed_bytes,
        proposed_sha=hashlib.sha256(proposed_bytes).hexdigest(),
        old_count_before=old_before,
        new_count_before=new_before,
        old_count_after=proposed_lines.count(OLD_LINE),
        new_count_after=proposed_lines.count(NEW_LINE),
        precondition_ok=True,
        precondition_msg='',
    )


def atomic_write(target, data, perm=0o644, uid=0, gid=0):
    """Same-fs atomic write: tmp + fchmod/fchown + fsync + rename.

    Raises on any I/O error. Caller is responsible for catching and
    deciding whether to roll back.
    """
    tmp = target + '.tmp'
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        n = os.write(fd, data)
        if n != len(data):
            raise IOError(f'short write to {tmp}: {n}/{len(data)}')
        os.fchmod(fd, perm)
        os.fchown(fd, uid, gid)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, target)


def sha256_of(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def now_iso_utc():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def _next_5min_wait_seconds(now=None):
    """Seconds to sleep until next */5 minute boundary + 120s buffer."""
    if now is None:
        now = datetime.datetime.utcnow()
    next5 = ((now.minute // 5) + 1) * 5
    if next5 >= 60:
        wait_min = 60 - now.minute
    else:
        wait_min = next5 - now.minute
    return wait_min * 60 - now.second + 120


# ========================================================================
# dry-run report rendering (= READ-ONLY)
# ========================================================================
def render_report(current_bytes, file_owner, file_perm, computed, current_sha):
    """Return a multi-line string. Pure: no I/O."""
    proposed_bytes = computed['proposed_bytes']
    proposed_sha = computed['proposed_sha']
    proposed_text = proposed_bytes.decode('utf-8') if proposed_bytes else None
    final_nl_cur = current_bytes.endswith(b'\n')
    final_nl_prop = bool(proposed_bytes) and proposed_bytes.endswith(b'\n')
    delta = (len(proposed_bytes) - len(current_bytes)) if proposed_bytes else None

    def anchored_lines(text, line_body):
        if text is None:
            return []
        return re.findall(r'(?m)^' + re.escape(line_body) + r'$', text)

    active_in_proposed = anchored_lines(proposed_text, NEW_LINE.rstrip('\n'))
    commented_in_proposed = anchored_lines(proposed_text, OLD_LINE.rstrip('\n'))
    active_in_current = anchored_lines(current_bytes.decode('utf-8'), NEW_LINE.rstrip('\n'))
    commented_in_current = anchored_lines(current_bytes.decode('utf-8'), OLD_LINE.rstrip('\n'))

    out = []
    out.append('=== b6-enable-metal-anomalies-cron.py dry-run report ===')
    out.append(f'path: {CRON_PATH}')
    out.append('')
    out.append(f'1. current SHA:  {current_sha}')
    out.append(f'2. proposed SHA: {proposed_sha if proposed_sha else "(precondition fail)"}')
    out.append('')
    out.append('3. line-element counts (= splitlines(keepends=True) element-equality):')
    out.append(f"   old_line element count in current  : {computed['old_count_before']} (expected exactly 1)")
    out.append(f"   new_line element count in current  : {computed['new_count_before']} (expected exactly 0)")
    out.append(f"   old_line element count in proposed : {computed['old_count_after']} (expected exactly 0)")
    out.append(f"   new_line element count in proposed : {computed['new_count_after']} (expected exactly 1)")
    out.append('')
    out.append('4. regex-anchored line enumeration (^...$):')
    out.append(f'   active line count in proposed:   {len(active_in_proposed)} (expected 1)')
    for ln in active_in_proposed:
        out.append(f'     -> "{ln}"')
    out.append(f'   commented line count in proposed: {len(commented_in_proposed)} (expected 0)')
    out.append(f'   active line count in current:   {len(active_in_current)} (expected 0)')
    out.append(f'   commented line count in current: {len(commented_in_current)} (expected 1)')
    out.append('')
    out.append('5. final newline:')
    out.append(f'   current  ends with \\n: {final_nl_cur}')
    out.append(f'   proposed ends with \\n: {final_nl_prop}')
    out.append('')
    out.append('6. owner / perm preservation plan:')
    out.append(f'   current owner: {file_owner}')
    out.append(f'   current perm:  {oct(file_perm)}')
    out.append(f'   apply plan: atomic_write({CRON_PATH}, proposed_bytes, perm=0o644, uid=0, gid=0)')
    out.append(f'               then verify sha256(read(path)) == proposed_sha AND read(path) == proposed_bytes')
    out.append('')
    out.append('7. proposed full cron file content:')
    out.append(f"   --- begin proposed (length={len(proposed_bytes) if proposed_bytes else 0} bytes) ---")
    if proposed_text is not None:
        for ln in proposed_text.splitlines(keepends=False):
            out.append(f'   |{ln}')
        if proposed_text.endswith('\n'):
            out.append('   |\\n (= trailing newline preserved)')
    out.append('   --- end proposed ---')
    out.append('')
    out.append('8. byte sizes:')
    out.append(f'   current bytes:  {len(current_bytes)}')
    out.append(f"   proposed bytes: {len(proposed_bytes) if proposed_bytes else '(n/a)'}")
    out.append(f"   delta:          {delta if delta is not None else '(n/a)'} (expected -2 = removes '# ' prefix)")
    out.append('')
    out.append('=== verdict ===')
    if computed['precondition_ok'] and computed['old_count_after'] == 0 and computed['new_count_after'] == 1 \
       and len(active_in_proposed) == 1 and len(commented_in_proposed) == 0 \
       and final_nl_prop and delta == -2 \
       and file_owner == 'root:root' and file_perm == 0o644:
        out.append('READY: dry-run preconditions all PASS.')
        ready = True
    else:
        out.append('NOT-READY:')
        if not computed['precondition_ok']:
            out.append(f"  - {computed['precondition_msg']}")
        if computed['precondition_ok']:
            if computed['old_count_after'] != 0:
                out.append(f"  - old_count_after != 0 (got {computed['old_count_after']})")
            if computed['new_count_after'] != 1:
                out.append(f"  - new_count_after != 1 (got {computed['new_count_after']})")
            if len(active_in_proposed) != 1:
                out.append(f"  - active line count != 1 (got {len(active_in_proposed)})")
            if len(commented_in_proposed) != 0:
                out.append(f"  - commented line count != 0 (got {len(commented_in_proposed)})")
            if not final_nl_prop:
                out.append('  - proposed missing trailing newline')
            if delta != -2:
                out.append(f"  - byte delta != -2 (got {delta})")
        if file_owner != 'root:root':
            out.append(f'  - owner != root:root (got {file_owner})')
        if file_perm != 0o644:
            out.append(f'  - perm != 0o644 (got {oct(file_perm)})')
        ready = False
    return '\n'.join(out), ready


# ========================================================================
# commands
# ========================================================================
def _read_owner_perm(path):
    import pwd, grp
    st = os.stat(path)
    try:
        owner = pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        owner = str(st.st_uid)
    try:
        group = grp.getgrgid(st.st_gid).gr_name
    except KeyError:
        group = str(st.st_gid)
    perm = stat.S_IMODE(st.st_mode)
    return f'{owner}:{group}', perm


def cmd_dry_run():
    with open(CRON_PATH, 'rb') as f:
        current_bytes = f.read()
    pre_sha = hashlib.sha256(current_bytes).hexdigest()
    owner_str, perm = _read_owner_perm(CRON_PATH)
    computed = compute_proposed(current_bytes)
    report, ready = render_report(current_bytes, owner_str, perm, computed, pre_sha)
    print(report)
    # Defensive: verify file untouched.
    post_sha = sha256_of(CRON_PATH)
    if post_sha != pre_sha:
        print(f'*** PANIC: file SHA changed during dry-run! pre={pre_sha} post={post_sha} ***')
        return 20
    print(f'post-dry-run file SHA: {post_sha} (= matches pre, file untouched)')
    print('NO WRITE PERFORMED — file on disk unchanged.')
    return 0 if ready else 1


def _check_rollback_triggers(uncomment_ts, proposed_sha, baselines, new_log_text):
    """Return list of trigger ids that fired. Pure-ish (subprocess for journalctl)."""
    triggers = []
    if re.search(
        r'^\[K-1\]|^\[K-2\] observedAt|^\[K-3\.5\] new corruption|^\[K-3\.5\] state file missing|^\[K-4\] cannot open lock|^\[K-3\] notify permanent fail',
        new_log_text, re.MULTILINE
    ):
        triggers.append('a:gate-error-in-log')

    pre_q = baselines['quar']
    post_q = sorted(os.listdir(PROD_QUAR)) if os.path.isdir(PROD_QUAR) else []
    if post_q != pre_q:
        triggers.append('b:quarantine-changed')

    if (not baselines['marker']) and os.path.exists(PROD_MARKER):
        triggers.append('c:missing-marker-appeared')

    post_counter_str = open(PROD_COUNTER).read().strip() if os.path.exists(PROD_COUNTER) else 'absent'
    if post_counter_str != 'absent' and post_counter_str != baselines['counter']:
        pc = int(baselines['counter']) if baselines['counter'] != 'absent' else 0
        pp = int(post_counter_str)
        if pp - pc >= 2:
            triggers.append(f'd:counter-grew-by-{pp - pc}')

    commits = len(re.findall(r'\[K-3\] committed candidate to ', new_log_text))
    if commits > 0:
        triggers.append(f'e:K3-commit-{commits}-times')

    post_state_mtime = os.stat(PROD_STATE).st_mtime_ns
    if post_state_mtime != baselines['state_mtime']:
        triggers.append('f:state-mtime-advanced')

    post_cron_sha = sha256_of(CRON_PATH)
    if post_cron_sha != proposed_sha:
        triggers.append(f'g:cron-file-drift-{post_cron_sha}-vs-{proposed_sha}')

    ticks = len(re.findall(r'\[K-4\] lock acquired', new_log_text))
    if ticks == 0:
        triggers.append('h:silent-skip-zero-ticks')

    try:
        cron_log = subprocess.run(
            ['journalctl', '-u', 'cron', '--since', uncomment_ts, '--no-pager'],
            capture_output=True, text=True, timeout=10
        ).stdout
        suspicious = [l for l in cron_log.splitlines()
                      if re.search(r'(?i)\berror\b|\bbad\b|\bparse\b|\bskipped\b|\binvalid\b', l)]
        # Filter known-benign lines (= "No MTA installed" is normal info, not error).
        suspicious = [l for l in suspicious if 'No MTA installed' not in l]
        if suspicious:
            triggers.append(f'i:cron-parse-error-{len(suspicious)}-lines')
    except (subprocess.SubprocessError, OSError):
        pass

    return triggers, dict(commits=commits, ticks=ticks, post_cron_sha=post_cron_sha, log_delta=len(new_log_text))


def cmd_apply():
    with open(CRON_PATH, 'rb') as f:
        current_bytes = f.read()
    current_sha = hashlib.sha256(current_bytes).hexdigest()

    if current_sha != B0_SHA:
        print(f'ABORT: --apply refuses unless current file == B0 baseline SHA.')
        print(f'  current SHA: {current_sha}')
        print(f'  expected:    {B0_SHA}')
        return 1

    computed = compute_proposed(current_bytes)
    if not computed['precondition_ok']:
        print(f'ABORT: dry-run preconditions failed: {computed["precondition_msg"]}')
        return 1

    proposed_bytes = computed['proposed_bytes']
    proposed_sha = computed['proposed_sha']

    # Snapshot baselines for rollback-trigger comparison.
    baselines = dict(
        state_mtime=os.stat(PROD_STATE).st_mtime_ns,
        state_sha=sha256_of(PROD_STATE),
        log_size=os.path.getsize(ANOMALY_LOG) if os.path.exists(ANOMALY_LOG) else 0,
        quar=sorted(os.listdir(PROD_QUAR)) if os.path.isdir(PROD_QUAR) else [],
        marker=os.path.exists(PROD_MARKER),
        counter=(open(PROD_COUNTER).read().strip() if os.path.exists(PROD_COUNTER) else 'absent'),
    )

    # Apply atomic write.
    uncomment_ts = now_iso_utc()
    try:
        atomic_write(CRON_PATH, proposed_bytes, perm=0o644, uid=0, gid=0)
    except Exception as e:
        print(f'WRITE FAILED: {e}')
        try:
            atomic_write(CRON_PATH, B0_BASELINE, perm=0o644, uid=0, gid=0)
            print('baseline restored after write failure.')
        except Exception as e2:
            print(f'*** PANIC: baseline restore ALSO failed: {e2} ***')
        return 2

    # Post-write byte-perfect verify.
    post_bytes = open(CRON_PATH, 'rb').read()
    post_sha = hashlib.sha256(post_bytes).hexdigest()
    if post_sha != proposed_sha or post_bytes != proposed_bytes:
        print(f'POST-WRITE VERIFY FAILED: post_sha={post_sha} proposed_sha={proposed_sha}')
        try:
            atomic_write(CRON_PATH, B0_BASELINE, perm=0o644, uid=0, gid=0)
            print('baseline restored after post-write verify failure.')
        except Exception as e:
            print(f'*** PANIC: baseline restore failed: {e} ***')
        return 2

    print(f'applied: pre_sha={current_sha} post_sha={post_sha} ts={uncomment_ts}')

    # Wait for first tick.
    wait_sec = _next_5min_wait_seconds()
    print(f'waiting {wait_sec}s for first */5 tick + 120s buffer ...')
    time.sleep(wait_sec)
    post_tick_ts = now_iso_utc()

    # Read new log content.
    post_log_size = os.path.getsize(ANOMALY_LOG) if os.path.exists(ANOMALY_LOG) else 0
    log_delta = post_log_size - baselines['log_size']
    new_log = ''
    if log_delta > 0:
        with open(ANOMALY_LOG, 'rb') as f:
            f.seek(baselines['log_size'])
            new_log = f.read().decode('utf-8', errors='replace')

    triggers, observations = _check_rollback_triggers(uncomment_ts, proposed_sha, baselines, new_log)

    re_comment_ts = None
    post_revert_sha = None
    if triggers:
        print(f'ROLLBACK FIRED: {triggers}')
        try:
            atomic_write(CRON_PATH, B0_BASELINE, perm=0o644, uid=0, gid=0)
            re_comment_ts = now_iso_utc()
            post_revert_sha = sha256_of(CRON_PATH)
            assert post_revert_sha == B0_SHA, f'baseline restore SHA mismatch: {post_revert_sha}'
            print(f're_comment_ts={re_comment_ts} post_revert_sha={post_revert_sha}')
        except Exception as e:
            print(f'*** PANIC: baseline restore failed: {e} ***')

    print('=== apply report ===')
    print(f'1. pre-change SHA:  {current_sha}')
    print(f'2. post-change SHA: {post_sha}')
    print(f'3. proposed SHA:    {proposed_sha}')
    print(f'4. uncomment_ts:    {uncomment_ts}')
    print(f'5. wait_sec:        {wait_sec}')
    print(f'6. post_tick_ts:    {post_tick_ts}')
    print(f'7. log_delta_bytes: {log_delta}')
    print(f'8. ticks:           {observations["ticks"]}')
    print(f'9. K-3 commits:     {observations["commits"]}')
    print(f'10. post_cron_sha:   {observations["post_cron_sha"]}')
    print(f'11. triggers:        {triggers if triggers else "NONE"}')
    if re_comment_ts:
        print(f'12. re_comment_ts:   {re_comment_ts}')
        print(f'13. post_revert_sha: {post_revert_sha}')
    print('--- new log content ---')
    print(new_log if new_log else '(empty)')
    print('--- end log ---')
    return 3 if triggers else 0


def cmd_restore_baseline():
    """Operator-driven full baseline restore (= for incident recovery)."""
    current_sha = sha256_of(CRON_PATH)
    if current_sha == B0_SHA:
        print(f'no-op: current file already matches B0 baseline ({B0_SHA})')
        return 0
    atomic_write(CRON_PATH, B0_BASELINE, perm=0o644, uid=0, gid=0)
    post_sha = sha256_of(CRON_PATH)
    assert post_sha == B0_SHA, f'restore SHA mismatch: {post_sha}'
    print(f'restored: pre={current_sha} post={post_sha} (= B0 baseline)')
    return 0


def cmd_self_test():
    """In-process unit checks. Returns 0 PASS, 10 FAIL."""
    failures = []

    # Test 1: B0 baseline SHA matches.
    if hashlib.sha256(B0_BASELINE).hexdigest() != B0_SHA:
        failures.append('embedded B0_BASELINE SHA mismatch')

    # Test 2: compute_proposed on B0 baseline yields READY proposed.
    c = compute_proposed(B0_BASELINE)
    if not c['precondition_ok']:
        failures.append(f'compute_proposed on B0 baseline NOT ready: {c["precondition_msg"]}')
    if c['proposed_bytes'] is None:
        failures.append('compute_proposed returned None bytes for valid B0 baseline')
    elif c['proposed_sha'] != '494a825cc8743b3a84c28d02a52358123bad033406d409b8cc2412ffa74f1e1c':
        failures.append(f'compute_proposed SHA mismatch on B0: got {c["proposed_sha"]}')
    if c['old_count_before'] != 1 or c['new_count_before'] != 0:
        failures.append(f'compute_proposed B0 counts before wrong: old={c["old_count_before"]} new={c["new_count_before"]}')
    if c['old_count_after'] != 0 or c['new_count_after'] != 1:
        failures.append(f'compute_proposed B0 counts after wrong: old={c["old_count_after"]} new={c["new_count_after"]}')

    # Test 3: compute_proposed on already-uncommented file returns NOT ready.
    already = B0_BASELINE.replace(OLD_LINE.encode(), NEW_LINE.encode(), 1)
    c2 = compute_proposed(already)
    if c2['precondition_ok']:
        failures.append('compute_proposed should NOT be ready on already-uncommented file')

    # Test 4: line-element match catches the substring trap.
    # If OLD_LINE appears AND NEW_LINE appears as a separate line, we have
    # two distinct elements, not one with substring overlap.
    fake_with_both = OLD_LINE + NEW_LINE + b'\n'.decode()  # decode to str then re-encode below
    c3 = compute_proposed((OLD_LINE + NEW_LINE).encode())
    # NEW_LINE present as element → new_count_before=1 → NOT ready.
    if c3['precondition_ok']:
        failures.append('compute_proposed should NOT be ready when NEW_LINE already present as element')

    # Test 5: atomic_write produces byte-equal file.
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False) as t:
        target = t.name
    try:
        payload = b'hello\nworld\n'
        # When not root, fchown(0, 0) may fail. Use current uid/gid for the test.
        atomic_write(target, payload, perm=0o644, uid=os.geteuid(), gid=os.getegid())
        actual = open(target, 'rb').read()
        if actual != payload:
            failures.append(f'atomic_write content mismatch: {actual!r} vs {payload!r}')
        st = os.stat(target)
        if stat.S_IMODE(st.st_mode) != 0o644:
            failures.append(f'atomic_write perm wrong: {oct(stat.S_IMODE(st.st_mode))}')
    finally:
        try:
            os.unlink(target)
        except OSError:
            pass

    # Test 6: _next_5min_wait_seconds boundary behaviour.
    fake_now = datetime.datetime(2026, 6, 24, 10, 7, 15)
    expected = (10 - 7) * 60 - 15 + 120  # next5=10, wait=3min - 15s + 120s = 285s
    actual = _next_5min_wait_seconds(fake_now)
    if actual != expected:
        failures.append(f'_next_5min_wait_seconds(10:07:15) expected {expected}, got {actual}')

    fake_now2 = datetime.datetime(2026, 6, 24, 10, 58, 0)
    # next5 = 60 → wrap → wait_min = 60 - 58 = 2; wait = 120 - 0 + 120 = 240
    expected2 = 240
    actual2 = _next_5min_wait_seconds(fake_now2)
    if actual2 != expected2:
        failures.append(f'_next_5min_wait_seconds(10:58:00) expected {expected2}, got {actual2}')

    if failures:
        print('SELF-TEST FAILED:')
        for f in failures:
            print(f'  - {f}')
        return 10
    print('SELF-TEST PASS')
    return 0


# ========================================================================
# main
# ========================================================================
def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else '')
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='(default) read-only report; never writes')
    mode.add_argument('--apply', action='store_true', help='write proposed bytes + wait + check triggers + maybe rollback')
    mode.add_argument('--restore-baseline', action='store_true', help='full B0 baseline atomic restore')
    mode.add_argument('--self-test', action='store_true', help='in-process unit checks')
    args = p.parse_args(argv)

    if args.apply:
        return cmd_apply()
    if args.restore_baseline:
        return cmd_restore_baseline()
    if args.self_test:
        return cmd_self_test()
    # default = dry-run
    return cmd_dry_run()


if __name__ == '__main__':
    sys.exit(main())
