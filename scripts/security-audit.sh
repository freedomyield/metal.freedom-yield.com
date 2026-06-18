#!/usr/bin/env bash
# Monthly security audit — runs on the VPS, checks SSH / firewall / fail2ban / kernel.
# Exit code: 0 = all green; 1 = at least one critical drift detected.
# Output: stdout summary + /var/log/security-audit.log
#
# Designed to be run via /etc/cron.monthly/ or via SSH from the operator's
# laptop. Reports drift from the hardened baseline.
set -uo pipefail

LOG=/var/log/security-audit.log
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3" severity="${4:-WARN}"
  if [ "$actual" = "$expected" ]; then
    printf "  [OK]   %-40s = %s\n" "$name" "$actual"
  else
    printf "  [%s] %-40s expected=%s  actual=%s\n" "$severity" "$name" "$expected" "$actual"
    if [ "$severity" = "FAIL" ]; then FAIL=1; fi
  fi
}

echo "============================================================"
echo " Security audit  ($DATE)"
echo "============================================================"

echo
echo "[1] SSH effective configuration"
SSH_PA=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')
SSH_KI=$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication/ {print $2}')
SSH_RL=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/ {print $2}')
SSH_PK=$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication/ {print $2}')
check "passwordauthentication" "no" "$SSH_PA" FAIL
check "kbdinteractiveauthentication" "no" "$SSH_KI" FAIL
check "permitrootlogin" "without-password" "$SSH_RL" WARN
check "pubkeyauthentication" "yes" "$SSH_PK" FAIL

echo
echo "[2] Firewall (ufw)"
UFW_STATUS=$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')
check "ufw status" "active" "$UFW_STATUS" FAIL

EXPECTED_PORTS="22/tcp 443/tcp 443/udp 80/tcp 9651/tcp"
# ufw status prints "ALLOW" (no direction) for IPv4 / "ALLOW IN" only in verbose mode
# Match the leading port column on rule lines and skip the (v6) duplicates.
ACTUAL_PORTS=$(ufw status 2>/dev/null \
  | awk '$2 == "ALLOW" && !/\(v6\)/ {print $1}' \
  | sort -u \
  | tr '\n' ' ' \
  | sed 's/ $//')
check "open ports" "$EXPECTED_PORTS" "$ACTUAL_PORTS" FAIL

echo
echo "[3] fail2ban"
F2B_ACTIVE=$(systemctl is-active fail2ban 2>/dev/null)
check "fail2ban service" "active" "$F2B_ACTIVE" FAIL
F2B_SSHD=$(fail2ban-client status sshd 2>/dev/null | grep -c "^Status for the jail")
if [ "${F2B_SSHD:-0}" -ge 1 ]; then
  echo "  [OK]   sshd jail is configured"
  BANNED=$(fail2ban-client status sshd 2>/dev/null | awk -F'\t' '/Currently banned/ {print $2}' | tr -d ' ')
  echo "         currently banned: ${BANNED:-0} IPs"
  FAILED=$(fail2ban-client status sshd 2>/dev/null | awk -F'\t' '/Total failed/ {print $2}' | tr -d ' ')
  echo "         total failed (since boot): ${FAILED:-?}"
else
  echo "  [FAIL] sshd jail not configured"
  FAIL=1
fi

echo
echo "[4] Listening ports (sanity check)"
ss -tlnp 2>/dev/null | awk 'NR>1 && $4 !~ /127\.0\.0/' \
  | awk '{ print "  " $4 "  " $NF }'

echo
echo "[5] Recent SSH activity"
echo "  Last 5 successful key-auth logins:"
last -n 5 -i 2>/dev/null | awk 'NR<=5 && $1 != "" && $1 != "wtmp" {print "    " $0}'
echo "  Failed password attempts (last hour, count by IP):"
journalctl -u ssh --since "1 hour ago" 2>/dev/null \
  | grep -oE "Failed password .* from [0-9.]+" \
  | awk '{print $NF}' | sort | uniq -c | sort -rn | head -5 \
  | awk '{print "    " $2 ": " $1 " attempts"}'

echo
echo "[6] Kernel / package security updates"
# grep -c always prints a count; the || true keeps set -e/-u happy on no-match
UPDATES=$(apt list --upgradable 2>/dev/null | grep -ic security || true)
UPDATES=${UPDATES:-0}
if [ "$UPDATES" -gt 0 ]; then
  echo "  [WARN] $UPDATES security update(s) available"
  echo "         run: apt-get update && apt-get upgrade"
else
  echo "  [OK]   no security updates pending"
fi

echo
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  echo " Result: PASS  ($DATE)"
else
  echo " Result: FAIL — critical drift detected ($DATE)"
fi
echo "============================================================"

# tee summary line to log
echo "$DATE result=$([ $FAIL -eq 0 ] && echo PASS || echo FAIL)" >> "$LOG"

exit $FAIL
