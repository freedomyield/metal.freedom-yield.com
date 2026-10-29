# Staged disclosure entries — NOT YET PUBLISHED

Every `*.json` file in this directory is an incident record that the operator has
decided to disclose but has **not published yet**. It is a draft awaiting a
scheduled publication date, not a statement this project is currently making.

**The published incident log is [`/api/incidents.json`](https://metal.freedom-yield.com/api/incidents.json)**
(in this repository: `public/api/incidents.json`). That file is the only
authoritative record. If an id appears here and not there, it has not been
published — and the dates inside it, including `resolutionDate` and
`status: resolved`, describe the state expected **as of its publication date**,
which may still be in the future.

Why entries wait here instead of being written straight into `incidents.json`:
some disclosures are tied to a cycle transition and carry an ordering constraint
(they must reach the published feed before the closed cycle's row is written to
the append-only `cycle-history.jsonl` ledger, or that row records one incident
too few — permanently). Keeping the text in the repository ahead of time means
the day-of procedure inserts a reviewed file rather than composing prose under
time pressure. The full rules are in
[`docs/INCIDENT_RESPONSE.md` §6](../INCIDENT_RESPONSE.md) and the day-of
procedure is [`docs/CYCLE_GATE.md`](../CYCLE_GATE.md) step 2.5.

Publication deletes the file from this directory in the same commit that inserts
it into `incidents.json`, so in steady state this directory holds **no `*.json`
at all** — only this README, which stays. `tests/incidents/test-schema.sh`
enforces that: a staged id that already appears in `incidents.json` fails the
build. This README is not a staged entry; the guard globs `*.json` and never
reads it.
