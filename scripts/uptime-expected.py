#!/usr/bin/env python3
"""uptime-expected.py — the status page's "予定" (expected) uptime, for shell pushes.

The operator status page (/status/) shows the observed uptime next to an
EXPECTED value: the uptime the cycle would have if the only downtime were the
known outages listed in public/api/known-outages.json. That definition lives
in public/status/status-calc.js (uptimeView / expectedUptime / overlapMs /
signed / LIMITS.uptimeSlackPts). This file is a line-for-line port of it so the
daily status push (scripts/daily-status.sh, via notify.sh's [Uptime] footer)
shows the SAME numbers the page shows.

The two implementations are pinned to each other by one shared fixture,
tests/fixtures/uptime-expected-vectors.json, which tests/daily-status/
test-uptime-expected.sh evaluates against BOTH status-calc.js (node) and this
file. Change the definition in one place and that suite goes red until the
other place and the fixture agree.

One deliberate difference from the page: when known-outages.json is missing,
unreadable, not a JSON array, or holds a time this port cannot read, the page
falls back to "no outages" and prints a note; the push instead says
"予定: 未確認" (fail-closed — never present a guess as the expected value).

Usage:
  uptime-expected.py <validator.json> <known-outages.json>          → suffix
  uptime-expected.py --json <validator.json> <known-outages.json>   → JSON

Suffix (appended by notify.sh right after "[Uptime] <actual>%"):
  " (予定 87.40%・差 -0.09)"
  " (予定 87.40%・差 -7.40)\\n⚠ 想定外の低下 (予定より 0.5 pt 超低い)"
  " (予定: 未確認)"
  ""   — no observed uptime at all (notify.sh prints no footer then anyway)

Read-only: reads two local files, writes stdout only. Exit 0 always for the
suffix mode (a push must never be lost because the expected value could not
be computed); exit 2 on a usage error.
"""
import datetime
import json
import math
import re
import sys
from decimal import Decimal, ROUND_HALF_UP

# Same value as status-calc.js LIMITS.uptimeSlackPts — pinned by the shared
# fixture's threshold vectors (diff -0.49 → no drop, -0.51 → drop).
UPTIME_SLACK_PTS = 0.5

UNCONFIRMED = " (予定: 未確認)"
DROP_LINE = "⚠ 想定外の低下 (予定より 0.5 pt 超低い)"

_EPOCH = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
_NUMERIC = re.compile(r"^\d+(\.\d+)?$")
_ISO = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}:\d{2})$"
)


class Unreadable(Exception):
    """A time string the JS side might parse but this port cannot (fail-closed)."""


def to_ms(x):
    """status-calc.js toMs: ISO string, unix seconds, or epoch ms → epoch ms."""
    if isinstance(x, bool):
        return None
    if isinstance(x, (int, float)):
        if isinstance(x, float) and not math.isfinite(x):
            return None
        return x if x > 1e12 else x * 1000
    if isinstance(x, str) and x != "":
        if _NUMERIC.match(x):
            return to_ms(float(x) if "." in x else int(x))
        m = _ISO.match(x)
        if not m:
            raise Unreadable(x)
        y, mo, d, h, mi, s, frac, tz = m.groups()
        try:
            dt = datetime.datetime(int(y), int(mo), int(d), int(h), int(mi),
                                   int(s or 0), tzinfo=datetime.timezone.utc)
        except ValueError:
            raise Unreadable(x)
        if tz != "Z":
            sign = 1 if tz[0] == "+" else -1
            dt -= sign * datetime.timedelta(hours=int(tz[1:3]), minutes=int(tz[4:6]))
        ms = (dt - _EPOCH) // datetime.timedelta(milliseconds=1)
        if frac:
            ms += int((frac + "00")[:3])  # Date.parse keeps whole milliseconds
        return ms
    return None


def overlap_ms(outages, a, b):
    """status-calc.js overlapMs: ms of [a, b] covered by the (merged) outages."""
    if not (b > a) or not isinstance(outages, list):
        return 0
    spans = []
    for o in outages:
        o = o if isinstance(o, dict) else {}
        s = to_ms(o.get("start"))
        e = to_ms(o.get("end"))
        if s is None or e is None or not (e > s):
            continue
        s = max(s, a)
        e = min(e, b)
        if e > s:
            spans.append((s, e))
    spans.sort(key=lambda p: p[0])
    total = 0
    cur_s = cur_e = None
    for s, e in spans:
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        elif e > cur_e:
            cur_e = e
    if cur_e is not None:
        total += cur_e - cur_s
    return total


def expected_uptime(start_ms, t_ms, outages):
    elapsed = t_ms - start_ms
    if not (elapsed > 0):
        return None
    return 100 * (elapsed - overlap_ms(outages, start_ms, t_ms)) / elapsed


def to_fixed2(x):
    """JS Number.prototype.toFixed(2): exact binary value, ties away from zero."""
    return str(Decimal(x).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def signed(n):
    """status-calc.js signed()."""
    return ("+" if n >= 0 else "-") + to_fixed2(abs(n))


def actual_of(validator):
    up = validator.get("uptime") if isinstance(validator, dict) else None
    a = up.get("network") if isinstance(up, dict) else None
    if isinstance(a, str) and a != "":
        try:
            a = float(a.strip())
        except ValueError:
            return None
    if isinstance(a, bool) or not isinstance(a, (int, float)) or not math.isfinite(a):
        return None
    return a


def compute(validator, outages):
    """→ {"status": "ok"|"unconfirmed"|"no_actual", "expected", "diff", "drop"}.

    outages=None means known-outages.json was missing or unreadable.
    """
    res = {"status": "unconfirmed", "expected": None, "diff": None, "drop": False}
    actual = actual_of(validator)
    if actual is None:
        res["status"] = "no_actual"
        return res
    if not isinstance(outages, list):
        return res
    try:
        S = to_ms(validator.get("startTime"))
        E = to_ms(validator.get("endTime"))
        t = to_ms(validator.get("observedAt"))
        if S is None or E is None or t is None:
            return res
        expected = expected_uptime(S, min(t, E), outages)
    except Unreadable:
        return res
    if expected is None:
        return res
    diff = actual - expected
    res.update(status="ok", expected=to_fixed2(expected), diff=signed(diff),
               drop=actual < expected - UPTIME_SLACK_PTS)
    return res


def suffix(res):
    if res["status"] == "no_actual":
        return ""
    if res["status"] != "ok":
        return UNCONFIRMED
    s = " (予定 " + res["expected"] + "%・差 " + res["diff"] + ")"
    if res["drop"]:
        s += "\n" + DROP_LINE
    return s


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def main(argv):
    as_json = False
    if argv and argv[0] == "--json":
        as_json = True
        argv = argv[1:]
    if len(argv) != 2:
        sys.stderr.write("usage: uptime-expected.py [--json] <validator.json> <known-outages.json>\n")
        return 2
    validator = load(argv[0])
    if not isinstance(validator, dict):
        validator = {}
    res = compute(validator, load(argv[1]))
    if as_json:
        print(json.dumps(res, ensure_ascii=False, sort_keys=True))
    else:
        sys.stdout.write(suffix(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
