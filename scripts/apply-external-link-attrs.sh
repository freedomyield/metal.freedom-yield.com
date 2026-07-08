#!/usr/bin/env bash
# apply-external-link-attrs.sh — enforce target/rel hardening on every
# EXTERNAL <a> tag across the static site (public/ EN pages + public/ja/
# mirror).
#
# WHY: an external <a target="_blank"> without rel="noopener noreferrer"
# lets the destination page's JS reach back into window.opener (the
# classic reverse-tabnabbing vector) and leaks a Referer header naming
# this validator's own pages to every third party we link out to. Adding
# "nofollow" by default on links we don't editorially vouch for is also
# an SEO/link-equity hygiene call the operator wants baked in, not left to
# each page author's memory. Rather than trust every future edit to hand-
# author three rel tokens correctly, this script is the single source of
# truth: default mode rewrites public/**/*.html in place; --check mode
# refuses (non-zero exit) to let a non-compliant page reach production —
# a follow-up task wires that into CI.
#
# CHAIN: none. PRIME_DIRECTIVE: safe — this script never touches a
# blockchain endpoint, wallet, or any broadcast-capable command. It only
# reads/writes local *.html files under the given path.
#
# MINIMAL-DIFF CONTRACT: this tool touches ONLY the rel/target attribute
# bytes inside <a ...> start tags that are classified EXTERNAL below.
# It is deliberately NOT an HTML formatter/parser-and-re-emit tool (no
# BeautifulSoup/lxml/html5lib) — it locates each <a ...> start tag with a
# quote-aware character scan (never regexes across the whole file, so a
# '>' inside a quoted attribute value never truncates a tag early), edits
# only the rel/target attribute value spans (or inserts a whole new
# attribute immediately before the tag's closing '>' when absent), and
# leaves every other byte — indentation, other attributes, text content,
# non-anchor tags such as the googletagmanager preconnect <link>s —
# untouched. Second run over an already-compliant file is byte-identical
# (idempotent).
#
# Classification (which <a> tags are touched at all):
#   - no href, or a relative / #frag / mailto: / tel: / javascript: href
#     -> INTERNAL, untouched.
#   - absolute http(s):// or protocol-relative //host/... href whose host
#     equals OWN_HOST -> INTERNAL, untouched.
#   - anything else -> EXTERNAL: gets target="_blank" + a rel token union.
#   Only real <a ...> start tags are ever considered. <link>/<script>/
#   <img> etc. are never touched, even when they carry an external URL.
#
# rel tokens applied to an EXTERNAL <a>:
#   required = {noopener, noreferrer} + {nofollow} UNLESS the link's host
#   is on the NOFOLLOW_EXEMPT_ALLOWLIST (defined once, near the top of the
#   embedded python below — see that block to add/remove a host). The
#   final rel value is the UNION of (required tokens) and (every
#   pre-existing token already on that tag), de-duplicated case-
#   insensitively, in the canonical order: nofollow, noopener, noreferrer,
#   then any other original tokens in their original relative order. An
#   author's existing token is NEVER dropped — including a redundant
#   "nofollow" an author wrote by hand on an allowlisted host.
#
# Usage:
#   scripts/apply-external-link-attrs.sh [--check] [PATH_OR_GLOB]
#     PATH_OR_GLOB   defaults to "public" — a directory is scanned
#                    recursively for *.html; a glob (containing * ? [) is
#                    expanded; a single file path is scanned as-is.
#     --check        do not write anything. Print every external <a>
#                    tag missing a required rel token or target="_blank"
#                    (file:line: <tag text>) and exit non-zero if any
#                    offender exists; exit 0 with no output if the whole
#                    target already complies. This is what CI runs.
#
# Env overrides:
#   OWN_HOST   hostname treated as "internal" (default: metal.freedom-yield.com)
#
# Exit codes:
#   0  success — write mode: files scanned (0 or more updated); check
#      mode: zero non-compliant external <a> tags found
#   1  --check found at least one non-compliant external <a> tag
#   2  bad arg / usage error, or no HTML files matched PATH_OR_GLOB
#   3  python3 not available (this tool is stdlib-only — no pip deps)

set -euo pipefail

MODE="apply"
OWN_HOST="${OWN_HOST:-metal.freedom-yield.com}"
POSITIONAL=()

for arg in "$@"; do
	case "$arg" in
		--check)
			MODE="check"
			;;
		-h|--help)
			sed -n '2,64p' "$0" | sed 's/^# \?//'
			exit 0
			;;
		--)
			;;
		-*)
			echo "ERROR: unknown flag: $arg" >&2
			exit 2
			;;
		*)
			POSITIONAL+=("$arg")
			;;
	esac
done

if [ "${#POSITIONAL[@]}" -gt 1 ]; then
	echo "ERROR: at most one PATH_OR_GLOB argument accepted (got: ${POSITIONAL[*]})" >&2
	exit 2
fi

TARGET="public"
if [ "${#POSITIONAL[@]}" -eq 1 ]; then
	TARGET="${POSITIONAL[0]}"
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "ERROR: python3 not found on PATH (this tool is stdlib-only — no pip deps)" >&2
	exit 3
fi

python3 - "$MODE" "$OWN_HOST" "$TARGET" <<'PYEOF'
import glob
import os
import re
import sys
from urllib.parse import urlsplit

# ---------------------------------------------------------------------------
# NOFOLLOW-EXEMPT ALLOWLIST — single source of truth, edit ONLY here to add
# or remove a host. Hosts listed here still get target="_blank" + noopener
# + noreferrer like every other external link; they are exempted from the
# automatically-added "nofollow" token because the operator editorially
# trusts/references them (chain explorers, upstream ecosystem docs, our own
# ecosystem). "suffix" entries match the bare host AND any dot-bounded
# subdomain of it (metalblockchain.org matches itself and
# explorer.metalblockchain.org) via a real suffix check on a dot boundary —
# NOT a bare substring match, so a copy-cat host such as
# evilmetalblockchain.org never matches (it does not end in
# ".metalblockchain.org", nor does it equal "metalblockchain.org").
# ---------------------------------------------------------------------------
NOFOLLOW_EXEMPT_ALLOWLIST = {
	"exact": {
		"github.com",
		"tahoe.metalscan.io",
		"explorer.xprnetwork.org",
		"build.avax.network",
	},
	"suffix": {
		"metalblockchain.org",  # + any *.metalblockchain.org subdomain
	},
}


def is_nofollow_exempt(host):
	if host in NOFOLLOW_EXEMPT_ALLOWLIST["exact"]:
		return True
	for base in NOFOLLOW_EXEMPT_ALLOWLIST["suffix"]:
		if host == base or host.endswith("." + base):
			return True
	return False


# ---------------------------------------------------------------------------
# <a ...> start-tag scanner. Quote-aware character walk, NOT a "match up to
# the next >" regex — a '>' inside a quoted attribute value (e.g. a
# calendar URL with an encoded '>') must never truncate the tag early, and
# a bare regex like <a[^>]*> would do exactly that.
# ---------------------------------------------------------------------------
_TAG_BOUNDARY_CHARS = (" ", "\t", "\n", "\r", "\f", ">", "/", "")


def find_a_tag_spans(html):
	spans = []
	i = 0
	n = len(html)
	lower = html.lower()
	while True:
		idx = lower.find("<a", i)
		if idx == -1:
			break
		nxt = html[idx + 2 : idx + 3]
		if nxt not in _TAG_BOUNDARY_CHARS:
			# e.g. <article>, <aside> — not an <a ...> tag at all.
			i = idx + 2
			continue
		j = idx + 2
		quote = None
		found_close = False
		while j < n:
			c = html[j]
			if quote:
				if c == quote:
					quote = None
			elif c in ('"', "'"):
				quote = c
			elif c == ">":
				j += 1
				found_close = True
				break
			j += 1
		if not found_close:
			# Malformed trailing tag (unterminated) — stop scanning rather
			# than guess; nothing after this point can be safely edited.
			break
		spans.append((idx, j))
		i = j
	return spans


# Attribute tokenizer for the inside of a start tag: name, optional
# ="value" in double quotes / single quotes / bare (unquoted).
_ATTR_RE = re.compile(
	r"""([^\s"'>/=]+)(\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"""
)


def parse_attrs(tag_text):
	"""Return (attrs_dict, body_end, closing_len).

	attrs_dict maps lower-cased attribute name -> {
	    'value': str or None,
	    'quote': '"' | "'" | None,
	    'region': (start, end) tag_text-relative span to replace to
	              rewrite the value IN PLACE (includes surrounding quotes
	              for quoted values), or None if the attribute is a bare
	              boolean with no value at all,
	    'name_region': (start, end) tag_text-relative span of the
	              attribute name itself (used as a fallback insertion
	              point for the rare valueless-boolean-attribute case).
	}
	body_end is the tag_text offset of the closing '>' (or '/' of '/>'),
	i.e. the position immediately after the last attribute — the
	insertion point for any wholly-missing attribute.
	closing_len is 1 for a normal '>' close, 2 for a self-closing '/>'.
	"""
	assert tag_text.startswith("<a") and tag_text.endswith(">")
	# Self-closing '/>' is only recognized when the '/' is preceded by
	# whitespace (the universal hand-authored convention, e.g. `<a ... />`)
	# — NOT merely "second-to-last char is '/'". Without that guard, an
	# unquoted attribute value that happens to end in '/' right before '>'
	# (e.g. a bare `href=http://example.com/>`) would have its trailing
	# '/' wrongly stolen as a self-close marker, truncating the value.
	closing_len = (
		2
		if (
			len(tag_text) >= 3
			and tag_text[-2] == "/"
			and tag_text[-3] in (" ", "\t", "\n", "\r", "\f")
		)
		else 1
	)
	body_start = 2
	body_end = len(tag_text) - closing_len
	body = tag_text[body_start:body_end]

	attrs = {}
	for m in _ATTR_RE.finditer(body):
		name = m.group(1)
		if not name:
			continue
		name_lower = name.lower()
		if name_lower in attrs:
			# Duplicate attribute in the same tag: first occurrence wins,
			# matching real browser/HTML-parser behavior.
			continue
		name_region = (m.start(1) + body_start, m.end(1) + body_start)
		if m.group(2) is None:
			value, quote, region = None, None, None
		elif m.group(3) is not None:
			value, quote = m.group(3), '"'
			region = (m.start(3) - 1 + body_start, m.end(3) + 1 + body_start)
		elif m.group(4) is not None:
			value, quote = m.group(4), "'"
			region = (m.start(4) - 1 + body_start, m.end(4) + 1 + body_start)
		else:
			value, quote = m.group(5), None
			region = (m.start(5) + body_start, m.end(5) + body_start)
		attrs[name_lower] = {
			"value": value,
			"quote": quote,
			"region": region,
			"name_region": name_region,
		}
	return attrs, body_end, closing_len


def extract_host(netloc):
	if not netloc:
		return None
	host = netloc.rsplit("@", 1)[-1]
	if host.startswith("["):
		end = host.find("]")
		return host[1:end].lower() if end != -1 else host[1:].lower()
	host = host.split(":", 1)[0]
	host = host.rstrip(".").lower()
	return host or None


_SCHEME_RE = re.compile(r"^([a-zA-Z][a-zA-Z0-9+.\-]*):")


def classify_external_host(href, own_host):
	"""Return the external host string for hrefs the design classifies as
	EXTERNAL, else None (internal / relative / non-http(s) scheme / own
	host / no href)."""
	if href is None:
		return None
	h = href.strip()
	if h == "" or h.startswith("#"):
		return None
	if h.startswith("//"):
		host = extract_host(urlsplit("http:" + h).netloc)
	else:
		m = _SCHEME_RE.match(h)
		if not m:
			return None  # relative href — no scheme, not protocol-relative
		scheme = m.group(1).lower()
		if scheme not in ("http", "https"):
			return None  # mailto:, tel:, javascript:, ftp:, data:, etc.
		host = extract_host(urlsplit(h).netloc)
	if not host:
		return None
	own = own_host.strip().rstrip(".").lower()
	if host == own:
		return None
	return host


_CANON_ORDER = ("nofollow", "noopener", "noreferrer")


def compute_canonical_rel(existing_tokens, required_tokens):
	existing_lower = [t.lower() for t in existing_tokens if t]
	existing_set = set(existing_lower)
	out = []
	for t in _CANON_ORDER:
		if t in required_tokens or t in existing_set:
			out.append(t)
	seen = set(out)
	for t in existing_lower:
		if t in seen:
			continue
		out.append(t)
		seen.add(t)
	return " ".join(out)


def make_replace_edit(attr, tstart, new_value):
	"""Build a (doc_start, doc_end, replacement) edit that rewrites attr's
	value to new_value, preserving the original quote style. A valueless
	boolean attribute (bare `target`, no `=`) is turned into
	name="new_value" by inserting right after the attribute name."""
	if attr["region"] is not None:
		quote = attr["quote"] or '"'
		start, end = attr["region"]
		return (tstart + start, tstart + end, quote + new_value + quote)
	_, name_end = attr["name_region"]
	return (tstart + name_end, tstart + name_end, '="' + new_value + '"')


def scan_file(original, own_host, mode):
	"""Return (edits, offenders) for one file's content.
	edits: list of (doc_start, doc_end, replacement) — empty in check mode.
	offenders: list of (line_number, tag_text) — only populated in check
	mode, for external <a> tags missing a required attribute."""
	edits = []
	offenders = []
	for (tstart, tend) in find_a_tag_spans(original):
		tag_text = original[tstart:tend]
		attrs, body_end, _closing_len = parse_attrs(tag_text)
		href_attr = attrs.get("href")
		href_value = href_attr["value"] if href_attr else None
		host = classify_external_host(href_value, own_host)
		if host is None:
			continue  # internal / non-http(s) / own-host / no href

		required = {"noopener", "noreferrer"}
		if not is_nofollow_exempt(host):
			required.add("nofollow")

		rel_attr = attrs.get("rel")
		existing_tokens = (
			rel_attr["value"].split()
			if (rel_attr and rel_attr["value"])
			else []
		)
		new_rel = compute_canonical_rel(existing_tokens, required)
		current_rel = rel_attr["value"] if rel_attr else None
		rel_compliant = current_rel == new_rel

		target_attr = attrs.get("target")
		target_compliant = bool(target_attr and target_attr["value"] == "_blank")

		if mode == "check":
			if not rel_compliant or not target_compliant:
				line_no = original.count("\n", 0, tstart) + 1
				offenders.append((line_no, tag_text))
			continue

		pending_insert = []  # list of (attr_name, value), inserted together
		if not rel_compliant:
			if rel_attr is not None:
				edits.append(make_replace_edit(rel_attr, tstart, new_rel))
			else:
				pending_insert.append(("rel", new_rel))
		if not target_compliant:
			if target_attr is not None:
				edits.append(make_replace_edit(target_attr, tstart, "_blank"))
			else:
				pending_insert.append(("target", "_blank"))
		if pending_insert:
			# Fixed order (target before rel) regardless of dict/insertion
			# order above — matches this repo's existing hand-authored
			# convention (see the calendar CTA link in public/index.html)
			# and keeps output deterministic/idempotent.
			order = {"target": 0, "rel": 1}
			pending_insert.sort(key=lambda kv: order[kv[0]])
			text = "".join(' {}="{}"'.format(k, v) for k, v in pending_insert)
			insertion_point = tstart + body_end
			edits.append((insertion_point, insertion_point, text))
	return edits, offenders


def apply_edits(original, edits):
	edits = sorted(edits, key=lambda e: (e[0], e[1]))
	out = []
	pos = 0
	for (s, e, rep) in edits:
		if s < pos:
			raise RuntimeError("overlapping edits detected at offset {}".format(s))
		out.append(original[pos:s])
		out.append(rep)
		pos = e
	out.append(original[pos:])
	return "".join(out)


def collect_html_files(target):
	if os.path.isdir(target):
		files = []
		for dirpath, dirnames, filenames in os.walk(target):
			dirnames.sort()
			for fn in sorted(filenames):
				if fn.lower().endswith(".html"):
					files.append(os.path.join(dirpath, fn))
		return sorted(files)
	if any(ch in target for ch in ("*", "?", "[")):
		return sorted(glob.glob(target, recursive=True))
	if os.path.isfile(target):
		return [target]
	return []


def main():
	mode, own_host, target = sys.argv[1], sys.argv[2], sys.argv[3]
	files = collect_html_files(target)
	if not files:
		print("ERROR: no HTML files matched: {}".format(target), file=sys.stderr)
		return 2

	total_offenders = 0
	total_changed = 0
	for path in files:
		with open(path, "r", encoding="utf-8", newline="") as f:
			original = f.read()
		edits, offenders = scan_file(original, own_host, mode)
		if mode == "check":
			for (line_no, tag_text) in offenders:
				print("{}:{}: {}".format(path, line_no, tag_text))
			total_offenders += len(offenders)
			continue
		if not edits:
			continue
		new_content = apply_edits(original, edits)
		if new_content != original:
			with open(path, "w", encoding="utf-8", newline="") as f:
				f.write(new_content)
			total_changed += 1
			print("OK: updated {}".format(path))

	if mode == "check":
		if total_offenders > 0:
			print(
				"FAIL: {} external <a> tag(s) missing a required attribute".format(
					total_offenders
				),
				file=sys.stderr,
			)
			return 1
		print("OK: all external <a> tags compliant ({} file(s) scanned)".format(len(files)))
		return 0

	print("OK: {} file(s) changed, {} file(s) scanned".format(total_changed, len(files)))
	return 0


sys.exit(main())
PYEOF
