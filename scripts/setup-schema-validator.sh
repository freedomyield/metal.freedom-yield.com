#!/usr/bin/env bash
# scripts/setup-schema-validator.sh — sanctioned, non-destructive installer
# that guarantees a JSON-schema validator (ajv, or python3+jsonschema) is
# available on PATH for the anchor pipeline's mandatory schema-validation
# gate (schema_validate_or_die, duplicated across gen-anchor-source.sh,
# gen-anchor-receipt.sh, and append-anchor-history.sh — see those scripts'
# "R13" comments).
#
# Why this exists:
#   A prior session, faced with a host missing a JSON-schema validator,
#   improvised by replacing the machine's real python3 interpreter with a
#   scratchpad shim. That shim vanished on a later crash and took every
#   python3 invocation on that machine down with it — a self-inflicted,
#   avoidable outage. This script exists so nobody has to improvise again:
#   it makes a validator available through ONLY package managers (npm or
#   pip3) and never edits, replaces, or symlink-retargets any binary,
#   interpreter, or system path. If it cannot install one, it says so and
#   names the two manual commands to run instead — it never touches
#   anything to compensate.
#
# CHAIN: none. PRIME_DIRECTIVE: safe. This script only checks for and
#        (optionally) installs a schema-validation tool; it composes no
#        anchor artifact and invokes no broadcast-capable command.
#
# Usage:
#   bash scripts/setup-schema-validator.sh
#
# Env:
#   SETUP_VALIDATOR_PREFER=ajv|python   (default: ajv)
#     Which package-manager path to try FIRST when neither validator is
#     already present. "ajv" tries npm before pip3; "python" tries pip3
#     before npm. Either way, if the preferred manager is unavailable but
#     the other manager IS available (and its install succeeds), that
#     still counts as success — the contract is "some validator ends up
#     available", not "the preferred one specifically".
#
# Exit codes:
#   0  a validator is available on exit (already present, or installed and
#      re-verified by this run)
#   1  usage error (unknown argument, or SETUP_VALIDATOR_PREFER set to
#      anything other than "ajv"/"python")
#   2  neither npm nor pip3 is present on PATH — nothing this script can
#      shell out to; install one of the two manually (see the printed
#      commands)
#   3  an install was attempted (npm and/or pip3 ran) but re-verification
#      still finds no validator available afterward

set -euo pipefail

PREFER="${SETUP_VALIDATOR_PREFER:-ajv}"
case "$PREFER" in
	ajv|python) ;;
	*)
		echo "ERROR: SETUP_VALIDATOR_PREFER must be 'ajv' or 'python' (got '${PREFER}')" >&2
		exit 1
		;;
esac

for arg in "$@"; do
	case "$arg" in
		-h|--help) sed -n '2,46p' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)         echo "ERROR: unknown arg: $arg" >&2; exit 1 ;;
	esac
done

have_ajv() { command -v ajv >/dev/null 2>&1; }
have_jsonschema() { command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; }

echo "== setup-schema-validator: checking for an existing validator (prefer=${PREFER}) =="

if have_ajv; then
	echo "ajv already available"
	exit 0
fi

if have_jsonschema; then
	echo "python3+jsonschema already available"
	exit 0
fi

echo "INFO: no validator found on PATH (ajv absent; python3+jsonschema absent) — attempting install"

# ---- install attempt: package managers ONLY. This script never touches a
# binary, symlink, or system path directly — see the header note on why.
# It only ever shells out to `npm`/`pip3` resolved via PATH, which is also
# exactly what lets a test stub both commands on a synthetic PATH without
# any real network access or install. ---------------------------------
install_via_npm() {
	echo "INFO: npm found — installing: npm i -g ajv-cli ajv-formats"
	if npm i -g ajv-cli ajv-formats; then
		return 0
	fi
	echo "WARN: 'npm i -g ajv-cli ajv-formats' exited non-zero" >&2
	return 1
}

install_via_pip() {
	echo "INFO: pip3 found — installing: pip3 install --break-system-packages jsonschema"
	if pip3 install --break-system-packages jsonschema; then
		return 0
	fi
	echo "WARN: 'pip3 install --break-system-packages jsonschema' exited non-zero" >&2
	return 1
}

ATTEMPTED=0
if [ "$PREFER" = "ajv" ]; then
	if command -v npm >/dev/null 2>&1; then
		ATTEMPTED=1
		install_via_npm || true
	elif command -v pip3 >/dev/null 2>&1; then
		ATTEMPTED=1
		install_via_pip || true
	fi
else
	if command -v pip3 >/dev/null 2>&1; then
		ATTEMPTED=1
		install_via_pip || true
	elif command -v npm >/dev/null 2>&1; then
		ATTEMPTED=1
		install_via_npm || true
	fi
fi

if [ "$ATTEMPTED" -eq 0 ]; then
	echo "ERROR: no installer available — neither npm nor pip3 is on PATH. Install one manually:" >&2
	echo "  npm i -g ajv-cli ajv-formats" >&2
	echo "  OR: pip3 install --break-system-packages jsonschema" >&2
	exit 2
fi

# ---- re-verify: only genuine post-install state counts. Never trust an
# installer's own exit code alone — it can report success while PATH/import
# state is unchanged (e.g. a global npm prefix that isn't on PATH). --------
if have_ajv; then
	echo "OK: ajv now available after install"
	exit 0
fi
if have_jsonschema; then
	echo "OK: python3+jsonschema now available after install"
	exit 0
fi

echo "ERROR: install attempted but no validator is available afterward (ajv still absent; python3+jsonschema still absent). Install one manually:" >&2
echo "  npm i -g ajv-cli ajv-formats" >&2
echo "  OR: pip3 install --break-system-packages jsonschema" >&2
exit 3
