# Security layers — abuse / DDoS / brute-force defenses

How the public web side is protected, the gaps that exist, and the
runbook for tightening things when an attack starts. The validator
host is intentionally separate from the web host so that whatever
happens to one cannot take the other down — see
[`../public/continuity/`](../public/continuity/index.html) for the
delegator-facing version of that same point.

---

## 4 layers, outermost first

### 1. edge CDN (edge)

All traffic to `metal.freedom-yield.com` resolves to a edge CDN IP
(proxy / "orange cloud" enabled). Free tier already provides:

- **L3 / L4 DDoS auto-mitigation** — always on, no config
- **IP reputation filter** — known-bad scanners are challenged or dropped
- **Automatic edge caching** for static assets — reduces origin load
- **HTTPS termination + HTTP/3** at the edge

Free-tier configuration **operator must verify in the edge CDN dashboard**:

- [ ] DNS record for `metal.freedom-yield.com` is **proxied (orange)**, not DNS-only (grey)
- [ ] Security → **Bots → Bot Fight Mode = ON**
- [ ] Security → Settings → **Security Level = Medium** (default)
- [ ] Security → **Rate Limiting Rules** → one free rule set as below

#### edge CDN Rate Limiting rule (free plan allows 1)

Name: `block-bursty-per-ip`
Match expression: `(http.host contains "freedom-yield.com")` (covers
  all subdomains of the zone — metal / stake / my / www)
Counting characteristics: IP address
Requests per period: 50
Period: 10 seconds
Action: Block
Mitigation timeout: **10 seconds (free plan is fixed at 10s — Pro+
  gives 1 min / 1 hr / 1 day options)**

Rationale: 50 req / 10 sec = sustained 5 rps from one IP is a clear
abuse signal (a normal browser hits maybe ~30 assets on a cold load,
then idles). On the free plan the 10-second mitigation seems weak,
but in practice the rule re-arms every 10s and an offender's bursty
script gets caught in an endless trip cycle — effectively capping
them at 5 rps until they stop. Combined with the in-Caddy rate-limit
zones below (per-min quotas, harder to evade), the layered defenses
are stronger than either alone.

### 2. Caddy (Docker container behind nginx)

Custom Caddy build with `mholt/caddy-ratelimit` plugin (see
`caddy/Dockerfile`). Three zones defined in `caddy/Caddyfile`:

| Zone | Match | Quota | Purpose |
|---|---|---|---|
| `global` | every request | 300 / min per IP | catches anything edge CDN lets through |
| `api_json` | `/api/*` | 90 / min per IP | scraping defense for the JSON endpoints |

Requests over quota return `429 Too Many Requests`. The plugin is
in-memory (single Caddy instance, no need for distributed coordination)
and trusts `X-Forwarded-For` because `trusted_proxies static
private_ranges` is set globally.

The peers page also has `X-Robots-Tag: noindex, nofollow` +
`Cache-Control: private, no-store` so it can't be cached anywhere.

### 3. web host host nginx (TLS terminator)

Stock web host nginx in front of the Caddy container. Limited
configurability (managed-leaning host) but currently fine because the
heavy lifting is at the edge + inside Caddy. If a sustained attack
gets through both, contact web host support — they have provider-side
DDoS mitigation that activates per-customer.

### 4. OS / SSH (both hosts)

- **validator host (validator)**: ufw active, allows only 22/80/443; fail2ban
  watching sshd.
- **web host (web)**: fail2ban active with sshd jail; ufw not used
  (web host-side firewalling handles it).
- BasicAuth on `/peers` uses **bcrypt cost 14** — brute-forcing one
  24-char base62 password is ~10⁴¹ ops, well outside any feasible
  budget.

---

## Under attack — runbook

If `metal.freedom-yield.com` slows or returns 5xx:

1. **Check edge CDN Analytics** (dashboard → Analytics → Security)
   - Is traffic spiking? From which countries?
   - Are requests being challenged / blocked already?

2. **Enable "I'm Under Attack" mode** (one click)
   - Dashboard → Security → Settings → Security Level → **I'm Under Attack**
   - Adds a JS challenge to every visitor for ~5 seconds before they
     reach the origin. Aggressive but instant.
   - Disable once the spike subsides; not appropriate for normal traffic
     (it interferes with real users and breaks pure-API consumers).

3. **Tighten the existing rate-limit rule** if abuse continues
   - Lower threshold from 50/10s → 20/10s
   - Extend block duration from 1h → 24h

4. **Add a temporary Custom Rule** (free plan allows 5)
   - If the attack comes from a specific country / ASN, block by
     `ip.geoip.asnum`, `ip.geoip.country`, or `cf.threat_score`
   - These are surgical — leave the rate-limit rule running underneath

5. **Verify Caddy didn't fall over**
   - SSH to web host, `docker compose logs caddy --tail=50`
   - The rate-limit plugin should be returning 429 to abusers; if the
     log is full of 5xx, restart Caddy (`docker compose restart caddy`)

6. **Validator is unaffected** — the validator runs on validator host, not
   web host. Site outage has zero impact on consensus participation.

---

## What's intentionally **not** done

- **No WAF managed rule sets** (edge CDN paid plan only). Our
  attack surface is tiny — pure static + 6 JSON files + BasicAuth.
  The free protections cover the realistic threat model.
- **No distributed rate limit** (e.g. Redis-backed). Single Caddy
  instance, in-memory is fine.
- **No Argo / Spectrum / edge CDN Pro features**. Cost/benefit not
  there until a real attack happens.

---

## Verification checklist (run after any rate-limit change)

```bash
# 1. Caddy actually has the plugin
docker compose exec caddy caddy list-modules | grep rate_limit

# 2. Caddyfile validates with the new directives
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile

# 3. Hit the same endpoint 100x quickly — should start returning 429
for i in {1..100}; do curl -s -o /dev/null -w "%{http_code}\n" \
  https://metal.freedom-yield.com/api/validator.json; done | sort | uniq -c
# Expected: ~90 of 200, then a stream of 429

# 4. Real visitor (browser) on cold load should never trigger 429.
```
