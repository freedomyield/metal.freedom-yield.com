#!/usr/bin/env node
// scripts/lib/eosio-pubkey-raw-hex.js — decode an EOSIO/Antelope K1 public
// key string (legacy "EOS..." or new "PUB_K1_..." format) to its raw
// 33-byte compressed secp256k1 key, printed as lowercase hex.
//
// CHAIN: none — pure offline string decoding, no network/proton call.
// PRIME_DIRECTIVE: TESTNET-FIRST — not applicable; this is a decode-only
//                  utility with no broadcast capability whatsoever.
//
// Why this exists (2026-07-31, cycle-4 w3 testnet-rehearsal repair):
//   scripts/run-testnet-rehearsal.sh must verify that the CURRENT on-chain
//   <account>@anchor public key (fetched read-only via testnet RPC
//   `get_account`, which returns legacy "EOS..." format) is present in the
//   local proton-cli keystore (`proton key:list`, which returns "PUB_K1_..."
//   format per this repo's existing documentation, e.g.
//   docs/OPERATOR_IDENTITY_SETUP.md's "expected output" for key:list/
//   key:generate). These are TWO DIFFERENT base58check encodings of the
//   SAME 33-byte key data with DIFFERENT checksum inputs (see below) — they
//   typically share a long common prefix but can legitimately differ in an
//   arbitrary number of TRAILING characters even for the identical key,
//   because base58 is a positional big-integer encoding, not a per-byte
//   transform. A fixed-length prefix/substring heuristic is therefore not a
//   reliable equality test for a security-relevant check. Decoding both to
//   raw key bytes and comparing those bytes is the only correct approach.
//
// Checksum algorithm per the EOSIO/Antelope key spec (fc's "crypto public_key" type,
// mirrored in eosjs-ecc et al.):
//   legacy  "EOS<base58(keydata(33B) ++ ripemd160(keydata)[0:4])>"
//   new K1  "PUB_K1_<base58(keydata(33B) ++ ripemd160(keydata ++ \"K1\")[0:4])>"
//
// Verified structurally (not from memory alone) against 3 real testnet
// get_account responses during this repair — see w3-report.md — where the
// legacy-format checksum recomputed correctly for all 3 (owner/active/
// anchor permissions of the frdomyieltst testnet account). The PUB_K1_
// checksum formula (ripemd160(keydata ++ "K1")) is the standard, stable
// Antelope/EOSIO spec; this script's own hermetic test constructs a
// synthetic (non-real, fabricated) key pair in BOTH formats from the same
// raw bytes and asserts they decode to the identical raw hex, which
// exercises this exact formula end-to-end without touching real key data.
//
// Only dependency: Node's built-in `crypto` module. No npm install needed —
// `node` (and therefore this module) is already a transitive prerequisite
// of this repo's `proton` CLI, which is itself an npm package.
//
// Usage:
//   node eosio-pubkey-raw-hex.js <pubkey-string>
//
// Stdout (exit 0): 66 lowercase hex characters (the 33-byte raw key), plus
//                  a trailing newline.
// Stderr (exit 1): a one-line error — unsupported prefix, invalid base58
//                  character, wrong decoded length, or checksum mismatch
//                  (any of which means "not a well-formed EOSIO K1 public
//                  key string" — fail closed, do not guess).

'use strict';

const crypto = require('crypto');

const B58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function b58decode(str) {
	let num = 0n;
	for (const ch of str) {
		const idx = B58_ALPHABET.indexOf(ch);
		if (idx === -1) {
			throw new Error(`invalid base58 character ${JSON.stringify(ch)} in ${JSON.stringify(str)}`);
		}
		num = num * 58n + BigInt(idx);
	}
	let hex = num.toString(16);
	if (hex.length % 2 === 1) hex = '0' + hex;
	let bytes = hex.length ? Buffer.from(hex, 'hex') : Buffer.alloc(0);
	// Leading '1' characters in base58 encode leading 0x00 bytes, which the
	// big-integer conversion above otherwise drops.
	let leadingZeros = 0;
	for (const ch of str) {
		if (ch === '1') leadingZeros++;
		else break;
	}
	return Buffer.concat([Buffer.alloc(leadingZeros), bytes]);
}

function ripemd160(buf) {
	try {
		return crypto.createHash('ripemd160').update(buf).digest();
	} catch (e) {
		throw new Error(
			`Node crypto could not compute ripemd160 (${e.message}). This Node build/OpenSSL ` +
			`provider may need the "legacy" provider enabled, or a different Node version is ` +
			`required. Fail-closed: cannot verify the public key without this hash.`
		);
	}
}

// decodeEosioPubkey(pubkeyStr) -> Buffer(33) raw compressed secp256k1 key,
// or throws on any malformed input (unsupported prefix, bad base58,
// wrong length, checksum mismatch).
function decodeEosioPubkey(pubkeyStr) {
	let body;
	let checksumInput;
	if (pubkeyStr.startsWith('PUB_K1_')) {
		body = pubkeyStr.slice('PUB_K1_'.length);
		checksumInput = (keyData) => Buffer.concat([keyData, Buffer.from('K1', 'utf8')]);
	} else if (pubkeyStr.startsWith('EOS')) {
		body = pubkeyStr.slice('EOS'.length);
		checksumInput = (keyData) => keyData;
	} else {
		throw new Error(`unsupported public key prefix (expected "EOS" or "PUB_K1_"): ${pubkeyStr.slice(0, 16)}...`);
	}
	if (!body) {
		throw new Error('empty key body after prefix');
	}
	const decoded = b58decode(body);
	if (decoded.length !== 37) {
		throw new Error(`decoded length ${decoded.length} != 37 (expected 33-byte key + 4-byte checksum)`);
	}
	const keyData = decoded.subarray(0, 33);
	const checksum = decoded.subarray(33);
	const expected = ripemd160(checksumInput(keyData)).subarray(0, 4);
	if (!checksum.equals(expected)) {
		throw new Error('checksum mismatch — malformed or corrupted public key string');
	}
	return keyData;
}

function b58encode(buf) {
	let num = 0n;
	for (const b of buf) num = num * 256n + BigInt(b);
	let str = '';
	while (num > 0n) {
		const rem = num % 58n;
		str = B58_ALPHABET[Number(rem)] + str;
		num = num / 58n;
	}
	let leadingZeros = 0;
	for (const b of buf) {
		if (b === 0) leadingZeros++;
		else break;
	}
	return B58_ALPHABET[0].repeat(leadingZeros) + str;
}

// encodeEosioPubkey(keyData33, format) -> string
//   Test-support only (production code only ever DECODES a real chain/
//   keystore value; it never mints one). Used by
//   tests/run-testnet-rehearsal/ to construct SYNTHETIC, fabricated key
//   fixtures for round-trip assertions, so the test never needs to embed
//   any real public key material (this repo's sanitize policy forbids
//   real on-chain account/key material in fixtures — see CLAUDE.md).
//   format: "EOS" (legacy) or "PUB_K1_" (new).
function encodeEosioPubkey(keyData33, format) {
	if (!Buffer.isBuffer(keyData33) || keyData33.length !== 33) {
		throw new Error('keyData33 must be a 33-byte Buffer');
	}
	let prefix, checksumInput;
	if (format === 'PUB_K1_') {
		prefix = 'PUB_K1_';
		checksumInput = Buffer.concat([keyData33, Buffer.from('K1', 'utf8')]);
	} else if (format === 'EOS') {
		prefix = 'EOS';
		checksumInput = keyData33;
	} else {
		throw new Error('format must be "EOS" or "PUB_K1_"');
	}
	const checksum = ripemd160(checksumInput).subarray(0, 4);
	return prefix + b58encode(Buffer.concat([keyData33, checksum]));
}

function main() {
	const arg = process.argv[2];
	if (!arg) {
		process.stderr.write('usage: eosio-pubkey-raw-hex.js <pubkey-string>\n');
		process.exit(1);
		return;
	}
	try {
		const keyData = decodeEosioPubkey(arg.trim());
		process.stdout.write(keyData.toString('hex') + '\n');
		process.exit(0);
	} catch (e) {
		process.stderr.write(`ERROR: ${e.message}\n`);
		process.exit(1);
	}
}

// Export for the hermetic unit test (tests/run-testnet-rehearsal/) to
// require() directly, without spawning a subprocess per case.
if (require.main === module) {
	main();
} else {
	module.exports = { decodeEosioPubkey, encodeEosioPubkey, b58decode, b58encode, ripemd160 };
}
