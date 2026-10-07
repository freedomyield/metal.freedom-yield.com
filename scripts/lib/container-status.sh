#!/usr/bin/env bash
# scripts/lib/container-status.sh — docker container state for the status feed,
# telling "the container is gone" apart from "docker could not answer".
#
# CHAIN: none — read-only `docker inspect` / `docker ps -a`. No network client,
#        no proton, no broadcast.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe.
#
# WHY THIS EXISTS
#   scripts/server-status.sh monitors the ops-dashboard Caddy by the name in
#   CADDY_CONTAINER (host cron env, no repo default). Which Caddy container
#   serves the dashboard can change; when the configured one is retired and
#   removed, a bare `docker inspect` fails exactly like a dead docker daemon
#   does. server-status.sh then exited 5 and kept the last-known-good JSON, so
#   the whole status feed — metalgo included — went stale: one renamed web
#   container blinded the validator monitor, and the operator was never told
#   the Caddy name was wrong. With this helper a missing container is a real,
#   published state ("absent"), which check-anomalies.sh alerts on like any
#   other non-running state, while a docker failure still aborts the publish.
#
# INTERFACE
#   . "${SCRIPT_DIR}/lib/container-status.sh"
#   fy_container_status <name>
#     rc 0, prints the .State.Status (running / exited / restarting / …)
#     rc 0, prints "absent"  — docker answered and no container has that name
#     rc 1, prints nothing    — docker could not answer (daemon down,
#                               permission denied, empty name, …)
#   The name match is EXACT (whole name), never a substring/prefix match.

fy_container_status() {
  local name="${1:-}" out names
  [ -n "$name" ] || return 1
  if out=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null); then
    # docker inspect can emit a stray newline; strip whitespace before use.
    out=$(printf '%s' "$out" | tr -d '\r\n\t')
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  # inspect failed. Only call it "absent" when docker itself answers and the
  # full container list does not contain the name.
  names=$(docker ps -a --format '{{.Names}}' 2>/dev/null) || return 1
  if printf '%s\n' "$names" | grep -qxF -- "$name"; then
    return 1   # exists but inspect failed: not a state we can name
  fi
  printf 'absent'
  return 0
}
