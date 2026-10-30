#!/usr/bin/env bash
# staker-backup-encrypt.sh -- make the encrypted staker key backup from the
# Mac's FileVault-protected plaintext copy, and prove in the same run that it
# opens back to the same three files (constitution "backup", guarantee a).
#
# CHAIN: none. No network, no host, no container.
#
# The OPERATOR runs it in a terminal: it asks for a NEW passphrase twice (type,
# then confirm). The passphrase lives only in this process's environment for
# openssl and is never written, logged or echoed.
#
#   1. source: newest ~/staker-backup-*/staking (or the dir given), 3 key files
#   2. copy them into a private WORKDIR as staker-backup-<yyyymmdd>/staking
#      (the layout dr-drill.sh expects) and tar+gzip
#   3. encrypt with the drill's cipher (aes-256-cbc, pbkdf2, 600000 iterations)
#      to <out>.partial
#   4. decrypt <out>.partial again, extract, and compare the SHA-256 of all three
#      files with the source; any difference -> stop, delete .partial, exit 1
#   5. rename to ~/staker-backup-<yyyymmdd>.tar.gz.enc (mode 600) and write its
#      SHA-256 next to it (<out>.sha256)
#
# Afterwards prove the SAVED passphrase opens it (guarantee b):
#   bash scripts/dr-drill.sh        (asks the passphrase once)
#
# Usage:  bash scripts/operator-local/staker-backup-encrypt.sh [<staking dir>]
# Env:    STAKER_BACKUP_OUT_DIR  where the .enc is written (default: $HOME)
#         STAKER_BACKUP_DATE     yyyymmdd in the name (default: today)
# Exit:   0 written and verified / 1 failed (nothing written) / 2 refused
set -euo pipefail

KEY_FILES=(staker.crt staker.key signer.key)
OUT_DIR="${STAKER_BACKUP_OUT_DIR:-$HOME}"
DAY="${STAKER_BACKUP_DATE:-$(date +%Y%m%d)}"
MIN_LEN=16

die() { echo "止まりました: $2" >&2; exit "$1"; }

[ $# -le 1 ] || die 2 "引数は 1 つまで（鍵のディレクトリ）"
SRC="${1:-}"
if [ -z "$SRC" ]; then
	for d in "$HOME"/staker-backup-*/staking; do
		[ -d "$d" ] && [ ! -L "$d" ] && [ ! -L "${d%/staking}" ] || continue
		if [ -z "$SRC" ] || [[ "$d" > "$SRC" ]]; then SRC="$d"; fi
	done
fi
[ -n "$SRC" ] || die 2 "$HOME/staker-backup-*/staking が見つかりません"
[ -d "$SRC" ] && [ ! -L "$SRC" ] || die 2 "鍵のディレクトリがありません（またはリンク）: $SRC"
for f in "${KEY_FILES[@]}"; do
	[ -f "$SRC/$f" ] && [ ! -L "$SRC/$f" ] || die 2 "鍵のファイルがありません（またはリンク）: $SRC/$f"
done
[[ "$DAY" =~ ^[0-9]{8}$ ]] || die 2 "日付の形が違います: $DAY"
for t in openssl tar shasum; do command -v "$t" >/dev/null 2>&1 || die 2 "$t がありません"; done

OUT="$OUT_DIR/staker-backup-$DAY.tar.gz.enc"
[ ! -e "$OUT" ] && [ ! -e "$OUT.partial" ] || die 2 "同じ名前のファイルが既にあります（上書きしません）: $OUT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/fy-staker-enc.XXXXXX")"
chmod 700 "$WORKDIR"
DONE=0
cleanup() {
	rm -rf "$WORKDIR"
	[ "$DONE" = "1" ] || rm -f "$OUT.partial"
	unset PP_FOR_OPENSSL
}
trap cleanup EXIT

echo "鍵のバックアップを作ります。元: $SRC"
echo "新しいパスワードを 2 回聞きます（1 回目＝入力、2 回目＝打ち間違いの確認）。"
echo "先に Dashlane に保存し、そこから貼り付けてください。"
NO_INPUT="パスワードを読めません。パスワードを打てるターミナル（ターミナル.app）で実行してください。何も作っていません"
read -rs -p "  新しいパスワード: " P1 || die 1 "$NO_INPUT"; echo
read -rs -p "  もう一度、同じパスワード: " P2 || die 1 "$NO_INPUT"; echo
[ "$P1" = "$P2" ] || { unset P1 P2; die 1 "2 回のパスワードが違います。何も作っていません"; }
[ "${#P1}" -ge "$MIN_LEN" ] || { unset P1 P2; die 1 "パスワードが短すぎます（${MIN_LEN} 文字以上）。何も作っていません"; }
export PP_FOR_OPENSSL="$P1"
unset P1 P2

TOP="staker-backup-$DAY"
mkdir -p "$WORKDIR/src/$TOP/staking"
for f in "${KEY_FILES[@]}"; do
	( umask 077; cp "$SRC/$f" "$WORKDIR/src/$TOP/staking/$f" )
done
tar czf "$WORKDIR/backup.tar.gz" -C "$WORKDIR/src" "$TOP"

( umask 077; openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
	-pass env:PP_FOR_OPENSSL -in "$WORKDIR/backup.tar.gz" -out "$OUT.partial" ) \
	|| die 1 "暗号化に失敗しました"

# guarantee a: open what was written, compare with the source
mkdir "$WORKDIR/check"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
	-pass env:PP_FOR_OPENSSL -in "$OUT.partial" -out "$WORKDIR/check.tar.gz" 2>/dev/null \
	|| die 1 "作った直後のファイルが開けません。何も残していません"
unset PP_FOR_OPENSSL
tar xzf "$WORKDIR/check.tar.gz" -C "$WORKDIR/check" || die 1 "中身を取り出せません"
for f in "${KEY_FILES[@]}"; do
	[ -f "$WORKDIR/check/$TOP/staking/$f" ] || die 1 "開いた中に $f がありません"
	a="$(shasum -a 256 "$SRC/$f" | awk '{print $1}')"
	b="$(shasum -a 256 "$WORKDIR/check/$TOP/staking/$f" | awk '{print $1}')"
	[ "$a" = "$b" ] || die 1 "$f のハッシュが元と違います。何も残していません"
done

chmod 600 "$OUT.partial"
mv "$OUT.partial" "$OUT"
DONE=1
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$OUT")" >"$(basename "$OUT").sha256" )
chmod 600 "$OUT.sha256"

echo
echo "できました: $OUT"
echo "  3 つの鍵のファイルは、開き直して元とハッシュが一致しました。"
echo "  次に、Dashlane に保存したパスワードで開けるかを確かめます:"
echo "  bash scripts/dr-drill.sh   （パスワードを 1 回だけ聞きます）"
