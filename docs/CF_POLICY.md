# Cloudflare configuration policy

This document records intentional configuration decisions for the Cloudflare
zone managing `freedom-yield.com` (and its subdomains, including
`metal.freedom-yield.com`). Some of these decisions appear in Cloudflare's
Security Insights as "improvement" recommendations that are flagged but
deliberately not enabled. This document explains why, so future operators (or
any AI assistant looking at the dashboard) do not enable them by mistake.

## Intentionally OFF — bot-blocking features

The following Cloudflare features are listed as security improvements in the
dashboard, but are deliberately kept OFF for this zone.

### Bot Fight Mode

- **Where:** Cloudflare dashboard → Security → Settings → Bot Fight Mode
- **State:** OFF (and accepted-risk in Security Insights as of 2026-06-19)
- **Reason:** This zone hosts a Metal Blockchain validator project at
  `metal.freedom-yield.com`. The site is intentionally designed for
  *institutional and automated evaluator* access. Among the published
  surfaces:

  - `/api/evidence.json` — machine-readable manifest, intended for CI /
    automated parsers
  - `/api/*.schema.v1.json` — formal JSON Schema for each manifest, intended
    for `ajv validate` and similar
  - `/api/cycle-history.example.jsonl` — schema preview for the planned
    per-cycle audit packet
  - `/api/identity.example.json` — schema preview for the planned operator
    identity manifest, including the Merkle DAG hub that binds all leaf
    artefacts

  Bot Fight Mode targets and blocks automated user agents. Enabling it would
  cause exactly the consumers this architecture is designed for (CI scripts,
  `ajv` validators, `jq` pipelines, AI-assisted due-diligence tools) to
  receive HTTP 403 responses, defeating the purpose of publishing
  machine-readable contracts.

  A real incident confirming this risk: Cloudflare's bot-fight scoring has
  been observed to flag Anthropic's WebFetch user-agent as a bot on this
  zone's `/api/*` paths, returning 403. (See project memory
  `reference_cf_bot_fight_api`.) The same heuristic would block any other
  AI-assisted reviewer tool.

### AI Labyrinth

- **Where:** Cloudflare dashboard → Security → Settings → AI ラビリンス
- **State:** OFF (and accepted-risk in Security Insights as of 2026-06-19)
- **Reason:** AI Labyrinth serves honeypot / decoy content to AI bots. This
  zone explicitly *wants* AI-assisted evaluator tools to receive the real,
  canonical manifests. Serving them decoy content would mislead exactly the
  audience the architecture is built for.

### Block AI bots

- **Where:** Cloudflare dashboard → Security → Settings → AI ボットをブロックする
- **State:** OFF
- **Reason:** Same family of concern as AI Labyrinth. Identified AI bots
  should receive the real `/api/*` content, not a 403. The published JSON
  Schema and Merkle DAG hub are designed to be consumed by automated
  tooling; AI-assisted tools are part of that intended audience.

## How the bot-block decision is recorded in Cloudflare itself

The two recommendations that appear in **Security Overview → Security
Action Items** have been marked "リスクを受け入れる" (Accept the risk) on
2026-06-19 with a reason field pointing to this document:

- *Bot Fight モードで自動化されたトラフィックを検出して軽減する* — archived,
  accepted-risk
- *AI Labyrinth で不要な AI クローラーを阻止* — archived, accepted-risk

Future scans may re-surface these. If they do, dismiss again with the same
reason. Do not toggle the corresponding Settings ON.

## Intentionally ON — defenses that do not interfere with the architecture

These are good defaults and should stay ON. None of them target automated
user agents specifically; they target malformed traffic, DDoS, and
protocol-level abuse, all of which are orthogonal to the machine-readable
surface we publish.

- Cloudflare 管理ルールセット (Managed ruleset)
- HTTP DDoS 攻撃からの保護 (HTTP DDoS protection)
- SSL/TLS DDoS 攻撃からの保護 (SSL/TLS DDoS protection)
- ネットワーク層 DDoS 攻撃からの保護 (Network-layer DDoS protection)
- ウェブ資産検出 (Web asset discovery)
- スキーマ検証 (Schema validation)
- ブラウザ整合性チェック (Browser integrity check)
- TLS 1.3, HTTPS の自動リライト

## DMARC / SPF / DKIM / HSTS / Always HTTPS

Configured per project memory `reference_cf_email_routing` and
`reference_cf_policy_decisions`. Important constraints:

- **DMARC policy** for both `metal.freedom-yield.com` and
  `freedom-yield.com` is **permanently `p=none`** because operator outbound
  mail is routed via Gmail "Send mail as", which cannot align its SPF and
  DKIM signatures with our domains. Raising the policy to `p=quarantine` or
  `p=reject` would cause this zone's own outbound mail to be rejected by
  strict receivers.
- **HSTS** is enabled at apex with `max-age=1 month` and
  `includeSubDomains=on`. All subdomains of `freedom-yield.com` use HTTPS
  (CF Universal SSL + Let's Encrypt at the origin), so `includeSubDomains`
  is safe. Preload is intentionally OFF until the policy has been stable
  for several months.
- **Always Use HTTPS** is ON at apex (HTTP → HTTPS 301 redirect at the CF
  edge).
- **SPF** is auto-managed by Cloudflare Email Routing
  (`v=spf1 include:_spf.mx.cloudflare.net ~all`) at both apex and the
  subdomain.
- **DKIM** is auto-managed by Cloudflare Email Routing
  (`cf2024-1._domainkey.freedom-yield.com`).

## Why this document exists

The Cloudflare Security Insights dashboard is built around generic best
practices for typical consumer-facing sites. The Freedom Yield Metal
validator project is not a consumer site — it is a machine-readable
evidence surface published for institutional reviewers, with formal JSON
Schema and Merkle DAG manifest. Several of Cloudflare's "improvement"
recommendations are directly antagonistic to this architecture.

Without an explicit, durable record like this document, a future operator
(or an AI assistant unfamiliar with the architecture) could see the red
"improvement" badges in the dashboard, enable the recommended features,
and silently break automated evaluator access. The on-domain
acknowledgement (Security Insights "accept-risk" with this document as the
reason) plus the in-repo policy here together form a two-layer record.

## Related project memory

- `reference_cf_policy_decisions` — the same policy in memory form, for
  AI-session recall.
- `reference_cf_email_routing` — mail routing, DKIM, DMARC alignment
  constraints.
- `reference_cf_bot_fight_api` — historical observation of Cloudflare's
  bot scoring blocking `/api/*`.
- `reference_xserver_topology` — DNS authoritative on Cloudflare, vhost
  layout.
- `feedback_no_retail_marketing` — confirms the audience is institutional
  / evaluator, not retail.
- `feedback_smallness_as_asset` — confirms automated tooling / data feed
  is the differentiator.
