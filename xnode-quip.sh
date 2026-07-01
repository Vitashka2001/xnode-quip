#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://gitlab.com/quip.network/nodes.quip.network.git"
FAUCET_REPO_URL="https://gitlab.com/quip.network/faucet.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${XNODE_BASE_DIR:-$SCRIPT_DIR/quip_node}"
REPO_DIR="${XNODE_QUIP_DIR:-$BASE_DIR/nodes.quip.network}"
FAUCET_DIR="${XNODE_FAUCET_DIR:-$BASE_DIR/faucet}"
PUBLIC_VALIDATORS="wss://bootnode-2.testnet.quip.network:20049/rpc,wss://bootnode-3.testnet.quip.network:20049/rpc"
LOCAL_VALIDATOR="ws://quip-validator:9944"
ACTIVE_VALIDATORS="$PUBLIC_VALIDATORS"
FAUCET_URL="https://faucet.testnet.quip.network"
PUBLIC_IP_URL="https://api.ipify.org"
CHECK_PORT_URL="https://check.quip.network/checkport?port="
SUMMARY_FILE="${XNODE_SUMMARY_FILE:-$BASE_DIR/xnode-quip-summary.txt}"
BACKUP_DIR="${XNODE_BACKUP_DIR:-$BASE_DIR/backups}"
LOG_MAX_SIZE="${XNODE_LOG_MAX_SIZE:-50m}"
LOG_MAX_FILE="${XNODE_LOG_MAX_FILE:-3}"

MIN_CPU=2
MIN_RAM_MB=3900
MIN_DISK_GB=30
REC_CPU=4
REC_RAM_MB=7900
REC_DISK_GB=80

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

blue=$'\033[1;34m'
cyan=$'\033[1;36m'
magenta=$'\033[1;35m'
green=$'\033[1;32m'
yellow=$'\033[1;33m'
red=$'\033[1;31m'
bold=$'\033[1m'
dim=$'\033[2m'
reset=$'\033[0m'

logo() {
  clear || true
  echo -e "${magenta}"
  cat <<'LOGO'
            /$$   /$$                 /$$
           | $$$ | $$                | $$
  /$$   /$$| $$$$| $$  /$$$$$$   /$$$$$$$  /$$$$$$
 |  $$ /$$/| $$ $$ $$ /$$__  $$ /$$__  $$ /$$__  $$
  \  $$$$/ | $$  $$$$| $$  \ $$| $$  | $$| $$$$$$$$
   >$$  $$ | $$\  $$$| $$  | $$| $$  | $$| $$_____/
  /$$/\  $$| $$ \  $$|  $$$$$$/|  $$$$$$$|  $$$$$$$
 |__/  \__/|__/  \__/ \______/  \_______/ \_______/
-----------------------
version 1.00
-----------------------

        XNODE :: QUIP NODE MANAGER
LOGO
  echo -e "${reset}"
  echo
}

say() { echo -e "${green}[XNODE]${reset} $*"; }
warn() { echo -e "${yellow}[WARN]${reset} $*"; }
fail() { echo -e "${red}[ERROR]${reset} $*" >&2; }
pause() { echo; read -r -p "Нажми Enter чтобы продолжить..." _ || true; }
line() { printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '-'; }
section() { echo; echo -e "${cyan}${bold}$*${reset}"; line; }
kv() { printf "  ${bold}%-22s${reset} %s\n" "$1" "$2"; }
ok() { echo -e "  ${green}OK${reset} $*"; }
bad() { echo -e "  ${red}NO${reset} $*"; }
soft() { echo -e "${dim}$*${reset}"; }

run() {
  echo -e "${blue}>${reset} $*"
  "$@"
}

docker_cli() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker "$@"
  else
    $SUDO docker "$@"
  fi
}

compose() {
  (cd "$REPO_DIR" && docker_cli compose --profile cpu "$@")
}

compose_quiet() {
  (cd "$REPO_DIR" && docker_cli compose --profile cpu "$@" >/dev/null 2>&1)
}

need_repo() {
  if [[ ! -d "$REPO_DIR" ]]; then
    fail "Репозиторий не найден: $REPO_DIR"
    echo "Сначала запусти пункт 1: установка."
    return 1
  fi
}

install_packages() {
  say "Проверяю системные зависимости..."
  if ! command -v apt-get >/dev/null 2>&1; then
    fail "apt-get не найден. Скрипт рассчитан на Ubuntu/Debian."
    exit 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl git jq python3 iproute2
  if ! command -v docker >/dev/null 2>&1; then
    $SUDO apt-get install -y docker.io
  fi
  $SUDO apt-get install -y docker-compose-v2
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  if ! docker_cli info >/dev/null 2>&1; then
    fail "Docker daemon не отвечает. Проверь systemctl status docker."
    exit 1
  fi
  if ! docker_cli compose version >/dev/null 2>&1; then
    fail "Docker Compose v2 не работает после установки."
    exit 1
  fi
}

clone_or_update_repo() {
  local url="$1"
  local dir="$2"
  local label="$3"
  local pull_mode="${4:-ask}"

  if [[ -d "$dir/.git" ]]; then
    say "$label уже есть: $dir"
    if [[ "$pull_mode" == "yes" ]]; then
      run git -C "$dir" pull --ff-only
    fi
  elif [[ -d "$dir" ]]; then
    fail "$dir уже существует, но это не git repo. Укажи другой путь или убери папку."
    exit 1
  else
    run git clone "$url" "$dir"
  fi
}

git_repo_status() {
  local dir="$1"
  local label="$2"
  local remote branch upstream local_sha remote_sha ahead behind dirty

  if [[ ! -d "$dir/.git" ]]; then
    warn "$label repo не найден: $dir"
    return 2
  fi

  remote="$(git -C "$dir" remote 2>/dev/null | head -n1 || true)"
  branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"
  local_sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || true)"

  if [[ -z "$remote" || -z "$branch" ]]; then
    kv "$label" "local=$local_sha, branch=${branch:-detached}, remote=${remote:-none}"
    warn "$label: не могу проверить upstream автоматически."
    return 2
  fi

  if ! git -C "$dir" fetch --quiet "$remote"; then
    kv "$label" "branch=$branch, local=$local_sha"
    warn "$label: не удалось проверить удалённый repo. Возможно, временная проблема сети/GitLab."
    return 2
  fi

  upstream="$remote/$branch"
  if ! git -C "$dir" rev-parse --verify "$upstream" >/dev/null 2>&1; then
    kv "$label" "branch=$branch, local=$local_sha"
    warn "$label: upstream $upstream не найден."
    return 2
  fi

  remote_sha="$(git -C "$dir" rev-parse --short "$upstream" 2>/dev/null || echo unknown)"
  read -r ahead behind < <(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null || echo "0 0")

  kv "$label repo" "$branch local=$local_sha remote=$remote_sha"
  if [[ -n "$dirty" ]]; then
    warn "$label: есть локальные изменения в tracked files. Update через git pull может быть остановлен."
  fi

  if (( behind > 0 )); then
    warn "$label: доступно обновление, локальный repo отстаёт на $behind commit(s)."
    git -C "$dir" log --oneline --decorate --max-count=5 "HEAD..$upstream" 2>/dev/null | sed 's/^/    /' || true
    return 10
  fi

  if (( ahead > 0 )); then
    warn "$label: локальный repo впереди upstream на $ahead commit(s). Авто-update может потребовать ручной проверки."
    return 0
  fi

  ok "$label: Git repo актуален."
}

git_repo_pull_ff() {
  local dir="$1"
  local label="$2"
  local dirty

  if [[ ! -d "$dir/.git" ]]; then
    warn "$label repo не найден, пропускаю: $dir"
    return 0
  fi

  dirty="$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    fail "$label содержит локальные изменения в tracked files. Останавливаю update, чтобы ничего не затереть."
    git -C "$dir" status --short --untracked-files=no || true
    return 1
  fi

  say "Обновляю $label через git pull --ff-only..."
  run git -C "$dir" pull --ff-only
}

show_compose_images() {
  if [[ ! -d "$REPO_DIR" ]]; then
    warn "Repo не найден, images показать не могу."
    return 0
  fi

  say "Docker images из текущего compose:"
  compose config --images 2>/dev/null | sort -u | sed 's/^/  - /' || warn "Не удалось прочитать compose images."
  echo
  soft "Важно: у Quip в docker-compose.yml стоит pull_policy: always, поэтому безопасный update делается через compose pull + compose up -d."
}

show_update_status() {
  section "Проверка обновлений"
  git_repo_status "$REPO_DIR" "nodes.quip.network" || true
  git_repo_status "$FAUCET_DIR" "faucet" || true
  echo
  show_compose_images
  echo
  kv "Auto-recover" "$(auto_recover_status_line)"
  print_auto_recover_hint
  echo
  soft "Git update проверяется точно по upstream branch. Docker registry check без pull ненадёжен, поэтому update тянет images и Docker сам пересоздаёт только то, что изменилось."
}

check_updates() {
  need_repo || return
  logo
  show_update_status
  pause
}

install_repositories() {
  local pull_mode="no"
  mkdir -p "$BASE_DIR"
  if [[ -d "$REPO_DIR/.git" || -d "$FAUCET_DIR/.git" ]]; then
    read -r -p "Обновить существующие репозитории через git pull? [y/N]: " do_pull
    if [[ "$do_pull" =~ ^[Yy]$ ]]; then
      pull_mode="yes"
    fi
  fi
  clone_or_update_repo "$REPO_URL" "$REPO_DIR" "nodes.quip.network" "$pull_mode"
  clone_or_update_repo "$FAUCET_REPO_URL" "$FAUCET_DIR" "faucet" "$pull_mode"
}

system_cpu_count() { nproc 2>/dev/null || echo 0; }
system_ram_mb() { awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0; }
system_disk_gb() { df -BG "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4+0}' || echo 0; }

show_requirements() {
  section "Минимальные требования"
  kv "Минимум" "${MIN_CPU} CPU / 4 GB RAM / ${MIN_DISK_GB} GB disk"
  kv "Рекомендовано" "${REC_CPU}+ CPU / 8 GB+ RAM / ${REC_DISK_GB} GB+ disk"
  kv "ОС" "Ubuntu 22.04/24.04 или Debian с apt + systemd"
  kv "GPU" "не нужен, используется CPU profile"
  kv "Порты" "20049/tcp, 30333/tcp, 30333/udp"
  soft "Примечание: официальный старый DO-гайд упоминает 1 vCPU/2GB, но текущий v0.2 stack с dashboard+validator+CPU miner заметно тяжелее. Скрипт ориентирован на стабильную работу."
}

check_requirements() {
  local cpu ram disk ok_all
  cpu="$(system_cpu_count)"
  ram="$(system_ram_mb)"
  disk="$(system_disk_gb)"
  ok_all="yes"

  show_requirements
  echo
  section "Проверка ресурсов этой ВМ"
  if (( cpu >= MIN_CPU )); then ok "CPU: $cpu cores"; else bad "CPU: $cpu cores, минимум $MIN_CPU"; ok_all="no"; fi
  if (( ram >= MIN_RAM_MB )); then ok "RAM: $((ram / 1024)) GB (${ram} MB)"; else bad "RAM: ${ram} MB, минимум около 4 GB"; ok_all="no"; fi
  if (( disk >= MIN_DISK_GB )); then ok "Disk: ${disk} GB free"; else bad "Disk: ${disk} GB free, минимум ${MIN_DISK_GB} GB"; ok_all="no"; fi

  if [[ "$ok_all" != "yes" ]]; then
    warn "Ресурсов меньше рекомендуемого минимума. Установка может запуститься, но нода может падать, тормозить или не успевать синхронизироваться."
    read -r -p "Продолжить всё равно? [y/N]: " force_continue
    [[ "$force_continue" =~ ^[Yy]$ ]] || exit 1
  fi
}

check_network_access() {
  section "Проверка сети"
  if curl -fsS --max-time 10 https://gitlab.com >/dev/null; then
    ok "GitLab доступен"
  else
    bad "GitLab недоступен, git clone/images могут не скачаться"
  fi

  if curl -fsS --max-time 10 https://registry.gitlab.com/v2/ >/dev/null 2>&1; then
    ok "GitLab Container Registry доступен"
  else
    warn "Registry check не дал OK. Docker pull всё ещё может работать, но если pull упадёт — проверь сеть/firewall."
  fi

  if curl -fsS --max-time 10 "$FAUCET_URL/health" >/dev/null 2>&1; then
    ok "Quip faucet health отвечает"
  else
    warn "Faucet health не дал OK. Если miner не сможет получить стартовые QUIP, это будет внешняя проблема faucet."
  fi
}

check_port_conflicts() {
  section "Проверка портов"
  local occupied="no"
  for port in 20049 30333; do
    if ss -ltn 2>/dev/null | grep -q ":$port "; then
      if docker_cli ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^(quip-caddy|quip-validator)$'; then
        warn "Port $port уже слушает существующий Quip контейнер — repair/restart допустим."
      else
        bad "Port $port уже занят другим процессом. Освободи порт перед установкой."
        occupied="yes"
      fi
    else
      ok "Port $port свободен"
    fi
  done
  if [[ "$occupied" == "yes" ]]; then
    read -r -p "Продолжить несмотря на занятые порты? [y/N]: " force_ports
    [[ "$force_ports" =~ ^[Yy]$ ]] || exit 1
  fi
}

default_cpuset() {
  local total last
  total="$(nproc 2>/dev/null || echo 1)"
  if ! [[ "$total" =~ ^[0-9]+$ ]] || (( total <= 1 )); then
    echo "0"
    return
  fi
  last=$((total - 1))
  echo "0-$last"
}

sanitize_name() {
  local raw="$1"
  raw="${raw:-xnode-quip}"
  raw="$(tr -cs 'A-Za-z0-9_.-' '-' <<< "$raw" | sed 's/^-*//; s/-*$//')"
  echo "${raw:-xnode-quip}"
}

write_env_file() {
  local node_name="$1"
  local cpuset="$2"
  local env_file="$REPO_DIR/.env"
  local backup

  if [[ -f "$env_file" ]]; then
    backup="$env_file.xnode-backup-$(date -u +%Y%m%d-%H%M%S)"
    cp "$env_file" "$backup"
    warn "Существующий .env сохранён в $backup"
  fi

  cat > "$env_file" <<EOF
# Written by XNODE Quip installer.
QUIP_HOSTNAME=:20049
PUID=0
PGID=0
QUIP_MINER_TAG=v0.2
QUIP_DASHBOARD_TAG=v0.2
QUIP_VALIDATOR_TAG=v0.2
QUIP_FAUCET_TAG=latest
QUIP_MINER_CPUSET=$cpuset
VALIDATOR_NAME=$node_name-validator
SUBSTRATE_BOOTNODES=
POSTGRES_DB=quip
POSTGRES_USER=quip
POSTGRES_PASSWORD=quip
EOF
}

write_config_file() {
  local node_name="$1"
  local cpu_count="$2"
  local config_file="$REPO_DIR/data/config.toml"
  local backup

  mkdir -p "$REPO_DIR/data"
  if [[ -f "$config_file" ]]; then
    backup="$config_file.xnode-backup-$(date -u +%Y%m%d-%H%M%S)"
    cp "$config_file" "$backup"
    warn "Существующий config.toml сохранён в $backup"
  fi

  cat > "$config_file" <<EOF
# Quip miner v0.2 CPU configuration, written by XNODE.

[miner]
validators = [
    "ws://quip-validator:9944",
]
signer_key = "/data/keystore.json"
node_name = "$node_name"
rest_host = "0.0.0.0"
rest_port = 80
log_level = "INFO"
node_log = "/data/logs/quip-node.log"

[cpu]
num_cpus = $cpu_count
EOF
}

write_override_file() {
  local faucet_mode="$1"
  local validators="${2:-$PUBLIC_VALIDATORS}"
  local override_file="$REPO_DIR/docker-compose.override.yml"

  cat > "$override_file" <<EOF
x-xnode-logging: &xnode-logging
  driver: json-file
  options:
    max-size: "$LOG_MAX_SIZE"
    max-file: "$LOG_MAX_FILE"

services:
  cpu:
    logging: *xnode-logging
    environment:
      QUIP_VALIDATORS: "$validators"
EOF

  if [[ "$faucet_mode" == "disabled" ]]; then
    cat >> "$override_file" <<'EOF'
      QUIP_FAUCET_URL: ""
EOF
  fi

  cat >> "$override_file" <<'EOF'
  quip-validator:
    logging: *xnode-logging
  dashboard:
    logging: *xnode-logging
  postgres:
    logging: *xnode-logging
  caddy:
    logging: *xnode-logging
EOF
}

disable_faucet_in_override() {
  write_override_file "disabled" "$ACTIVE_VALIDATORS"
}

backup_override_file() {
  local override_file="$REPO_DIR/docker-compose.override.yml"
  local backup_file

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/docker-compose.override.$(date -u +%Y%m%d-%H%M%S).yml"

  if [[ -f "$override_file" ]]; then
    cp "$override_file" "$backup_file"
  else
    : > "$backup_file"
  fi
  echo "$backup_file"
}

restore_override_file() {
  local backup_file="$1"
  local override_file="$REPO_DIR/docker-compose.override.yml"

  if [[ -s "$backup_file" ]]; then
    cp "$backup_file" "$override_file"
  else
    rm -f "$override_file"
  fi
}

backup_keystore_file() {
  local keystore="$REPO_DIR/data/keystore.json"
  local backup_file

  [[ -f "$keystore" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/keystore-$(date -u +%Y%m%d-%H%M%S).json"
  cp "$keystore" "$backup_file"
  chmod 600 "$backup_file"
  say "Keystore backup: $backup_file"
}

apply_sysctl_tuning() {
  if [[ -x "$REPO_DIR/scripts/sysctl-tune.sh" ]]; then
    say "Применяю сетевой tuning из Quip repo..."
    (cd "$REPO_DIR" && $SUDO ./scripts/sysctl-tune.sh) || warn "sysctl tuning не применился, продолжаю."
  fi
}

start_stack() {
  say "Тяну образы и запускаю CPU stack..."
  compose pull
  compose up -d
}

restart_cpu_only() {
  say "Пересоздаю только miner контейнер..."
  compose up -d --force-recreate --no-deps cpu
}

stop_cpu_only() {
  say "Останавливаю только miner контейнер..."
  compose stop cpu >/dev/null 2>&1 || true
}

status_json() {
  curl -fsS --max-time 5 http://localhost:20049/api/v1/status
}

active_rpc_url() {
  if command -v jq >/dev/null 2>&1 && status_json >/tmp/xnode-quip-status.json 2>/dev/null; then
    jq -r '.data.modes.cpu.controller.active_url // empty' /tmp/xnode-quip-status.json
    return 0
  fi

  if command -v jq >/dev/null 2>&1 && [[ -f "$REPO_DIR/data/runtime/telemetry-stats-cpu.json" ]]; then
    jq -r '.controller.active_url // empty' "$REPO_DIR/data/runtime/telemetry-stats-cpu.json" 2>/dev/null
  fi
}

wallet_ss58() {
  local keystore="$REPO_DIR/data/keystore.json"
  [[ -f "$keystore" ]] || return 0
  python3 - "$keystore" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("ss58", ""))
PY
}

miner_logs_tail() {
  local lines="${1:-260}"
  (cd "$REPO_DIR" && docker_cli compose logs --tail="$lines" cpu 2>/dev/null) || docker_cli logs --tail "$lines" quip-cpu 2>/dev/null || true
}

faucet_health_check() {
  curl -fsS --max-time 10 "$FAUCET_URL/health" 2>/dev/null || true
}

faucet_blocker_seen() {
  miner_logs_tail 360 | grep -Eiq 'wallet-faucet-failed|faucet returned 502|transfer failed; see faucet logs|balance is still 0'
}

faucet_retry_seen() {
  miner_logs_tail 360 | grep -Eiq 'requesting [0-9]+ plancks from faucet|retrying up to 300s'
}

topology_blocker_seen() {
  miner_logs_tail 360 | grep -Eiq 'chain has no registered topology|DefaultTopology'
}

miner_state() {
  docker_cli inspect --format '{{.State.Status}}' quip-cpu 2>/dev/null || echo "missing"
}

chain_state_query() {
  local validator="${1:-wss://bootnode-2.testnet.quip.network:20049/rpc}"
  local ss58
  ss58="$(wallet_ss58 2>/dev/null || true)"

  if [[ -z "$ss58" ]]; then
    warn "Wallet SS58 не найден, пропускаю account/miner query."
  fi

  (cd "$REPO_DIR" && docker_cli compose --profile cpu run --rm --no-deps --pull never --entrypoint python3 cpu -c '
import asyncio
import sys

from substrate.client import SubstrateClient

validator = sys.argv[1]
ss58 = sys.argv[2] if len(sys.argv) > 2 else ""

async def main():
    client = SubstrateClient(url=validator)
    await client.connect()
    iface = client._iface

    async def safe_query(module, storage, params=None):
        try:
            if params is None:
                return await client._run(lambda: iface.query(module, storage))
            return await client._run(lambda: iface.query(module, storage, params))
        except Exception as exc:
            print(f"{module}.{storage}: unavailable ({type(exc).__name__}: {exc})")
            return None

    default_topology = await safe_query("QuantumPow", "DefaultTopology")
    difficulty = await safe_query("QuantumPow", "Difficulty")

    print(f"validator: {validator}")
    print("DefaultTopology:", None if default_topology is None else default_topology.value)
    print("Difficulty:", None if difficulty is None else difficulty.value)

    if ss58:
        account = await safe_query("System", "Account", [ss58])
        miner = await safe_query("QuantumPow", "Miners", [ss58])
        print("Account:", None if account is None else account.value)
        print("Miner:", None if miner is None else miner.value)

asyncio.run(main())
' "$validator" "$ss58")
}

chain_default_topology_present() {
  local validator="${1:-wss://bootnode-2.testnet.quip.network:20049/rpc}"
  local out
  out="$(
    cd "$REPO_DIR" && docker_cli compose --profile cpu run --rm --no-deps --pull never --entrypoint python3 cpu -c '
import asyncio
import sys

from substrate.client import SubstrateClient

async def main():
    client = SubstrateClient(url=sys.argv[1])
    await client.connect()
    iface = client._iface
    value = await client._run(lambda: iface.query("QuantumPow", "DefaultTopology"))
    print("yes" if value is not None and value.value is not None else "no")

asyncio.run(main())
' "$validator" 2>/dev/null
  )" || return 2

  [[ "$out" == "yes" ]]
}

auto_recover_service_name="xnode-quip-auto-recover.service"
auto_recover_timer_name="xnode-quip-auto-recover.timer"
cleanup_service_name="xnode-quip-cleanup.service"
cleanup_timer_name="xnode-quip-cleanup.timer"

auto_recover_status_line() {
  local status
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "$auto_recover_timer_name" >/dev/null 2>&1; then
    status="$(systemctl is-enabled "$auto_recover_timer_name" 2>/dev/null || true)"
    echo "${status:-installed}"
  else
    echo "not installed"
  fi
}

miner_rest_is_mining() {
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  status_json 2>/dev/null | jq -e '.data.is_mining == true' >/dev/null 2>&1
}

auto_recover_next_run() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl show "$auto_recover_timer_name" -p NextElapseUSecRealtime --value 2>/dev/null || true
}

print_auto_recover_hint() {
  local status next_run
  status="$(auto_recover_status_line)"
  if [[ "$status" == "enabled" ]]; then
    next_run="$(auto_recover_next_run)"
    echo -e "  ${yellow}Автовосстановление включено.${reset} Скрипт каждые 5 минут проверяет topology/health и сам поднимет miner, если сеть снова потребует перезапуск."
    if [[ -n "$next_run" && "$next_run" != "n/a" ]]; then
      echo "  Следующая проверка: $next_run"
    fi
  fi
}

auto_recover_once() {
  need_repo || return 0

  if ! docker_cli info >/dev/null 2>&1; then
    warn "Docker API недоступен, auto-recover пропущен."
    return 0
  fi

  if chain_default_topology_present; then
    if miner_rest_is_mining; then
      ok "Topology есть, miner уже майнит. Ничего не трогаю."
      return 0
    fi
    say "QuantumPow.DefaultTopology есть, но miner не выглядит здоровым. Обновляю/поднимаю stack..."
    compose pull
    compose up -d
    return 0
  fi

  warn "QuantumPow.DefaultTopology всё ещё отсутствует. Miner оставляю остановленным."
  stop_cpu_only
  return 0
}

install_auto_recover_timer() {
  need_repo || return
  local quiet="${1:-no}"
  local script_path="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  local service_file="/etc/systemd/system/$auto_recover_service_name"
  local timer_file="/etc/systemd/system/$auto_recover_timer_name"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl не найден. Автовосстановление можно запускать вручную: $script_path auto-recover"
    [[ "$quiet" == "yes" ]] || pause
    return 1
  fi

  chmod +x "$script_path" 2>/dev/null || true

  say "Устанавливаю systemd timer для авто-восстановления miner..."
  $SUDO tee "$service_file" >/dev/null <<EOF
[Unit]
Description=XNODE Quip auto-recover miner when testnet topology is available
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$script_path auto-recover
EOF

  $SUDO tee "$timer_file" >/dev/null <<EOF
[Unit]
Description=Run XNODE Quip auto-recover every 5 minutes

[Timer]
OnActiveSec=2min
OnUnitInactiveSec=5min
AccuracySec=30s
Persistent=true
Unit=$auto_recover_service_name

[Install]
WantedBy=timers.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$auto_recover_timer_name" >/dev/null
  $SUDO systemctl restart "$auto_recover_timer_name"
  ok "Автовосстановление включено: $auto_recover_timer_name"
  soft "Проверка будет идти каждые 5 минут. Когда DefaultTopology появится, miner поднимется сам."
  [[ "$quiet" == "yes" ]] || pause
}

disable_auto_recover_timer() {
  local quiet="${1:-no}"
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl disable --now "$auto_recover_timer_name" >/dev/null 2>&1 || true
    ok "Автовосстановление выключено: $auto_recover_timer_name"
  else
    warn "systemctl не найден, выключать нечего."
  fi
  [[ "$quiet" == "yes" ]] || pause
}

show_auto_recover_status() {
  section "Статус автовосстановления"
  kv "timer" "$(auto_recover_status_line)"
  print_auto_recover_hint
  echo
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "$auto_recover_timer_name" --no-pager 2>/dev/null || true
    echo
    say "Последние события auto-recover"
    journalctl -u "$auto_recover_service_name" -u "$auto_recover_timer_name" --since "12 hours ago" --no-pager 2>/dev/null | tail -n 80 || true
  fi
}

auto_recover_center() {
  need_repo || return
  while true; do
    logo
    show_auto_recover_status
    cat <<EOF

${bold}Автовосстановление miner:${reset}
1) Включить timer
2) Выключить timer
3) Разово проверить сейчас
0) Назад
EOF
    read -r -p "Выбор: " choice
    case "$choice" in
      1) install_auto_recover_timer ;;
      2) disable_auto_recover_timer ;;
      3) auto_recover_once; pause ;;
      0) return ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

auto_recover_status_cli() {
  need_repo || return
  logo
  show_auto_recover_status
}

explain_faucet_blocker() {
  local ss58 restart_policy restarts health
  ss58="$(wallet_ss58 2>/dev/null || true)"
  restart_policy="$(docker_cli inspect --format '{{.HostConfig.RestartPolicy.Name}}' quip-cpu 2>/dev/null || echo unknown)"
  restarts="$(docker_cli inspect --format '{{.RestartCount}}' quip-cpu 2>/dev/null || echo unknown)"
  health="$(faucet_health_check)"

  echo
  warn "Miner собрал CPU workers и подключился к RPC, но кошелёк ещё не funded."
  echo "  Faucet URL: $FAUCET_URL"
  echo "  Faucet health: ${health:-no response}"
  echo "  Wallet: ${ss58:-unknown}"
  echo "  Docker restart policy: $restart_policy, restarts: $restarts"
  echo
  echo "Что это значит:"
  echo "  - miner сам просит стартовые токены у public faucet при запуске;"
  echo "  - сейчас public faucet отвечает ошибкой 502/transfer failed;"
  echo "  - это не поломка Docker stack и не ошибка CPU miner;"
  echo "  - пока faucet не отправит токены или кошелёк не пополнят вручную, mining не стартует полностью."
  echo
  echo "Что делать:"
  echo "  1) Оставить quip-cpu запущенным: он будет перезапускаться и снова пробовать faucet."
  echo "  2) Попросить тестовые QUIP у команды Quip/Discord на адрес выше."
  echo "  3) После пополнения перезапустить miner: ./xnode-quip.sh restart"
}

explain_topology_blocker() {
  echo
  warn "Кошелёк funded/registered, но chain сейчас без QuantumPow.DefaultTopology."
  echo "  Miner не может начать PoW без топологии задач и выходит с ошибкой:"
  echo "  chain has no registered topology; run quip-miner bootstrap --seed-chain first"
  echo
  echo "Что это значит:"
  echo "  - это уже не проблема faucet и не проблема Docker;"
  echo "  - miner account живой, но public testnet должен быть засеян sudo/operator ключом Quip;"
  echo "  - обычно такое бывает после runtime upgrade/reset, когда QuantumPow state ещё не восстановили;"
  echo "  - переключение на локальный validator не поможет, потому что он синхронизирует ту же chain."
  echo
  echo "Что делать:"
  echo "  1) Дождаться, пока команда Quip засеет DefaultTopology на testnet."
  echo "  2) Пока топологии нет, лучше держать quip-cpu остановленным, чтобы не тратить баланс на crash-loop."
  echo "  3) Когда topology появится, запустить miner: ./xnode-quip.sh restart"
}

show_faucet_status() {
  need_repo || return
  logo
  section "Faucet / funding status"
  kv "Public faucet" "$FAUCET_URL"
  kv "Faucet health" "$(faucet_health_check || true)"
  kv "Wallet" "$(wallet_ss58 2>/dev/null || echo unknown)"
  kv "Miner restart policy" "$(docker_cli inspect --format '{{.HostConfig.RestartPolicy.Name}}' quip-cpu 2>/dev/null || echo unknown)"
  kv "Miner restarts" "$(docker_cli inspect --format '{{.RestartCount}}' quip-cpu 2>/dev/null || echo unknown)"
  echo

  if faucet_retry_seen; then
    ok "Miner сам запрашивает стартовые токены у faucet после запуска."
  else
    warn "В последних логах не вижу активного запроса к faucet. Возможно, miner уже funded или сейчас не в фазе bootstrap."
  fi

  if faucet_blocker_seen; then
    explain_faucet_blocker
  else
    ok "В последних логах нет явного wallet-faucet-failed / faucet 502."
  fi

  if topology_blocker_seen; then
    explain_topology_blocker
  fi

  echo
  say "Последние faucet/bootstrap строки из miner logs"
  miner_logs_tail 220 | grep -Ei 'faucet|funded|registered|topology|wallet-faucet|balance is still|requesting [0-9]+ plancks|substrate client connected|MinerCore|Miner built successfully' || true
  pause
}

show_chain_state() {
  need_repo || return
  logo
  section "Chain topology / account status"
  kv "Miner container" "$(miner_state)"
  kv "Wallet" "$(wallet_ss58 2>/dev/null || echo unknown)"
  echo
  say "Public bootnode RPC"
  chain_state_query "wss://bootnode-2.testnet.quip.network:20049/rpc" || warn "Public RPC query failed."
  echo
  say "Local validator RPC"
  chain_state_query "ws://quip-validator:9944" || warn "Local RPC query failed."
  echo
  if topology_blocker_seen; then
    explain_topology_blocker
  fi
  pause
}

print_chain_state_for_diagnostics() {
  echo
  say "Chain topology / account"
  echo "  miner_state: $(miner_state)"
  echo "  wallet: $(wallet_ss58 2>/dev/null || echo unknown)"
  echo
  echo "  Public bootnode RPC:"
  chain_state_query "wss://bootnode-2.testnet.quip.network:20049/rpc" 2>/dev/null | sed 's/^/    /' || echo "    query failed"
  echo
  echo "  Local validator RPC:"
  chain_state_query "ws://quip-validator:9944" 2>/dev/null | sed 's/^/    /' || echo "    query failed"
  if topology_blocker_seen; then
    echo
    echo -e "  ${yellow}Итог:${reset} wallet funded/registered, но QuantumPow.DefaultTopology отсутствует. Miner лучше держать остановленным до фикса testnet."
    print_auto_recover_hint
  fi
}

short_status() {
  if [[ ! -d "$REPO_DIR" ]]; then
    soft "Нода ещё не установлена. При установке будет создана папка: $BASE_DIR"
    return
  fi

  local ip state
  ip="$(public_ip 2>/dev/null || true)"
  state="$(docker_cli inspect --format '{{.State.Status}}' quip-cpu 2>/dev/null || echo "missing")"

  echo -e "${bold}Быстрый статус${reset}"
  kv "рабочая папка" "$REPO_DIR"
  kv "дашборд" "http://${ip:-SERVER_IP}:20049/"
  kv "miner контейнер" "$state"

  if status_json >/tmp/xnode-quip-status.json 2>/dev/null; then
    if ! command -v jq >/dev/null 2>&1; then
      ok "Miner REST отвечает. Для красивого статуса установи jq или запусти установку."
      return
    fi
    jq -r '
      "  \u001b[1mwallet\u001b[0m                 " + .data.ss58_address,
      "  \u001b[1mis_mining\u001b[0m              " + (.data.is_mining|tostring),
      "  \u001b[1mregistered\u001b[0m             " + (.data.miner_registered|tostring),
      "  \u001b[1mhead\u001b[0m                   " + (.data.chain.head_number|tostring),
      "  \u001b[1mrpc\u001b[0m                    " + .data.modes.cpu.controller.active_url
    ' /tmp/xnode-quip-status.json 2>/dev/null || true
  else
    warn "Miner REST пока не отвечает."
    if topology_blocker_seen; then
      warn "Причина по последним логам: missing QuantumPow.DefaultTopology на chain."
      print_auto_recover_hint
    elif faucet_blocker_seen; then
      warn "Похоже, причина в funding: public faucet возвращает ошибку, кошелёк ещё без стартовых QUIP."
    fi
  fi
  echo
}

preflight() {
  logo
  section "Предварительная проверка"
  show_requirements

  section "Зависимости"
  if command -v docker >/dev/null 2>&1; then
    ok "Docker: $(docker --version 2>/dev/null)"
  else
    bad "Docker не установлен"
  fi

  if docker_cli compose version >/dev/null 2>&1; then
    ok "Compose: $(docker_cli compose version 2>/dev/null)"
  else
    bad "Docker Compose v2 не найден"
  fi

  if command -v git >/dev/null 2>&1; then ok "git найден"; else bad "git не найден"; fi
  if command -v jq >/dev/null 2>&1; then ok "jq найден"; else bad "jq не найден"; fi

  echo
  kv "OS" "$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || uname -a)"
  kv "CPU cores" "$(nproc 2>/dev/null || echo unknown)"
  kv "Memory" "$(free -h 2>/dev/null | awk '/Mem:/ {print $2 " total, " $7 " available"}')"
  kv "Disk" "$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4 " free on " $1}')"
  kv "Install dir" "$BASE_DIR"

  echo
  if ss -ltn 2>/dev/null | grep -q ':20049 '; then warn "Port 20049 уже занят/listening"; else ok "Port 20049 свободен"; fi
  if ss -ltn 2>/dev/null | grep -q ':30333 '; then warn "Port 30333 уже занят/listening"; else ok "Port 30333 свободен"; fi

  echo
  if [[ -f "$REPO_DIR/data/keystore.json" ]]; then
    ok "Keystore найден: $REPO_DIR/data/keystore.json"
  else
    warn "Keystore пока не найден, будет создан miner при первом запуске."
  fi
  pause
}

wait_for_miner() {
  local attempts="${1:-60}"
  local i

  say "Жду, пока miner станет is_mining=true..."
  for ((i = 1; i <= attempts; i++)); do
    if status_json 2>/dev/null | grep -q '"is_mining": true'; then
      say "Miner запущен и майнит."
      return 0
    fi

    if (cd "$REPO_DIR" && docker_cli compose logs --tail=120 cpu 2>/dev/null | grep -q 'destination already funded'); then
      warn "Поймал баг faucet: destination already funded. Отключаю faucet и пересоздаю miner."
      disable_faucet_in_override
      restart_cpu_only
    fi

    if topology_blocker_seen && ! chain_default_topology_present; then
      explain_topology_blocker
      stop_cpu_only
      return 1
    fi

    if (( i % 6 == 0 )); then
      echo "  всё ещё жду... попытка $i/$attempts"
    fi
    sleep 5
  done

  warn "Miner не подтвердил is_mining=true за отведённое время. Показываю последние логи."
  if faucet_blocker_seen; then
    explain_faucet_blocker
  fi
  if topology_blocker_seen; then
    explain_topology_blocker
  fi
  compose logs --tail=120 cpu
  return 1
}

wait_for_rpc_url() {
  local expected="$1"
  local attempts="${2:-36}"
  local i current

  say "Жду RPC miner: $expected"
  for ((i = 1; i <= attempts; i++)); do
    current="$(active_rpc_url 2>/dev/null || true)"
    if [[ "$current" == "$expected" ]]; then
      say "Miner использует ожидаемый RPC: $current"
      return 0
    fi
    if (( i % 6 == 0 )); then
      echo "  текущий RPC: ${current:-unknown} ($i/$attempts)"
    fi
    sleep 5
  done

  warn "RPC не стал ожидаемым. Сейчас: ${current:-unknown}, ожидал: $expected"
  return 1
}

recent_miner_errors() {
  (cd "$REPO_DIR" && docker_cli compose logs --since=3m cpu 2>/dev/null | grep -Ei 'fatal|traceback|exception|wallet-underfunded|underfunded|destination already funded|connection refused|failed to connect|panic' || true)
}

switch_miner_rpc() {
  need_repo || return
  local mode="$1"
  local validators expected backup_file errors

  case "$mode" in
    local)
      validators="$LOCAL_VALIDATOR"
      expected="$LOCAL_VALIDATOR"
      ;;
    public)
      validators="$PUBLIC_VALIDATORS"
      expected=""
      ;;
    *)
      fail "Unknown RPC mode: $mode"
      return 1
      ;;
  esac

  logo
  section "Switch Miner RPC"
  kv "mode" "$mode"
  kv "validators" "$validators"
  warn "Это advanced-режим. Для обычной Quip-ноды официально рекомендуется локальный validator ws://quip-validator:9944."
  warn "Переключение RPC пересоздаёт miner и может временно сломать рабочую ноду."
  read -r -p "Напиши YES чтобы продолжить переключение RPC: " confirm_rpc || true
  if [[ "$confirm_rpc" != "YES" ]]; then
    warn "Переключение RPC отменено."
    pause
    return 0
  fi

  if ! docker_cli info >/dev/null 2>&1; then
    fail "Docker API недоступен из этой сессии. Переключение не применено."
    return 1
  fi

  backup_file="$(backup_override_file)"
  say "Backup override: $backup_file"

  ACTIVE_VALIDATORS="$validators"
  write_override_file "disabled" "$validators"
  say "Override обновлён. Пересоздаю miner..."

  if ! restart_cpu_only; then
    warn "Recreate miner не удался. Возвращаю прежний override."
    restore_override_file "$backup_file"
    restart_cpu_only || true
    return 1
  fi

  if ! wait_for_miner 48; then
    warn "Miner не стал is_mining=true. Возвращаю прежний override."
    restore_override_file "$backup_file"
    restart_cpu_only || true
    wait_for_miner 24 || true
    return 1
  fi

  if [[ -n "$expected" ]] && ! wait_for_rpc_url "$expected" 36; then
    warn "Переключение RPC не подтвердилось. Возвращаю прежний override."
    restore_override_file "$backup_file"
    restart_cpu_only || true
    wait_for_miner 24 || true
    return 1
  fi

  if [[ -z "$expected" ]]; then
    say "Public mode включён. Active RPC: $(active_rpc_url 2>/dev/null || echo unknown)"
  fi

  errors="$(recent_miner_errors)"
  if [[ -n "$errors" ]]; then
    warn "В свежих логах есть критичные строки. Возвращаю прежний override."
    echo "$errors"
    restore_override_file "$backup_file"
    restart_cpu_only || true
    wait_for_miner 24 || true
    return 1
  fi

  say "Переключение успешно."
  status_json 2>/dev/null | jq '{is_mining: .data.is_mining, active_url: .data.modes.cpu.controller.active_url, registered: .data.miner_registered}' 2>/dev/null || true
  pause
}

install_node() {
  logo
  section "Установка / восстановление Quip CPU node"
  kv "Режим" "CPU miner, GPU не нужен"
  kv "Дашборд" "HTTP на :20049, домен не нужен"
  kv "RPC miner" "по умолчанию локальный validator ws://quip-validator:9944"
  kv "Локальный validator" "запускается и синхронизируется в фоне"
  kv "Папка установки" "$BASE_DIR"
  kv "Основной repo" "$REPO_DIR"
  kv "Faucet repo" "$FAUCET_DIR"
  echo
  warn "Если keystore уже существует, скрипт сохранит его и не будет запрашивать faucet повторно."
  echo

  section "Шаг 1/7: Проверка ресурсов"
  check_requirements

  section "Шаг 2/8: Пакеты"
  install_packages

  section "Шаг 3/8: Сеть и порты"
  check_network_access
  check_port_conflicts

  section "Шаг 4/8: Репозитории"
  install_repositories

  local node_name cpuset cpu_count faucet_mode has_keystore validators
  local suggested_cpuset
  suggested_cpuset="$(default_cpuset)"

  section "Шаг 5/8: Профиль ноды"
  read -r -p "Имя ноды [xnode-quip]: " node_name
  node_name="$(sanitize_name "${node_name:-xnode-quip}")"
  say "Имя ноды: $node_name"

  read -r -p "CPU cpuset для miner [$suggested_cpuset]: " cpuset
  cpuset="${cpuset:-$suggested_cpuset}"

  cpu_count="$(awk -F'[-,]' '{if ($0 ~ /-/) print $2-$1+1; else print NF}' <<< "$cpuset")"
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
    cpu_count=1
  fi

  has_keystore="no"
  if [[ -f "$REPO_DIR/data/keystore.json" ]]; then
    has_keystore="yes"
    warn "Найден существующий keystore. Он будет сохранён, faucet выключу, чтобы не ловить 403."
    backup_keystore_file
  fi

  validators="$LOCAL_VALIDATOR"
  say "RPC miner: $validators (локальный validator, официальный default)"
  ACTIVE_VALIDATORS="$validators"

  section "Шаг 6/8: Конфигурация"
  write_env_file "$node_name" "$cpuset"
  write_config_file "$node_name" "$cpu_count"

  faucet_mode="enabled"
  if [[ "$has_keystore" == "yes" ]]; then
    faucet_mode="disabled"
  fi
  write_override_file "$faucet_mode" "$validators"
  ok ".env, config.toml и docker-compose.override.yml записаны"

  section "Шаг 7/8: Настройка хоста"
  apply_sysctl_tuning

  section "Шаг 8/8: Запуск Docker stack"
  start_stack

  if wait_for_miner 72; then
    disable_faucet_in_override
    say "Faucet отключён в override для будущих restart/update."
    write_summary
    section "Установка завершена"
    show_dashboard_info
    show_wallet_info "no-secret"
  else
    if faucet_blocker_seen; then
      warn "Установка Docker stack выполнена, но public faucet не выдал стартовые QUIP. Это внешний funding-блокер, см. пункт 6: Полная диагностика."
    elif topology_blocker_seen; then
      warn "Установка Docker stack выполнена, wallet funded/registered, но в testnet отсутствует QuantumPow.DefaultTopology."
      warn "Miner остановлен, чтобы не тратить баланс на crash-loop. Проверяй пункт 6: Полная диагностика."
      stop_cpu_only
      install_auto_recover_timer "yes" || true
    else
      warn "Установка завершилась, но miner требует ручной проверки логов."
    fi
  fi
  pause
}

show_logs_menu() {
  need_repo || return
  logo
  section "Logs"
  cat <<EOF
Что показать?
1) Miner logs
2) Validator logs
3) Dashboard logs
4) Caddy logs
5) Postgres logs
6) Все важные логи
7) Только ошибки за последние 10 минут
8) Follow miner + validator
0) Назад
EOF
  read -r -p "Выбор: " choice
  case "$choice" in
    1) compose logs --tail=160 cpu ;;
    2) compose logs --tail=160 quip-validator ;;
    3) compose logs --tail=160 dashboard ;;
    4) compose logs --tail=160 caddy ;;
    5) compose logs --tail=160 postgres ;;
    6) compose logs --tail=120 cpu quip-validator dashboard caddy ;;
    7) (cd "$REPO_DIR" && docker_cli compose logs --since=10m cpu quip-validator dashboard caddy | grep -Ei 'error|exception|traceback|panic|failed|warn|502|503' || true) ;;
    8) compose logs -f --tail=80 cpu quip-validator ;;
    0) return ;;
    *) warn "Нет такого пункта." ;;
  esac
  pause
}

public_ip() {
  curl -fsS --max-time 5 "$PUBLIC_IP_URL" 2>/dev/null || hostname -I | awk '{print $1}'
}

check_port_remote() {
  local port="$1"
  local out
  out="$(curl -m 15 -fsS "${CHECK_PORT_URL}${port}" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    sleep 1
    out="$(curl -m 15 -fsS "${CHECK_PORT_URL}${port}" 2>/dev/null || true)"
  fi
  if [[ -z "$out" ]]; then
    echo "remote check unavailable"
  else
    echo "$out"
  fi
}

show_dashboard_info() {
  need_repo || return
  local ip
  ip="$(public_ip)"
  echo
  say "Dashboard:"
  echo "  Local:  http://localhost:20049/"
  echo "  Public: http://$ip:20049/"
  echo
  echo "Health:"
  curl -fsS http://localhost:20049/api/health 2>/dev/null || warn "Dashboard health пока не отвечает."
  echo
}

show_wallet_info() {
  need_repo || return
  local mode="${1:-ask-secret}"
  local keystore="$REPO_DIR/data/keystore.json"

  if [[ ! -f "$keystore" ]]; then
    warn "Keystore ещё не найден: $keystore"
    return
  fi

  echo
  say "Miner wallet / keystore"
  echo "  Keystore file: $keystore"
  echo "  ВАЖНО: сохрани весь keystore.json. master_seed_hex внутри него — приватный ключ."
  echo

  python3 - "$keystore" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    data = json.load(f)
for k in ("version", "scheme", "encrypted", "ss58", "account_id_hex", "sr25519_public_hex", "ml_dsa_public_hex"):
    if k in data:
        v = data[k]
        if isinstance(v, str) and len(v) > 110:
            v = v[:110] + "..."
        print(f"{k}: {v}")
PY

  if [[ "$mode" == "ask-secret" ]]; then
    echo
    warn "Показывать master_seed_hex на экране опасно."
    read -r -p "Напиши YES чтобы показать приватный master_seed_hex: " confirm
    if [[ "$confirm" == "YES" ]]; then
      python3 - "$keystore" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print("master_seed_hex:", data.get("master_seed_hex", "<not found>"))
PY
    fi
  fi
}

write_summary() {
  local ip ss58 account keystore
  ip="$(public_ip)"
  keystore="$REPO_DIR/data/keystore.json"
  ss58=""
  account=""

  if [[ -f "$keystore" ]]; then
    ss58="$(python3 - "$keystore" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("ss58", ""))
PY
)"
    account="$(python3 - "$keystore" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("account_id_hex", ""))
PY
)"
  fi

  mkdir -p "$(dirname "$SUMMARY_FILE")"
  cat > "$SUMMARY_FILE" <<EOF
XNODE Quip Node Summary
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Dashboard:
  http://$ip:20049/

Base dir:
  $BASE_DIR

Node repo:
  $REPO_DIR

Faucet repo:
  $FAUCET_DIR

Wallet:
  ss58: $ss58
  account_id_hex: $account
  keystore: $keystore

Important commands:
  cd $SCRIPT_DIR
  ./xnode-quip.sh
  ./xnode-quip.sh status
  ./xnode-quip.sh logs
  ./xnode-quip.sh wallet
  ./xnode-quip.sh backup
  ./xnode-quip.sh check-updates
  ./xnode-quip.sh update
  ./xnode-quip.sh auto-recover-install
  ./xnode-quip.sh auto-recover-disable

Notes:
  - Save the full keystore.json file.
  - master_seed_hex inside keystore.json is the private key.
  - HTTP dashboard mode is used: no domain and no TLS required.
  - Ports 20049/tcp and 30333/tcp+udp should be open publicly.
  - On a new wallet the miner asks the public faucet for testnet QUIP automatically.
  - If the faucet returns 502/transfer failed, leave quip-cpu running or fund the wallet manually.
  - If QuantumPow.DefaultTopology is missing, the miner account can be funded/registered but mining cannot start until Quip seeds topology on testnet.
  - Auto-recover can keep watching topology/miner health and restart the miner after Quip network updates.
  - Use menu item 10 or ./xnode-quip.sh check-updates to detect Git updates before applying them.
  - Use menu item 13 or ./xnode-quip.sh cleanup to safely prune old Docker leftovers.
EOF
  chmod 600 "$SUMMARY_FILE"
  say "Summary saved: $SUMMARY_FILE"
}

backup_keystore() {
  need_repo || return
  local keystore="$REPO_DIR/data/keystore.json"

  if [[ ! -f "$keystore" ]]; then
    warn "Keystore не найден: $keystore"
    pause
    return
  fi

  backup_keystore_file
  pause
}

check_external_ports() {
  need_repo || return
  logo
  section "External Port Check"
  for p in 20049 30333 80 443; do
    printf "  %-5s " "$p"
    check_port_remote "$p"
    echo
  done
  echo
  soft "Для no-domain режима Quip важны 20049 и 30333. 80/443 могут быть закрыты."
  pause
}

dir_size() {
  local path="$1"
  if [[ -e "$path" ]]; then
    du -sh "$path" 2>/dev/null | awk '{print $1}'
  else
    echo "missing"
  fi
}

largest_docker_logs() {
  find /var/lib/docker/containers -name '*-json.log' -printf '%s %p\n' 2>/dev/null \
    | sort -n \
    | tail -10 \
    | awk '{size=$1; $1=""; sub(/^ /,""); printf "  %8.1f MB  %s\n", size/1024/1024, $0}'
}

disk_report() {
  section "Disk / storage"
  kv "Root disk" "$(df -h "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $3 " used / " $4 " free / " $5}')"
  kv "Install dir" "$BASE_DIR"
  kv "Quip repo" "$(dir_size "$REPO_DIR")"
  kv "Validator DB" "$(dir_size "$REPO_DIR/data/validator-data")"
  kv "Miner runtime" "$(dir_size "$REPO_DIR/data/runtime")"
  kv "Quip logs dir" "$(dir_size "$REPO_DIR/data/logs")"
  kv "Docker dir" "$(dir_size /var/lib/docker)"
  echo
  say "Docker disk usage"
  docker_cli system df 2>/dev/null || warn "Docker disk usage недоступен."
  echo
  say "Самые крупные Docker json logs"
  largest_docker_logs || true
  echo
  soft "Важно: validator DB растёт потому что Quip validator запущен как archive node. Это рабочие chain data, их нельзя чистить как мусор."
}

current_override_validators() {
  local override_file="$REPO_DIR/docker-compose.override.yml"
  local value
  if [[ -f "$override_file" ]]; then
    value="$(awk -F'"' '/QUIP_VALIDATORS:/ {print $2; exit}' "$override_file" 2>/dev/null || true)"
    if [[ -z "$value" ]]; then
      value="$(sed -n 's/^[[:space:]]*QUIP_VALIDATORS:[[:space:]]*//p' "$override_file" 2>/dev/null | head -n1 | sed 's/^["'\'']//; s/["'\'']$//')"
    fi
  fi
  echo "${value:-$LOCAL_VALIDATOR}"
}

current_faucet_mode() {
  local override_file="$REPO_DIR/docker-compose.override.yml"
  if [[ -f "$override_file" ]] && grep -Eq 'QUIP_FAUCET_URL:[[:space:]]*""' "$override_file"; then
    echo "disabled"
  else
    echo "enabled"
  fi
}

apply_log_limits_to_override() {
  need_repo || return
  local validators faucet_mode recreate="${1:-ask}"
  validators="$(current_override_validators)"
  faucet_mode="$(current_faucet_mode)"

  backup_override_file >/dev/null || true
  write_override_file "$faucet_mode" "$validators"
  ok "Лимит Docker logs записан в docker-compose.override.yml: max-size=$LOG_MAX_SIZE, max-file=$LOG_MAX_FILE"

  if [[ "$recreate" == "ask" ]]; then
    warn "Чтобы Docker применил logging limit к уже запущенным контейнерам, нужно пересоздать stack."
    read -r -p "Пересоздать Quip stack сейчас? [y/N]: " do_recreate || true
    [[ "$do_recreate" =~ ^[Yy]$ ]] || return 0
  fi

  say "Применяю override и пересоздаю контейнеры..."
  compose up -d --force-recreate
  wait_for_miner 24 || true
}

safe_disk_cleanup() {
  need_repo || return
  local quiet="${1:-no}"

  section "Безопасная очистка диска"
  warn "Эта очистка НЕ удаляет keystore, validator-data, postgres volume и рабочую chain database."
  echo
  say "До очистки"
  docker_cli system df 2>/dev/null || true
  echo

  say "Удаляю dangling Docker images (<none>)..."
  docker_cli image prune -f || true
  echo

  say "Удаляю Docker build cache старше 24 часов..."
  docker_cli builder prune -f --filter until=24h || true
  echo

  say "После очистки"
  docker_cli system df 2>/dev/null || true
  [[ "$quiet" == "yes" ]] || pause
}

truncate_docker_logs() {
  need_repo || return
  section "Очистка Docker json logs"
  largest_docker_logs || true
  echo
  warn "Это очистит историю docker logs, но не тронет контейнеры и данные ноды."
  read -r -p "Напиши YES чтобы обнулить Docker json logs: " confirm || true
  if [[ "$confirm" != "YES" ]]; then
    warn "Очистка логов отменена."
    pause
    return 0
  fi
  find /var/lib/docker/containers -name '*-json.log' -exec truncate -s 0 {} \; 2>/dev/null || true
  ok "Docker json logs очищены."
  pause
}

cleanup_status_line() {
  local status
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "$cleanup_timer_name" >/dev/null 2>&1; then
    status="$(systemctl is-enabled "$cleanup_timer_name" 2>/dev/null || true)"
    echo "${status:-installed}"
  else
    echo "not installed"
  fi
}

cleanup_next_run() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl show "$cleanup_timer_name" -p NextElapseUSecRealtime --value 2>/dev/null || true
}

install_cleanup_timer() {
  need_repo || return
  local quiet="${1:-no}"
  local script_path="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  local service_file="/etc/systemd/system/$cleanup_service_name"
  local timer_file="/etc/systemd/system/$cleanup_timer_name"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl не найден. Очистку можно запускать вручную: $script_path cleanup"
    [[ "$quiet" == "yes" ]] || pause
    return 1
  fi

  chmod +x "$script_path" 2>/dev/null || true
  say "Устанавливаю ежедневную безопасную автоочистку Docker..."
  $SUDO tee "$service_file" >/dev/null <<EOF
[Unit]
Description=XNODE Quip safe Docker cleanup
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$script_path cleanup-auto
EOF

  $SUDO tee "$timer_file" >/dev/null <<'EOF'
[Unit]
Description=Run XNODE Quip safe Docker cleanup daily

[Timer]
OnCalendar=*-*-* 04:15:00
AccuracySec=30min
Persistent=true
Unit=xnode-quip-cleanup.service

[Install]
WantedBy=timers.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$cleanup_timer_name" >/dev/null
  $SUDO systemctl restart "$cleanup_timer_name"
  ok "Автоочистка включена: $cleanup_timer_name"
  soft "Каждый день будет удалять только dangling images и старый build cache. Chain database не трогается."
  [[ "$quiet" == "yes" ]] || pause
}

disable_cleanup_timer() {
  local quiet="${1:-no}"
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl disable --now "$cleanup_timer_name" >/dev/null 2>&1 || true
    ok "Автоочистка выключена: $cleanup_timer_name"
  else
    warn "systemctl не найден, выключать нечего."
  fi
  [[ "$quiet" == "yes" ]] || pause
}

show_cleanup_status() {
  section "Автоочистка"
  kv "timer" "$(cleanup_status_line)"
  kv "next run" "$(cleanup_next_run)"
  echo
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status "$cleanup_timer_name" --no-pager 2>/dev/null || true
  fi
}

cleanup_center() {
  need_repo || return
  while true; do
    logo
    disk_report
    echo
    show_cleanup_status
    cat <<EOF

${bold}Очистка и защита диска:${reset}
1) Безопасная очистка Docker сейчас
2) Применить лимит Docker logs к Quip контейнерам
3) Очистить Docker json logs вручную
4) Включить ежедневную безопасную автоочистку
5) Выключить автоочистку
0) Назад
EOF
    read -r -p "Выбор: " choice
    case "$choice" in
      1) safe_disk_cleanup ;;
      2) apply_log_limits_to_override "ask"; pause ;;
      3) truncate_docker_logs ;;
      4) install_cleanup_timer ;;
      5) disable_cleanup_timer ;;
      0) return ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

diagnostics() {
  need_repo || return
  logo
  section "Diagnostics"
  say "Docker containers"
  compose ps
  echo
  say "Restart counters"
  docker_cli inspect --format '{{.Name}} restart={{.RestartCount}} state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    quip-cpu quip-validator quip-dashboard quip-postgres quip-caddy 2>/dev/null || true
  echo
  say "Miner status"
  local miner_status_ok="no"
  if command -v jq >/dev/null 2>&1; then
    if status_json >/tmp/xnode-quip-status.json 2>/dev/null; then
      jq '{success, ss58: .data.ss58_address, is_mining: .data.is_mining, miner_registered: .data.miner_registered, head: .data.chain.head_number, active_url: .data.modes.cpu.controller.active_url}' /tmp/xnode-quip-status.json || true
      miner_status_ok="yes"
    fi
  else
    if status_json 2>/dev/null; then
      miner_status_ok="yes"
    fi
  fi
  if [[ "$miner_status_ok" != "yes" ]]; then
    if topology_blocker_seen; then
      warn "Miner REST не отвечает, потому что miner падает на missing QuantumPow.DefaultTopology."
    elif faucet_blocker_seen; then
      warn "Miner REST пока не отвечает, потому что bootstrap ждёт funding от public faucet."
    elif [[ "$(miner_state)" == "exited" ]]; then
      warn "Miner REST не отвечает, потому что quip-cpu сейчас остановлен."
    else
      warn "Miner REST пока не отвечает. Проверь логи miner."
    fi
  fi
  echo
  say "Faucet / funding"
  echo "  faucet_health: $(faucet_health_check || true)"
  echo "  wallet: $(wallet_ss58 2>/dev/null || echo unknown)"
  echo "  miner_state: $(miner_state)"
  if faucet_retry_seen; then
    echo -e "  auto_request: ${green}yes${reset}"
  else
    echo -e "  auto_request: ${yellow}not seen in recent logs${reset}"
  fi
  if faucet_blocker_seen; then
    echo -e "  funding_blocker: ${yellow}public faucet returned 502 / transfer failed${reset}"
  else
    echo -e "  funding_blocker: ${green}not seen in recent logs${reset}"
  fi
  if topology_blocker_seen; then
    echo -e "  topology_blocker: ${yellow}DefaultTopology is missing on chain${reset}"
  else
    echo -e "  topology_blocker: ${green}not seen in recent logs${reset}"
  fi
  echo "  auto_recover: $(auto_recover_status_line)"
  print_auto_recover_hint
  print_chain_state_for_diagnostics
  echo
  say "Dashboard health"
  curl -fsS http://localhost:20049/api/health 2>/dev/null || true
  echo
  say "External ports"
  for p in 20049 30333; do
    printf "  %s: " "$p"
    check_port_remote "$p"
    echo
  done
  echo
  say "Resource usage"
  docker_cli stats --no-stream quip-cpu quip-validator quip-dashboard quip-postgres quip-caddy 2>/dev/null || true
  echo
  disk_report
  pause
}

restart_node() {
  need_repo || return
  if topology_blocker_seen; then
    say "Проверяю, появилась ли QuantumPow.DefaultTopology перед запуском miner..."
    if ! chain_default_topology_present; then
      explain_topology_blocker
      warn "Miner сейчас не запускаю автоматически, чтобы не тратить баланс на crash-loop."
      read -r -p "Всё равно принудительно перезапустить stack? [y/N]: " force_restart || true
      if [[ ! "$force_restart" =~ ^[Yy]$ ]]; then
        pause
        return
      fi
    fi
  fi
  say "Перезапускаю stack..."
  compose up -d --force-recreate
  wait_for_miner 36 || true
  pause
}

stop_node() {
  need_repo || return
  warn "Остановить Quip stack?"
  read -r -p "Напиши YES для остановки: " confirm
  if [[ "$confirm" == "YES" ]]; then
    compose down
  fi
  pause
}

update_node() {
  need_repo || return
  local confirm="${1:-ask}"
  local recover_status_before

  logo
  section "Обновление Quip node"
  warn "Update НЕ удаляет data/keystore.json и не сбрасывает папку data."
  warn "Будет выполнено: git pull --ff-only, docker compose pull, docker compose up -d."
  echo
  show_update_status
  echo

  if [[ "$confirm" == "ask" ]]; then
    read -r -p "Напиши YES чтобы обновить ноду сейчас: " update_confirm || true
    if [[ "$update_confirm" != "YES" ]]; then
      warn "Update отменён."
      pause
      return 0
    fi
  fi

  section "Backup"
  backup_keystore_file
  recover_status_before="$(auto_recover_status_line)"

  section "Git repos"
  git_repo_pull_ff "$REPO_DIR" "nodes.quip.network"
  git_repo_pull_ff "$FAUCET_DIR" "faucet" || true

  section "Docker images"
  compose pull

  section "Apply"
  compose up -d
  if [[ "$recover_status_before" == "enabled" ]]; then
    install_auto_recover_timer "yes" || true
  else
    soft "Автовосстановление было выключено/не установлено, update не включает его автоматически."
  fi
  wait_for_miner 36 || true
  write_summary || true
  say "Update завершён. Проверь пункт 6, если хочешь увидеть полную диагностику."
  [[ "$confirm" == "ask" ]] && pause
}

update_center() {
  need_repo || return
  while true; do
    logo
    show_update_status
    cat <<EOF

${bold}Центр обновлений:${reset}
1) Обновить сейчас
2) Только проверить ещё раз
0) Назад
EOF
    read -r -p "Выбор: " choice
    case "$choice" in
      1) update_node "ask"; return ;;
      2) continue ;;
      0) return ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

update_images() {
  update_node "ask"
}

update_node_cli() {
  update_node "no"
}

check_updates_cli() {
  need_repo || return
  logo
  show_update_status
}

main_menu() {
  while true; do
    logo
    short_status
    cat <<EOF
${bold}Меню:${reset}
1) Установка / восстановление Quip CPU node
2) Предварительная проверка
3) Центр логов
4) URL дашборда + health
5) Wallet / приватный ключ / инфо майнера
6) Полная диагностика
7) Проверка внешних портов
8) Backup keystore.json
9) Перезапуск ноды
10) Проверить / обновить Quip node
11) Остановить ноду
12) Автовосстановление miner: статус / вкл / выкл
13) Очистка диска / лимит логов / автоочистка
0) Выход

Папка установки: $BASE_DIR
EOF
    read -r -p "Выбор: " choice
    case "$choice" in
      1) install_node ;;
      2) preflight ;;
      3) show_logs_menu ;;
      4) logo; show_dashboard_info; pause ;;
      5) logo; show_wallet_info "ask-secret"; pause ;;
      6) diagnostics ;;
      7) check_external_ports ;;
      8) backup_keystore ;;
      9) restart_node ;;
      10) update_center ;;
      11) stop_node ;;
      12) auto_recover_center ;;
      13) cleanup_center ;;
      0) exit 0 ;;
      *) warn "Нет такого пункта."; sleep 1 ;;
    esac
  done
}

case "${1:-menu}" in
  menu) main_menu ;;
  install) install_node ;;
  preflight) preflight ;;
  logs) show_logs_menu ;;
  dashboard) show_dashboard_info ;;
  wallet) show_wallet_info "ask-secret" ;;
  status) diagnostics ;;
  ports) check_external_ports ;;
  backup) backup_keystore ;;
  auto-recover) auto_recover_once ;;
  auto-recover-status) auto_recover_status_cli ;;
  auto-recover-install) install_auto_recover_timer "yes" ;;
  auto-recover-disable) disable_auto_recover_timer "yes" ;;
  restart) restart_node ;;
  stop) stop_node ;;
  check-updates) check_updates_cli ;;
  update) update_node_cli ;;
  cleanup) logo; safe_disk_cleanup ;;
  cleanup-auto) safe_disk_cleanup "yes" ;;
  cleanup-status) logo; show_cleanup_status ;;
  cleanup-install) install_cleanup_timer "yes" ;;
  cleanup-disable) disable_cleanup_timer "yes" ;;
  log-limits) apply_log_limits_to_override "ask" ;;
  rpc-local) switch_miner_rpc local ;;
  rpc-public) switch_miner_rpc public ;;
  *) echo "Usage: $0 [menu|install|preflight|logs|dashboard|wallet|status|ports|backup|auto-recover|auto-recover-status|auto-recover-install|auto-recover-disable|restart|stop|check-updates|update|cleanup|cleanup-auto|cleanup-status|cleanup-install|cleanup-disable|log-limits|rpc-local|rpc-public]"; exit 1 ;;
esac
