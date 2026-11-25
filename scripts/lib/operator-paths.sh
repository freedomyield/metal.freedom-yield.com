#!/usr/bin/env bash
# Every name below is read by the scripts that source this file.
# shellcheck disable=SC2034
#
# scripts/lib/operator-paths.sh — the single home of the names of this
# project's operator-local places on the Mac (keystores, identity key,
# broadcast config, notify-relay tokens, owner pubcheck).
#
# CHAIN: none — this file defines shell variables only. It defines no
#        function, runs nothing, prints nothing, and reads nothing.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe, no broadcast pathway.
#
# Every value is RELATIVE TO A HOME and carries no leading "/" or "~/".
# Each consumer keeps the base it already used (the login home for
# scripts/install-rehearsal-preflight.sh, $HOME for scripts/lib/identity-pq.sh,
# scripts/cycle-transition.sh and
# scripts/operator-local/make-notify-relay-token.sh) and joins it as
# "${base}/${FYD_..._REL}". Text shown to a person is built as
# "~/${FYD_..._REL}".
#
# Read by: scripts/lib/require-keystore-home.sh (and through it every script
# that sources that guard), scripts/lib/identity-pq.sh,
# scripts/cycle-transition.sh, scripts/operator-local/make-notify-relay-token.sh.
# The quoted heredocs in scripts/cycle-transition.sh cannot expand these
# names; tests/operator-paths/ checks their text against this file.
#
# Since 2026-11-25 (operator decision: project things do not live directly
# under the home directory). The former places directly under the home no
# longer exist; there is deliberately no fallback to them.
# Must stay bash 3.2 compatible (macOS /bin/bash).

FYD_PROJECT_CONFIG_REL=".config/metal.freedom-yield.com"
FYD_KEY_DIR_REL="${FYD_PROJECT_CONFIG_REL}/key"
FYD_KEYSTORE_MAINNET_REL="${FYD_KEY_DIR_REL}/mainnet"
FYD_KEYSTORE_TESTNET_REL="${FYD_KEY_DIR_REL}/testnet"
FYD_IDENTITY_KEY_DIR_REL="${FYD_KEY_DIR_REL}/identity"
FYD_BROADCAST_DIR_REL="${FYD_KEY_DIR_REL}/broadcast"
FYD_BROADCAST_CONFIG_REL="${FYD_BROADCAST_DIR_REL}/config"
FYD_NOTIFY_RELAY_DIR_REL="${FYD_KEY_DIR_REL}/notify-relay"
FYD_OWNER_PUBCHECK_REL="${FYD_KEY_DIR_REL}/owner-pubcheck"
FYD_REHEARSAL_CONFIG_REL="${FYD_KEY_DIR_REL}/rehearsal"
FYD_BACKUP_DIR_REL="${FYD_PROJECT_CONFIG_REL}/backup"
FYD_BROADCAST_AUDIT_LOG_BASENAME=".fyd-broadcast-audit.log"
FYD_BROADCAST_AUDIT_LOG_REL="${FYD_BACKUP_DIR_REL}/${FYD_BROADCAST_AUDIT_LOG_BASENAME}"
FYD_TESTNET_RECEIPT_REL="${FYD_BACKUP_DIR_REL}/.fya-testnet-receipt.json"
FYD_TESTNET_DRYRUN_LOG_REL="${FYD_BACKUP_DIR_REL}/.fya-testnet-dryrun-log.json"
FYD_RESTORE_DRILL_LOG_REL="${FYD_BACKUP_DIR_REL}/fy-restore-drill.log"
