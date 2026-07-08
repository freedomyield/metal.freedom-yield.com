# Schema-validator tooling conventions

This document captures the convention every session and script in this
project must follow when a JSON-schema validator is missing from a host.
It exists because on 2026-07-08 a crashed session, trying to make the
anchor scripts' `python3 -c 'import jsonschema'` check pass, replaced the
machine's real Python 3.14 interpreter — the terminus every `python3`
symlink on that machine resolved to — with a two-line shell shim that
`exec`'d a venv Python living inside that session's own scratchpad
directory. The scratchpad was deleted when the session later crashed,
deleting the shim's exec target with it: every `python3` invocation on
the machine broke at once. The test suite had been reporting green
against the shimmed interpreter the whole time — a corrupted interpreter
still answers to `command -v python3`, and nothing had checked what it
actually was. Recovery was `brew reinstall python@3.14` plus
`pip3 install --break-system-packages jsonschema`.

## How schema validation works in the anchor scripts

The anchor pipeline scripts — `scripts/gen-anchor-source.sh`,
`scripts/gen-anchor-receipt.sh`, `scripts/append-anchor-history.sh` —
each carry an identical `schema_validate_or_die()` function (tagged
`R13` in their comments) that runs before the script writes its output
artifact:

1. **`ajv`**, if present on `PATH` — validated via
   `ajv --spec=draft2020 --strict=false validate -s <schema> -d <data>`.
2. Else **`python3` + the `jsonschema` module**, if both are present — a
   heredoc script calls `jsonschema.validate(...)` with format checking.
3. Else **fail closed** — the function returns non-zero and the calling
   script exits without writing anything.

There is no skip path: an anchor artifact is never composed against
unvalidated JSON.

## Sanctioned setup: `scripts/setup-schema-validator.sh`

If a host is missing both `ajv` and `python3`+`jsonschema`, the anchor
scripts fail at step 3 above — by design. The fix is:

```sh
bash scripts/setup-schema-validator.sh
```

It only ever shells out to `npm` or `pip3`, resolved via `PATH`:

- If a validator is already present, it does nothing (exit 0).
- Otherwise it installs one — `npm i -g ajv-cli ajv-formats` or
  `pip3 install --break-system-packages jsonschema` — trying the manager
  named by `SETUP_VALIDATOR_PREFER` (`ajv` or `python`, default `ajv`)
  first, falling back to whichever else is on `PATH`.
- It re-verifies with the same detection check after the install
  attempt; a package manager's own exit code is never trusted alone.
- If neither `npm` nor `pip3` is on `PATH` (exit 2), or an install ran
  but no validator is importable/runnable afterward (exit 3), it prints
  both manual commands and stops. It never does anything else to
  compensate — see the hard rule below.

## Hard rule

> Never satisfy a tooling dependency by replacing or shimming a system
> binary or its symlink terminus. Use `scripts/setup-schema-validator.sh`;
> if it can't help, stop and ask the operator.

This is not a style preference. Doing this once, on 2026-07-08, took
every `python3` invocation on the machine down the moment the shim's
exec target (a scratchpad directory) was deleted by an unrelated crash —
and it had been running invisibly, unverified, before that.

## Related lessons

- `tests/run-all-tests.sh` carries a preflight guard (added alongside
  this document) that fails loud, before any suite runs, if `python3`
  resolves to something shaped like a shim (a shell script `exec`ing a
  path under `/tmp`, `/private/tmp`, a scratchpad, or a venv) or if no
  schema validator is available at all. Absence of `python3` by itself
  is not a failure — plenty of hosts legitimately lack it; a shim, or a
  validator-less host that a validator-dependent suite would otherwise
  silently skip or pass against, is.
- Never trust a package manager's own exit code as proof a tool is now
  on `PATH` or importable — re-verify with the same detection check used
  to decide a validator was absent in the first place.
