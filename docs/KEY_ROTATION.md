# Validator key rotation runbook

Metal Blockchain (metalgo) の staking 用 key を扱う際の手順。漏洩疑い時の緊急対応も含む。

## key の構造

metalgo は `--data-dir` の下に staking dir を持ち、以下 3 ファイルを保管する。

| ファイル | 用途 | 公開 |
|---|---|---|
| `staker.crt` | X.509 公開証明書(NodeID の元) | 公開可 |
| `staker.key` | 上記の **秘密鍵 (PEM)** | **絶対に外に出さない** |
| `signer.key` | BLS の **秘密鍵** | **絶対に外に出さない** |

本リポの compose では `/data` は Docker named volume (`METALGO_DATA_PATH` を設定すれば bind mount) に格納される。実体の名前は compose project 名で変わり、現行本番 host の metalgo は repo の compose とは別の名前で動いている ([DISASTER_RECOVERY.md 冒頭の警告](DISASTER_RECOVERY.md))。**volume 名・コンテナ名は固定で仮定しない。** 下の手順は compose label でコンテナを特定し、その `/data` の mount 元を使う。

> ⚠️ 固定の volume 名で `docker run -v <名前>:/data` すると、その名前の volume が無い host では **空の volume が黙って作られ**、一覧は空・backup は空の tar になる。

## NodeID とは

`staker.crt` のハッシュを base58check した値が `NodeID-xxxx`。**公開して問題ない識別子**(explorer に常に出る)。`staker.key` がなければ NodeID から秘密鍵を逆算することはできない。

## ファイルにアクセスする方法

普段はアクセス不要。backup / rotation などの必要時のみ。

```sh
# 対象コンテナを特定する (期待: 1 行だけ。2 行以上なら止まって確認)
docker ps -a --filter label=com.docker.compose.service=metalgo --format '{{.ID}} {{.Names}} {{.Status}}'
CID=<上の ID>
# その /data の mount 元 (空なら止まる)
DATA=$(docker inspect "$CID" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
echo "$DATA"
# staking dir のファイル一覧
sudo ls -la "$DATA/staking"
```

## Backup 手順

1. 暗号化保管先を用意(macOS なら encrypted disk image、Linux なら LUKS、外部 KMS 推奨)
2. backup を取る:

   ```sh
   # DATA は「ファイルにアクセスする方法」の手順で求めたもの
   mkdir -p "$(pwd)/secure-backup"
   sudo tar czf "$(pwd)/secure-backup/staking-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$DATA" staking
   # 中身に staker.crt / staker.key / signer.key が入っていることを確認
   sudo tar tzf "$(pwd)"/secure-backup/staking-*.tar.gz
   ```

3. tar を**すぐ暗号化** (`gpg -c` / `age` / KMS にアップロード) して、平文 tar は削除
4. backup の存在を public な場所に書かない

## Rotation 戦略

Avalanche family は **active な validation 中に key を差し替えると stake が無効になる**(NodeID が変わるため)。安全なローテーション:

1. 新 staking key を別 volume で生成
2. 旧 stake の `endTime` まで運用継続
3. 旧 stake の `endTime` 到達 → metalgo 停止 → 新 volume で起動 → 新 NodeID で P-Chain に `addValidator` tx 送信
4. 旧 key と旧 backup を shred + 暗号化バックアップからも削除

testnet は経済価値ゼロなので即時 rotation 可能(named volume を消して再生成)。

## 漏洩疑い時の緊急対応

`staker.key` または `signer.key` が**外部に出た疑い**がある場合:

1. **すぐ metalgo を停止**: compose label でコンテナを特定して `docker stop <ID>` し、止まったことを確認する。手順は [INCIDENT_RESPONSE.md §3.4](INCIDENT_RESPONSE.md#34-staking-key-漏洩疑い-sev-1) の step 1。`make node-down` や compose の down は使わない (testnet 用 compose / 別 project を指すので、現行本番 host の metalgo は止まらない)
2. 当該 key を含む全 backup を特定し、暗号化破棄
3. 公衆 explorer で当該 NodeID の `endTime` を確認:
   - stake が active なら **その期間は経済的損失リスクあり**(攻撃者が一時的に validator を動かして報酬を盗む / 不正委任を受ける)
   - スラッシングは無いので元本(stake) は守られる、損失は逸失利益のみ
4. 新 key で別 NodeID として新 stake を立ち上げる
5. **情報開示**: 本サイト `/incidents/` に経緯を公開する(信用情報サイトとしての責務)

## testnet vs mainnet

- testnet (Tahoe) の key を mainnet で**絶対に流用しない**(逆も)
- testnet で生成された Tahoe NodeID は mainnet で意味を持たない(別 chain)
- 各 environment で独立した key set を保持し、ファイル名・volume・backup 先も分離する

## 関連

- インシデント response: `docs/INCIDENT_RESPONSE.md`
- disaster recovery: `docs/DISASTER_RECOVERY.md`
