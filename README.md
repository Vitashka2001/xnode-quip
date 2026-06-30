# XNODE Quip CPU Node Installer

Russian-first installer and maintenance menu for a Quip Network testnet CPU node.

The script installs the official Quip Docker Compose stack, prepares a CPU miner configuration, starts the dashboard without a domain, and provides a menu for logs, diagnostics, wallet backup, updates, and optional miner auto-recovery.

## Quick Install

Download the script on a fresh Ubuntu/Debian VM:

```bash
curl -fsSL https://raw.githubusercontent.com/XNODE-Team/xnode-quip/main/xnode-quip.sh -o xnode-quip.sh
chmod +x xnode-quip.sh
./xnode-quip.sh
```

Then choose:

```text
1) Установка / восстановление Quip CPU node
```

The installer creates a `quip_node` directory next to `xnode-quip.sh` and installs the Quip repositories and Docker stack there.

## Useful Commands

Open the menu:

```bash
./xnode-quip.sh
```

Run diagnostics:

```bash
./xnode-quip.sh status
```

Check updates:

```bash
./xnode-quip.sh check-updates
```

Apply updates:

```bash
./xnode-quip.sh update
```

Show wallet info:

```bash
./xnode-quip.sh wallet
```

Backup `keystore.json`:

```bash
./xnode-quip.sh backup
```

Manage miner auto-recovery:

```bash
./xnode-quip.sh auto-recover-status
./xnode-quip.sh auto-recover-install
./xnode-quip.sh auto-recover-disable
```

## Requirements

Minimum:

- Ubuntu/Debian with `apt` and `systemd`
- 2 CPU cores
- 4 GB RAM
- 30 GB free disk
- Open ports: `20049/tcp`, `30333/tcp`, `30333/udp`

Recommended:

- 4+ CPU cores
- 8+ GB RAM
- 80+ GB free disk

GPU is not required. The installer uses the Quip CPU profile.

## Security Notes

Save the full generated `data/keystore.json` from your installed node. The `master_seed_hex` inside that file is the private key.

This repository must not contain:

- `keystore.json`
- `.env`
- `quip_node/`
- Docker volumes or runtime data
- private keys, seeds, tokens, or server-specific backups

## Official Quip Sources

- Website: <https://quip.network/>
- Node repository: <https://gitlab.com/quip.network/nodes.quip.network>
- Faucet repository: <https://gitlab.com/quip.network/faucet>

