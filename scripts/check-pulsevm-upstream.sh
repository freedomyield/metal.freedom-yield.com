#!/usr/bin/env bash
# check-pulsevm-upstream.sh — watch the PulseVM upstream for the handful of
# changes that would actually oblige this project to act, and stay silent
# otherwise.
#
# CHAIN: none — read-only HTTP GETs against public third-party URLs (seven per
#        run with the default watch list; see S5). No broadcast, no push, no
#        signing, no chain RPC of any kind.
# PRIME_DIRECTIVE: TESTNET-FIRST — this script has no broadcast pathway.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# PulseVM is a metalgo VM plugin that runs the Antelope execution model on
# Avalanche Snowman as a Metal subnet. Its documentation site states that
# A-Chain — the chain this project anchors its cycle receipts to — is to be
# rebuilt on it. If that happens, two things in this repo break at once:
#
#   * bin/safe-broadcast's gate 1 takes its testnet evidence from
#     /v1/history/get_transaction (:266) and gate 3 reads `proton chain:info`
#     (:549). The rebooted A-Chain Alpine testnet offers neither route: its
#     own endpoints page states the Antelope-style /v1/chain REST "is not
#     currently exposed" and directs history reads to the Hyperion /v2 API
#     instead. A permanently-failing gate 1 is a permanent `exit 3`, which
#     under the Prime Directive means mainnet anchoring stops being possible
#     at all.
#   * the public verification story survives, because
#     scripts/gen-anchor-receipt.sh already prefers Hyperion /v2 (:160) and
#     the chain_id is already externalised into FYD_*_CHAIN_ID (:147-150).
#
# The migration has no published date. As surveyed on 2026-08-17, Metallicus's
# own properties (metallicus.com, metalblockchain.org,
# docs.metalblockchain.org, xprnetwork.org) do not mention PulseVM at all, and
# the only place the A-Chain claim is written down is the community-run
# pulsevm.dev docs site — see docs/STRATEGIC_TARGET_ALIGNMENT.md "What PulseVM
# changed" for that survey and which parts of it were re-measured directly.
# So there is nothing to build against yet — only something to WATCH. This
# script is that watch, and its entire design goal is to be silent until one
# of four specific things becomes true.
#
# ---------------------------------------------------------------------------
# THE ENDPOINTS PAGE AS MEASURED 2026-08-19 (S2, fetched and read directly)
# ---------------------------------------------------------------------------
# T1 fired for real on the first cron run against the live page, and reading
# what the page actually says afterwards is what produced the wording rules
# below. Recorded here so the next reader does not have to re-derive it:
#
#   * The "third-party node sync is not yet supported" sentence is GONE. Zero
#     hits for the full sentence and for every fragment of it — "third-party",
#     "node sync", "not yet supported", "sync" — so this is a real removal and
#     not a rewording the default ERE happened to miss.
#   * THE PAGE DOES NOT SAY WE CAN RUN OUR OWN NODE. Its node row reads
#     "PulseVM v0.6.x-series — connect via the public RPC above; validator
#     releases at GitHub". It stopped saying no; it did not start saying yes.
#     This distinction is the whole reason the T1 alert body is written as
#     OBSERVED / NOT ESTABLISHED / OBLIGATION rather than as a conclusion.
#   * The page states its most recent genesis as 2026-08-05, chain id
#     193526980f523c07a567dda80f5f543e2356518ce1475cf3e03d98ca740b3f67 — the
#     SAME id the 2026-08-17 survey recorded, so this is the reset that
#     preceded that survey and NOT a further one. (Said precisely because
#     "Alpine reset again" is the easy thing to write and would have been
#     wrong.) The page's own tip says it "upgrades frequently as development
#     ships", which is why the chain-id sub-condition of T2 pages `default`.
#   * "Antelope-style /v1/chain REST is not currently exposed on the testnet"
#     — still true, and still the single most consequential line on the page
#     for this repo: that REST surface is what bin/safe-broadcast's gate 3
#     (`proton chain:info`) needs. The page routes callers to a native
#     JSON-RPC instead, and to Hyperion /v2 for history.
#   * The indexer is named as hyperion-rs, Metallicus's own Rust Hyperion.
#   * The core token is stated as XPR (4 decimals). The SYS/XPR discrepancy
#     noted in the 2026-08-17 survey is resolved on the page's side.
#   * There is still no mainnet section.
#
# (Recording only. Acting on the /v1/chain line is a separate task and is
# deliberately not attempted here.)
#
# ---------------------------------------------------------------------------
# WHAT IT READS (five sources — none of them a chain RPC; see below)
# ---------------------------------------------------------------------------
#   S1  api.github.com/repos/MetalBlockchain/pulsevm/releases/latest
#         -> .tag_name                       (recorded; never notifies — see below)
#   S2  pulsevm.dev/network/endpoints.md
#         -> the "third-party node sync is not yet supported" sentence,
#            any 64-hex chain id, and whether a mainnet section exists
#   S3  a-chain-alpine-hyperion.metalblockchain.org/v2/health
#         -> head_block_num
#   S4  pulsevm.dev/llms.txt
#         -> the site's own page list
#   S5  registry.npmjs.org — the developer surface the docs tell people to
#         install. Two shapes, both read-only GETs:
#         S5a  <registry>/<name>/latest, once per name in
#              $PULSEVM_NPM_PACKAGES -> whether that exact name has an
#              installable latest version at all, which version, and the
#              identity that publishes it
#         S5b  the registry search API for "pulsevm" -> the set of package
#              names whose name or description mentions PulseVM, which is how
#              a package published under a name we did not guess is noticed
#
# ---------------------------------------------------------------------------
# WHY npm IS WATCHED AT ALL (S5)
# ---------------------------------------------------------------------------
# Measured 2026-08-19, directly against registry.npmjs.org and the docs site:
#
#   * pulsevm.dev/build/get-started tells a newcomer that step 1 is running
#     `pulse-ts create-key`, and quickstart-typescript's template imports from
#     "pulse-tsc" and installs with a plain `npm i`.
#   * `pulse-ts` on npm answers 200 — with an UNRELATED third-party package.
#     It is a TypeScript event emitter; all twelve of its versions were
#     published on one day in 2025-12 and none since; both its repository and
#     homepage fields are null; it has a single maintainer, with no visible
#     connection to Metallicus. So the documented first command installs a
#     stranger's code.
#   * `pulse-tsc` is not on npm at all (404). The docs link it as a GitHub
#     fork of XPR Network's proton-tsc, retargeted at PulseVM.
#   * Exactly one package mentions PulseVM on npm today:
#     @metalblockchain/pulsevm-js, "TypeScript SDK for PulseVM", last
#     published 2026-07-27 from a metalpay.co address. An official surface
#     therefore exists — just not at either name the docs name.
#
# The moment an official package appears at a documented name, or a documented
# name changes hands to a Metallicus identity, is the moment the published
# developer surface stops being aspirational. Whether that deserves the `high`
# channel depends on WHO published it, not on the fact of a publish — see T5.
#
# NOT READ, DELIBERATELY: the Alpine RPC endpoint, which is an AvalancheGo
# per-blockchain URL. scripts/broadcast-guard.sh:98 refuses any command line
# where curl or wget is followed by that per-blockchain path prefix and then
# an X, a P or a C — read-only queries included, because a guard that tries to
# tell a read from a write on that path is a guard with a hole in it.
#
# Be precise about how much that guard actually covers, because the margin is
# thinner than it looks. Those three letters are the chain ALIASES. A full
# blockchain ID is a base58 string, and the current Alpine ID is matched
# solely because base58 happened to give it a leading "C" — a different reset
# could produce an ID starting with any other base58 character and slip
# straight past the pattern. Treating that as protection would be a safety
# claim backed by luck. So this checker does not go near a chain RPC at all:
# every value comes from GitHub, the docs site, and Hyperion /v2, none of
# which carry the shape. The design is right whatever the guard happens to
# cover, which is the point — it does not depend on the guard being right.
#
# The absence is load-bearing, not incidental, and it extends to this comment:
# THIS FILE MUST NOT CONTAIN THE LITERAL PATH PREFIX AT ALL, not even in
# prose, because the invariant is asserted by a plain grep for it in
# tests/pulsevm-upstream/test-pulsevm-upstream.sh (case 12) — a header that
# explains the rule by quoting it would fail the rule. Do not "just add a
# liveness ping", and do not paste the endpoint here as documentation.
#
# (S2's page BODY does carry that shape, in a table row this script never
# parses. Reading a document that mentions a URL is not requesting it.)
#
# ---------------------------------------------------------------------------
# WHAT IT NOTIFIES ABOUT (and what it deliberately does not)
# ---------------------------------------------------------------------------
# Two channels. `high` means "the ground moved, go and act"; `default` means
# "something changed, read it when you get to it". Which one a run uses is
# decided by what fired ON THAT RUN — see the PRIORITY SPLIT comment above the
# trigger block for the reasoning and for why a state-based test would be
# wrong. A run that fires both kinds escalates to `high`.
#
#   T1  [high]  the "third-party node sync is not yet supported" sentence is
#         GONE from S2. Still the most important signal here, because it is
#         the only one that could convert "watch" into "act" — but THE
#         ABSENCE OF A PROHIBITION IS NOT A CAPABILITY. All this checker
#         measures is that a sentence stopped matching; a page can remove
#         "not supported" and go on routing readers to a public RPC, which is
#         exactly what happened on 2026-08-19 (see the measurement block
#         above). The alert body therefore separates what was OBSERVED from
#         what is NOT ESTABLISHED, and names reading the page as the
#         obligation instead of announcing a conclusion.
#   T2  S2 grew a mainnet section, or shows a chain id we have not seen
#         before. These are two sub-conditions with two different weights and
#         the alert names which one fired:
#           mainnet section [high]  -> the page grew a markdown HEADING that
#             matches "mainnet". That is the earliest shape a migration would
#             take, but a heading is not a live endpoint — "A-Chain Mainnet
#             (not yet live)" matches identically — so the alert reports the
#             heading and asks for the gate assumptions to be re-checked,
#             rather than declaring that the migration landed.
#           new chain id  [default] -> possibly the migration, but far more
#             often just another Alpine reset. The page itself says it
#             upgrades frequently as development ships and keeps its chain
#             ids current, so this is the one path likely to be routine.
#   T3  [default]  S4's page list grew -> a new page is the earliest warning
#         available, because a migration date or a validator-onboarding route
#         would have to be published somewhere before anything else changes.
#   T4  [default]  S3's head block advanced by at least
#         $PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA since the last run -> Alpine
#         started producing blocks for real.
#   T5  the npm surface moved. Three sub-conditions, and the AFFILIATION of
#         the publisher — not the bare fact of a publish — picks the channel:
#           a watched name goes from having no installable latest version to
#           having one:
#             under an identity matching $PULSEVM_NPM_OFFICIAL_RE  [high]
#               -> the publisher fields on a name the docs tell people to
#               install now carry a Metallicus organisation token. Verify the
#               publisher, re-read the get-started page, and check whether a
#               node or validator route shipped alongside.
#             under any other identity  [default]  -> the name is now taken,
#               by someone. Verify who before typing the documented command.
#           a name that was ALREADY published changes hands INTO a matching
#           identity  [high]  -> same obligation; this is the shape a takeover
#             of the existing `pulse-ts` name would have.
#           S5b's set gains a name we have not recorded  [default], escalated
#             to [high] when the new name itself matches -> read it.
#
#         WHY AFFILIATION, AND WHY NOT THE SUBJECT WORD. The default pattern
#         is organisation tokens only and deliberately EXCLUDES "pulsevm",
#         even though that is the very word S5b searches for. "pulsevm" names
#         the SUBJECT of a package, not its owner: any admirer can publish
#         `pulsevm-tools`, and matching the subject would route a stranger's
#         package straight onto the `high` channel — precisely the
#         training-into-noise the PRIORITY SPLIT below exists to prevent.
#
#         A MATCH IS EVIDENCE, NOT PROOF; A NON-MATCH IS NOT A VERDICT. The
#         pattern is tested against the package name (so an @metalblockchain
#         scope counts), its maintainers' npm usernames and e-mail addresses,
#         the last publisher, and the repository/homepage URLs. Metallicus
#         publishing from a personal account with no repository field would
#         not match, and would page at `default` instead of `high` — the alert
#         still names the package and still tells the reader to verify the
#         publisher, so nothing is missed and only the channel is softer. No
#         T5 body ever asserts that a package IS official; every one of them
#         says to check.
#
#   BASELINE  [high]  no usable prior state -> fires once, says exactly that,
#         and records a baseline. High because until it runs, this monitor was
#         not actually watching anything, and the operator should know that
#         happened. See "fail open" below.
#
# Every alert body names the OBLIGATION, not just the observation — what to go
# and re-check. The script's whole premise is "the changes that would oblige
# this project to act", and a page that reports a fact without naming the
# action makes the reader reconstruct it at the worst possible moment.
#
# AND NO ALERT BODY MAY CLAIM MORE THAN THE RUN MEASURED. This is a rule with
# a scar behind it: the first T1 body ended "running our own node may now be
# possible", which the checker had not measured and the upstream page did not
# say. An alert is the most-read surface this repo has — nobody diffs the
# header comment at 11:00 JST — so an over-claim there is the worst place for
# the "declaration stronger than implementation" failure to land. The shape
# every body follows now is:
#
#   OBSERVED      the literal thing this run compared, and nothing else
#   NOT ESTABLISHED  the conclusion a reader would jump to, explicitly denied
#                 (T4 words it as the alternative reading rather than as a
#                 denial, which is the same move in the other grammar)
#   OBLIGATION    what to go and read or re-check, in order to find out
#
# EVERY means every: the three shipped by an alert() call are the trigger page,
# the first-run BASELINE page, and the outage page, and ALL THREE carry all
# three labels. The first draft of this rule exempted the latter two without
# saying so — the header claimed "every alert body" while eight of the suite's
# twenty-three bodies had neither label, and the suite could not catch it
# because the shape assertion was only wired to seven trigger cases. That is
# the same declaration-stronger-than-implementation failure this whole block
# exists to end, reproduced inside its own correction. The two that were
# missing are, on inspection, the two that most needed it:
#
#   BASELINE  pages `high` and reports a page full of values. Without the
#             disclaimer a reader takes them for changes. They are first
#             readings, compared against nothing.
#   outage    is the single easiest alert in this file to misread as "checked,
#             nothing changed". A run that could not read a source compared
#             NOTHING, and the body now says so in those words.
#
# The enforcement is structural rather than per-case, for the same reason:
# tests/pulsevm-upstream/test-pulsevm-upstream.sh tees every notification the
# whole suite emits into one ledger that survives teardown, then asserts at the
# end that EVERY line carries OBSERVED and OBLIGATION and matches no phrase on
# the over-claim denylist. A new alert added without the shape fails even if
# nobody remembers to assert it — which is exactly what went wrong here. The
# denylist itself is a backstop, not the rule: it can only catch the phrasings
# someone thought to list. The rule is the shape above.
#
# NOT notified: a new release tag. Releases land roughly weekly and mean
# nothing on their own; the tag is written to the log and to the state file
# so it is there when a real trigger needs context. (This is the plan's
# explicit call, and it is what keeps a daily cron at zero pages in steady
# state — see the operator's standing "no false urgency" rule.)
#
# NOT notified either, all three logged with both values instead:
#   * a watched npm package's VERSION moving. Same rule as the release tag,
#     for the same reason — `pulse-ts` shipped twelve versions in one
#     afternoon, and a version counter is not a change of surface.
#   * a watched npm package DISAPPEARING. The documented command failing
#     loudly is strictly less dangerous than it installing a stranger's
#     package, so an unpublish is a hazard going down, not an obligation
#     appearing. If an official package then takes the freed name, the
#     absent -> present sub-condition pages on that.
#   * a watched name changing hands between two identities that BOTH fail to
#     match. One stranger handing a package to another stranger does not
#     change what this project would do about it.
#   * a watched name LOSING a match it previously had. That returns the name
#     to the state it is in today — a documented name in unaffiliated hands —
#     which is this watch's steady state and its stated premise, not a new
#     obligation. It is logged for the same reason the others are: so the
#     next real trigger has the history in front of it.
#
# NOT notified either: a single failed fetch. See "Fetch failures" below.
#
# ---------------------------------------------------------------------------
# FAIL OPEN, TOWARD ALERTING
# ---------------------------------------------------------------------------
# Detection is a diff against $PULSEVM_UPSTREAM_STATE. A missing, unreadable,
# or unparseable state file therefore leaves the diff undefined — and an
# undefined diff must never resolve to silence, because "the state file got
# corrupted six months ago" and "nothing has changed" would then look
# identical from the outside. So:
#
#   * no usable prior state  -> the run FIRES (exit 3) with reason BASELINE.
#   * T1 and T2 are additionally evaluated from the CURRENT observation alone
#     whenever they can be (the sync notice being absent right now, or a
#     mainnet section existing right now, are facts that need no history), so
#     a first run against an already-changed upstream reports the real
#     condition rather than only "baseline recorded".
#   * T3 and T4 are pure diffs and cannot be evaluated without history. They
#     are reported as DEFERRED in the message rather than claimed as fired —
#     firing is the safe direction, but SAYING something fired when nothing
#     was compared is a fabricated claim, and this repo does not make those.
#   * T5 splits along the same seam. "This watched name is published under a
#     matching identity RIGHT NOW" needs no history, so it is evaluated on a
#     baseline run too. Its transitions (absent -> present, an owner newly
#     matching, a name new to the search set) are pure diffs and are DEFERRED
#     with T3/T4.
#
# The first run of a fresh install is therefore expected to page once and
# then go quiet. That is the intended behaviour, not a defect.
#
# ONE NAME WITHOUT HISTORY IS NOT A BASELINE. Adding a name to
# $PULSEVM_NPM_PACKAGES leaves the state file perfectly usable and exactly one
# name uncomparable. That case logs "first observation of <name>" and does NOT
# fire: the state is not undefined, so the fail-open argument does not apply,
# and the operator who just edited the list is already looking at it. Only a
# state file that cannot be read or trusted AS A WHOLE re-baselines.
#
# ---------------------------------------------------------------------------
# FETCH FAILURES (exit 4 / 5) — one page per outage, not one per day
# ---------------------------------------------------------------------------
# Every one of the five sources is someone else's property: a community
# developer's Vercel deployment, GitHub's unauthenticated API (60 requests/hour
# per IP, which answers 403 — not 429 — when exhausted), Hyperion, and the npm
# registry. Paging the operator every
# time a third party has a bad morning is precisely the false urgency that
# makes a real alert invisible. Going permanently quiet because a URL moved is
# worse.
#
# So a failed run increments `consecutive_failures` in the state file and
# alerts ONCE, at `default` priority, on the exact run where the counter
# REACHES $PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER (default 3 = three days on the
# daily cron). Equality, not `-ge`: a week-long outage pages on day three and
# then stops. Any successful run resets the counter to 0, which re-arms that
# single page for the next distinct outage.
#
# In dry mode (no FY_LIVE=1) the counter is not persisted, so this escalation
# is a live-cron behaviour only — consistent with every other side effect
# here, and stated so the reader does not expect a test to observe it without
# setting FY_LIVE=1 and a sandbox state path.
#
# S5 needs one extra rule, because npm answers a question the other four
# sources do not: A 404 ON A PACKAGE'S /latest IS DATA, NOT AN OUTAGE. "This
# name has no installable latest version" is exactly the fact T5 watches for a
# change in, so 200 and 404 are both accepted there and everything else (403,
# 429, 5xx, a connection failure) still fails the run. fetch()'s "a 4xx is a
# verdict, do not retry" rule makes an absent package cost exactly one request
# per run, which is what keeps a daily poll of a public registry polite.
#
# S5b gets NO such exemption. A 404 on the search API means the API moved, and
# "read nothing" must not be allowed to look like "read zero packages" — that
# is the same confusion the S4 empty-page-list guard refuses, for the same
# reason: recording an empty set would make the NEXT healthy run fire T5 and
# name every package as new.
#
# One failure path is outside the counter: a missing jq. That exits 5 before
# the state file is even read, and it could not write the counter afterwards
# either, since composing the state needs jq. A host without jq has bigger
# problems than this watch (the anchor pipeline needs it too), so it is left
# as a loud exit rather than given a jq-free counter of its own.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  all four sources read, nothing fired (verbose: one heartbeat line)
#   3  at least one trigger fired (T1 / T2 / T3 / T4 / BASELINE) — alerts
#   4  a source did not return HTTP 200 after retrying
#   5  a source returned 200 but its body could not be parsed (or jq is absent)
#   6  scripts/lib/side-effects.sh is missing/unreadable
#
# There is deliberately no 64 here. scripts/lib/side-effects.sh returns 64 for
# "you called me wrong", but every call site in this file either swallows it
# (alert(), by contract — a watch must not die because its alert channel is
# down) or ignores it (state_write, whose failure is a logged WARN and never
# an exit code, matching check-anchor-publish-health.sh's best-effort state
# contract). So 64 cannot reach the caller, and listing it would describe a
# path that does not exist.
#
# ---------------------------------------------------------------------------
# STATE SCHEMA
# ---------------------------------------------------------------------------
# $PULSEVM_UPSTREAM_STATE carries schema_version 2. A version-1 file (S1-S4
# only) cannot answer T5's "was this name published yesterday", so it is NOT
# upgraded in place: it fails the gate below, the run re-baselines, and the
# operator gets one BASELINE page. That is the fail-open rule applied to our
# own format change rather than to someone else's outage, and it is why the
# version is compared with `==` and not `>=` — a file written by a newer
# format is equally uncomparable, in the other direction.
#
# The first run after this change therefore pages once on any host that
# already had a state file. Expected, not a defect; same contract as a fresh
# install.
#
# DEPLOY HOLD (2026-08-19). Be concrete about what that page will say, because
# it is louder than "a baseline was recorded". A version-1 file forces
# PREV_OK=0, and T1 is re-evaluated from the CURRENT page alone on a baseline
# run — and the live endpoints page no longer carries the sync notice. So the
# first run on the validator host sends `BASELINE,T1` at **high**: a verbatim
# resend of the T1 body the operator already received today. That is a
# duplicate act-now page, not a routine first-run notice.
#
# This branch is therefore merged but NOT deployed to the host. Deployment
# waits until after the 2026-09-04 cycle transition and is announced in
# advance as "this will page once, and it is the known T1 resend". Do not
# install it on the host before then.
#
# ---------------------------------------------------------------------------
# ENV OVERRIDES
# ---------------------------------------------------------------------------
#   FY_LIVE=1   REQUIRED for the ntfy push, for the state write, AND for the
#               file log. The cron env header carries it; tests deliberately
#               do not.
#
#               The file log is gated here, which differs from
#               scripts/check-anchor-publish-health.sh (where the log is
#               deliberately NOT gated). The reason for the difference: that
#               checker's log is an audit trail of OUR published state, so a
#               dry tick still owes the record. This one's log is a diary of a
#               third party's website, the state file it would sit beside in
#               logs/ is gated anyway, and the requirement for this task is
#               that a dry run leave logs/ byte-identical. Visibility is not
#               lost: every line still goes to stderr, the installed cron
#               pipes stderr to `logger`, and the first suppressed write emits
#               one "DRY: would ..." line naming the log path.
#
#   FYD_NOTIFY            notifier delegate (resolved by side-effects.sh)
#   FYD_CURL              curl binary (tests point this at a stub)
#   FYD_FETCH_ATTEMPTS    max attempts per fetch (default 3)
#   FYD_RETRY_SLEEP       seconds between attempts (default 3; tests set 0)
#
#   PULSEVM_UPSTREAM_LOG        file log (default: repo-local
#                               ${SCRIPT_DIR}/../logs/pulsevm-upstream.log —
#                               /var/log is not deploy-writable on the host)
#   PULSEVM_UPSTREAM_STATE      state file (default: repo-local
#                               ${SCRIPT_DIR}/../logs/pulsevm-upstream-state.json)
#   PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA   T4 threshold (default 1000). A chain
#                               producing even one block a minute advances
#                               1440 in a day; a stalled one advances 0
#                               (Alpine's head block was 3406 across repeated
#                               samples on 2026-08-17). 1000 sits below the
#                               one-per-minute floor and far above the handful
#                               of blocks a manual poke produces.
#   PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER  consecutive failures before the one
#                               outage page (default 3). MUST BE >= 1 to page
#                               at all: the counter starts at 1 on the first
#                               failed run and the comparison is `-eq`, so 0
#                               can never be met. That is a legal way to
#                               silence the outage page entirely — it is
#                               documented rather than rejected, because
#                               "never tell me about a third party's downtime"
#                               is a reasonable thing to want — but it is NOT
#                               a way to make it page sooner, and it does not
#                               affect the T1-T4 triggers, which are never
#                               gated by this value.
#   PULSEVM_UPSTREAM_SYNC_NOTICE_RE  ERE for the T1 sentence (default
#                               'third-party node sync is not yet supported',
#                               matched case-insensitively). Any rewording
#                               upstream makes this stop matching and T1 fire
#                               — a false page in the SAFE direction. Adjust
#                               the override rather than widening the default
#                               to something that would also match a reworded
#                               "now supported".
#   PULSEVM_NPM_REGISTRY  registry base for S5a (default
#                               https://registry.npmjs.org). The URL built
#                               from it is <base>/<name>/latest — the small
#                               per-version manifest, not the full packument,
#                               which carries the whole readme and would be an
#                               order of magnitude more bytes to pull daily
#                               for the same four fields.
#   PULSEVM_NPM_SEARCH_URL  the S5b discovery query (default: the registry
#                               search API for "pulsevm", size 50). NOTE: the
#                               registry search API has NO `scope:` qualifier
#                               — measured 2026-08-19, `scope:pulsevm` and the
#                               control `scope:babel` both answer total 0 — so
#                               "watch the @pulsevm scope" is not something
#                               this API can be asked. A free-text query is
#                               what actually exists, and the parsed names are
#                               filtered client-side against the npm name
#                               grammar so a loosened server-side match cannot
#                               inject a result. size 50 sits far above
#                               today's total of 1; if the total ever exceeds
#                               what comes back, the run logs that the set is
#                               truncated rather than silently diffing a
#                               partial one.
#   PULSEVM_NPM_PACKAGES  space-separated exact names for S5a (default
#                               "pulse-ts pulse-tsc": the name get-started's
#                               first command invokes, and the name
#                               quickstart-typescript imports from). EACH NAME
#                               COSTS ONE REQUEST PER RUN — one, not the retry
#                               budget, because both answers it can give (200
#                               and 404) end fetch()'s loop on the first
#                               attempt; only a 5xx or a connection failure
#                               spends more. A list containing
#                               anything that is not a valid npm package name
#                               is rejected wholesale in favour of the
#                               default, loudly — skipping just the bad entry
#                               would leave a silent hole in the watch, and
#                               this file's other malformed-env paths already
#                               fall back to their documented default rather
#                               than to "never fire".
#   PULSEVM_NPM_OFFICIAL_RE  ERE for a Metallicus-affiliated publisher
#                               identity, matched case-insensitively (default
#                               'metallicus|metalblockchain|metalpay|xprnetwork').
#                               See T5 for why the subject word "pulsevm" is
#                               deliberately absent from it. An ERE that grep
#                               refuses to compile falls back to the default,
#                               loudly: a pattern that errors would classify
#                               every package as unaffiliated and silently
#                               disarm the only sub-condition that pages high.
#
#   PULSEVM_RELEASES_URL / PULSEVM_ENDPOINTS_URL / PULSEVM_HEALTH_URL /
#   PULSEVM_LLMS_URL      source URLs (tests point these at a stub)
#
# Usage:
#   bash scripts/check-pulsevm-upstream.sh [--verbose]
#
# Cron target (/etc/cron.d/metal-pulsevm-watch), daily — see
# scripts/install-metal-pulsevm-watch-cron.sh.

set -uo pipefail

VERBOSE=0
for arg in "$@"; do
	case "$arg" in
		--verbose|-v) VERBOSE=1 ;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FYD_LIB="${SCRIPT_DIR}/lib/side-effects.sh"
if [ ! -r "$FYD_LIB" ]; then
	printf 'check-pulsevm-upstream: FATAL: side-effects library not readable at %s\n' "$FYD_LIB" >&2
	exit 6
fi
# shellcheck source=scripts/lib/side-effects.sh
. "$FYD_LIB"

RELEASES_URL="${PULSEVM_RELEASES_URL:-https://api.github.com/repos/MetalBlockchain/pulsevm/releases/latest}"
ENDPOINTS_URL="${PULSEVM_ENDPOINTS_URL:-https://pulsevm.dev/network/endpoints.md}"
HEALTH_URL="${PULSEVM_HEALTH_URL:-https://a-chain-alpine-hyperion.metalblockchain.org/v2/health}"
LLMS_URL="${PULSEVM_LLMS_URL:-https://pulsevm.dev/llms.txt}"

NPM_REGISTRY="${PULSEVM_NPM_REGISTRY:-https://registry.npmjs.org}"
NPM_SEARCH_URL="${PULSEVM_NPM_SEARCH_URL:-https://registry.npmjs.org/-/v1/search?text=pulsevm&size=50}"
NPM_PACKAGES_DEFAULT='pulse-ts pulse-tsc'
NPM_PACKAGES="${PULSEVM_NPM_PACKAGES:-$NPM_PACKAGES_DEFAULT}"
NPM_OFFICIAL_RE_DEFAULT='metallicus|metalblockchain|metalpay|xprnetwork'
NPM_OFFICIAL_RE="${PULSEVM_NPM_OFFICIAL_RE:-$NPM_OFFICIAL_RE_DEFAULT}"

# The npm package-name grammar this file will put into a URL or a `for` split.
# Lowercase only (npm has forbidden uppercase in new names since 2017), and
# with no glob metacharacter in the class — so the word split below cannot
# expand a name against the working directory.
NPM_NAME_RE='^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$'

LOG="${PULSEVM_UPSTREAM_LOG:-${SCRIPT_DIR}/../logs/pulsevm-upstream.log}"
STATE="${PULSEVM_UPSTREAM_STATE:-${SCRIPT_DIR}/../logs/pulsevm-upstream-state.json}"
HEAD_BLOCK_DELTA="${PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA:-1000}"
FAILURE_ALERT_AFTER="${PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER:-3}"
SYNC_NOTICE_RE="${PULSEVM_UPSTREAM_SYNC_NOTICE_RE:-third-party node sync is not yet supported}"

CURL="${FYD_CURL:-curl}"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# A non-numeric threshold must not become an accidental "never fire" (T4) or
# "never page" (outage escalation). Both fall back to their documented
# defaults, loudly, rather than being carried into arithmetic that would
# error and be read as false.
if ! [[ "$HEAD_BLOCK_DELTA" =~ ^[0-9]+$ ]]; then
	printf '%s WARN PULSEVM_UPSTREAM_HEAD_BLOCK_DELTA=%s is not a non-negative integer — using 1000\n' "$NOW_ISO" "$HEAD_BLOCK_DELTA" >&2
	HEAD_BLOCK_DELTA=1000
fi
if ! [[ "$FAILURE_ALERT_AFTER" =~ ^[0-9]+$ ]]; then
	printf '%s WARN PULSEVM_UPSTREAM_FAILURE_ALERT_AFTER=%s is not a non-negative integer — using 3\n' "$NOW_ISO" "$FAILURE_ALERT_AFTER" >&2
	FAILURE_ALERT_AFTER=3
fi

# The watch list is rejected WHOLESALE, never per entry. A per-entry skip
# would leave the operator with a list they believe is being watched and a
# name that silently is not — the "declaration stronger than implementation"
# failure this repo keeps paying for. The charset of the whole string is
# checked FIRST, before any word splitting, so a `*` in the value can never
# reach the shell's globbing.
npm_packages_valid() {
	local list="$1" n
	[ -n "${list// /}" ] || return 1
	[[ "$list" =~ ^[a-z0-9@/._[:space:]-]+$ ]] || return 1
	for n in $list; do
		[[ "$n" =~ $NPM_NAME_RE ]] || return 1
	done
	return 0
}
if ! npm_packages_valid "$NPM_PACKAGES"; then
	printf '%s WARN PULSEVM_NPM_PACKAGES=%s is not a space-separated list of valid npm package names — using the default list (%s)\n' "$NOW_ISO" "$NPM_PACKAGES" "$NPM_PACKAGES_DEFAULT" >&2
	NPM_PACKAGES="$NPM_PACKAGES_DEFAULT"
fi

# grep exits 2 on a pattern it cannot compile. Left unchecked, that reads as
# "no match" everywhere and silently disarms the one T5 sub-condition that
# pages high, so an uncompilable ERE falls back to the documented default.
NPM_OFFICIAL_RE_RC=0
printf 'x' | grep -qiE "$NPM_OFFICIAL_RE" >/dev/null 2>&1 || NPM_OFFICIAL_RE_RC=$?
if [ "$NPM_OFFICIAL_RE_RC" -gt 1 ]; then
	printf '%s WARN PULSEVM_NPM_OFFICIAL_RE=%s is not a usable ERE — using the default (%s)\n' "$NOW_ISO" "$NPM_OFFICIAL_RE" "$NPM_OFFICIAL_RE_DEFAULT" >&2
	NPM_OFFICIAL_RE="$NPM_OFFICIAL_RE_DEFAULT"
fi

# ---- logging -------------------------------------------------------------
# stderr always (cron pipes it to logger); the file log only when live. The
# latch makes the suppression visible exactly once per run instead of once
# per line.
LOG_DRY_NOTED=0
log() {
	printf '%s %s\n' "$NOW_ISO" "$*" >&2
	if ! fyd_is_live; then
		if [ "$LOG_DRY_NOTED" -eq 0 ]; then
			LOG_DRY_NOTED=1
			fyd_dry_note "append this run's lines to ${LOG} (stderr above carries them regardless)"
		fi
		return 0
	fi
	if [ -w "$(dirname "$LOG")" ] 2>/dev/null || [ -w "$LOG" ] 2>/dev/null; then
		printf '%s %s\n' "$NOW_ISO" "$*" >> "$LOG" 2>/dev/null || true
	fi
}

alert() {
	# alert <priority> <title> <message> — best-effort; a notify failure is
	# logged and never changes the caller's exit code. A watch that dies
	# because its alert channel is down has stopped watching.
	fyd_notify "$1" "$2" "$3" || log "WARN: notify failed (alert was: $2 — $3)"
}

if ! command -v jq >/dev/null 2>&1; then
	log "ERROR jq not found — cannot parse any upstream source"
	exit 5
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pulsevm-upstream.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---- prior state (read BEFORE fetching, so a failure path can carry the
# previous observations forward instead of erasing the baseline) -----------
PREV_OK=0
PREV_CONSEC=0
PREV_OBS='null'
PREV_TAG=""
PREV_SYNC_NOTICE=""
PREV_MAINNET=""
PREV_HEAD=""
if [ -r "$STATE" ] && jq -e '.schema_version == 2' "$STATE" >/dev/null 2>&1; then
	PREV_CONSEC="$(jq -r '.consecutive_failures // 0' "$STATE" 2>/dev/null || echo 0)"
	[[ "$PREV_CONSEC" =~ ^[0-9]+$ ]] || PREV_CONSEC=0
	# The whole observations object must be USABLE, not merely present: every
	# field a trigger reads is type-checked here, so a truncated or
	# hand-edited record re-baselines (fail open) instead of being read
	# field-by-field with silent fallbacks. A `// empty` fallback would be
	# actively wrong for the two booleans — in jq, `false // empty` yields
	# EMPTY, so a legitimately-false flag would be indistinguishable from a
	# missing one and T1/T2 would never see their "was it true yesterday"
	# transition. That bug shipped in the first draft of this file and was
	# caught by the T2a case; hence `tostring` below, and this gate.
	if jq -e '.observations | type == "object"
	          and (.sync_notice_present | type) == "boolean"
	          and (.mainnet_section_present | type) == "boolean"
	          and (.head_block | type) == "number"
	          and (.npm_discovered | type) == "array"
	          and (.npm_watch | type) == "array"
	          and (.npm_watch | all(type == "object"
	                                and (.name | type) == "string"
	                                and (.present | type) == "boolean"
	                                and (.official | type) == "boolean"
	                                and (.version | type) == "string"))' "$STATE" >/dev/null 2>&1; then
		PREV_OK=1
		PREV_OBS="$(jq -c '.observations' "$STATE" 2>/dev/null || echo 'null')"
		PREV_TAG="$(jq -r '.observations.release_tag // empty' "$STATE" 2>/dev/null || true)"
		PREV_SYNC_NOTICE="$(jq -r '.observations.sync_notice_present | tostring' "$STATE" 2>/dev/null || true)"
		PREV_MAINNET="$(jq -r '.observations.mainnet_section_present | tostring' "$STATE" 2>/dev/null || true)"
		PREV_HEAD="$(jq -r '.observations.head_block | tostring' "$STATE" 2>/dev/null || true)"
		jq -r '.observations.chain_ids[]? // empty' "$STATE" 2>/dev/null | sort -u > "$TMP/prev_chain_ids" || true
		jq -r '.observations.pages[]? // empty'     "$STATE" 2>/dev/null | sort -u > "$TMP/prev_pages"     || true
		jq -r '.observations.npm_discovered[]? // empty' "$STATE" 2>/dev/null | sort -u > "$TMP/prev_npm_found" || true
		jq -c '.observations.npm_watch[]?' "$STATE" 2>/dev/null > "$TMP/prev_npm_watch.jsonl" || true
	fi
fi
[ -f "$TMP/prev_chain_ids" ]      || : > "$TMP/prev_chain_ids"
[ -f "$TMP/prev_pages" ]          || : > "$TMP/prev_pages"
[ -f "$TMP/prev_npm_found" ]      || : > "$TMP/prev_npm_found"
[ -f "$TMP/prev_npm_watch.jsonl" ] || : > "$TMP/prev_npm_watch.jsonl"

# prev_npm_field <package-name> <field> — prints the recorded value, or
# nothing at all when this run's watch list has a name the last run did not.
# "Nothing" is the caller's signal that there is no history for that ONE name;
# see "ONE NAME WITHOUT HISTORY IS NOT A BASELINE" in the header.
prev_npm_field() {
	jq -r --arg n "$1" --arg f "$2" \
		'select(.name == $n) | .[$f] | tostring' "$TMP/prev_npm_watch.jsonl" 2>/dev/null | head -1
}

# ---- state writes (whole body gated: a dry run leaves no temp file either) -
state_write() {
	# state_write <observations-json-or-null> <consecutive_failures>
	fyd_live_run "record the pulsevm upstream state in ${STATE}" state_write_live "$1" "$2"
}
state_write_live() {
	# FYD-GATE(branch): reached only through the fyd_live_run above.
	local obs="$1" consec="$2" dir tmp
	dir="$(dirname "$STATE")"
	mkdir -p "$dir" 2>/dev/null || true
	if [ ! -w "$dir" ] 2>/dev/null; then
		log "WARN: state dir not writable: $dir (state not persisted; the next run will re-baseline)"
		return 1
	fi
	tmp="$(mktemp "${dir}/.pulsevm-upstream.XXXXXX" 2>/dev/null)" || {
		log "WARN: mktemp failed for the state file in $dir (state not persisted; the next run will re-baseline)"
		return 1
	}
	if ! jq -n --arg iso "$NOW_ISO" --argjson consec "$consec" --argjson obs "$obs" \
		'{schema_version: 2, checked_at: $iso, consecutive_failures: $consec, observations: $obs}' \
		> "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		log "WARN: jq compose failed for the state file (state not persisted; the next run will re-baseline)"
		return 1
	fi
	if ! mv "$tmp" "$STATE" 2>/dev/null; then
		rm -f "$tmp"
		log "WARN: rename failed writing the state file to $STATE (state not persisted; the next run will re-baseline)"
		return 1
	fi
	return 0
}

# fail_and_exit <rc> <summary> — the single exit path for 4 and 5. Increments
# the consecutive-failure counter, pages exactly once when it REACHES the
# threshold, keeps the previous observations so the next successful run still
# has a baseline to diff against.
fail_and_exit() {
	local rc="$1" summary="$2" consec
	log "ERROR $summary"
	consec=$((PREV_CONSEC + 1))
	if [ "$consec" -eq "$FAILURE_ALERT_AFTER" ]; then
		alert default "pulsevm-upstream: source unreachable (exit ${rc})" \
			"OBSERVED: ${consec} consecutive failed runs — ${summary}. NOT ESTABLISHED: anything at all about the upstream — a run that could not read a source compared nothing, so this is emphatically NOT evidence that nothing changed. OBLIGATION: check whether the URL moved or the third party is simply down. Alerting once per outage; a successful run re-arms it."
	else
		log "INFO consecutive_failures=${consec} (page fires only on the run that reaches ${FAILURE_ALERT_AFTER})"
	fi
	state_write "$PREV_OBS" "$consec"
	exit "$rc"
}

# ---- fetch ---------------------------------------------------------------
# Same shape as scripts/check-anchor-publish-health.sh's fetch(): prints the
# FINAL attempt's HTTP status, leaves the FINAL attempt's body in <outfile>,
# retries up to FYD_FETCH_ATTEMPTS and stops the moment a 200 arrives.
#
# One deliberate difference: a 4xx also stops the loop. A 4xx is a verdict,
# not a blip — a moved page will 404 three times in a row, and GitHub answers
# an exhausted unauthenticated rate limit with 403, so retrying it spends two
# more requests against a budget already known to be empty. Retrying a 4xx
# cannot succeed and is impolite to a third party; 5xx and connection failures
# (000) still get the full retry budget, which is where transient blips
# actually live.
fetch() {
	local url="$1" outfile="$2"
	local attempts="${FYD_FETCH_ATTEMPTS:-3}"
	local sleep_s="${FYD_RETRY_SLEEP:-3}"
	local attempt=1 code
	while :; do
		code="$("$CURL" -sS -o "$outfile" -w "%{http_code}" --max-time 20 "$url" 2>/dev/null || echo "000")"
		[ "$code" = "200" ] && break
		case "$code" in 4??) break ;; esac
		[ "$attempt" -ge "$attempts" ] && break
		sleep "$sleep_s"
		attempt=$((attempt + 1))
	done
	printf '%s' "$code"
}

fetch_or_fail() {
	# fetch_or_fail <label> <url> <outfile>
	local label="$1" url="$2" outfile="$3" code
	code="$(fetch "$url" "$outfile")"
	[ "$code" = "200" ] || fail_and_exit 4 "${label} not readable: ${url} HTTP=${code} after retrying"
}

# fetch_present <label> <url> <outfile> — for S5a, where 404 is an ANSWER
# ("this name has no installable latest version"), not an outage. Sets
# $FETCH_PRESENT to 1 or 0; anything that is neither 200 nor 404 still fails
# the run through fail_and_exit.
#
# The result is returned in a GLOBAL rather than on stdout on purpose: this
# function can exit the process, and `x="$(fetch_present …)"` would run that
# exit inside a command substitution's subshell, killing only the subshell and
# letting the caller sail on with an empty variable.
FETCH_PRESENT=0
fetch_present() {
	local label="$1" url="$2" outfile="$3" code
	code="$(fetch "$url" "$outfile")"
	case "$code" in
		200) FETCH_PRESENT=1; return 0 ;;
		404) FETCH_PRESENT=0; return 0 ;;
	esac
	fail_and_exit 4 "${label} not readable: ${url} HTTP=${code} after retrying"
}

fetch_or_fail "S1 releases"  "$RELEASES_URL"  "$TMP/s1.json"
fetch_or_fail "S2 endpoints" "$ENDPOINTS_URL" "$TMP/s2.md"
fetch_or_fail "S3 health"    "$HEALTH_URL"    "$TMP/s3.json"
fetch_or_fail "S4 llms"      "$LLMS_URL"      "$TMP/s4.txt"

# ---- parse ---------------------------------------------------------------
# S1: the release tag. Recorded only; never a trigger.
CUR_TAG="$(jq -er '.tag_name // empty' "$TMP/s1.json" 2>/dev/null || true)"
[ -n "$CUR_TAG" ] || fail_and_exit 5 "S1 returned 200 but has no .tag_name (${RELEASES_URL})"

# S3: head block. Taken by recursive descent rather than a fixed path — the
# value appears under more than one service entry in Hyperion's health
# payload (PulseVM-RPC and Indexer both carry it) and the service order is
# not contractual. First match wins; they agree in practice, and disagreeing
# by a block or two cannot cross the T4 threshold.
CUR_HEAD="$(jq -r 'first(.. | objects | .head_block_num? | numbers) // empty' "$TMP/s3.json" 2>/dev/null || true)"
[[ "$CUR_HEAD" =~ ^[0-9]+$ ]] || fail_and_exit 5 "S3 returned 200 but has no numeric head_block_num (${HEALTH_URL})"

# S2: the endpoints page. A 200 that is empty means the docs site served us a
# shell instead of the document.
[ -s "$TMP/s2.md" ] || fail_and_exit 5 "S2 returned 200 with an empty body (${ENDPOINTS_URL})"
if grep -qiE "$SYNC_NOTICE_RE" "$TMP/s2.md"; then CUR_SYNC_NOTICE=true; else CUR_SYNC_NOTICE=false; fi
# A mainnet SECTION, i.e. a markdown heading — not the bare word anywhere on
# the page, which would fire on a sentence like "mainnet is not live yet".
if grep -qiE '^#{1,6}[[:space:]].*mainnet' "$TMP/s2.md"; then CUR_MAINNET=true; else CUR_MAINNET=false; fi
# Antelope chain ids are 32-byte hex. The page's other identifier (the
# Avalanche blockchain ID) is base58 and cannot collide with this shape.
grep -oiE '\b[0-9a-f]{64}\b' "$TMP/s2.md" | tr 'A-F' 'a-f' | sort -u > "$TMP/cur_chain_ids" || true

# S4: the page list, taken from the link targets rather than the titles (a
# title can be reworded without the page changing).
[ -s "$TMP/s4.txt" ] || fail_and_exit 5 "S4 returned 200 with an empty body (${LLMS_URL})"
grep -oE 'https://[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*\.md\b' "$TMP/s4.txt" | sort -u > "$TMP/cur_pages" || true
[ -s "$TMP/cur_pages" ] || fail_and_exit 5 "S4 returned 200 but no page links could be parsed (${LLMS_URL})"

# ---- S5: the npm surface -------------------------------------------------
# Fetched last, so a failure in any of S1-S4 costs the registry nothing.

# npm_fingerprint <manifest-file> — the identity a package is published
# under, flattened to one line for the affiliation grep: the name (an
# @metalblockchain scope is itself the strongest available signal), every
# maintainer's username and e-mail, the account that pushed the last version,
# and the repository/homepage URLs. Deliberately NOT the description: a
# description says what a package is ABOUT, and "for PulseVM" is a claim
# anyone can type.
npm_fingerprint() {
	jq -r '[ .name,
	         (.maintainers[]? | (.name // empty), (.email // empty)),
	         (._npmUser.name // empty), (._npmUser.email // empty),
	         (.repository | if type == "string" then . elif type == "object" then (.url // empty) else empty end),
	         (.homepage // empty)
	       ] | map(select(type == "string" and . != "")) | join(" ")' "$1" 2>/dev/null || true
}

npm_is_official() {
	# npm_is_official <fingerprint-string> — evidence of a Metallicus-
	# affiliated publisher, never a claim of officialness. See T5.
	printf '%s' "$1" | grep -qiE "$NPM_OFFICIAL_RE"
}

: > "$TMP/cur_npm_watch.jsonl"
for npm_pkg in $NPM_PACKAGES; do
	# %2F, not a bare slash: a scoped name is one path segment to the registry.
	npm_url="${NPM_REGISTRY}/${npm_pkg//\//%2F}/latest"
	npm_slug="$(printf '%s' "$npm_pkg" | tr -c 'A-Za-z0-9' '_')"
	npm_body="$TMP/s5_${npm_slug}.json"
	fetch_present "S5a npm ${npm_pkg}" "$npm_url" "$npm_body"
	if [ "$FETCH_PRESENT" -eq 0 ]; then
		# -c is load-bearing, not cosmetic: this file is read back one record
		# per LINE by the T5 loop, and jq's default pretty-printing would
		# split every record across five of them.
		jq -nc --arg n "$npm_pkg" \
			'{name: $n, present: false, version: "", official: false}' \
			>> "$TMP/cur_npm_watch.jsonl" 2>/dev/null \
			|| fail_and_exit 5 "could not compose the S5a record for ${npm_pkg}"
		continue
	fi
	npm_ver="$(jq -er '.version // empty' "$npm_body" 2>/dev/null || true)"
	[ -n "$npm_ver" ] || fail_and_exit 5 "S5a npm ${npm_pkg} returned 200 but has no .version (${npm_url})"
	npm_fp="$(npm_fingerprint "$npm_body")"
	if npm_is_official "$npm_fp"; then npm_official=true; else npm_official=false; fi
	jq -nc --arg n "$npm_pkg" --arg v "$npm_ver" --argjson o "$npm_official" \
		'{name: $n, present: true, version: $v, official: $o}' \
		>> "$TMP/cur_npm_watch.jsonl" 2>/dev/null \
		|| fail_and_exit 5 "could not compose the S5a record for ${npm_pkg}"
done

fetch_or_fail "S5b npm search" "$NPM_SEARCH_URL" "$TMP/s5search.json"
jq -e '.objects | type == "array"' "$TMP/s5search.json" >/dev/null 2>&1 \
	|| fail_and_exit 5 "S5b returned 200 but has no .objects array (${NPM_SEARCH_URL})"
# Filtered against the npm name grammar client-side, so a server-side match
# that ever loosens cannot put an arbitrary string into an alert body or into
# a `for` split.
#
# -i here and NOT in npm_packages_valid, deliberately. npm has refused
# uppercase in NEW package names since 2017, but names created before that
# keep it, and this is a DISCOVERY filter — silently dropping such a name
# would be a hole in the watch, while the shape checks that make the value
# safe to interpolate still hold. The watch list is operator-written config
# rather than a third party's answer, so it stays strict.
jq -r '.objects[]?.package.name // empty' "$TMP/s5search.json" 2>/dev/null \
	| grep -Ei "$NPM_NAME_RE" | sort -u > "$TMP/cur_npm_found" || true
[ -s "$TMP/cur_npm_found" ] \
	|| fail_and_exit 5 "S5b returned 200 but no package names could be parsed (${NPM_SEARCH_URL})"
NPM_FOUND_N="$(wc -l < "$TMP/cur_npm_found" | tr -d ' ')"
NPM_SEARCH_TOTAL="$(jq -r '.total // 0' "$TMP/s5search.json" 2>/dev/null || echo 0)"
[[ "$NPM_SEARCH_TOTAL" =~ ^[0-9]+$ ]] || NPM_SEARCH_TOTAL=0
if [ "$NPM_SEARCH_TOTAL" -gt "$NPM_FOUND_N" ]; then
	log "WARN S5b reports total=${NPM_SEARCH_TOTAL} but ${NPM_FOUND_N} usable name(s) came back — the discovery set is truncated; raise size= in PULSEVM_NPM_SEARCH_URL before trusting its diff"
fi

# ---- evaluate triggers ---------------------------------------------------
# PRIORITY SPLIT. Not every trigger deserves the same channel. Three of them
# say "the ground moved, go and act": the sync notice disappearing (T1), a
# mainnet section appearing (T2-mainnet), and a run with nothing to compare
# against (BASELINE). Those page `high`.
#
# The rest are "something changed, read it when you get to it": a chain id we
# have not seen (T2-chainid), a new docs page (T3), the head block moving
# (T4). Those page `default`.
#
# The reason the split exists is specifically T2-chainid. The endpoints page
# warns that Alpine "resets frequently during hardening" and that each reset
# changes the chain id — and the repository is visibly in a hardening burst.
# So the chain-id path is likely to be at its noisiest exactly when the
# project starts moving, and if it arrives at the same priority as T1 then the
# `high` channel stops meaning "act" and starts meaning "PulseVM did
# something". That is how a high-priority channel is trained into background
# noise, which is the harm behind the operator's standing no-false-urgency
# rule. The outage page is already `default` (see fail_and_exit) for the same
# reason; this makes the trigger path consistent with it.
#
# The flag records what fired ON THIS RUN, rather than testing $CUR_MAINNET at
# dispatch time. Those differ: a mainnet section that appeared last week is
# still present today, so a state-based test would keep escalating every later
# T3/T4 to `high` forever. Only the transition is worth `high`.
FIRED=""
DETAIL=""
FIRED_HIGH=0
add_fire() { FIRED="${FIRED}${FIRED:+,}$1"; DETAIL="${DETAIL}${DETAIL:+ — }$2"; }

if [ "$PREV_OK" -eq 0 ]; then
	add_fire "BASELINE" "OBSERVED: no usable prior state at ${STATE}; a baseline has been recorded (release=${CUR_TAG}, head_block=${CUR_HEAD}, chain_ids=$(wc -l < "$TMP/cur_chain_ids" | tr -d ' '), pages=$(wc -l < "$TMP/cur_pages" | tr -d ' '), npm_watched=$(grep -c . < "$TMP/cur_npm_watch.jsonl" | tr -d ' '), npm_found=${NPM_FOUND_N}). NOT ESTABLISHED: that any of those values is NEW — this run compared them against nothing, so each is a first reading and not a change. T3/T4 DEFERRED — and so are T5's transitions: nothing to diff against yet. OBLIGATION: none IF this is a first run; if it is not, the state file was lost or rejected, and that is the thing to go and find out about"
	FIRED_HIGH=1
fi

# T1 — the sentence is gone. Evaluable from the current page alone, so it is
# also checked on a baseline run.
if [ "$CUR_SYNC_NOTICE" = "false" ] && { [ "$PREV_OK" -eq 0 ] || [ "$PREV_SYNC_NOTICE" = "true" ]; }; then
	add_fire "T1" "OBSERVED: nothing on ${ENDPOINTS_URL} matches '${SYNC_NOTICE_RE}' any more. NOT ESTABLISHED: that third-party node sync is supported — this run only measured that a sentence stopped matching, and a page can drop 'not supported' while still routing readers to the public RPC (which is what it did on 2026-08-19). OBLIGATION: read the page's node/version row and decide whether running our own node is actually described yet; re-plan only after that"
	FIRED_HIGH=1
fi

# T2 — mainnet section, or a chain id we have not recorded before.
if [ "$CUR_MAINNET" = "true" ] && { [ "$PREV_OK" -eq 0 ] || [ "$PREV_MAINNET" = "false" ]; }; then
	add_fire "T2" "OBSERVED: a mainnet section appeared in ${ENDPOINTS_URL} — specifically, a markdown heading matching 'mainnet'. NOT ESTABLISHED: that a mainnet is live; a heading reading 'A-Chain Mainnet (not yet live)' matches identically. OBLIGATION: read the section, then re-check bin/safe-broadcast gate 1 (/v1/history/get_transaction) and gate 3 (proton chain:info) endpoint assumptions BEFORE the next anchor"
	FIRED_HIGH=1
fi
if [ "$PREV_OK" -eq 1 ]; then
	NEW_CHAIN_IDS="$(comm -13 "$TMP/prev_chain_ids" "$TMP/cur_chain_ids" | head -3 | tr '\n' ' ')"
	if [ -n "${NEW_CHAIN_IDS// /}" ]; then
		add_fire "T2" "OBSERVED: new chain id(s) on ${ENDPOINTS_URL}: ${NEW_CHAIN_IDS%% } (an Alpine reset changes the chain id too — check which). OBLIGATION: if it is a migration rather than a reset, FYD_*_CHAIN_ID and safe-broadcast gate 3 need updating"
	fi
fi

# T3 — new pages.
if [ "$PREV_OK" -eq 1 ]; then
	NEW_PAGES="$(comm -13 "$TMP/prev_pages" "$TMP/cur_pages" | head -5 | tr '\n' ' ')"
	if [ -n "${NEW_PAGES// /}" ]; then
		add_fire "T3" "OBSERVED: new page(s) in ${LLMS_URL}: ${NEW_PAGES%% } — the page list grew; this run did not read the pages themselves. OBLIGATION: read them for a migration date or a validator-onboarding route"
	fi
fi

# T4 — the head block moved for real.
if [ "$PREV_OK" -eq 1 ] && [[ "$PREV_HEAD" =~ ^[0-9]+$ ]]; then
	if [ "$CUR_HEAD" -gt "$PREV_HEAD" ] && [ $((CUR_HEAD - PREV_HEAD)) -ge "$HEAD_BLOCK_DELTA" ]; then
		add_fire "T4" "OBSERVED: A-Chain Alpine head block advanced ${PREV_HEAD} -> ${CUR_HEAD} (>= ${HEAD_BLOCK_DELTA}). READS TWO WAYS: the testnet may be in real use, or it may have been reset and replayed — the page says it upgrades frequently, and both look identical from a head block. OBLIGATION: re-check whether third-party node sync and a subnet ID are published yet"
	fi
fi

# T5 — the npm surface. Read from a file redirect, NOT `cat … | while`: a
# pipeline would run the loop body in a subshell and every add_fire in it
# would be discarded when the subshell exited.
while IFS= read -r npm_rec; do
	[ -n "$npm_rec" ] || continue
	n_name="$(printf '%s' "$npm_rec"    | jq -r '.name')"
	n_present="$(printf '%s' "$npm_rec" | jq -r '.present | tostring')"
	n_official="$(printf '%s' "$npm_rec" | jq -r '.official | tostring')"
	n_version="$(printf '%s' "$npm_rec" | jq -r '.version')"

	if [ "$PREV_OK" -eq 0 ]; then
		# Baseline: only the fact that needs no history. "It is published
		# under a matching identity RIGHT NOW" is the npm analogue of T1's
		# "the notice is absent right now".
		if [ "$n_present" = "true" ] && [ "$n_official" = "true" ]; then
			add_fire "T5" "OBSERVED: npm package ${n_name}@${n_version} — a name the PulseVM docs tell you to install — has publisher fields matching '${NPM_OFFICIAL_RE}'. NOT ESTABLISHED: that it is the official package; this is a pattern match on a name, maintainers and URLs, which anyone can arrange to satisfy. OBLIGATION: verify the publisher, re-read pulsevm.dev/build/get-started before running its command, and check whether a node or validator route shipped with it"
			FIRED_HIGH=1
		fi
		continue
	fi

	p_present="$(prev_npm_field "$n_name" present)"
	p_official="$(prev_npm_field "$n_name" official)"
	p_version="$(prev_npm_field "$n_name" version)"

	if [ -z "$p_present" ]; then
		log "INFO first observation of watched npm package ${n_name} (present=${n_present} official=${n_official}) — no history for this name, so nothing is claimed about it this run"
		continue
	fi

	if [ "$n_present" = "true" ] && [ "$p_present" = "false" ]; then
		if [ "$n_official" = "true" ]; then
			add_fire "T5" "OBSERVED: npm package ${n_name} went from unpublished to published (${n_version}), with publisher fields matching '${NPM_OFFICIAL_RE}'. NOT ESTABLISHED: that it is the official package, or that the docs now work end to end. OBLIGATION: verify the publisher, re-read pulsevm.dev/build/get-started, and check whether a node or validator route shipped with it"
			FIRED_HIGH=1
		else
			add_fire "T5" "OBSERVED: npm package ${n_name} went from unpublished to published (${n_version}), under publisher fields that do NOT match '${NPM_OFFICIAL_RE}'. NOT ESTABLISHED: that it is unofficial — the pattern only sees names, maintainers and URLs. OBLIGATION: the name the docs tell you to install is taken by someone; verify who before running that command"
		fi
	elif [ "$n_present" = "true" ] && [ "$n_official" = "true" ] && [ "$p_official" = "false" ]; then
		add_fire "T5" "OBSERVED: npm package ${n_name}@${n_version} was already published and its publisher fields now match '${NPM_OFFICIAL_RE}' where they did not before — an existing name changing hands rather than a fresh publish. NOT ESTABLISHED: who actually holds it now. OBLIGATION: verify the publisher and re-read pulsevm.dev/build/get-started before running its command"
		FIRED_HIGH=1
	elif [ "$n_present" = "false" ] && [ "$p_present" = "true" ]; then
		log "INFO npm package ${n_name} is no longer published (was ${p_version}) — recorded, not a trigger; the documented command now fails loudly instead of installing someone else's code"
	fi

	# Movements that are recorded and never paged. Kept OUTSIDE the chain
	# above so a run that sees two of them logs both, and guarded on the name
	# having been present in both runs so a fresh publish is not also
	# reported as a version move.
	if [ "$n_present" = "true" ] && [ "$p_present" = "true" ]; then
		if [ "$n_version" != "$p_version" ]; then
			log "INFO npm package ${n_name} ${p_version} -> ${n_version} (recorded, not a trigger)"
		fi
		if [ "$n_official" = "false" ] && [ "$p_official" = "true" ]; then
			log "INFO npm package ${n_name} no longer matches '${NPM_OFFICIAL_RE}' (recorded, not a trigger) — losing the affiliation puts the name back in the state it is in today, which is this watch's documented steady state, not a new obligation"
		fi
	fi
done < "$TMP/cur_npm_watch.jsonl"

if [ "$PREV_OK" -eq 1 ]; then
	NEW_NPM_PKGS="$(comm -13 "$TMP/prev_npm_found" "$TMP/cur_npm_found" | head -5 | tr '\n' ' ')"
	if [ -n "${NEW_NPM_PKGS// /}" ]; then
		NEW_NPM_OFFICIAL=0
		for npm_new in $NEW_NPM_PKGS; do
			npm_new_fp="$(jq -r --arg n "$npm_new" \
				'.objects[]? | select(.package.name == $n)
				 | [ .package.name,
				     (.package.publisher.username // empty), (.package.publisher.email // empty),
				     (.package.maintainers[]? | (.username // empty), (.email // empty)),
				     (.package.links.repository // empty), (.package.links.homepage // empty) ]
				 | map(select(type == "string" and . != "")) | join(" ")' \
				"$TMP/s5search.json" 2>/dev/null || true)"
			npm_is_official "$npm_new_fp" && NEW_NPM_OFFICIAL=1
		done
		if [ "$NEW_NPM_OFFICIAL" -eq 1 ]; then
			add_fire "T5" "OBSERVED: npm package(s) new to the PulseVM search set: ${NEW_NPM_PKGS%% } — at least one carries publisher fields matching '${NPM_OFFICIAL_RE}'. NOT ESTABLISHED: what any of them is; this run read names and publisher fields, not code. OBLIGATION: read it — an SDK or toolchain arriving is the first thing that would replace the docs' pulse-ts entry command"
			FIRED_HIGH=1
		else
			add_fire "T5" "OBSERVED: npm package(s) new to the PulseVM search set: ${NEW_NPM_PKGS%% } — no publisher fields on them match '${NPM_OFFICIAL_RE}'. NOT ESTABLISHED: that they are unrelated; a package can be relevant without carrying an organisation token. OBLIGATION: read who published them before installing anything"
		fi
	fi
fi

# Release tag movement is recorded, never paged.
if [ "$PREV_OK" -eq 1 ] && [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$CUR_TAG" ]; then
	log "INFO release tag ${PREV_TAG} -> ${CUR_TAG} (recorded, not a trigger)"
fi

# ---- record + verdict ----------------------------------------------------
# `jq -R -s` rather than `--rawfile`: --rawfile needs jq 1.6, and nothing
# else in this repo has taken that dependency yet. -R -s has worked since
# jq 1.4, so the checker runs on whatever the validator host happens to have.
CHAIN_IDS_JSON="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$TMP/cur_chain_ids" 2>/dev/null || true)"
PAGES_JSON="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$TMP/cur_pages" 2>/dev/null || true)"
NPM_FOUND_JSON="$(jq -R -s 'split("\n") | map(select(length > 0))' < "$TMP/cur_npm_found" 2>/dev/null || true)"
# -s over the JSONL the S5a loop appended, so the array is built from records
# that were each composed by jq and are therefore already valid.
NPM_WATCH_JSON="$(jq -s '.' < "$TMP/cur_npm_watch.jsonl" 2>/dev/null || true)"
CUR_OBS=""
if [ -n "$CHAIN_IDS_JSON" ] && [ -n "$PAGES_JSON" ] && [ -n "$NPM_FOUND_JSON" ] && [ -n "$NPM_WATCH_JSON" ]; then
	CUR_OBS="$(jq -n \
		--arg tag "$CUR_TAG" \
		--argjson sync "$CUR_SYNC_NOTICE" \
		--argjson mainnet "$CUR_MAINNET" \
		--argjson head "$CUR_HEAD" \
		--argjson chain_ids "$CHAIN_IDS_JSON" \
		--argjson pages "$PAGES_JSON" \
		--argjson npm_watch "$NPM_WATCH_JSON" \
		--argjson npm_discovered "$NPM_FOUND_JSON" \
		'{release_tag: $tag, sync_notice_present: $sync, mainnet_section_present: $mainnet,
		  head_block: $head, chain_ids: $chain_ids, pages: $pages,
		  npm_watch: $npm_watch, npm_discovered: $npm_discovered}' 2>/dev/null || true)"
fi
if [ -z "$CUR_OBS" ]; then
	# Composing our OWN record failed — that is a local defect, not an
	# upstream one, but it is still "this run produced no usable state".
	fail_and_exit 5 "could not compose the observation record from the fetched bodies"
fi

state_write "$CUR_OBS" 0

if [ -n "$FIRED" ]; then
	# Priority comes from FIRED_HIGH, set only by the three act-now triggers
	# (T1 / T2-mainnet-section / BASELINE) at the point each one fires. See the
	# PRIORITY SPLIT comment above the trigger block for why a routine
	# chain-id change must not arrive on the same channel as T1. A run that
	# fires BOTH kinds escalates to high, which is correct: the high one is
	# still in there and still needs acting on.
	PRIO=default
	[ "$FIRED_HIGH" -eq 1 ] && PRIO=high
	log "TRIGGER ${FIRED} (priority=${PRIO}): ${DETAIL}"
	alert "$PRIO" "pulsevm-upstream: ${FIRED} (exit 3)" "${DETAIL}"
	exit 3
fi

[ "$VERBOSE" -eq 1 ] && log "OK no upstream change: release=${CUR_TAG} head_block=${CUR_HEAD} sync_notice_present=${CUR_SYNC_NOTICE} mainnet_section=${CUR_MAINNET} pages=$(wc -l < "$TMP/cur_pages" | tr -d ' ') npm_watched=$(grep -c . < "$TMP/cur_npm_watch.jsonl" | tr -d ' ') npm_found=${NPM_FOUND_N}"
exit 0
