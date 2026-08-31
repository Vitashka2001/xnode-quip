# Changelog

## 1.02

Stall watchdog. The node was observed running for days with a live container,
`is_mining: true` and 100% CPU while submitting nothing, recovering only on a
manual restart.

Evidence from this node's own miner logs: the substrate connection degrades and
the client loops `substrate call cancelled` -> `rebuilding substrate connection`
forever, roughly 940 of each per day (one per 90-second timeout). Windows with
zero successful submissions: 24-29 July (6 days), 1-6 August (6 days) and
15-31 August (17 days). Container state, process liveness and `is_mining` all
stayed green throughout, which is why the previous auto-recovery — it checked
only chain topology and `is_mining` — never fired.

- Added a watchdog that judges the miner on forward progress instead of
  liveness. It samples the miner's chain head, `heads_observed` and
  `results_received` from the REST API. A healthy node advances about ten
  chain heads per minute; the watchdog acts only when all three are flat for
  `XNODE_STALL_SECONDS` (default 900).
- The watchdog cross-checks the real chain head from the public bootnodes
  before acting. A halted testnet or a dead uplink freezes the same counters,
  and restarting the miner for that would only cost rounds.
- Counter resets are recognised as restarts, not stalls. Every counter is a
  process-lifetime value that returns to zero when the container restarts, so
  `uptime_seconds` is sampled alongside them and a drop rebaselines instead of
  triggering recovery.
- Recovery escalates: restart the miner container, then recreate it, then
  recreate the whole stack in case the colocated validator is the wedged
  party. The cooldown widens with each consecutive attempt (15, 30, 45, 60
  minutes) so a cause outside the miner cannot turn into a restart loop, and
  the script says so once five attempts have not helped.
- The last twenty miner log lines are printed before each recovery, so the
  reason for a restart survives in the journal.
- Added `./xnode-quip.sh health`, menu item 4 under auto-recovery, and a
  watchdog block in the full diagnostics.
- `auto-recover` no longer runs `docker compose pull` on every five-minute
  tick. It starts the container when it is down, and otherwise checks progress.

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
