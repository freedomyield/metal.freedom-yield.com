# External link `rel`/`target` hardening — design

## Problem

The Metal Freedom Yield validator site (`public/` for English, `public/ja/` for the
Japanese mirror) links out to a fixed, small set of third-party destinations: the
Metal Blockchain ecosystem (explorer, wallet, faucet, docs), the chain explorers for
adjacent networks, the project's own GitHub repository, and a handful of one-off
references (a calendar subscription link, external standards documents). Before this
change those `<a>` tags were hand-authored, and hand-authored external links
accumulate two problems as a site grows:

- An external `<a target="_blank">` without `rel="noopener noreferrer"` lets the
  destination page's JavaScript reach back into `window.opener` (reverse tabnabbing),
  and leaks a full `Referer` header naming the visited Metal Freedom Yield page to
  every third party linked out to.
- Links to destinations the operator does not editorially vouch for should carry
  `rel="nofollow"` as SEO/link-equity hygiene, a policy call that is easy to apply
  consistently only if it is enforced mechanically rather than remembered by every
  future page author.

This document records the approved design: which links are "external," what
attributes they must carry, which destinations are exempted from `nofollow`, and the
mechanism (a static rewrite tool plus a CI gate) that applies and then enforces the
policy going forward.

## Definition of "external"

An `<a href="...">` is classified **external** if its `href`:

- is an absolute `http://` or `https://` URL, or a protocol-relative `//host/...`
  URL, and
- resolves to a host other than the site's own host, `metal.freedom-yield.com`.

Everything else is **internal** and is left untouched:

- a relative path (`/pledge/`, `about-metal/`),
- a same-page fragment (`#acknowledgments`),
- a non-`http(s)` scheme (`mailto:`, `tel:`, `javascript:`), or
- an absolute/protocol-relative URL whose host equals the site's own host.

Only real `<a ...>` start tags are ever considered. Other tags that can carry a URL
(`<link>`, `<script>`, `<img>`, the Google Tag Manager preconnect hints, etc.) are
never touched, regardless of what host they point to — this design governs
click-driven navigation, not resource loading.

Host comparison is exact-host, not substring: a URL such as the calendar
subscription link, whose *query string* happens to contain the literal text
`metal.freedom-yield.com` URL-encoded inside a `cid=` parameter, is still classified
by its actual host (`calendar.google.com`) and is therefore external. Conversely, a
GitHub URL whose *path* happens to contain the repository name
`metal.freedom-yield.com` (`github.com/freedomyield/metal.freedom-yield.com/...`) is
external because its host is `github.com`, not because of anything in the path.

## Attributes applied to every external link

Every external `<a>` tag gets exactly two things normalized:

- `target="_blank"` — external destinations open in a new tab/window rather than
  navigating the visitor away from the validator site.
- a `rel` value built from a token union (below).

### `rel` token union rules

The final `rel` value is the union of:

1. the **required tokens** for that link (`noopener`, `noreferrer`, and `nofollow`
   unless the host is on the nofollow-exempt allowlist below), and
2. **every pre-existing token** already present on that tag.

Tokens are de-duplicated case-insensitively. The output order is canonical:
`nofollow`, `noopener`, `noreferrer` first (in that fixed order, whichever of the
three apply), followed by any other original tokens in their original relative
order. An author's existing token is never dropped — including a redundant
`nofollow` an author wrote by hand on an allowlisted host; the allowlist only
controls whether `nofollow` is *added*, not whether it may be *present*.

### Nofollow-exempt allowlist

The following hosts are destinations the operator editorially trusts or actively
references, so they still receive `target="_blank"` and
`rel="noopener noreferrer"` but are exempted from the automatically added
`nofollow` token:

- `github.com` (the project's own source repository)
- `metalblockchain.org`, plus any subdomain of it (e.g. `explorer.metalblockchain.org`,
  `wallet.metalblockchain.org`, `faucet.metalblockchain.org`, `docs.metalblockchain.org`)
- `tahoe.metalscan.io`
- `explorer.xprnetwork.org`
- `build.avax.network`

Subdomain matching is a real suffix check on a dot boundary (a host matches if it
equals the listed host, or ends in `.` + the listed host) — never a bare substring
match. This means a look-alike host such as `evilmetalblockchain.org` does not
match `metalblockchain.org`: it neither equals it nor ends in
`.metalblockchain.org`.

The allowlist is a single, explicit list maintained in one place (inside the tool
described below); it is not inferred from any other config, and adding or removing
an entry is a one-line, reviewable change.

## Why a static rewrite tool, not runtime JavaScript

The design deliberately does the attribute normalization **once, at content-authoring
time, on the static HTML files that ship** — not at page-load time via a JavaScript
snippet that walks the DOM and patches `<a>` tags on every visit. Reasons:

- **No runtime JS surface added.** The site's Content-Security-Policy is not
  relaxed, no new script is added to the page weight or execution path, and there is
  nothing to defer, race, or fail silently against a slow-loading DOM.
- **The published HTML is the actual security boundary.** `rel="noopener noreferrer"`
  only protects a visitor if it is present in the HTML the browser parses; a
  JavaScript patch that runs after initial paint (or that a visitor's script/ad
  blocker prevents from running at all) leaves a real, if brief or occasional,
  window where an unpatched anchor is live.
- **Static output is inspectable and diffable.** Anyone reviewing a page's source,
  or reviewing a pull request, sees the final, correct attributes directly — no
  need to reason about what a script will do to the DOM at runtime.
- **No client-side performance or accessibility cost.** No extra script execution,
  no layout thrash from attribute mutation after render.

## Mechanism: `scripts/apply-external-link-attrs.sh` + CI gate

### The tool

`scripts/apply-external-link-attrs.sh` is a stdlib-only (no `pip` dependencies)
Python script wrapped in a small bash entry point. It takes a directory, glob, or
single file (defaulting to `public`) and recurses to find every `*.html` file. It
locates `<a ...>` start tags with a quote-aware character scan — not a regular
expression applied across the whole file — so a `>` inside a quoted attribute value
(for example, an encoded character in a calendar URL) can never truncate a tag scan
early. It edits only the `rel`/`target` attribute value spans (or inserts a whole
new attribute immediately before the tag's closing `>` when one is absent) and
leaves every other byte of the file — indentation, other attributes, text content,
non-anchor tags — untouched. A second run over an already-compliant file is
byte-identical (idempotent).

The tool has two modes:

- **Apply mode** (default): rewrites non-compliant external `<a>` tags in place and
  reports how many files were changed and scanned.
- **`--check` mode**: writes nothing. It prints every external `<a>` tag that is
  missing a required `rel` token or `target="_blank"` (as `file:line: <tag text>`)
  and exits non-zero if any offender exists, or exits `0` silently if the target is
  fully compliant. This is the mode the CI gate runs.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. Apply mode: files scanned (0 or more updated). Check mode: zero non-compliant external `<a>` tags found. |
| `1` | Check mode found at least one non-compliant external `<a>` tag. |
| `2` | Bad argument / usage error, or no HTML files matched the given path or glob. |
| `3` | `python3` not available on `PATH` (the tool is stdlib-only by design; this should not occur in CI or on the deploy host). |
| `4` | A malformed or unterminated `<a ...>` tag (e.g. an unmatched quote) was found while scanning a file. That file is skipped entirely, and the tool prints a loud, file-and-line-numbered error and writes nothing for that file, in both modes — a compliance gate must never silently stop scanning partway through a file and then report success. |

CI treats **any** non-zero exit as a failed job; it does not special-case any of the
codes above.

### Applying the design to the live site

The tool was run once in apply mode over `public` to bring the entire published
site (English pages and the `public/ja/` Japanese mirror) into compliance in a
single, minimal-diff commit: every changed line is an existing `<a>` tag gaining or
normalizing its `rel`/`target` attributes, with no reformatting, reflow, or
non-anchor byte changed anywhere in the diff, and no `metal.freedom-yield.com`
(own-host) anchor altered.

### CI gate

The `html` job in `.github/workflows/validate.yml` (the job that already lints
every page for `<title>`, `lang`, viewport, and canonical link presence) runs
`bash scripts/apply-external-link-attrs.sh --check public` as an additional step.
Because the tool's own exit code is non-zero on any drift, no extra parsing or
reporting logic is needed in the workflow — a future hand-authored external link
that omits `target="_blank"` or a required `rel` token fails this step, and the job,
before it reaches production. Only this job's steps are touched; the workflow's
other jobs — including the license-free `gitleaks` CLI secret-scan job — are
unmodified by this change.

## Non-goals

- This design does not add, remove, or otherwise change any external link's
  *destination* (`href`). It only normalizes `rel`/`target` on links that already
  exist in the page source.
- It does not change the site's Content-Security-Policy or introduce any new
  script, inline or external.
- It does not attempt to classify or rewrite non-`<a>` elements (`<link>`,
  `<script>`, `<img>`), even when they reference an external host.
