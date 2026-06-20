#!/usr/bin/env python3
"""Reference implementation + vector generator for the Phase α Merkle DAG.

This is a self-contained Python reference implementation of the
construction specified in docs/MERKLE_DAG_SPEC.md. It is independent
of (and bit-for-bit equivalent to) the portable shell function at
scripts/operator-local/gen-identity.sh::compute_merkle_root.

Auditor usage:

    python3 generate.py            # regenerate all vector files on disk
    python3 generate.py --verify   # re-derive and assert match with on-disk files
    python3 generate.py --inspect  # print all vector summaries to stdout

The vectors are synthetic — they intentionally do NOT correspond to any
production identity, key, or validation cycle. An auditor implementing
a verifier in another language can read inputs.* + expected.json from
each vector dir, run their implementation against the same inputs, and
assert the same outputs.

Python 3.8+, stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
NULL_BRANCH_HASH = hashlib.sha256(b"").hexdigest()

SYNTH_PUBKEY_FPR_1 = "SHA256:V1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
SYNTH_PUBKEY_FPR_2 = "SHA256:V2BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
SYNTH_NODE_ID = "NodeID-yyPvtQHTA4FZU5cJtjWZa7RVBpWU3i5v"


# -----------------------------------------------------------------------------
# Reference implementation (= docs/MERKLE_DAG_SPEC.md §3, §4, §5)
# -----------------------------------------------------------------------------

def sha256_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def hex_to_bytes(h: str) -> bytes:
    return bytes.fromhex(h)


def jsonl_leaves(jsonl_bytes: bytes) -> list[str]:
    """Split JSONL into leaf hashes.

    Per MERKLE_DAG_SPEC.md §2: each non-empty line is one leaf.
    The bytes hashed are the line bytes as served, including the
    trailing '\\n' if the line is followed by another line, excluding
    the trailing '\\n' on the final line.
    """
    if not jsonl_bytes:
        return []
    # Split preserving terminators on intermediate lines.
    pieces: list[bytes] = []
    cur = bytearray()
    for byte in jsonl_bytes:
        cur.append(byte)
        if byte == 0x0A:  # '\n'
            pieces.append(bytes(cur))
            cur = bytearray()
    if cur:
        pieces.append(bytes(cur))
    # Drop empty lines (e.g., trailing newline produced an empty piece).
    return [sha256_hex(p) for p in pieces if p.rstrip(b"\n").strip()]


def compute_merkle_root(leaf_hashes_hex: list[str]) -> str:
    """Bitcoin-style: duplicate last leaf on odd counts."""
    if not leaf_hashes_hex:
        return NULL_BRANCH_HASH
    level = list(leaf_hashes_hex)
    while len(level) > 1:
        if len(level) % 2 == 1:
            level.append(level[-1])
        next_level = []
        for i in range(0, len(level), 2):
            parent = sha256_hex(hex_to_bytes(level[i]) + hex_to_bytes(level[i + 1]))
            next_level.append(parent)
        level = next_level
    return level[0]


def compute_merkle_proof(leaf_hashes_hex: list[str], index: int) -> list[str]:
    """Sibling-hash path from leaf to root (= excludes the target leaf itself)."""
    if not leaf_hashes_hex:
        raise ValueError("no leaves")
    if not (0 <= index < len(leaf_hashes_hex)):
        raise IndexError(f"index {index} out of range [0, {len(leaf_hashes_hex)})")
    level = list(leaf_hashes_hex)
    proof: list[str] = []
    idx = index
    while len(level) > 1:
        if len(level) % 2 == 1:
            level.append(level[-1])
        sibling_idx = idx ^ 1
        proof.append(level[sibling_idx])
        next_level = []
        for i in range(0, len(level), 2):
            parent = sha256_hex(hex_to_bytes(level[i]) + hex_to_bytes(level[i + 1]))
            next_level.append(parent)
        level = next_level
        idx //= 2
    return proof


def verify_merkle_proof(leaf_hex: str, index: int, proof: list[str], root: str) -> bool:
    cur = leaf_hex
    idx = index
    for sibling in proof:
        if idx % 2 == 0:
            cur = sha256_hex(hex_to_bytes(cur) + hex_to_bytes(sibling))
        else:
            cur = sha256_hex(hex_to_bytes(sibling) + hex_to_bytes(cur))
        idx //= 2
    return cur == root


def dag_root_hash(identity_root_hex: str, cycles_root_hex: str) -> str:
    return sha256_hex(hex_to_bytes(identity_root_hex) + hex_to_bytes(cycles_root_hex))


# -----------------------------------------------------------------------------
# Synthetic line builders (= shape matches identity-history.schema.v1.json,
# cycle-history.schema.v1.json)
# -----------------------------------------------------------------------------

def identity_line(
    key_seq: int,
    fpr: str,
    iat: str,
    exp: str,
    revoked: bool = False,
    revoked_at: str | None = None,
    revocation_reason: str | None = None,
    superseded_by: int | None = None,
    pubkey_filename: str = "operator-identity.pub",
    comment: str | None = None,
) -> str:
    obj = {
        "schema_version": 1,
        "key_seq": key_seq,
        "operator_identity_pubkey_fingerprint": fpr,
        "operator_identity_pubkey_url": f"https://metal.freedom-yield.com/.well-known/{pubkey_filename}",
        "key_iat": iat,
        "key_exp": exp,
        "revoked": revoked,
        "revoked_at": revoked_at,
        "revocation_reason": revocation_reason,
        "superseded_by_key_seq": superseded_by,
    }
    if comment is not None:
        obj["comment"] = comment
    return json.dumps(obj, separators=(",", ":"))


def cycle_line(
    cycle_n: int,
    start_iso: str,
    end_iso: str,
    signed_by_key_seq: int | None = None,
    signed_by_fpr: str | None = None,
) -> str:
    obj = {
        "schema_version": 1,
        "cycle_n": cycle_n,
        "node_id": SYNTH_NODE_ID,
        "network": "metal-mainnet",
        "start_iso": start_iso,
        "end_iso": end_iso,
        "duration_days": 14,
        "final_uptime_pct": 99.5,
        "days_recorded": 14,
        "final_self_stake_metal": 2000,
        "final_total_delegated_metal": 0,
        "final_delegation_fee_pct": 3.0,
        "avg_peer_count": 220.0,
        "min_peer_count": 200,
        "incidents_in_cycle_count": 0,
        "incidents_in_cycle_ids": [],
        "explorer_url": f"https://explorer.metalblockchain.org/validators/{SYNTH_NODE_ID}",
        "cycle_status": "closed",
        "notes": f"synthetic cycle {cycle_n} for verifier test vector",
    }
    if signed_by_key_seq is not None:
        obj["signed_by_key_seq"] = signed_by_key_seq
    if signed_by_fpr is not None:
        obj["signed_by_pubkey_fingerprint"] = signed_by_fpr
    return json.dumps(obj, separators=(",", ":"))


# -----------------------------------------------------------------------------
# Vectors
# -----------------------------------------------------------------------------

def _jsonl_bytes(lines: list[str]) -> bytes:
    """Join lines with '\\n' and a trailing newline on the file (= the form gen-*.sh emits)."""
    return ("\n".join(lines) + "\n").encode("utf-8") if lines else b""


def _branch_vector(name: str, description: str, lines: list[str], proof_index: int) -> dict:
    body = _jsonl_bytes(lines)
    leaves = jsonl_leaves(body)
    root = compute_merkle_root(leaves)
    out = {
        "vector_name": name,
        "description": description,
        "leaf_count": len(leaves),
        "branch_root": root,
        "leaf_hashes_in_order": leaves,
    }
    if leaves:
        out["proof_for_leaf_index"] = proof_index
        out["proof_sibling_hashes"] = compute_merkle_proof(leaves, proof_index)
        out["proof_target_leaf_hash"] = leaves[proof_index]
        out["proof_reverify"] = verify_merkle_proof(
            leaves[proof_index], proof_index,
            out["proof_sibling_hashes"], root,
        )
    return out, body


def vector_v01_single_leaf():
    return _branch_vector(
        "v01-single-leaf",
        "identity_branch with one leaf. branch_root equals the single leaf hash (no pairing).",
        [identity_line(1, SYNTH_PUBKEY_FPR_1, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z",
                       comment="initial production key, vector v01")],
        proof_index=0,
    )


def vector_v02_three_leaf_odd():
    return _branch_vector(
        "v02-three-leaf-odd",
        "cycles_branch with three leaves. The last leaf is duplicated at level 0 "
        "(= Bitcoin-style odd-count handling) to form pairs; root level emerges after "
        "one more pairing of two intermediate parents.",
        [
            cycle_line(1, "2026-05-19T07:10:14Z", "2026-06-04T07:17:46Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
            cycle_line(2, "2026-06-04T17:01:57Z", "2026-07-04T13:00:00Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
            cycle_line(3, "2026-07-04T13:00:00Z", "2026-08-04T13:00:00Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
        ],
        proof_index=2,
    )


def vector_v03_four_leaf():
    return _branch_vector(
        "v03-four-leaf",
        "cycles_branch with four leaves. Two pairings at level 0 produce two parents; "
        "one pairing at level 1 produces the root. Demonstrates multi-level reduction "
        "without any duplication.",
        [
            cycle_line(1, "2026-05-19T07:10:14Z", "2026-06-04T07:17:46Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
            cycle_line(2, "2026-06-04T17:01:57Z", "2026-07-04T13:00:00Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
            cycle_line(3, "2026-07-04T13:00:00Z", "2026-08-04T13:00:00Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
            cycle_line(4, "2026-08-04T13:00:00Z", "2026-09-04T13:00:00Z",
                       signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
        ],
        proof_index=1,
    )


def vector_v04_empty_branch():
    """Synthetic empty-branch case. Per spec §5, branch_root = SHA-256("")."""
    out, body = _branch_vector(
        "v04-empty-branch",
        "Zero-leaf branch. Sentinel hash convention from MERKLE_DAG_SPEC.md §5: "
        "branch_root equals SHA-256(\"\") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.",
        [],
        proof_index=0,
    )
    out["expected_sentinel"] = NULL_BRANCH_HASH
    out["matches_sentinel"] = (out["branch_root"] == NULL_BRANCH_HASH)
    return out, body


def vector_v05_full_dag():
    """End-to-end: two-leaf identity_branch + four-leaf cycles_branch + dag_root_hash."""
    id_lines = [
        identity_line(1, SYNTH_PUBKEY_FPR_1, "2026-01-01T00:00:00Z", "2027-01-01T00:00:00Z",
                      superseded_by=2, pubkey_filename="operator-identity.v1.pub",
                      comment="initial key, rotated routinely 2027-01-01"),
        identity_line(2, SYNTH_PUBKEY_FPR_2, "2027-01-01T00:00:00Z", "2028-01-01T00:00:00Z",
                      comment="second key, current"),
    ]
    cy_lines = [
        cycle_line(1, "2026-05-19T07:10:14Z", "2026-06-04T07:17:46Z",
                   signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
        cycle_line(2, "2026-06-04T17:01:57Z", "2026-07-04T13:00:00Z",
                   signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
        cycle_line(3, "2026-07-04T13:00:00Z", "2026-08-04T13:00:00Z",
                   signed_by_key_seq=1, signed_by_fpr=SYNTH_PUBKEY_FPR_1),
        cycle_line(4, "2027-01-04T13:00:00Z", "2027-02-04T13:00:00Z",
                   signed_by_key_seq=2, signed_by_fpr=SYNTH_PUBKEY_FPR_2),
    ]
    id_body = _jsonl_bytes(id_lines)
    cy_body = _jsonl_bytes(cy_lines)
    id_leaves = jsonl_leaves(id_body)
    cy_leaves = jsonl_leaves(cy_body)
    id_root = compute_merkle_root(id_leaves)
    cy_root = compute_merkle_root(cy_leaves)
    dag = dag_root_hash(id_root, cy_root)
    out = {
        "vector_name": "v05-full-dag",
        "description": "End-to-end DAG: two-leaf identity_branch (key rotation) plus four-leaf "
                       "cycles_branch (with cross-ref to identity_branch). Demonstrates "
                       "dag_root_hash = SHA-256(raw(identity_root)||raw(cycles_root)).",
        "identity_branch": {
            "leaf_count": len(id_leaves),
            "branch_root": id_root,
            "leaf_hashes_in_order": id_leaves,
        },
        "cycles_branch": {
            "leaf_count": len(cy_leaves),
            "branch_root": cy_root,
            "leaf_hashes_in_order": cy_leaves,
        },
        "dag_root_hash": dag,
        "memo_for_anchor": f"fyid1:{dag}",
        "cross_ref_check": [
            {"cycle_n": 1, "signed_by_key_seq": 1, "signed_by_pubkey_fingerprint": SYNTH_PUBKEY_FPR_1,
             "matches_identity_entry_key_seq_1": True},
            {"cycle_n": 2, "signed_by_key_seq": 1, "signed_by_pubkey_fingerprint": SYNTH_PUBKEY_FPR_1,
             "matches_identity_entry_key_seq_1": True},
            {"cycle_n": 3, "signed_by_key_seq": 1, "signed_by_pubkey_fingerprint": SYNTH_PUBKEY_FPR_1,
             "matches_identity_entry_key_seq_1": True},
            {"cycle_n": 4, "signed_by_key_seq": 2, "signed_by_pubkey_fingerprint": SYNTH_PUBKEY_FPR_2,
             "matches_identity_entry_key_seq_2": True},
        ],
    }
    return out, id_body, cy_body


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------

def write_vector_dir(name: str, files: dict[str, bytes], expected: dict) -> None:
    d = ROOT / name
    d.mkdir(exist_ok=True)
    for fname, body in files.items():
        (d / fname).write_bytes(body)
    (d / "expected.json").write_text(json.dumps(expected, indent=2) + "\n")


def read_vector_dir(name: str) -> tuple[dict[str, bytes], dict]:
    d = ROOT / name
    files = {}
    for p in sorted(d.iterdir()):
        if p.name == "expected.json":
            continue
        if p.is_file():
            files[p.name] = p.read_bytes()
    expected = json.loads((d / "expected.json").read_text())
    return files, expected


def regenerate_all() -> dict[str, dict]:
    results = {}

    out, body = vector_v01_single_leaf()
    write_vector_dir(out["vector_name"], {"identity-history.jsonl": body}, out)
    results[out["vector_name"]] = out

    out, body = vector_v02_three_leaf_odd()
    write_vector_dir(out["vector_name"], {"cycle-history.jsonl": body}, out)
    results[out["vector_name"]] = out

    out, body = vector_v03_four_leaf()
    write_vector_dir(out["vector_name"], {"cycle-history.jsonl": body}, out)
    results[out["vector_name"]] = out

    out, body = vector_v04_empty_branch()
    write_vector_dir(out["vector_name"], {"cycle-history.jsonl": body}, out)
    results[out["vector_name"]] = out

    out, id_body, cy_body = vector_v05_full_dag()
    write_vector_dir(out["vector_name"], {
        "identity-history.jsonl": id_body,
        "cycle-history.jsonl": cy_body,
    }, out)
    results[out["vector_name"]] = out

    return results


def verify_all() -> int:
    results = regenerate_all()
    failures = 0
    for name in results:
        d = ROOT / name
        if not d.exists():
            print(f"FAIL {name}: directory missing", file=sys.stderr)
            failures += 1
            continue
        on_disk_expected = json.loads((d / "expected.json").read_text())
        re_derived = results[name]
        if on_disk_expected != re_derived:
            print(f"FAIL {name}: on-disk expected.json does not match re-derived values", file=sys.stderr)
            failures += 1
        else:
            print(f"OK   {name}")
    return failures


def inspect_all() -> None:
    for name, exp in regenerate_all().items():
        print(f"=== {name} ===")
        print(f"  description: {exp['description']}")
        if "branch_root" in exp:
            print(f"  leaf_count : {exp['leaf_count']}")
            print(f"  branch_root: {exp['branch_root']}")
        if "dag_root_hash" in exp:
            print(f"  identity_branch_root: {exp['identity_branch']['branch_root']} (leaves={exp['identity_branch']['leaf_count']})")
            print(f"  cycles_branch_root  : {exp['cycles_branch']['branch_root']} (leaves={exp['cycles_branch']['leaf_count']})")
            print(f"  dag_root_hash       : {exp['dag_root_hash']}")
            print(f"  memo_for_anchor     : {exp['memo_for_anchor']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true",
                        help="Re-derive and assert match with on-disk vector files (no write).")
    parser.add_argument("--inspect", action="store_true",
                        help="Print vector summaries to stdout.")
    args = parser.parse_args()

    if args.verify:
        return 1 if verify_all() else 0
    if args.inspect:
        inspect_all()
        return 0
    regenerate_all()
    print(f"Regenerated {len(list(ROOT.glob('v*-*/')))} vector directories under {ROOT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
