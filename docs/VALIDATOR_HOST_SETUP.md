# Validator Host Setup

Initial VPS provisioning and hardening for the Metal Blockchain validator host. After this, continue with [docs/DEPLOY_SETUP.md](DEPLOY_SETUP.md) to wire up CI/CD for the web side.

## Host requirements

Per the published Metallicus minimum recommendation:

- **8 vCPU / 16 GiB RAM** minimum
- **NVMe-class storage** ≥ 500 GB (chain state grows; pruning helps but plan for headroom)
- **Stable public IPv4** (or dual-stack) reachable on port **9651/TCP** for the `metalgo` P2P staking layer
- **Ubuntu 22.04 LTS** or equivalent — the runbooks assume Debian-family

Anything above the published minimum is operator preference; Snowman consensus does not reward over-provisioning.

> **Constitution §4.2 C1**: cloud provider name, data center region, and provider plan tier are default-confidential. Choose any provider that meets the requirements above. Provider-specific console steps in this runbook are illustrative — the equivalent exists in every reputable IaaS console.

## Overall flow

```
1. Open an account with a VPS provider that meets the requirements above
2. Generate an SSH key pair locally
3. Provision the instance (Ubuntu 22.04 + NVMe storage)
4. Configure a network firewall for the required ports only
5. First SSH login + system update
6. Create the deploy user (handed off to docs/DEPLOY_SETUP.md)
```

## 1. SSH keys

Generate two ed25519 keys on your workstation — one for administrative root access, one for the deploy user (created later):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/<your_validator_host_key> -C "metal validator admin"
ssh-keygen -t ed25519 -f ~/.ssh/<your_deploy_key>          -C "metal validator deploy"
```

Register the **administrative public key** in your VPS provider's SSH-key store before provisioning, so the instance is reachable on first boot.

> **Constitution §4.1 S7**: SSH key paths and fingerprints are SECRET. The names above are placeholders; pick your own and keep them in your operator-local secret manager, not in the repo.

## 2. Provision the instance

| Setting | Value |
|---|---|
| Image | Ubuntu 22.04 LTS |
| vCPU | ≥ 8 |
| RAM | ≥ 16 GiB |
| Storage | NVMe-class, ≥ 500 GB |
| Networking | IPv4 + IPv6 |
| SSH keys | the administrative key registered in step 1 |
| Backups | enable if available; cheap insurance for accidental data loss |
| Hostname | operator's choice |

If your provider separates compute and storage, attach the storage volume in the **same region** as the compute instance to keep latency in single-digit milliseconds.

> **Host identifier discipline**: the host is dual-stack (IPv4 + IPv6), so treat both addresses as SECRET (Constitution §4.1 S7) — neither belongs in a commit, doc, or public config. `scripts/publish-guard.sh` blocks a real public IPv4 **and** a real public IPv6 literal automatically (doc/link-local/loopback/unique-local/multicast ranges on either protocol are allowed); it does not need per-project configuration for this.

## 3. Network firewall (provider-managed)

Whichever provider you use, configure the cloud-side firewall **before** the OS-level firewall. Cloud firewalls drop traffic upstream of the VPS, which both protects the host and saves bandwidth.

| Direction | Source | Port | Protocol | Purpose |
|---|---|---|---|---|
| In | Any | 22 | TCP | SSH (key-only, see step 5) |
| In | Any | 80 | TCP | HTTP-01 ACME challenge for TLS |
| In | Any | 443 | TCP | HTTPS |
| In | Any | 443 | UDP | HTTP/3 |
| In | Any | **9651** | **TCP** | **`metalgo` P2P staking — required for validation** |

## 4. First SSH login + system baseline

```sh
ssh -i ~/.ssh/<your_validator_host_key> root@<vps-ip>
```

Then on the host:

```sh
# System update
apt update && apt upgrade -y

# Required packages
apt install -y curl ufw fail2ban jq rsync git

# Docker + Compose v2
curl -fsSL https://get.docker.com | sh
docker --version
docker compose version

# Confirm any attached storage volume is mounted
df -h

# fail2ban is up
systemctl status fail2ban

# Unattended security updates
apt install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
```

### OS-level firewall (defense in depth)

```sh
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 9651/tcp
ufw enable
ufw status verbose
```

## 5. SSH hardening (after the deploy user exists)

Once you've created the deploy user in [docs/DEPLOY_SETUP.md](DEPLOY_SETUP.md), tighten `/etc/ssh/sshd_config`:

```
PasswordAuthentication no
PermitRootLogin no
```

Then `systemctl reload sshd`.

## 6. Hand off to DEPLOY_SETUP.md

Continue with [docs/DEPLOY_SETUP.md](DEPLOY_SETUP.md) for:

- deploy user creation
- public key registration
- docker group membership
- deploy path
- `.env` placement
- GitHub Secrets registration
- the `DEPLOY_ENABLED` gate
- first CI-driven deploy

## Running `metalgo`

Once the deploy user is set up and the repository is rsync'd to the host, start the validator process:

```sh
su - deploy
cd <deploy_path>

cat >> .env <<EOF
METAL_NETWORK=mainnet
METAL_PUBLIC_IP=<your-vps-ipv4>
EOF

# Storage path for chain data (point at your NVMe mount)
sudo mkdir -p /var/lib/metalgo
sudo chown deploy:deploy /var/lib/metalgo

# Bring up metalgo
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml up -d

# Watch bootstrap
docker compose -f docker-compose.metalgo.yml -f docker-compose.metalgo.prod.yml logs -f
```

Wait for bootstrap to complete on all chains (P, X, C) before treating the node as ready.

## Troubleshooting

| Symptom | Likely fix |
|---|---|
| `Permission denied` on first SSH | Confirm the public key is registered in the provider's SSH-key store, and `ssh-add` is loaded on the workstation |
| Storage volume attached but not mounted | `lsblk` to see the device; mount manually if your provider doesn't automount |
| `apt update` slow | Provider may not use a nearby mirror by default; switch `/etc/apt/sources.list` to a closer mirror |
| 9651 not reachable | Check cloud firewall **and** host ufw **and** the `--public-ip` flag passed to `metalgo` — all three must agree |
| `metalgo` won't sync | Same three things; also check that the public IP printed in `metalgo` logs matches the VPS public IP |

## Related

- [docs/DEPLOY_SETUP.md](DEPLOY_SETUP.md) — CI/CD for the web side after the validator host is up
- [docs/MAINNET_MIGRATION.md](MAINNET_MIGRATION.md) — staged migration from testnet to mainnet
- [docs/KEY_ROTATION.md](KEY_ROTATION.md) — staking key handling
