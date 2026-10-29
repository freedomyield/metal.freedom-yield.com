#!/usr/bin/env python3
"""
b6-enable-metal-anomalies-cron.py

Repo-managed transition helper for /etc/cron.d/metal-anomalies.

Mutation rules (= B6 re-design gate, sed BANNED, line-element replace):
  - splitlines(keepends=True) element-equality only (= NEW_LINE is a
    substring of OLD_LINE; substring count would mis-gate)
  - Atomic write: mktemp + fchmod + fchown + fsync + rename
  - Post-write: byte-equal AND SHA-equal verify against in-memory bytes
  - Fail-closed on unknown state

v2 baseline split (= 2026-06-24 redesign after the v1 apply succeeded the
file write but the cron tick failed because the cron file was missing
the ANOMALY_STATE_DIR env assignment):

  B0_OLD  (paused, no ANOMALY_STATE_DIR env) ── T1 ──► B0_NEW (paused + env)
  B0_NEW  (paused + ANOMALY_STATE_DIR env)   ── T2 ──► ACTIVE (uncommented)

Each transition is a separate subcommand with its own expected SHA and
its own report. --apply (= T2) explicitly refuses to run from B0_OLD.

Rollback triggers (= post-T2 observation window):
  a. K-1/K-2/K-3.5/K-4/K-3 gate-error line in /var/log/anomalies.log delta
  b. /var/lib/freedom-yield/quarantine listing changed
  c. /var/lib/freedom-yield/.missing-notified.marker appeared
  d. /var/lib/freedom-yield/anomaly-contention-counter grew by ≥ 2
  e. K-3 committed candidate line in log (= unexplained transition)
  f. /var/lib/freedom-yield/anomaly-state.json mtime advanced
  g. cron file SHA != ACTIVE_SHA after wait (= drift / corruption)
  h. no-success-evidence-in-anomaly-log (primary when fires alongside i*)
  i1. crontab-load-error (= cron daemon parse failure — narrow pattern)
  i2. job-runtime-error-evidence (= job exited non-zero — the 2026-06-24
      incident pattern: bash "line N:" + "is required" + similar)

v1 had a single trigger i:"cron-parse-error" with broad regex that
matched anything in the cron journal. v2 splits this into i1 (= crontab
load) and i2 (= job runtime) for accurate classification. Detection is
not weakened; primary/corroborating roles are explicit.

T2 rollback target is B0_NEW (= the post-T1 paused baseline), NOT B0_OLD.
B0_OLD restore is an emergency operator-explicit action (= --restore-old)
that strips the ANOMALY_STATE_DIR env line; help warns about this.

Usage:
  python3 b6-enable-metal-anomalies-cron.py                       # default: dry-run
  python3 b6-enable-metal-anomalies-cron.py --dry-run             # READ-ONLY report
  python3 b6-enable-metal-anomalies-cron.py --install-new-baseline  # T1
  python3 b6-enable-metal-anomalies-cron.py --apply               # T2 (with wait + rollback)
  python3 b6-enable-metal-anomalies-cron.py --restore-new         # → B0_NEW
  python3 b6-enable-metal-anomalies-cron.py --restore-old         # → B0_OLD (DANGER: strips env)
  python3 b6-enable-metal-anomalies-cron.py --self-test           # unit checks

Exit codes:
   0 success
   1 dry-run NOT-READY / precondition fail (= no mutation done)
   2 write or post-write verify failure (auto-restored)
   3 T2 rollback trigger fired (auto-restored to B0_NEW)
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
ENV_LINE = 'ANOMALY_STATE_DIR=/var/lib/freedom-yield\n'
NTFY_ENV_LINE = 'NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic\n'

# --- 3 known baselines (= immutable bytes, SHA-asserted at module load) --
# B0_OLD = v1 paused baseline (= no ANOMALY_STATE_DIR env).
B0_OLD = (
    b'# === MAINTENANCE PAUSE ===\n'
    b'# anomaly input is invalid; see incident record.\n'
    b'# Resume only after server-status and anomaly validation gates pass.\n'
    b'\n'
    b'# notify.sh uses a sanitized placeholder by default.\n'
    b'# Production topic path must be provided explicitly.\n'
    b'NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic\n'
    b'# */5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1\n'
)
B0_OLD_SHA = '1d7d6e2f07fc20e77593cb523364503bf3770d0c43cf9c69805bb6e5dae8b74e'

# B0_NEW = post-T1 paused baseline (= +ANOMALY_STATE_DIR env). The only
# baseline --apply will accept.
B0_NEW = (
    b'# === MAINTENANCE PAUSE ===\n'
    b'# anomaly input is invalid; see incident record.\n'
    b'# Resume only after server-status and anomaly validation gates pass.\n'
    b'\n'
    b'# notify.sh uses a sanitized placeholder by default.\n'
    b'# Production topic path must be provided explicitly.\n'
    b'NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic\n'
    b'ANOMALY_STATE_DIR=/var/lib/freedom-yield\n'
    b'# */5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1\n'
)
B0_NEW_SHA = '358ac8d367694fa5a43574e0361f68574765c3559f0fc41959a80f5043c281c7'

# ACTIVE = post-T2 active baseline.
ACTIVE = (
    b'# === MAINTENANCE PAUSE ===\n'
    b'# anomaly input is invalid; see incident record.\n'
    b'# Resume only after server-status and anomaly validation gates pass.\n'
    b'\n'
    b'# notify.sh uses a sanitized placeholder by default.\n'
    b'# Production topic path must be provided explicitly.\n'
    b'NTFY_TOPIC_FILE=/etc/freedom-yield/ntfy-topic\n'
    b'ANOMALY_STATE_DIR=/var/lib/freedom-yield\n'
    b'*/5 * * * * deploy bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1\n'
)
ACTIVE_SHA = '3e050b149fca4638ee071902a6ce53d704f0bde1664ea9bf0f99d9eed45ce894'

# Hard module-load guard: any corrupted embedded baseline must fail loud.
for _name, _bytes, _expected in (
    ('B0_OLD', B0_OLD, B0_OLD_SHA),
    ('B0_NEW', B0_NEW, B0_NEW_SHA),
    ('ACTIVE', ACTIVE, ACTIVE_SHA),
):
    _actual = hashlib.sha256(_bytes).hexdigest()
    if _actual != _expected:
        raise RuntimeError(
            f'{_name} embedded bytes SHA mismatch: got {_actual}, expected {_expected}. '
            f'Module refusing to load — possible tamper or mis-edit.'
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
def identify_state(current_bytes):
    """Map current file bytes to one of the known baselines, or UNKNOWN."""
    if current_bytes == B0_OLD:
        return 'B0_OLD'
    if current_bytes == B0_NEW:
        return 'B0_NEW'
    if current_bytes == ACTIVE:
        return 'ACTIVE'
    return 'UNKNOWN'


def compute_install_proposed(current_bytes):
    """T1: B0_OLD bytes → B0_NEW bytes. Same dict shape as compute_proposed."""
    if current_bytes == B0_OLD:
        return dict(
            proposed_bytes=B0_NEW, proposed_sha=B0_NEW_SHA,
            precondition_ok=True, precondition_msg='',
            transition='install-new-baseline',
        )
    return dict(
        proposed_bytes=None, proposed_sha=None,
        precondition_ok=False,
        precondition_msg=f'install-new-baseline requires current SHA == B0_OLD_SHA ({B0_OLD_SHA})',
        transition='install-new-baseline',
    )


def compute_proposed(current_bytes):
    """T2: B0_NEW bytes → ACTIVE bytes via line-element replace.

    v2 precondition change: current MUST be B0_NEW (= post-T1 paused
    baseline). v1 accepted B0_OLD; v2 explicitly refuses because the
    pre-T1 baseline lacks the ANOMALY_STATE_DIR env line that
    check-anomalies.sh requires at runtime.

    Keys:
      proposed_bytes : bytes or None when preconditions fail
      proposed_sha   : str or None
      old_count_before, new_count_before : int (element count in current)
      old_count_after,  new_count_after  : int or None
      env_count      : int — count of ANOMALY_STATE_DIR env-line element
      precondition_ok: bool
      precondition_msg: str (empty if OK)
    """
    if current_bytes != B0_NEW:
        return dict(
            proposed_bytes=None, proposed_sha=None,
            old_count_before=None, new_count_before=None,
            old_count_after=None, new_count_after=None,
            env_count=None,
            precondition_ok=False,
            precondition_msg=f'--apply requires current SHA == B0_NEW_SHA ({B0_NEW_SHA}); v2 refuses B0_OLD',
        )
    text = current_bytes.decode('utf-8')
    lines = text.splitlines(keepends=True)
    old_before = lines.count(OLD_LINE)
    new_before = lines.count(NEW_LINE)
    env_count = lines.count(ENV_LINE)
    # Belt-and-suspenders element-count checks (= already-known to PASS
    # because current_bytes == B0_NEW, but explicit for clarity).
    if old_before != 1 or new_before != 0 or env_count != 1:
        return dict(
            proposed_bytes=None, proposed_sha=None,
            old_count_before=old_before, new_count_before=new_before,
            old_count_after=None, new_count_after=None,
            env_count=env_count,
            precondition_ok=False,
            precondition_msg=f'B0_NEW element counts unexpected: old={old_before} new={new_before} env={env_count}',
        )
    idx = lines.index(OLD_LINE)
    proposed_lines = lines[:idx] + [NEW_LINE] + lines[idx + 1:]
    proposed_bytes = ''.join(proposed_lines).encode('utf-8')
    # Belt-and-suspenders: computed proposed must equal embedded ACTIVE.
    if proposed_bytes != ACTIVE:
        return dict(
            proposed_bytes=None, proposed_sha=None,
            old_count_before=old_before, new_count_before=new_before,
            old_count_after=proposed_lines.count(OLD_LINE),
            new_count_after=proposed_lines.count(NEW_LINE),
            env_count=env_count, precondition_ok=False,
            precondition_msg='computed proposed != embedded ACTIVE bytes — INTERNAL ERROR',
        )
    return dict(
        proposed_bytes=proposed_bytes,
        proposed_sha=ACTIVE_SHA,
        old_count_before=old_before,
        new_count_before=new_before,
        old_count_after=proposed_lines.count(OLD_LINE),
        new_count_after=proposed_lines.count(NEW_LINE),
        env_count=env_count,
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


def render_install_report(current_bytes, file_owner, file_perm, current_sha):
    """T1 install dry-run report (= B0_OLD → B0_NEW). Pure: no I/O."""
    delta = len(B0_NEW) - len(current_bytes)
    out = [
        '=== b6-enable-metal-anomalies-cron.py install-new-baseline dry-run ===',
        f'path: {CRON_PATH}',
        f'transition: B0_OLD → B0_NEW (= add ANOMALY_STATE_DIR env line, keep paused)',
        '',
        f'1. current SHA:  {current_sha}',
        f'2. proposed SHA: {B0_NEW_SHA}',
        f'3. byte delta:   +{delta} (expected +41 = "ANOMALY_STATE_DIR=/var/lib/freedom-yield\\n")',
        f'4. owner: {file_owner} (expected root:root)',
        f'5. perm:  {oct(file_perm)} (expected 0o644)',
        '',
        '6. proposed full content:',
        '   --- begin proposed ---',
    ]
    for ln in B0_NEW.decode('utf-8').splitlines(keepends=False):
        out.append(f'   |{ln}')
    if B0_NEW.endswith(b'\n'):
        out.append('   |\\n (= trailing newline preserved)')
    out.append('   --- end proposed ---')
    out.append('')
    out.append('=== verdict ===')
    ready = (current_bytes == B0_OLD and file_owner == 'root:root' and file_perm == 0o644)
    out.append('READY' if ready else f'NOT-READY (state must be B0_OLD; got SHA {current_sha})')
    return '\n'.join(out), ready


# ========================================================================
# trigger classification (= pure, unit-testable; replaces v1's monolithic
# _check_rollback_triggers regex blob with named primitives)
# ========================================================================
SUCCESS_PATTERN = re.compile(r'^\[K-4\] lock acquired$', re.MULTILINE)

GATE_ERROR_PATTERN = re.compile(
    r'^\[K-1\]|'
    r'^\[K-2\] observedAt|'
    r'^\[K-3\.5\] new corruption|'
    r'^\[K-3\.5\] state file missing|'
    r'^\[K-4\] cannot open lock|'
    r'^\[K-3\] notify permanent fail',
    re.MULTILINE,
)

# Job-runtime error patterns (= bash diagnostics; the 2026-06-24 incident
# matched these). Conservative: requires structured failure evidence,
# not arbitrary 'error' substring.
JOB_RUNTIME_ERROR_PATTERNS = (
    re.compile(r'(?m)^[^\n]*: line \d+: '),
    re.compile(r'(?m)command not found'),
    re.compile(r'(?m)Permission denied'),
    re.compile(r'(?m)No such file or directory'),
    re.compile(r'(?m)is required\b'),
    re.compile(r'(?m)\bunbound variable\b'),
    re.compile(r'(?m)\bsyntax error\b'),
)

# Narrow crontab daemon parse-failure patterns (= NOT job runtime errors).
# v1 broadly grepped /(?i)error|bad|parse|skipped|invalid/ which
# misclassified the 2026-06-24 incident as a crontab parse error when in
# fact it was a job runtime failure caused by missing env.
CRONTAB_LOAD_ERROR_PATTERNS = (
    re.compile(r'\bcrontab[^\n]*\berror\b', re.IGNORECASE),
    re.compile(r'\(\*system\*\)[^\n]*\bbad\b', re.IGNORECASE),
    re.compile(r'\(CRON\)\s+ERROR\b'),
    re.compile(r'\(CRON\)\s+info\s+\(.*crontab.*bad', re.IGNORECASE),
    re.compile(r'\binvalid\s+(day|hour|minute|cron|crontab)\b', re.IGNORECASE),
)


def classify_anomaly_log(log_delta_text):
    """Pure: classify anomaly log delta into structured findings."""
    log_delta_text = log_delta_text or ''
    runtime_matches = []
    for pat in JOB_RUNTIME_ERROR_PATTERNS:
        runtime_matches.extend(pat.findall(log_delta_text))
    sample = ''
    for line in log_delta_text.splitlines():
        if any(p.search(line) for p in JOB_RUNTIME_ERROR_PATTERNS):
            sample = line.strip()
            break
    return dict(
        success_count=len(SUCCESS_PATTERN.findall(log_delta_text)),
        gate_errors_count=len(GATE_ERROR_PATTERN.findall(log_delta_text)),
        job_runtime_error_count=len(runtime_matches),
        k3_commit_count=len(re.findall(r'\[K-3\] committed candidate to ', log_delta_text)),
        k3_equal_count=len(re.findall(r'candidate == original \(canonical\)', log_delta_text)),
        sample_error_line=sample,
    )


def classify_cron_journal(journal_text):
    """Pure: classify cron daemon journal into structured findings."""
    journal_text = journal_text or ''
    job_start_count = len(re.findall(
        r'\(deploy\)\s+CMD\s+\(bash\s+/home/deploy/metal\.freedom-yield\.com/scripts/check-anomalies\.sh',
        journal_text,
    ))
    crontab_load_error_count = 0
    sample = ''
    for line in journal_text.splitlines():
        if any(p.search(line) for p in CRONTAB_LOAD_ERROR_PATTERNS):
            crontab_load_error_count += 1
            if not sample:
                sample = line.strip()
    return dict(
        crontab_load_error_count=crontab_load_error_count,
        job_start_count=job_start_count,
        sample_crontab_error_line=sample,
    )


def evaluate_triggers(baselines, post, log_class, journal_class, post_cron_sha, expected_active_sha):
    """Pure: combine snapshots + classifications into (triggers, primary, corroborating).

    primary / corroborating selection:
      - g (file drift) fires → g is primary (external mutation has top concern)
      - else h (no success evidence) fires → h is primary, others are
        corroborating (= "WHY no success was logged")
      - else first-by-severity (a > c > b > d > e > f > i1 > i2)
    """
    triggers = []
    if log_class['gate_errors_count'] > 0:
        triggers.append(f"a:gate-error-in-anomaly-log-{log_class['gate_errors_count']}")
    if post['quar'] != baselines['quar']:
        triggers.append('b:quarantine-listing-changed')
    if (not baselines['marker']) and post['marker']:
        triggers.append('c:missing-marker-appeared')
    if post['counter_delta'] >= 2:
        triggers.append(f"d:contention-counter-grew-by-{post['counter_delta']}")
    if log_class['k3_commit_count'] > 0:
        triggers.append(f"e:K3-commit-{log_class['k3_commit_count']}-times")
    if post['state_mtime_advanced']:
        triggers.append('f:state-mtime-advanced')
    if post_cron_sha != expected_active_sha:
        triggers.append(f'g:cron-file-drift-{post_cron_sha[:16]}...')
    if log_class['success_count'] == 0:
        triggers.append('h:no-success-evidence-in-anomaly-log')
    if journal_class['crontab_load_error_count'] > 0:
        triggers.append(f"i1:crontab-load-error-{journal_class['crontab_load_error_count']}-lines")
    if log_class['job_runtime_error_count'] > 0:
        triggers.append(f"i2:job-runtime-error-evidence-{log_class['job_runtime_error_count']}-matches")

    if not triggers:
        return triggers, None, []
    g_match = next((t for t in triggers if t.startswith('g:')), None)
    if g_match:
        return triggers, g_match, [t for t in triggers if t != g_match]
    h_match = next((t for t in triggers if t.startswith('h:')), None)
    if h_match:
        return triggers, h_match, [t for t in triggers if t != h_match]
    for prefix in ('a:', 'c:', 'b:', 'd:', 'e:', 'f:', 'i1:', 'i2:'):
        c = next((t for t in triggers if t.startswith(prefix)), None)
        if c:
            return triggers, c, [t for t in triggers if t != c]
    return triggers, triggers[0], triggers[1:]


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
    state = identify_state(current_bytes)

    # State-aware dispatch: B0_OLD → install report; B0_NEW → apply (T2)
    # report; ACTIVE / UNKNOWN → short summary (no transition applicable).
    if state == 'B0_OLD':
        report, ready = render_install_report(current_bytes, owner_str, perm, pre_sha)
    elif state == 'B0_NEW':
        report, ready = render_report(current_bytes, owner_str, perm,
                                      compute_proposed(current_bytes), pre_sha)
    elif state == 'ACTIVE':
        report = (f'=== dry-run report ===\npath: {CRON_PATH}\ncurrent SHA: {pre_sha}\n'
                  f'identified state: ACTIVE (= cron already uncommented). No transition applicable.')
        ready = False
    else:
        report = (f'=== dry-run report ===\npath: {CRON_PATH}\ncurrent SHA: {pre_sha}\n'
                  f'identified state: UNKNOWN. Fail-closed — refuse all transitions.\n'
                  f'Expected one of B0_OLD ({B0_OLD_SHA}), B0_NEW ({B0_NEW_SHA}), '
                  f'ACTIVE ({ACTIVE_SHA}).')
        ready = False

    print(report)
    # Defensive: verify file untouched.
    post_sha = sha256_of(CRON_PATH)
    if post_sha != pre_sha:
        print(f'*** PANIC: file SHA changed during dry-run! pre={pre_sha} post={post_sha} ***')
        return 20
    print(f'post-dry-run file SHA: {post_sha} (= matches pre, file untouched)')
    print('NO WRITE PERFORMED — file on disk unchanged.')
    return 0 if ready else 1


def _read_journal_since(uncomment_ts):
    try:
        return subprocess.run(
            ['journalctl', '-u', 'cron', '--since', uncomment_ts, '--no-pager'],
            capture_output=True, text=True, timeout=10,
        ).stdout or ''
    except (subprocess.SubprocessError, OSError):
        return ''


def _check_rollback_triggers(uncomment_ts, expected_active_sha, baselines, new_log_text):
    """Evaluate post-T2 triggers. Delegates to classify_* + evaluate_triggers.

    Signature kept compatible with v1; semantics tightened (= trigger i
    split into i1 + i2; primary/corroborating returned).

    Returns (triggers, primary, corroborating, observations).
    """
    log_class = classify_anomaly_log(new_log_text)
    journal_class = classify_cron_journal(_read_journal_since(uncomment_ts))

    post_counter_str = open(PROD_COUNTER).read().strip() if os.path.exists(PROD_COUNTER) else 'absent'
    pc = int(baselines['counter']) if baselines['counter'] != 'absent' else 0
    pp = int(post_counter_str) if post_counter_str != 'absent' else 0
    post = dict(
        quar=sorted(os.listdir(PROD_QUAR)) if os.path.isdir(PROD_QUAR) else [],
        marker=os.path.exists(PROD_MARKER),
        counter=post_counter_str,
        counter_delta=pp - pc,
        state_mtime_advanced=os.stat(PROD_STATE).st_mtime_ns != baselines['state_mtime'],
    )
    post_cron_sha = sha256_of(CRON_PATH)

    triggers, primary, corro = evaluate_triggers(
        baselines, post, log_class, journal_class, post_cron_sha, expected_active_sha,
    )
    observations = dict(
        success_ticks=log_class['success_count'],
        k3_commits=log_class['k3_commit_count'],
        k3_equals=log_class['k3_equal_count'],
        job_runtime_errors=log_class['job_runtime_error_count'],
        crontab_load_errors=journal_class['crontab_load_error_count'],
        job_starts_journal=journal_class['job_start_count'],
        post_cron_sha=post_cron_sha,
        log_delta=len(new_log_text),
        sample_error_line=log_class['sample_error_line'],
    )
    return triggers, primary, corro, observations


def cmd_install_new_baseline():
    """T1: B0_OLD → B0_NEW. Atomic write + byte-perfect verify. No wait, no fire."""
    with open(CRON_PATH, 'rb') as f:
        current_bytes = f.read()
    current_sha = hashlib.sha256(current_bytes).hexdigest()
    if current_sha != B0_OLD_SHA:
        print(f'ABORT: --install-new-baseline requires current SHA == B0_OLD_SHA')
        print(f'  current SHA: {current_sha}')
        print(f'  expected:    {B0_OLD_SHA}')
        return 1
    install_ts = now_iso_utc()
    try:
        atomic_write(CRON_PATH, B0_NEW, perm=0o644, uid=0, gid=0)
    except Exception as e:
        print(f'WRITE FAILED: {e}')
        return 2
    post_bytes = open(CRON_PATH, 'rb').read()
    post_sha = hashlib.sha256(post_bytes).hexdigest()
    if post_bytes != B0_NEW or post_sha != B0_NEW_SHA:
        print(f'POST-WRITE VERIFY FAILED: post_sha={post_sha} expected={B0_NEW_SHA}')
        try:
            atomic_write(CRON_PATH, B0_OLD, perm=0o644, uid=0, gid=0)
            print('restored to B0_OLD after verify failure.')
        except Exception as e:
            print(f'*** PANIC: B0_OLD restore failed: {e} ***')
        return 2
    print(f'install-new-baseline OK: transition=B0_OLD→B0_NEW pre={current_sha} post={post_sha} ts={install_ts}')
    return 0


def cmd_apply():
    with open(CRON_PATH, 'rb') as f:
        current_bytes = f.read()
    current_sha = hashlib.sha256(current_bytes).hexdigest()

    # v2: --apply explicitly refuses B0_OLD (= the v1 baseline with no
    # ANOMALY_STATE_DIR env line). Must be run from post-T1 B0_NEW.
    if current_sha != B0_NEW_SHA:
        print(f'ABORT: --apply refuses unless current file == B0_NEW_SHA.')
        print(f'  current SHA: {current_sha}')
        print(f'  expected:    {B0_NEW_SHA}')
        if current_sha == B0_OLD_SHA:
            print(f'  hint: current is B0_OLD; run --install-new-baseline first.')
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
            atomic_write(CRON_PATH, B0_NEW, perm=0o644, uid=0, gid=0)
            print('rolled back to B0_NEW after write failure.')
        except Exception as e2:
            print(f'*** PANIC: B0_NEW restore ALSO failed: {e2} ***')
        return 2

    # Post-write byte-perfect verify.
    post_bytes = open(CRON_PATH, 'rb').read()
    post_sha = hashlib.sha256(post_bytes).hexdigest()
    if post_sha != proposed_sha or post_bytes != proposed_bytes:
        print(f'POST-WRITE VERIFY FAILED: post_sha={post_sha} proposed_sha={proposed_sha}')
        try:
            atomic_write(CRON_PATH, B0_NEW, perm=0o644, uid=0, gid=0)
            print('rolled back to B0_NEW after post-write verify failure.')
        except Exception as e:
            print(f'*** PANIC: B0_NEW restore failed: {e} ***')
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

    triggers, primary, corroborating, observations = _check_rollback_triggers(
        uncomment_ts, ACTIVE_SHA, baselines, new_log)

    re_comment_ts = None
    post_revert_sha = None
    if triggers:
        print(f'ROLLBACK FIRED: {triggers}')
        print(f'  primary cause:     {primary}')
        print(f'  corroborating:     {corroborating}')
        try:
            atomic_write(CRON_PATH, B0_NEW, perm=0o644, uid=0, gid=0)
            re_comment_ts = now_iso_utc()
            post_revert_sha = sha256_of(CRON_PATH)
            assert post_revert_sha == B0_NEW_SHA, f'B0_NEW restore SHA mismatch: {post_revert_sha}'
            print(f're_comment_ts={re_comment_ts} post_revert_sha={post_revert_sha}')
        except Exception as e:
            print(f'*** PANIC: B0_NEW restore failed: {e} ***')

    print('=== apply report ===')
    print(f'1. pre-change SHA:    {current_sha}')
    print(f'2. post-change SHA:   {post_sha}')
    print(f'3. proposed SHA:      {proposed_sha}')
    print(f'4. uncomment_ts:      {uncomment_ts}')
    print(f'5. wait_sec:          {wait_sec}')
    print(f'6. post_tick_ts:      {post_tick_ts}')
    print(f'7. log_delta_bytes:   {log_delta}')
    print(f'8. success ticks:     {observations["success_ticks"]}')
    print(f'9. K-3 commits:       {observations["k3_commits"]}')
    print(f'10. K-3 equals:        {observations["k3_equals"]}')
    print(f'11. job runtime errs:  {observations["job_runtime_errors"]}')
    print(f'12. crontab load errs: {observations["crontab_load_errors"]}')
    print(f'13. job starts (jour): {observations["job_starts_journal"]}')
    print(f'14. post_cron_sha:     {observations["post_cron_sha"]}')
    print(f'15. triggers:          {triggers if triggers else "NONE"}')
    print(f'16. primary cause:     {primary or "(no trigger)"}')
    print(f'17. corroborating:     {corroborating}')
    if re_comment_ts:
        print(f'18. re_comment_ts:    {re_comment_ts}')
        print(f'19. post_revert_sha:  {post_revert_sha}')
    print('--- new log content ---')
    print(new_log if new_log else '(empty)')
    print('--- end log ---')
    return 3 if triggers else 0


def cmd_restore(target_label):
    """Fail-closed restore to B0_OLD or B0_NEW.

    Strict precondition: current bytes must be exactly one of the known
    baselines (B0_OLD, B0_NEW, ACTIVE). UNKNOWN state is refused — the
    operator must triage and explicitly recover before this command will
    act. Same-state restore is a no-op success.

    cmd_restore does NOT wait, does NOT inspect logs, does NOT touch state
    / topic / lock / counter / quarantine, and does NOT manually fire the
    cron job.

    WARNING: --restore-old strips ACTIVE → B0_OLD (= removes both the
    uncommented cron line AND the ANOMALY_STATE_DIR env line). This is an
    emergency-only path that intentionally rolls back past T1 too. Normal
    rollback after a failed --apply targets B0_NEW (= cmd_apply does this
    automatically), NOT B0_OLD.
    """
    if target_label not in ('B0_OLD', 'B0_NEW'):
        print(f'ABORT: target_label must be B0_OLD or B0_NEW, got {target_label}')
        return 64
    target_bytes = {'B0_OLD': B0_OLD, 'B0_NEW': B0_NEW}[target_label]
    target_sha = {'B0_OLD': B0_OLD_SHA, 'B0_NEW': B0_NEW_SHA}[target_label]

    with open(CRON_PATH, 'rb') as f:
        current_bytes = f.read()
    current_sha = hashlib.sha256(current_bytes).hexdigest()
    current_state = identify_state(current_bytes)

    if current_state == 'UNKNOWN':
        print(f'ABORT: current state is UNKNOWN (= not byte-identical to B0_OLD, B0_NEW, or ACTIVE).')
        print(f'  current SHA: {current_sha}')
        print(f'  refusing all restore until operator triages the unknown content.')
        return 1

    transition = f'{current_state}→{target_label}'
    if current_state == target_label:
        print(f'no-op: current state already matches {target_label} ({target_sha})')
        print(f'transition: {transition} (= no mutation needed)')
        return 0

    if target_label == 'B0_OLD' and current_state == 'ACTIVE':
        print('WARNING: ACTIVE → B0_OLD restores past T1 too, stripping ANOMALY_STATE_DIR env line.')
        print('         The normal post-failure rollback target is B0_NEW, not B0_OLD.')

    try:
        atomic_write(CRON_PATH, target_bytes, perm=0o644, uid=0, gid=0)
    except Exception as e:
        # atomic_write either succeeded or did not modify the target.
        # tmp may be left behind; current bytes preserved.
        print(f'RESTORE WRITE FAILED: {e}')
        post_check_sha = sha256_of(CRON_PATH)
        print(f'  current SHA unchanged: {post_check_sha == current_sha}')
        return 2

    post_sha = sha256_of(CRON_PATH)
    if post_sha != target_sha:
        print(f'POST-WRITE VERIFY FAILED: post_sha={post_sha} target_sha={target_sha}')
        return 2
    print(f'restored: transition={transition} pre={current_sha} post={post_sha}')
    return 0


def cmd_self_test():
    """In-process unit checks. Returns 0 PASS, 10 FAIL."""
    failures = []

    # v2: 3 baselines + transitions.
    for name, b, expected in (('B0_OLD', B0_OLD, B0_OLD_SHA), ('B0_NEW', B0_NEW, B0_NEW_SHA), ('ACTIVE', ACTIVE, ACTIVE_SHA)):
        if hashlib.sha256(b).hexdigest() != expected:
            failures.append(f'{name} embedded SHA mismatch')

    # identify_state
    if identify_state(B0_OLD) != 'B0_OLD': failures.append('identify_state(B0_OLD)')
    if identify_state(B0_NEW) != 'B0_NEW': failures.append('identify_state(B0_NEW)')
    if identify_state(ACTIVE) != 'ACTIVE': failures.append('identify_state(ACTIVE)')
    if identify_state(b'garbage\n') != 'UNKNOWN': failures.append('identify_state(garbage)')

    # T1 proposal
    c1 = compute_install_proposed(B0_OLD)
    if not c1['precondition_ok'] or c1['proposed_bytes'] != B0_NEW:
        failures.append(f'compute_install_proposed(B0_OLD) wrong: {c1}')
    if compute_install_proposed(B0_NEW)['precondition_ok']:
        failures.append('compute_install_proposed(B0_NEW) should NOT be ready')

    # T2 proposal (= compute_proposed v2 semantics).
    c2 = compute_proposed(B0_NEW)
    if not c2['precondition_ok'] or c2['proposed_bytes'] != ACTIVE:
        failures.append(f'compute_proposed(B0_NEW) wrong: {c2}')
    if c2.get('proposed_sha') != ACTIVE_SHA:
        failures.append(f'compute_proposed(B0_NEW) SHA mismatch: got {c2.get("proposed_sha")}')
    if compute_proposed(B0_OLD)['precondition_ok']:
        failures.append('compute_proposed(B0_OLD) should NOT be ready (= v2 refuses old baseline)')
    if compute_proposed(ACTIVE)['precondition_ok']:
        failures.append('compute_proposed(ACTIVE) should NOT be ready')

    # Trigger classification: 2026-06-24 incident pattern.
    incident_log = '/home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh: line 45: ANOMALY_STATE_DIR: ANOMALY_STATE_DIR is required\n'
    lc = classify_anomaly_log(incident_log)
    if lc['success_count'] != 0:
        failures.append(f'incident: success_count must be 0, got {lc["success_count"]}')
    if lc['job_runtime_error_count'] < 1:
        failures.append(f'incident: job_runtime_error_count must be >= 1, got {lc["job_runtime_error_count"]}')
    if lc['gate_errors_count'] != 0:
        failures.append('incident: gate_errors_count must be 0 (= bash error is not a K-N gate)')

    # Genuine crontab parse error vs job launch (= must NOT be confused).
    jc_err = classify_cron_journal('Jun 24 10:30:00 host cron[123]: (CRON) ERROR (failed to read crontab: bad day-of-week)\n')
    if jc_err['crontab_load_error_count'] < 1:
        failures.append('crontab parse error fixture: i1 must fire')
    jc_launch = classify_cron_journal('Jun 24 10:30:00 host CRON[123]: (deploy) CMD (bash /home/deploy/metal.freedom-yield.com/scripts/check-anomalies.sh >> /var/log/anomalies.log 2>&1)\n')
    if jc_launch['crontab_load_error_count'] != 0:
        failures.append('job launch CMD line must NOT count as crontab parse error')

    # evaluate_triggers: incident → h primary + i2 corroborating; clean → empty.
    bl = dict(quar=[], marker=False, counter='absent', state_mtime=1, state_sha='x', log_size=0)
    post = dict(quar=[], marker=False, counter='absent', counter_delta=0, state_mtime_advanced=False)
    triggers, primary, corro = evaluate_triggers(bl, post, lc, classify_cron_journal(''), ACTIVE_SHA, ACTIVE_SHA)
    if not any(t.startswith('h:') for t in triggers): failures.append('incident: h trigger missing')
    if not any(t.startswith('i2:') for t in triggers): failures.append('incident: i2 trigger missing')
    if primary is None or not primary.startswith('h:'): failures.append(f'incident: primary should be h, got {primary}')

    lc_normal = classify_anomaly_log('[K-4] lock acquired\n[K-3] candidate == original (canonical); no commit, mtime preserved\n')
    triggers_n, primary_n, _ = evaluate_triggers(bl, post, lc_normal, classify_cron_journal(''), ACTIVE_SHA, ACTIVE_SHA)
    if triggers_n:
        failures.append(f'normal tick: expected NO triggers, got {triggers_n}')

    # atomic_write basic sanity.
    import tempfile
    with tempfile.NamedTemporaryFile(delete=False) as t:
        target = t.name
    try:
        atomic_write(target, b'hello\n', perm=0o644, uid=os.geteuid(), gid=os.getegid())
        if open(target, 'rb').read() != b'hello\n':
            failures.append('atomic_write content mismatch')
    finally:
        try:
            os.unlink(target)
        except OSError:
            pass

    # _next_5min_wait_seconds spot check.
    if _next_5min_wait_seconds(datetime.datetime(2026, 6, 24, 10, 7, 15)) != 3 * 60 - 15 + 120:
        failures.append('_next_5min_wait_seconds(10:07:15)')

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
    mode.add_argument('--dry-run', action='store_true', help='(default) read-only state report; never writes')
    mode.add_argument('--install-new-baseline', action='store_true', help='T1: B0_OLD → B0_NEW (= add ANOMALY_STATE_DIR env, keep paused)')
    mode.add_argument('--apply', action='store_true', help='T2: B0_NEW → ACTIVE (= uncomment; waits + checks triggers + rolls back to B0_NEW on fire)')
    mode.add_argument('--restore-new', action='store_true', help='fail-closed restore to B0_NEW (= normal post-failure target)')
    mode.add_argument('--restore-old', action='store_true', help='fail-closed restore to B0_OLD (= EMERGENCY: strips ANOMALY_STATE_DIR env)')
    mode.add_argument('--self-test', action='store_true', help='in-process unit checks')
    args = p.parse_args(argv)

    if args.install_new_baseline:
        return cmd_install_new_baseline()
    if args.apply:
        return cmd_apply()
    if args.restore_new:
        return cmd_restore('B0_NEW')
    if args.restore_old:
        return cmd_restore('B0_OLD')
    if args.self_test:
        return cmd_self_test()
    # default = dry-run
    return cmd_dry_run()


if __name__ == '__main__':
    sys.exit(main())
