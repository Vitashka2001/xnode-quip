# Changelog

## 1.01

Compatibility with the Quip v0.3 miner. An existing node fails
`docker compose pull` with `not found` until this release, because upstream
moved the miner to a new repository line and the installer pinned a tag that
was never published there.

- Stopped pinning `QUIP_MINER_TAG` / `QUIP_DASHBOARD_TAG` / `QUIP_VALIDATOR_TAG`
  / `QUIP_FAUCET_TAG` in `.env`. Upstream moved the miner to
  `quip-miner/v0.3/quip-miner` and made `:latest` the compose default for every
  quip image; a leftover `v0.2` pin resolves to a tag that does not exist on the
  new path and fails the pull for the whole stack.
- Added a migration that comments stale `QUIP_*_TAG` pins out of an existing
  `.env` during `update` and `restart`, with a backup.
- `data/config.toml` is now written in the v0.3 coordinator schema:
  `[miner].public_host` / `public_port` (both mandatory — v0.3 exits with
  `missing [miner].public_host` without them), an explicit `[cpu]` backend
  section, and a `[dashboard]` section on port 8086 replacing the dead
  `rest_host` / `rest_port` pair. Port 8086 must match the
  `reverse_proxy quip-miner:8086` line in the Quip repo's Caddyfile.
- Added a migration that rewrites an existing v0.2 `config.toml` in place,
  preserving validators, node name, CPU count and faucet setting.
- Moved the faucet switch from the `QUIP_FAUCET_URL` environment variable to
  `[miner].faucet_url` in `config.toml`. The environment variable has been
  inert since the v0.2.1-rc images; a node that thought its faucet was disabled
  was relying on a setting nothing read.
- Dropped the dead `QUIP_VALIDATORS` / `QUIP_FAUCET_URL` entries from the
  generated `docker-compose.override.yml`, and migrate an existing override off
  them. Validators live in `config.toml` now.
- Rewrote the chain queries. They used to run `python3 -c` inside the miner
  image against its bundled `substrate.client`; the v0.3 image dropped those
  Python modules. They now call `state_getStorage` over JSON-RPC with
  precomputed `twox128` storage keys, using nothing but `curl` and the Python
  standard library, and work against both the public bootnodes and the local
  validator through Caddy.
- `chain_default_topology_present` now distinguishes "no topology on chain"
  from "no validator answered", so auto-recovery no longer stops a healthy
  miner because an RPC endpoint was briefly unreachable.
- Replaced the `QuantumPow.Difficulty` query with `RegisteredTopologies`. The
  former is not a storage item in the current runtime and always read as empty.
- Wallet lookups fall back to the miner REST API. `quip-coordinator keygen`
  (v0.3) writes a keystore holding `master_seed_hex` only, without the `ss58`
  and `account_id_hex` fields the v0.2 entrypoint recorded.
- Fixed the quick status view. It read
  `modes.cpu.controller.active_url`, which v0.3 no longer reports; the missing
  key made `jq` fail and blanked the entire status block. Every field is
  coalesced now, proof counters were added, and the RPC line falls back to the
  configured validator list.
- Widened the log matchers to the v0.3 coordinator's wording for the funding
  and topology blockers. v0.3 idles on a missing topology instead of exiting.

## 1.00

- Added XNODE Quip CPU node installer.
- Added Russian maintenance menu.
- Added dependency and resource checks.
- Added dashboard URL and health view.
- Added wallet/keystore display and backup helpers.
- Added full diagnostics.
- Added update center for Git repositories and Docker images.
- Added optional miner auto-recovery timer with status, enable, disable, and manual check commands.
