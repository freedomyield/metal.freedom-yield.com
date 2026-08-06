#!/usr/bin/env python3
"""check-field-contracts.py — writer/reader JSON field-name contract checker.

CHAIN: none — pure static analysis of repo files. Reads nothing outside the
repo, writes nothing, makes no network call, runs no broadcast-capable command.
PRIME_DIRECTIVE: TESTNET-FIRST — safe (read-only static analysis).

WHY THIS EXISTS
---------------
2026-08-04, mid cycle-transition: scripts/append-anchor-history.sh writes the
per-anchor JSONL field as "dag_root_hash". scripts/gen-anchor-source.sh read
the same line back with

    jq -r '.dag_root // .dag_root_computed // ""'

Neither key exists on that line. jq returned "" for every input, so
prev_anchor_root serialized as null — indistinguishable from genuine genesis —
and the on-chain hash chain would have been permanently severed at cycle 4. A
pre-inscription verify caught it. It had been latent for a month only because
cycle 3 was genesis (empty history file), so the reader never ran against real
data.

The structural cause is not that one jq path was wrong. It is that the writer
and the reader live in DIFFERENT FILES and nothing in the repo ever compared
the two sets of names. Schema validation does not help: a schema constrains
what the WRITER emits; the reader is not schema-aware and can ask for any name
at all, and jq (like JavaScript) hands back null/undefined without complaint.

WHAT THIS CHECKS
----------------
For every JSON/JSONL artifact this repo produces — public feeds under
public/api/ and mutable state under /var/lib/freedom-yield/ — it builds:

  * a WRITER VOCABULARY: every field name the artifact is known to carry,
    unioned from four independent sources (example file, checked-in live file,
    JSON schema, and the emitting script's own object construction), and
  * a READER KEY SET: every field any consumer asks for — jq paths in shell
    scripts, and property accesses in the site's browser JavaScript.

It then reports each reader key matching NO name in the writer vocabulary.
That is precisely the 2026-08-04 shape, and it is language-agnostic: the same
check catches `jq '.dag_root'` against anchor-history.jsonl and
`inc.date || "—"` against incidents.json.

DISCOVERY IS AUTOMATIC — there is no hand-maintained list of feeds and no
hand-maintained list of readers to keep in sync (that dual maintenance is what
rots, and a rotted list is worse than no check). Artifacts are discovered by
scanning public/api/ and by harvesting path literals out of the scripts;
shell readers are discovered by binding variables to artifacts, including
transitively (LAST="$(tail -1 "$HISTORY")"); JS readers are discovered by
following each fetch() of an /api/ path into its response callback. Add a
feed, or a consumer of one, and this picks it up with no edit here.

SEVERITY MODEL — this is what decides whether the check is useful or is noise:

  CRITICAL  The unknown key is guarded by a default — jq `// ""`, `// empty`,
            `// 0`; JS `|| "—"`, `?.`, `? :` — AND is the first alternative in
            its chain. This is the accident's exact disguise: it never errors,
            never logs, and silently yields the default forever.
  HIGH      The unknown key is unguarded: it evaluates to null/undefined and
            surfaces as a downstream failure. Bad, but loud.
  LOW       The unknown key is a LATER alternative in a fallback chain
            (`.good // .typo`, `a.self || a.amount`) — dead debris. Harmless
            today; reported because such debris is exactly what made the real
            bug hard to see (with three alternatives on one line, no reader can
            tell which name is authoritative). Non-fatal unless --strict.

PRECISION / RECALL, STATED HONESTLY
-----------------------------------
Deliberately biased toward NOT crying wolf: a checker that fires falsely gets
ignored, and then the real finding is ignored with it.

  * Vocabulary is an OVER-approximation (four unioned sources; writer-side
    harvesting takes every construction key in an emitting file, not only the
    keys of the one artifact it emits). Over-approximating vocabulary can only
    SUPPRESS findings, never invent them. Every reported finding is therefore a
    name appearing nowhere plausible. False positives are rare by construction;
    the accepted cost is false negatives when a typo happens to collide with an
    unrelated sibling key in the same emitting file.
  * Matching is by KEY NAME, not by full dotted path: `.anchor.tx_id` passes if
    both `anchor` and `tx_id` appear somewhere in the artifact. Full-path
    matching is more precise in theory but breaks on JSONL-vs-array nesting and
    schema $defs indirection, and would generate exactly the noise this check
    cannot afford.
  * Shell: only single-quoted jq programs whose input binds to a KNOWN artifact
    are analyzed. jq against RPC responses, `curl | jq`, and unbound variables
    are skipped by design — they have no writer in this repo to compare to.
  * JS: only property accesses on the fetch() callback's own parameter and its
    one-hop aliases are analyzed, so DOM and local-object properties are not
    mistaken for feed fields. A short list of Array/String/Object builtins is
    subtracted (JS_BUILTINS) — that is a *language* list, not a feed list, so
    it does not create the dual-maintenance problem above.
  * tests/ is NOT scanned by default: fixtures are intentionally synthetic and
    partial, so treating them as writers would widen vocabulary (hiding real
    findings) and treating them as readers would invent findings. --include-tests
    scans them anyway, for manual review.

`--coverage` prints every artifact, its vocabulary sources, and how many read
sites were skipped and why, so the blind spots stay visible rather than
implicit.

Exit codes:
  0  no CRITICAL/HIGH findings (LOW findings may be present; see --strict)
  1  at least one CRITICAL or HIGH finding
  2  usage error / repo layout problem / malformed waiver file

Usage:
  python3 scripts/check-field-contracts.py [--repo=<path>] [--coverage]
          [--strict] [--json] [--quiet] [--include-tests]

Waivers: tests/field-contracts/waivers.txt — one `<artifact> <key>  # reason`
per line. A waiver REQUIRES a `#` justification on the same line; an
unjustified waiver is itself an error (exit 2). Waivers are for genuinely
dynamic or externally-defined names, not for "we'll fix it later".
"""

import json
import os
import re
import sys

# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------

SCHEMA_RE = re.compile(r"^(?P<base>.+?)\.schema\.v\d+\.json$")
EXAMPLE_RE = re.compile(r"^(?P<base>.+?)(?:\.[A-Za-z0-9-]+)?\.example\.(?P<ext>jsonl?)$")
STATE_PATH_RE = re.compile(r"/var/lib/freedom-yield/([A-Za-z0-9._-]+\.jsonl?)\b")
API_PATH_RE = re.compile(r"public/api/([A-Za-z0-9._-]+\.jsonl?)\b")


def walk_files(root, exts):
    out = []
    if not os.path.isdir(root):
        return out
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != "vendor")
        for fn in sorted(filenames):
            if fn.endswith(exts):
                out.append(os.path.join(dirpath, fn))
    return out


def collect_sources(repo, include_tests):
    """(shell_scripts, python_scripts, js_files) — production code by default."""
    shell = walk_files(os.path.join(repo, "scripts"), (".sh",))
    shell += walk_files(os.path.join(repo, "bin"), (".sh",))
    python = walk_files(os.path.join(repo, "scripts"), (".py",))
    # Exclude self: this file names artifacts and field names in its own prose
    # (the 2026-08-04 example), which would otherwise be harvested as writer
    # vocabulary and mask the very bug class it documents.
    python = [p for p in python
              if os.path.basename(p) != os.path.basename(__file__)]
    if include_tests:
        shell += walk_files(os.path.join(repo, "tests"), (".sh",))
    js = walk_files(os.path.join(repo, "public"), (".js",))
    js = [p for p in js if not os.path.basename(p).endswith(".min.js")]
    return shell, python, js


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# Artifact discovery + boundary-safe name matching
# ---------------------------------------------------------------------------


def artifact_hits(text, artifacts):
    """Artifact basenames occurring in `text` as whole filenames.

    Boundary-checked, because plain substring matching conflates
    'anchor-history.json' with 'anchor-history.jsonl' — which silently left
    every anchor-history read site unbound (ambiguous: two hits) and therefore
    unanalyzed. That is, naive matching blinds this checker to the exact file
    the 2026-08-04 incident happened in.
    """
    hits = set()
    for a in artifacts:
        for m in re.finditer(re.escape(a), text):
            after = text[m.end():m.end() + 1]
            if after and (after.isalnum() or after in "._-"):
                continue
            before = text[m.start() - 1:m.start()] if m.start() else ""
            if before and (before.isalnum() or before in "_-"):
                continue
            hits.add(a)
            break
    return hits


def discover_artifacts(repo, texts):
    """{artifact_id: {'samples': [...], 'schemas': [...], 'live': [...]}}."""
    arts = {}

    def ensure(aid):
        return arts.setdefault(aid, {"samples": [], "schemas": [], "live": []})

    api_dir = os.path.join(repo, "public", "api")
    if os.path.isdir(api_dir):
        for fn in sorted(os.listdir(api_dir)):
            path = os.path.join(api_dir, fn)
            if not os.path.isfile(path):
                continue
            m = SCHEMA_RE.match(fn)
            if m:
                # A schema filename does not reveal .json vs .jsonl; attach to
                # both candidates and drop the unreferenced ghost below.
                for ext in ("json", "jsonl"):
                    ensure("%s.%s" % (m.group("base"), ext))["schemas"].append(path)
                continue
            m = EXAMPLE_RE.match(fn)
            if m:
                ensure("%s.%s" % (m.group("base"), m.group("ext")))["samples"].append(path)
                continue
            if fn.endswith(".json") or fn.endswith(".jsonl"):
                ensure(fn)["live"].append(path)

    # Runtime-only artifacts (never checked in): the only evidence they exist
    # is a path literal in the code that produces or consumes them.
    for text in texts:
        for m in STATE_PATH_RE.finditer(text):
            ensure(m.group(1))
        for m in API_PATH_RE.finditer(text):
            fn = m.group(1)
            if SCHEMA_RE.match(fn) or EXAMPLE_RE.match(fn):
                continue
            ensure(fn)

    referenced = set()
    for text in texts:
        referenced |= artifact_hits(text, list(arts))
    for aid in list(arts):
        a = arts[aid]
        if not a["samples"] and not a["live"] and aid not in referenced:
            del arts[aid]
    return arts


# ---------------------------------------------------------------------------
# Vocabulary: what the writers actually emit
# ---------------------------------------------------------------------------


def keys_from_json_value(value, out):
    if isinstance(value, dict):
        for k, v in value.items():
            out.add(k)
            keys_from_json_value(v, out)
    elif isinstance(value, list):
        for v in value:
            keys_from_json_value(v, out)


def keys_from_sample_file(path, out):
    text = read_text(path)
    if path.endswith(".jsonl"):
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                keys_from_json_value(json.loads(line), out)
            except ValueError:
                continue
    else:
        try:
            keys_from_json_value(json.loads(text), out)
        except ValueError:
            return


def keys_from_schema_file(path, out):
    """Every declared property name, at any depth, under any combinator."""
    try:
        schema = json.loads(read_text(path))
    except ValueError:
        return

    def walk(node):
        if isinstance(node, dict):
            props = node.get("properties")
            if isinstance(props, dict):
                for k, v in props.items():
                    out.add(k)
                    walk(v)
            for key in ("items", "additionalItems", "contains", "not",
                        "if", "then", "else", "propertyNames"):
                if key in node:
                    walk(node[key])
            for key in ("$defs", "definitions", "patternProperties",
                        "dependentSchemas"):
                sub = node.get(key)
                if isinstance(sub, dict):
                    for v in sub.values():
                        walk(v)
            for key in ("oneOf", "anyOf", "allOf", "prefixItems"):
                sub = node.get(key)
                if isinstance(sub, list):
                    for v in sub:
                        walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(schema)


# jq object-construction keys: `{foo: ...}` and `{"foo": ...}`.
CONSTRUCT_KEY_RE = re.compile(r'(?:[{,]|\A)\s*"?([A-Za-z_][A-Za-z0-9_]*)"?\s*:')
# JSON keys emitted through printf / heredoc / an embedded python3 -c writer.
# Both quote styles: shell heredocs use "k":, embedded python dicts use 'k':.
QUOTED_KEY_RE = re.compile(r'''["']([A-Za-z_][A-Za-z0-9_]*)["']\s*:''')


def keys_from_writer_text(text, programs, out):
    for prog in programs:
        for m in CONSTRUCT_KEY_RE.finditer(prog):
            out.add(m.group(1))
    for m in QUOTED_KEY_RE.finditer(text):
        out.add(m.group(1))


# ---------------------------------------------------------------------------
# Shell scanning
# ---------------------------------------------------------------------------


def strip_full_line_comments(text):
    """Blank whole-line `#` comments, preserving length and line numbering.

    Trailing comments are deliberately kept: a `#` inside a double-quoted
    string or a jq program would otherwise truncate real code, and losing
    program text is worse than tolerating a little comment prose in the scan.
    """
    return "\n".join(" " * len(l) if re.match(r"^\s*#", l) else l
                     for l in text.split("\n"))


def strip_js_comments(text):
    """Blank `//` and `/* */` comments, preserving length and line numbering.

    Required, not cosmetic: prose in a comment that MENTIONS a field name
    (`// a v.stake.amount fallback used to sit here`) is otherwise parsed as a
    live read of that field, so documenting a removed key re-reports it as a
    finding forever. String literals are tracked so that `https://…` and any
    `/*` inside a string are not mistaken for comment openers.
    """
    out = list(text)
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'`":
            quote = c
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            while i < n and not text.startswith("*/", i):
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            for _ in range(2):
                if i < n:
                    out[i] = " "
                    i += 1
            continue
        i += 1
    return "".join(out)


def skip_double_quoted(text, i):
    i += 1
    n = len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == '"':
            return i + 1
        i += 1
    return n


def find_jq_calls(text):
    """Yield (offset, program, operand_region, preceding_region, argfile_region).

    Only single-quoted jq programs are recognized. Scanning skips double-quoted
    spans so a `--arg x "$VAR"` before the program does not confuse the search
    for the opening quote.

    argfile_region is the text BETWEEN `jq` and the program — where
    `--slurpfile NAME <file>` / `--argfile NAME <file>` bind a SECOND artifact
    into the same program under a jq variable. Without this, every read scoped
    to that variable gets mis-attributed to the main operand's artifact, which
    is how gen-cycle-history.sh's dead `.date` filter on incidents.json hid.
    """
    n = len(text)
    for m in re.finditer(r"(?<![\w./-])jq(?![\w.-])", text):
        i = m.end()
        prog_start = None
        while i < n:
            c = text[i]
            if c == '"':
                i = skip_double_quoted(text, i)
                continue
            if c == "'":
                prog_start = i
                break
            if c == "\\" and i + 1 < n and text[i + 1] == "\n":
                i += 2
                continue
            if c == "\n" or c in "|;)&":
                break        # `jq .` / `jq -e` with no quoted program
            i += 1
        if prog_start is None:
            continue
        prog_end = text.find("'", prog_start + 1)
        if prog_end == -1:
            continue
        program = text[prog_start + 1:prog_end]

        j = prog_end + 1
        while j < n:
            c = text[j]
            if c == '"':
                j = skip_double_quoted(text, j)
                continue
            if c == "\\" and j + 1 < n and text[j + 1] == "\n":
                j += 2
                continue
            if c in "\n|;)&":
                break
            j += 1
        operand = text[prog_end + 1:j]

        # Back to the start of the whole pipeline — NOT just this stage. The
        # input often arrives through a pipe (`printf '%s\n' "$LAST_LINE" |
        # jq -r '...'`), so stopping at `|` discards the very variable that
        # identifies the artifact. That mistake made this checker blind to
        # gen-anchor-source.sh's prev-root read: the exact line of the
        # 2026-08-04 incident.
        k = m.start()
        while k > 0 and text[k - 1] not in "\n;&(":
            k -= 1
        yield (m.start(), program, operand, text[k:m.start()],
               text[m.end():prog_start])


VAR_REF_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
ASSIGN_RE = re.compile(
    r"^[ \t]*(?:local[ \t]+|export[ \t]+|declare[ \t]+(?:-[a-zA-Z]+[ \t]+)?)?"
    r"([A-Za-z_][A-Za-z0-9_]*)=(.*)$",
    re.MULTILINE,
)


def logical_rhs(text, match):
    """RHS of an assignment with continuations and `$( ... )` bodies joined."""
    start = match.start(2)
    i, n, depth = start, len(text), 0
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n and text[i + 1] == "\n":
            i += 2
            continue
        if c == '"':
            i = skip_double_quoted(text, i)
            continue
        if text.startswith("$(", i):
            depth += 1
            i += 2
            continue
        if c == ")" and depth > 0:
            depth -= 1
            i += 1
            continue
        if c == "\n" and depth == 0:
            break
        i += 1
    return text[start:i]


def bind_variables(text, artifacts):
    """Shell variable name -> artifact id, transitively.

    Direct: the RHS names exactly one artifact. Exactly-one is required so a
    line mentioning two artifacts stays unbound rather than mis-attributed.
    Transitive: a command substitution referencing an already-bound variable
    (`LAST="$(tail -1 "$HISTORY")"`) inherits its artifact.
    """
    bindings, assigns = {}, []
    for m in ASSIGN_RE.finditer(text):
        rhs = logical_rhs(text, m)
        assigns.append((m.group(1), rhs))
        # A schema/example path must not bind a variable to the artifact it
        # describes: SCHEMA_FILE=...anchor-history.schema.v2.json reads a
        # schema, not a history line.
        if ".schema.v" in rhs or ".example." in rhs:
            continue
        hits = artifact_hits(rhs, artifacts)
        if len(hits) == 1:
            bindings[m.group(1)] = hits.pop()

    for _ in range(4):                  # fixpoint; alias depth is tiny here
        changed = False
        for name, rhs in assigns:
            if name in bindings or "$(" not in rhs:
                continue
            targets = {bindings[r] for r in VAR_REF_RE.findall(rhs) if r in bindings}
            if len(targets) == 1:
                bindings[name] = targets.pop()
                changed = True
        if not changed:
            break
    return bindings


WRITE_PATTERNS = (
    r">>?\s*\"?\$\{?%s\}?\"?",
    r"\bmv\b[^\n;|]*\"?\$\{?%s\}?\"?",
    r"\bcp\b[^\n;|]*\"?\$\{?%s\}?\"?",
    r"\btee\b[^\n;|]*\"?\$\{?%s\}?\"?",
    r"\bsponge\b[^\n;|]*\"?\$\{?%s\}?\"?",
)


def writer_artifacts(text, bindings, artifacts):
    written = set()
    for var, aid in bindings.items():
        for pat in WRITE_PATTERNS:
            if re.search(pat % re.escape(var), text):
                written.add(aid)
                break
    for aid in artifacts:
        if re.search(r">>?\s*\"?[^\s\"|;]*%s\"?" % re.escape(aid), text):
            written.add(aid)
    return written


# ---------------------------------------------------------------------------
# jq program parsing: which field names does this program READ?
# ---------------------------------------------------------------------------

# A dotted chain not preceded by an identifier char, `$`, `)` or `]`, so
# `$var.field` and `some.file` are not mistaken for field reads.
CHAIN_RE = re.compile(r"(?<![\w$)\]])((?:\.[A-Za-z_][A-Za-z0-9_]*)+)")

# `to_entries` / `with_entries` / `group_by` synthesize these names; they are
# jq's own, not the artifact's.
JQ_ENTRY_BUILTINS = {"key", "value", "name"}
JQ_ENTRY_FNS = ("to_entries", "with_entries", "from_entries", "group_by")


def blank_jq_strings(prog):
    """Space out jq string-literal contents, preserving offsets."""
    out, i, n = list(prog), 0, len(prog)
    while i < n:
        if prog[i] == '"':
            j = i + 1
            while j < n:
                if prog[j] == "\\":
                    j += 2
                    continue
                if prog[j] == '"':
                    break
                out[j] = " "
                j += 1
            i = j + 1
            continue
        i += 1
    return "".join(out)


def classify(before, after_guard_re, is_alt):
    if is_alt:
        return "alternative"
    return "first_guarded" if after_guard_re else "bare"


ARGFILE_RE = re.compile(
    r"--(?:slurpfile|argfile|rawfile)\s+([A-Za-z_][A-Za-z0-9_]*)\s+"
    r"(\"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\"?|\"[^\"]*\"|\S+)")


def bracket_spans(text):
    spans, stack = [], []
    for i, c in enumerate(text):
        if c in "([{":
            stack.append(i)
        elif c in ")]}" and stack:
            spans.append((stack.pop(), i))
    return spans


def jq_read_keys(program, scoped_vars=None):
    """Yield (key, position_class, artifact_override) for each field read.

    artifact_override is non-None when the read is lexically scoped to a jq
    variable bound with --slurpfile/--argfile, i.e. it reads a DIFFERENT
    artifact than the command's main operand.
    """
    prog = blank_jq_strings(program)
    entryish = any(fn in prog for fn in JQ_ENTRY_FNS)

    # Map each `$name` occurrence to the innermost bracket group around it;
    # field reads inside that group are reads of that variable's artifact.
    scopes = []
    if scoped_vars:
        spans = bracket_spans(prog)
        for name, aid in scoped_vars.items():
            for vm in re.finditer(r"\$%s\b" % re.escape(name), prog):
                inner = [(s, e) for s, e in spans if s < vm.start() < e]
                if inner:
                    s, e = min(inner, key=lambda p: p[1] - p[0])
                else:
                    s, e = 0, len(prog)
                scopes.append((s, e, aid))

    def scope_for(pos):
        cands = [(e - s, aid) for s, e, aid in scopes if s < pos < e]
        return min(cands)[1] if cands else None

    for m in CHAIN_RE.finditer(prog):
        before = prog[max(0, m.start() - 24):m.start()]
        after = prog[m.end():m.end() + 24]
        is_alt = re.search(r"//\s*$", before) is not None
        guarded = re.match(r"\s*//", after) is not None
        cls = classify(before, guarded, is_alt)
        override = scope_for(m.start())
        parts = [p for p in m.group(1).split(".") if p]
        for idx, key in enumerate(parts):
            if entryish and key in JQ_ENTRY_BUILTINS:
                continue
            # Only the final segment inherits the guard/alternative class; a
            # parent segment of `.a.b // ""` is not itself "the guarded key".
            yield key, (cls if idx == len(parts) - 1 else "bare"), override


# ---------------------------------------------------------------------------
# JavaScript scanning: fetch('/api/x.json') -> callback -> property reads
# ---------------------------------------------------------------------------

JS_BUILTINS = {
    # Array / String / Object / Promise members that are language surface, not
    # feed fields. Language-level list, so it needs no per-feed maintenance.
    "length", "forEach", "map", "filter", "sort", "join", "slice", "splice",
    "indexOf", "lastIndexOf", "push", "pop", "shift", "unshift", "concat",
    "reduce", "some", "every", "find", "findIndex", "includes", "reverse",
    "toFixed", "toString", "toLowerCase", "toUpperCase", "trim", "split",
    "replace", "replaceAll", "substring", "substr", "charAt", "padStart",
    "padEnd", "startsWith", "endsWith", "localeCompare", "match", "repeat",
    "hasOwnProperty", "then", "catch", "finally", "json", "text", "ok",
    "status", "constructor", "prototype", "call", "apply", "bind",
    "toISOString", "getTime", "valueOf", "keys", "values", "entries",
}

FETCH_RE = re.compile(r"""fetch\s*\(\s*['"]([^'"]*?/api/[A-Za-z0-9._/-]+)['"]""")
# `.then(function (d) {`, `.then(d => `, `.then((d) => `
THEN_PARAM_RE = re.compile(
    r"\.then\s*\(\s*(?:function\s*\(\s*([A-Za-z_$][\w$]*)\s*\)|"
    r"\(\s*([A-Za-z_$][\w$]*)\s*\)\s*=>|([A-Za-z_$][\w$]*)\s*=>)"
)
CALLBACK_PARAM_RE = (
    r"\.(?:forEach|map|filter|find|some|every|sort)\s*\(\s*"
    r"(?:function\s*\(\s*([A-Za-z_$][\w$]*)(?:\s*,\s*([A-Za-z_$][\w$]*))?"
    r"|\(?\s*([A-Za-z_$][\w$]*)\s*\)?\s*=>)"
)
# `data = await res.json()` — the async/await form of a fetch handler. The
# site's incidents page uses this shape, and a .then()-only scanner sees
# nothing there at all.
AWAIT_JSON_RE = re.compile(
    r"(?:var|let|const)?\s*([A-Za-z_$][\w$]*)\s*=\s*await\s+"
    r"[A-Za-z_$][\w$]*\s*\.\s*json\s*\(")


def brace_body(text, start):
    """Text of the brace-balanced block beginning at/after `start`."""
    i = text.find("{", start)
    if i == -1:
        return ""
    depth, j, n = 0, i, len(text)
    while j < n:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
        j += 1
    return text[i:]


NAMED_CALLBACK_RE = (r"\.(?:map|forEach|filter|find|some|every|sort)\s*"
                     r"\(\s*([A-Za-z_$][\w$]*)\s*\)")


def js_read_keys(body, root, file_text=""):
    """Yield (key, position_class) for property reads on `root` and aliases.

    Aliases followed: `var x = data.foo`, inline element callbacks
    (`arr.forEach(function (e) {...})`), and callbacks passed BY NAME
    (`incidents.map(renderIncident)`) — the last one matters because that is
    where a card renderer's per-field reads live, several lines away from the
    fetch that supplied them.
    """
    regions = [body]
    aliases = {root}
    for _ in range(3):
        added = False
        for name in list(aliases):
            for region in list(regions):
                pat = (r"(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*[^;\n]*"
                       r"\b%s\b\s*[.\[]" % re.escape(name))
                for m in re.finditer(pat, region):
                    if m.group(1) not in aliases:
                        aliases.add(m.group(1))
                        added = True
                # Inline element callback: `arr.forEach(function (e) { ... })`
                for m in re.finditer(r"\b%s\b\s*(?:\[[^\]]*\]|\.[\w$]+)*\s*%s"
                                     % (re.escape(name), CALLBACK_PARAM_RE), region):
                    for g in m.groups():
                        if g and g not in aliases:
                            aliases.add(g)
                            added = True
                # Callback passed by name: pull that function's body in and
                # treat its first parameter as an element alias.
                for m in re.finditer(r"\b%s\b\s*(?:\[[^\]]*\]|\.[\w$]+)*\s*%s"
                                     % (re.escape(name), NAMED_CALLBACK_RE), region):
                    fn_name = m.group(1)
                    if fn_name in JS_BUILTINS:
                        continue
                    fm = re.search(r"function\s+%s\s*\(\s*([A-Za-z_$][\w$]*)"
                                   % re.escape(fn_name), file_text)
                    if not fm:
                        continue
                    fn_body = brace_body(file_text, fm.end())
                    if fn_body and fn_body not in regions:
                        regions.append(fn_body)
                        added = True
                    if fm.group(1) not in aliases:
                        aliases.add(fm.group(1))
                        added = True
        if not added:
            break

    seen = set()
    for region in regions:
        for name in aliases:
            pat = (r"(?<![\w$.])%s\b((?:\s*\[[^\]]*\]|\s*\??\.\s*[A-Za-z_$][\w$]*)+)"
                   % re.escape(name))
            for m in re.finditer(pat, region):
                tail = m.group(1)
                after = region[m.end():m.end() + 12]
                props = re.findall(r"\??\.\s*([A-Za-z_$][\w$]*)", tail)
                for idx, prop in enumerate(props):
                    if prop in JS_BUILTINS:
                        continue
                    last = idx == len(props) - 1
                    guarded = (bool(re.match(r"\s*(?:\|\||\?\?|\?[^.])", after))
                               or "?." in tail)
                    # `x.foo != null` / `x.foo === undefined` is an explicit
                    # existence probe — i.e. the author already wrote it as a
                    # defensive alternative. Unknown key there is dead debris,
                    # not a live failure; classing it HIGH would be crying wolf.
                    probe = re.match(r"\s*[!=]==?\s*(?:null|undefined)\b", after)
                    if last and probe:
                        cls = "alternative"
                    else:
                        cls = "first_guarded" if (last and guarded) else "bare"
                    if (prop, cls) in seen:
                        continue
                    seen.add((prop, cls))
                    yield prop, cls


def find_js_reads(text, artifacts):
    """Yield (offset, artifact_id, [(key, class), ...]) per fetch callback."""
    for m in FETCH_RE.finditer(text):
        url = m.group(1)
        base = url.rsplit("/", 1)[-1]
        if base not in artifacts:
            continue
        # Bound the window at the NEXT fetch(): two loaders sitting a few lines
        # apart otherwise bleed into each other, and the second loader's
        # (perfectly valid) reads get charged to the first one's feed — a pure
        # false positive, which is the one thing this check cannot afford.
        nxt = text.find("fetch(", m.end())
        stop = min(m.end() + 4000, nxt if nxt != -1 else len(text))
        window = text[m.end():stop]

        # async/await form: `res = await fetch(...); ... var data = await res.json();`
        am = AWAIT_JSON_RE.search(window)
        if am:
            yield (m.start(), base,
                   list(js_read_keys(window[am.end():], am.group(1), text)))
            continue

        tm = THEN_PARAM_RE.search(window)
        # Skip the `.then(r => r.json())` hop to reach the data callback.
        while tm:
            param = tm.group(1) or tm.group(2) or tm.group(3)
            body = brace_body(window, tm.end()) or window[tm.end():tm.end() + 400]
            if re.search(r"\b%s\s*\.\s*json\s*\(" % re.escape(param), body):
                nxt = THEN_PARAM_RE.search(window, tm.end() + len(body))
                if nxt:
                    tm = nxt
                    continue
            break
        if not tm:
            continue
        param = tm.group(1) or tm.group(2) or tm.group(3)
        body = brace_body(window, tm.end())
        if not body:
            continue
        yield m.start(), base, list(js_read_keys(body, param, text))


# ---------------------------------------------------------------------------
# Waivers
# ---------------------------------------------------------------------------


def load_waivers(repo):
    path = os.path.join(repo, "tests", "field-contracts", "waivers.txt")
    waived, errors = set(), []
    if not os.path.isfile(path):
        return waived, errors
    for lineno, raw in enumerate(read_text(path).split("\n"), 1):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "#" not in line:
            errors.append("%s:%d: waiver without a `# justification` — refusing "
                          "an unexplained waiver: %s" % (path, lineno, line.strip()))
            continue
        decl = line.split("#", 1)[0].split()
        if len(decl) != 2:
            errors.append("%s:%d: expected `<artifact> <key>  # reason`, got: %s"
                          % (path, lineno, line.strip()))
            continue
        waived.add((decl[0], decl[1]))
    return waived, errors


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

SEVERITY_OF = {"first_guarded": "CRITICAL", "bare": "HIGH", "alternative": "LOW"}
RATIONALE_OF = {
    "first_guarded": ("primary key of a fallback chain matches no writer key — "
                      "the default silently substitutes forever, exactly as in "
                      "the 2026-08-04 near-miss"),
    "bare": "unguarded read of a key no writer emits — evaluates to null/undefined",
    "alternative": ("dead fallback: this alternative matches no writer key "
                    "(harmless today, but it obscures which name is authoritative)"),
}
SEV_ORDER = ["CRITICAL", "HIGH", "LOW"]


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, ".."))
    coverage = strict = as_json = quiet = include_tests = False

    for arg in argv[1:]:
        if arg.startswith("--repo="):
            repo = os.path.abspath(arg.split("=", 1)[1])
        elif arg == "--coverage":
            coverage = True
        elif arg == "--strict":
            strict = True
        elif arg == "--json":
            as_json = True
        elif arg == "--quiet":
            quiet = True
        elif arg == "--include-tests":
            include_tests = True
        elif arg in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        else:
            sys.stderr.write("ERROR: unknown arg: %s\n" % arg)
            return 2

    if not os.path.isdir(os.path.join(repo, "scripts")):
        sys.stderr.write("ERROR: no scripts/ under repo root: %s\n" % repo)
        return 2

    shell_files, py_files, js_files = collect_sources(repo, include_tests)
    shell_raw = {p: read_text(p) for p in shell_files}
    shell_text = {p: strip_full_line_comments(t) for p, t in shell_raw.items()}
    py_text = {p: read_text(p) for p in py_files}
    js_raw = {p: read_text(p) for p in js_files}
    js_text = {p: strip_js_comments(t) for p, t in js_raw.items()}

    # Discovery reads RAW text (comments included): a state-file path that only
    # ever appears in a comment still proves the artifact exists, and losing it
    # would silently shrink coverage. Analysis below uses the stripped text.
    artifacts = discover_artifacts(
        repo, list(shell_raw.values()) + list(py_text.values()) + list(js_raw.values()))

    programs = {p: [c[1] for c in find_jq_calls(t)] for p, t in shell_text.items()}
    bindings = {p: bind_variables(t, artifacts) for p, t in shell_text.items()}

    # ---- vocabulary --------------------------------------------------------
    vocab = {aid: set() for aid in artifacts}
    sources = {aid: set() for aid in artifacts}

    def absorb(aid, fn, arg, label):
        before = len(vocab[aid])
        fn(arg, vocab[aid])
        if len(vocab[aid]) > before:
            sources[aid].add(label)

    for aid, meta in artifacts.items():
        for path in meta["samples"]:
            absorb(aid, keys_from_sample_file, path, "example")
        for path in meta["live"]:
            absorb(aid, keys_from_sample_file, path, "live")
        for path in meta["schemas"]:
            absorb(aid, keys_from_schema_file, path, "schema")

    writers = {aid: [] for aid in artifacts}
    for path, text in shell_text.items():
        for aid in writer_artifacts(text, bindings[path], artifacts):
            writers[aid].append(path)
            before = len(vocab[aid])
            keys_from_writer_text(text, programs[path], vocab[aid])
            if len(vocab[aid]) > before:
                sources[aid].add("writer-script")
    # Python emitters (peer-geo.py, peer-analytics.py, embedded python3 -c):
    # attribute by mention, since they write through open()/json.dump rather
    # than a shell redirect. Over-attribution only widens vocabulary.
    for path, text in py_text.items():
        for aid in artifact_hits(text, artifacts):
            if aid not in writers:
                continue
            writers[aid].append(path)
            before = len(vocab[aid])
            keys_from_writer_text(text, [], vocab[aid])
            if len(vocab[aid]) > before:
                sources[aid].add("writer-python")

    waived, waiver_errors = load_waivers(repo)
    if waiver_errors:
        for e in waiver_errors:
            sys.stderr.write("ERROR: %s\n" % e)
        return 2

    # ---- reader analysis ---------------------------------------------------
    findings = []
    analyzed = 0
    skipped_unbound = 0
    skipped_no_vocab = []

    def record(aid, key, cls, rel, ln, snippet, lang):
        findings.append({
            "artifact": aid, "key": key, "class": cls,
            "severity": SEVERITY_OF[cls], "rationale": RATIONALE_OF[cls],
            "file": rel, "line": ln, "lang": lang,
            "snippet": " ".join(snippet.split())[:160],
            "writers": sorted(os.path.relpath(w, repo) for w in writers.get(aid, [])),
        })

    for path, text in shell_text.items():
        rel = os.path.relpath(path, repo)
        binds = bindings[path]
        for offset, program, operand, preceding, argregion in find_jq_calls(text):
            aid = None
            for region in (operand, preceding):
                for var in VAR_REF_RE.findall(region):
                    if var in binds:
                        aid = binds[var]
                        break
                if aid:
                    break
                hits = artifact_hits(region, artifacts)
                if len(hits) == 1:
                    aid = hits.pop()
                    break

            # --slurpfile/--argfile bring a SECOND artifact into the same
            # program under a jq variable; reads scoped to it are checked
            # against that artifact, not the main operand's.
            scoped = {}
            for am in ARGFILE_RE.finditer(argregion):
                operand_txt = am.group(2)
                sub = None
                for var in VAR_REF_RE.findall(operand_txt):
                    if var in binds:
                        sub = binds[var]
                        break
                if sub is None:
                    hits = artifact_hits(operand_txt, artifacts)
                    if len(hits) == 1:
                        sub = hits.pop()
                if sub is not None:
                    scoped[am.group(1)] = sub

            if aid is None and not scoped:
                skipped_unbound += 1
                continue
            if aid is not None and not vocab.get(aid):
                skipped_no_vocab.append((rel, line_of(text, offset), aid))
                aid = None
                if not scoped:
                    continue
            analyzed += 1
            seen = set()
            for key, cls, override in jq_read_keys(program, scoped):
                target = override or aid
                if target is None or not vocab.get(target):
                    continue
                if key in vocab[target] or (target, key) in waived:
                    continue
                if (target, key, cls) in seen:
                    continue
                seen.add((target, key, cls))
                record(target, key, cls, rel, line_of(text, offset), program, "shell")

    for path, text in js_text.items():
        rel = os.path.relpath(path, repo)
        for offset, aid, keys in find_js_reads(text, artifacts):
            if not vocab.get(aid):
                skipped_no_vocab.append((rel, line_of(text, offset), aid))
                continue
            analyzed += 1
            seen = set()
            for key, cls in keys:
                if key in vocab[aid] or (aid, key) in waived or (key, cls) in seen:
                    continue
                seen.add((key, cls))
                record(aid, key, cls, rel, line_of(text, offset),
                       "fetch('%s') callback" % aid, "js")

    # One line of code that reads one bad key is ONE finding. The same
    # property often appears twice at a site under different guard contexts
    # (`x.k != null ? x.k : …`); report the most severe reading only, so the
    # count reflects work to do rather than parser artifacts.
    best = {}
    for f in findings:
        k = (f["artifact"], f["key"], f["file"], f["line"])
        if k not in best or SEV_ORDER.index(f["severity"]) < SEV_ORDER.index(best[k]["severity"]):
            best[k] = f
    findings = list(best.values())

    findings.sort(key=lambda f: (SEV_ORDER.index(f["severity"]), f["artifact"],
                                 f["file"], f["line"], f["key"]))
    counts = {s: 0 for s in SEV_ORDER}
    for f in findings:
        counts[f["severity"]] += 1

    if as_json:
        json.dump({"findings": findings, "counts": counts,
                   "analyzed_sites": analyzed, "artifacts": sorted(artifacts)},
                  sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        if not quiet:
            for f in findings:
                print("%s  %s:%d  [%s]" % (f["severity"], f["file"], f["line"], f["lang"]))
                print("    artifact : %s" % f["artifact"])
                print("    reads    : .%s   (%s)" % (f["key"], f["rationale"]))
                print("    context  : %s" % f["snippet"])
                if f["writers"]:
                    print("    writer(s): %s" % ", ".join(f["writers"]))
                print()
        print("field-contracts: artifacts=%d  read-sites-analyzed=%d  "
              "findings: CRITICAL=%d HIGH=%d LOW=%d"
              % (len(artifacts), analyzed, counts["CRITICAL"], counts["HIGH"],
                 counts["LOW"]))

    if coverage:
        print()
        print("---- coverage ----")
        for aid in sorted(artifacts):
            src = ",".join(sorted(sources[aid])) or "NONE"
            wr = ", ".join(sorted(os.path.relpath(w, repo)
                                  for w in writers.get(aid, []))) or "-"
            print("  %-30s keys=%-4d sources=%-30s writers=%s"
                  % (aid, len(vocab[aid]), src, wr))
        print("  jq sites skipped (input not bound to a known artifact): %d"
              % skipped_unbound)
        if skipped_no_vocab:
            print("  read sites skipped (artifact has NO vocabulary source): %d"
                  % len(skipped_no_vocab))
            for rel, ln, aid in skipped_no_vocab:
                print("    %s:%d -> %s" % (rel, ln, aid))

    if counts["CRITICAL"] or counts["HIGH"]:
        return 1
    if strict and counts["LOW"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
