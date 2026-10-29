#!/usr/bin/env bash
# install-web-host-static-deploy-key.sh
# Install an rrsync -wo (write-only, single-path) restricted authorized_keys
# entry on the web host for the GitHub Actions static-deploy key, confining it
# to the metal public dir on the shared multi-project host.
#
# Operator usage (Mac, once):
#   WEB_ADMIN_HOST=<ip> WEB_ROOT=/home/<acct>/metal.freedom-yield.com/public \
#   CI_PUBKEY=~/.ssh/freedom-yield-static-deploy.pub \
#   bash scripts/install-web-host-static-deploy-key.sh
#
# Idempotent. Backs up authorized_keys. Never edits other entries. Does not
# touch other projects' vhosts or services. BROADCASTS NOTHING.
#
# Test/local mode: SKIP_SSH=1 AUTHORIZED_KEYS_FILE=<path> operates on a local
# authorized_keys file (no host contacted).
set -euo pipefail

: "${CI_PUBKEY:?CI_PUBKEY (path to the CI deploy key .pub) required}"
: "${WEB_ROOT:?WEB_ROOT (metal public dir on web host) required}"
WEB_ADMIN_USER="${WEB_ADMIN_USER:-root}"
WEB_ADMIN_KEY="${WEB_ADMIN_KEY:-$HOME/.ssh/id_rsa}"

[ -r "${CI_PUBKEY}" ] || { echo "ERROR: CI_PUBKEY not readable: ${CI_PUBKEY}" >&2; exit 2; }
PUBLINE="$(tr -d '\r\n' < "${CI_PUBKEY}")"
[ -n "${PUBLINE}" ] || { echo "ERROR: CI_PUBKEY is empty" >&2; exit 2; }

# The restricted entry. rrsync -wo <dir> = write-only rsync sandboxed to <dir>.
RESTRICT='command="rrsync -wo '"${WEB_ROOT}"'",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding'
ENTRY="${RESTRICT} ${PUBLINE}"
# match token: the CI key body, to detect an existing install idempotently
KEYBODY="$(printf '%s' "${PUBLINE}" | awk '{print $2}')"

install_into() {  # $1 = authorized_keys file path (local)
  local AK="$1"
  [ -f "${AK}" ] || : > "${AK}"
  if grep -qF "${KEYBODY}" "${AK}"; then
    echo "OK: CI key already present in ${AK} — no change"
    return 0
  fi
  cp -p "${AK}" "${AK}.bak-$(date +%Y%m%d-%H%M%S)"
  printf '%s\n' "${ENTRY}" >> "${AK}"
  echo "OK: installed restricted CI deploy key into ${AK}"
}

if [ "${SKIP_SSH:-0}" = "1" ]; then
  # Local/test mode: operate on a local authorized_keys file.
  install_into "${AUTHORIZED_KEYS_FILE:?AUTHORIZED_KEYS_FILE required in SKIP_SSH mode}"
  exit 0
fi

# Remote mode: rrsync must exist on web host; edit ~/.ssh/authorized_keys there.
: "${WEB_ADMIN_HOST:?WEB_ADMIN_HOST required}"
[ -r "${WEB_ADMIN_KEY}" ] || { echo "ERROR: WEB_ADMIN_KEY not readable: ${WEB_ADMIN_KEY}" >&2; exit 2; }
ssh -i "${WEB_ADMIN_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
    "${WEB_ADMIN_USER}@${WEB_ADMIN_HOST}" \
    "command -v rrsync >/dev/null || { echo 'ERROR: rrsync not found on web host (install rsync/rrsync)'; exit 5; }"
# The key body carried below is a PUBLIC key (no secret). ENTRY/KEYBODY are
# passed as env so the remote shell appends idempotently with a backup.
ssh -i "${WEB_ADMIN_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
    "${WEB_ADMIN_USER}@${WEB_ADMIN_HOST}" \
    "KEYBODY='${KEYBODY}' ENTRY='${ENTRY}' bash -s" <<'REMOTE'
set -euo pipefail
AK="${HOME}/.ssh/authorized_keys"
mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
[ -f "${AK}" ] || : > "${AK}"
if grep -qF "${KEYBODY}" "${AK}"; then echo "OK: CI key already present — no change"; exit 0; fi
cp -p "${AK}" "${AK}.bak-$(date +%Y%m%d-%H%M%S)"
printf '%s\n' "${ENTRY}" >> "${AK}"
chmod 600 "${AK}"
echo "OK: installed restricted CI deploy key on web host"
REMOTE
echo "==> Done. Next: register the private key + host/user/port as GitHub Actions secrets,"
echo "    then push to trigger a deploy and verify (see docs/DEPLOY_OWNERSHIP_MATRIX.md)."
