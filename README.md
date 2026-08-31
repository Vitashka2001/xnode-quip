# XNODE Quip CPU Node Installer

Russian-first installer and maintenance menu for a Quip Network testnet CPU node.

The script installs the official Quip Docker Compose stack, prepares a CPU miner configuration, starts the dashboard without a domain, and provides a menu for logs, diagnostics, wallet backup, updates, disk protection, and optional miner auto-recovery.

## Quick Install

Download the script on a fresh Ubuntu/Debian VM:

```bash
curl -fsSL https://raw.githubusercontent.com/Vitashka2001/xnode-quip/main/xnode-quip.sh -o xnode-quip.sh
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

Safe Docker cleanup and disk report:

```bash
./xnode-quip.sh cleanup
./xnode-quip.sh cleanup-status
./xnode-quip.sh cleanup-install
```

Storage guard and validator database maintenance:

```bash
./xnode-quip.sh storage-guard
./xnode-quip.sh validator-reset
./xnode-quip.sh validator-prune-override
```

Manage miner auto-recovery:

```bash
./xnode-quip.sh auto-recover-status
./xnode-quip.sh auto-recover-install
./xnode-quip.sh auto-recover-disable
```

## Upgrading an Existing Node to Quip v0.3

Quip moved the miner to a new image repository line
(`quip-miner/v0.3/quip-miner`) and made `:latest` the default for every quip
image. A node installed before this change carries a `QUIP_MINER_TAG=v0.2` pin
in its `.env`, and that tag was never published on the new path, so
`docker compose pull` fails for the whole stack:

```text
failed to resolve reference ".../quip-miner/v0.3/quip-miner:v0.2": not found
```

Run the update and the installer repairs this on its own:

```bash
./xnode-quip.sh update
```

It comments the stale image pins out of `.env`, rewrites `data/config.toml` in
the v0.3 coordinator schema, and drops the environment variables the miner
images stopped reading. Backups of `.env`, `config.toml`, `keystore.json` and
`docker-compose.override.yml` are written before anything is changed, and the
miner wallet is never touched. Re-running `update` afterwards is a no-op.

Two things worth knowing about v0.3:

- `[miner].public_host` and `public_port` are mandatory. The installer fills
  them with the detected public IP and port `20049`. If the server's public IP
  changes later, update `public_host` in `data/config.toml` and restart.
- The faucet is controlled by `[miner].faucet_url` in `data/config.toml`. The
  old `QUIP_FAUCET_URL` environment variable is ignored by current images. Set
  `faucet_url = ""` to disable auto-funding.

## Stall Watchdog

A Quip node can stop making progress without stopping. The miner container
stays up, the REST API keeps answering `is_mining: true`, the CPU stays pinned
at 100%, and nothing is submitted for days. On the node this was developed
against, that state lasted 6, 6 and 17 days across three separate episodes,
each ended only by a manual restart.

The watchdog therefore ignores liveness and watches forward progress: the
miner's view of the chain head, the chain heads it has observed, and the
results it has taken back from its workers. A healthy node advances roughly ten
chain heads per minute. When all three counters are flat for 15 minutes *and*
the public bootnodes show the chain still advancing, the miner is restarted.

Enable it:

```bash
./xnode-quip.sh auto-recover-install
```

Inspect it at any time:

```bash
./xnode-quip.sh health
```

It runs every five minutes as a systemd timer, and recovery escalates —
restart the container, recreate it, then recreate the whole stack — with a
cooldown that widens (15, 30, 45, 60 minutes) so a cause outside the miner
cannot become a restart loop. Restarts are logged with the twenty miner log
lines that preceded them:

```bash
journalctl -u xnode-quip-auto-recover.service --since -7d
```

Tuning, if the defaults do not suit a host:

| variable | default | meaning |
|---|---|---|
| `XNODE_STALL_SECONDS` | `900` | flat counters for this long counts as a stall |
| `XNODE_STALL_COOLDOWN_SECONDS` | `900` | base gap between recovery attempts |

Turn it off with `./xnode-quip.sh auto-recover-disable`.

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

Note: the installer runs the bundled Quip validator with pruning by default to prevent unbounded archive database growth. If an old archive database already exists, use `./xnode-quip.sh validator-reset` to delete only `data/validator-data` and recreate it with pruning. This does not delete the miner wallet `data/keystore.json`.

The daily cleanup timer installed by `./xnode-quip.sh cleanup-install` safely prunes Docker leftovers and runs a storage guard. If the validator database crosses the configured threshold, the guard can recreate only the validator database with pruning while preserving the miner wallet.

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
