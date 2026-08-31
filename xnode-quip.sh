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
PUBLIC_RPC="wss://bootnode-2.testnet.quip.network:20049/rpc"
# Caddy publishes the local validator's JSON-RPC on the same host port as the
# dashboard (see caddy/Caddyfile `handle /rpc`), so the host reaches it without
# a container exec.
LOCAL_RPC_HTTP="http://localhost:20049/rpc"
# Port the coordinator's [dashboard] section binds. Must match the
# `reverse_proxy quip-miner:8086` in caddy/Caddyfile or /api/v1/* 502s.
MINER_REST_PORT="${XNODE_MINER_REST_PORT:-8086}"
# Advertised front door written to [miner].public_port. The v0.3 coordinator
# refuses to start without public_host/public_port, and 20049 is the port this
# installer opens and puts Caddy on.
MINER_PUBLIC_PORT="${XNODE_MINER_PUBLIC_PORT:-20049}"
# Substrate storage keys, twox128(pallet) ++ twox128(item). Precomputed so the
# chain queries below need nothing but curl + python3 stdlib — the v0.3 miner
# image dropped the Python substrate client the old queries ran inside.
SK_DEFAULT_TOPOLOGY="0x9b2c4dbe49d7a1aed7ce99e4b8c072e8a4bccd2391f1245103331f3189ad079f"
# Map prefix; counting its keys says whether anything is registered at all.
SK_REGISTERED_TOPOLOGIES="0x9b2c4dbe49d7a1aed7ce99e4b8c072e869e36f224eee7745986b1399492ef513"
# Map prefixes; the key is prefix ++ blake2_128(account) ++ account.
SK_MINERS_PREFIX="9b2c4dbe49d7a1aed7ce99e4b8c072e83c8312b14d47df66cbccdda7f2601ff7"
SK_SYSTEM_ACCOUNT_PREFIX="26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9"
PUBLIC_IP_URL="https://api.ipify.org"
CHECK_PORT_URL="https://check.quip.network/checkport?port="
SUMMARY_FILE="${XNODE_SUMMARY_FILE:-$BASE_DIR/xnode-quip-summary.txt}"
BACKUP_DIR="${XNODE_BACKUP_DIR:-$BASE_DIR/backups}"
HEALTH_STATE_FILE="${XNODE_HEALTH_STATE_FILE:-$BASE_DIR/health-state.json}"
# How long the miner may show zero forward progress, while the chain keeps
# advancing, before the watchdog restarts it. A healthy node advances ~10
# chain heads per minute, so 15 minutes of a flat counter is unambiguous
# rather than a blip.
STALL_SECONDS="${XNODE_STALL_SECONDS:-900}"
# Minimum gap between recovery attempts, widened on repeats (see below).
STALL_COOLDOWN_SECONDS="${XNODE_STALL_COOLDOWN_SECONDS:-900}"
# The validator gets a longer rope than the miner: a restart costs it a
# startup and a chunk of resync, and normal full sync can pause on a slow
# peer without being wedged.
VALIDATOR_STALL_SECONDS="${XNODE_VALIDATOR_STALL_SECONDS:-1800}"
LOG_MAX_SIZE="${XNODE_LOG_MAX_SIZE:-50m}"
LOG_MAX_FILE="${XNODE_LOG_MAX_FILE:-3}"
VALIDATOR_STATE_PRUNING="${XNODE_VALIDATOR_STATE_PRUNING:-1024}"
VALIDATOR_BLOCKS_PRUNING="${XNODE_VALIDATOR_BLOCKS_PRUNING:-1024}"
VALIDATOR_DB_CACHE_MB="${XNODE_VALIDATOR_DB_CACHE_MB:-256}"
VALIDATOR_RESET_THRESHOLD_GB="${XNODE_VALIDATOR_RESET_THRESHOLD_GB:-55}"

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
version 1.02
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

# Upstream caps the miner at QUIP_MINER_MEM_LIMIT, default 16g, to stop a
# runaway miner from triggering a host-wide OOM. On any box with less than
# 16 GB that default is above total RAM, so the cap never binds and the
# protection is silently off — which is how this node ended up with the kernel
# OOM-killing the *validator* ten times in 26 hours, it being the largest RSS
# on the box. Size the cap from the host instead, leaving room for the
# validator (~3.5G), the dashboard (~1.2G) and postgres/caddy/OS (~1G).
default_miner_mem_limit() {
  local total_mb limit_mb
  total_mb="$(system_ram_mb)"
  if ! [[ "$total_mb" =~ ^[0-9]+$ ]] || (( total_mb <= 0 )); then
    echo "2g"
    return
  fi
  limit_mb=$(( total_mb - 5700 ))
  (( limit_mb < 1024 )) && limit_mb=1024
  (( limit_mb > 16384 )) && limit_mb=16384
  echo "${limit_mb}m"
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
# Image tags are deliberately NOT pinned here. Upstream moved the miner to the
# v0.3 repository line (quip-miner/v0.3/quip-miner) and made :latest the
# compose default for every quip image; a leftover QUIP_MINER_TAG=v0.2 pin
# resolves to a tag that does not exist on that path and fails the pull with
# "not found". Every service sets pull_policy: always, so an unpinned stack
# re-resolves :latest on every up. Pin one of these only to freeze a deploy:
#   QUIP_MINER_TAG=v0.3.1-rc2
#   QUIP_DASHBOARD_TAG=v0.2.1
#   QUIP_VALIDATOR_TAG=v0.2.2-rc4
#   QUIP_FAUCET_TAG=latest
QUIP_MINER_CPUSET=$cpuset
# Sized from this host's RAM. The compose default (16g) is above total memory
# on a smaller box, which turns the cap off exactly where it matters.
QUIP_MINER_MEM_LIMIT=$(default_miner_mem_limit)
VALIDATOR_NAME=$node_name-validator
SUBSTRATE_BOOTNODES=
POSTGRES_DB=quip
POSTGRES_USER=quip
POSTGRES_PASSWORD=quip
EOF
}

# Read one scalar (or comma-joined array) out of data/config.toml.
#   config_read <table> <key>
# tomllib needs python3.11+; the regex fallback covers older hosts and is good
# enough for the flat file this installer writes.
config_read() {
  local table="$1" key="$2"
  local config_file="$REPO_DIR/data/config.toml"
  [[ -f "$config_file" ]] || return 0
  python3 - "$config_file" "$table" "$key" <<'PY'
import re, sys

path, table, key = sys.argv[1], sys.argv[2], sys.argv[3]

def emit(value):
    if value is None:
        return
    if isinstance(value, (list, tuple)):
        print(",".join(str(v) for v in value))
    elif isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)

try:
    import tomllib
    with open(path, "rb") as fh:
        emit(tomllib.load(fh).get(table, {}).get(key))
    sys.exit(0)
except ImportError:
    pass
except Exception:
    sys.exit(0)

# Fallback: walk the file, tracking the current table header.
text = open(path, "r", encoding="utf-8", errors="replace").read()
current, buf, found = None, None, None
for raw in text.splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    if buf is not None:
        buf += " " + line
        if "]" in line:
            found = buf
            break
        continue
    header = re.match(r"^\[([^\]]+)\]$", line)
    if header:
        current = header.group(1)
        continue
    if current != table:
        continue
    match = re.match(r"^%s\s*=\s*(.*)$" % re.escape(key), line)
    if not match:
        continue
    value = match.group(1)
    if value.startswith("[") and "]" not in value:
        buf = value
        continue
    found = value
    break

if found is None:
    sys.exit(0)
found = found.strip()
if found.startswith("["):
    emit(re.findall(r'"([^"]*)"', found))
else:
    emit(found.strip().strip('"').strip("'"))
PY
}

# [miner].public_host is mandatory in v0.3 and an empty string is rejected, so
# reuse whatever is already configured before falling back to detection.
config_public_host() {
  local host
  host="$(config_read miner public_host 2>/dev/null || true)"
  host="${host//[[:space:]]/}"
  if [[ -z "$host" ]]; then
    host="$(public_ip 2>/dev/null || true)"
    host="${host//[[:space:]]/}"
  fi
  if [[ -z "$host" ]]; then
    host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "$host"
}

write_config_file() {
  local node_name="$1"
  local cpu_count="$2"
  local validators="${3:-$PUBLIC_VALIDATORS}"
  local faucet_mode="${4:-enabled}"
  local config_file="$REPO_DIR/data/config.toml"
  local backup faucet_url public_host
  local validator
  local -a validator_list

  mkdir -p "$REPO_DIR/data"
  public_host="$(config_public_host)"
  if [[ -z "$public_host" ]]; then
    fail "Не удалось определить public_host, а v0.3 coordinator без него не стартует."
    fail "Задай его вручную в $config_file или экспортируй XNODE_PUBLIC_HOST."
    return 1
  fi

  faucet_url="$FAUCET_URL"
  [[ "$faucet_mode" == "disabled" ]] && faucet_url=""

  if [[ -f "$config_file" ]]; then
    backup="$config_file.xnode-backup-$(date -u +%Y%m%d-%H%M%S)"
    cp "$config_file" "$backup"
    warn "Существующий config.toml сохранён в $backup"
  fi

  cat > "$config_file" <<EOF
# quip-coordinator v0.3 CPU configuration, written by XNODE.
# Schema notes: [miner].public_host/public_port are mandatory, the old
# rest_host/rest_port pair is gone (the REST surface moved to [dashboard]),
# and at least one backend section must be present.

[miner]
validators = [
EOF
  IFS=',' read -ra validator_list <<< "$validators"
  for validator in "${validator_list[@]}"; do
    validator="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$validator")"
    [[ -n "$validator" ]] && printf '    "%s",\n' "$validator" >> "$config_file"
  done
  cat >> "$config_file" <<EOF
]
signer_key = "/data/keystore.json"
node_name = "$node_name"
# Empty disables auto-funding; the coordinator refuses to start on an
# underfunded account when it has no faucet to ask.
faucet_url = "$faucet_url"
# Address peers use to reach this node. Required, and "" is not a host.
public_host = "$public_host"
public_port = $MINER_PUBLIC_PORT

[cpu]
# Bundled miner binary; quip-cpu-gibbs is the other choice.
binary = "quip-cpu-sa"
num_cpus = $cpu_count

# Miner telemetry + /api/v1/* REST. The port must match the
# reverse_proxy quip-miner:8086 line in caddy/Caddyfile.
[dashboard]
listen = "0.0.0.0:$MINER_REST_PORT"
data_dir = "/data/attempts"
EOF
}

# Rewrite config.toml keeping every value the installer manages, changing only
# what the caller passes. Both setters below funnel through this.
rewrite_config_file() {
  local validators="$1" faucet_mode="$2"
  local node_name cpu_count

  node_name="$(config_read miner node_name 2>/dev/null || true)"
  cpu_count="$(config_read cpu num_cpus 2>/dev/null || true)"
  node_name="${node_name:-xnode-quip}"
  [[ "$cpu_count" =~ ^[0-9]+$ ]] || cpu_count=1
  write_config_file "$node_name" "$cpu_count" "$validators" "$faucet_mode"
}

set_config_validators() {
  need_repo || return
  rewrite_config_file "$1" "$(current_faucet_mode)"
}

set_config_faucet() {
  need_repo || return
  rewrite_config_file "$(current_config_validators)" "$1"
}

# Upstream v0.3 rejects the v0.2 schema outright ("missing [miner].public_host"),
# and a v0.2 config that somehow parses still leaves REST off because
# rest_host/rest_port are ignored now. Detect both and rewrite in place.
migrate_config_v03() {
  local config_file="$REPO_DIR/data/config.toml"
  local public_host dashboard_listen has_backend

  [[ -f "$config_file" ]] || return 0

  public_host="$(config_read miner public_host 2>/dev/null || true)"
  dashboard_listen="$(config_read dashboard listen 2>/dev/null || true)"
  has_backend="no"
  grep -Eq '^[[:space:]]*\[(cpu|cuda(\.[0-9]+)?|metal|dwave|qpu)\]' "$config_file" && has_backend="yes"

  if [[ -n "$public_host" && -n "$dashboard_listen" && "$has_backend" == "yes" ]]; then
    return 0
  fi

  warn "data/config.toml написан по схеме v0.2 — v0.3 coordinator её не принимает. Мигрирую."
  rewrite_config_file "$(current_config_validators)" "$(current_faucet_mode)" || return 1
  ok "config.toml переписан под v0.3 (public_host/public_port + [dashboard] + backend section)."
}

# A `QUIP_*_TAG=` pin in .env overrides the compose default. The installer used
# to write `QUIP_MINER_TAG=v0.2`, which after upstream's move to the
# quip-miner/v0.3/quip-miner path resolves to a tag that was never published
# there — `docker compose pull` then dies with "not found" and takes the whole
# stack's pull down with it. Comment the pins out so :latest applies again.
# The override still carried QUIP_VALIDATORS / QUIP_FAUCET_URL, which no image
# has read since v0.2.1-rc. Left in place they read as live configuration and
# quietly contradict data/config.toml, so rewrite the file once.
migrate_override_file() {
  local override_file="$REPO_DIR/docker-compose.override.yml"

  [[ -f "$override_file" ]] || return 0
  grep -Eq 'QUIP_VALIDATORS:|QUIP_FAUCET_URL:' "$override_file" || return 0

  say "Backup override: $(backup_override_file)"
  write_override_file
  ok "docker-compose.override.yml переписан без мёртвых QUIP_* env."
}

# An .env written before the cap was sized has no QUIP_MINER_MEM_LIMIT at all,
# so compose falls back to its 16g default.
migrate_env_mem_limit() {
  local env_file="$REPO_DIR/.env"
  local limit

  [[ -f "$env_file" ]] || return 0
  grep -Eq '^[[:space:]]*QUIP_MINER_MEM_LIMIT[[:space:]]*=' "$env_file" && return 0

  limit="$(default_miner_mem_limit)"
  printf '\n# Added by XNODE: compose defaults to 16g, which is above total RAM on a\n# smaller host and therefore never binds.\nQUIP_MINER_MEM_LIMIT=%s\n' "$limit" >> "$env_file"
  ok "В .env добавлен QUIP_MINER_MEM_LIMIT=$limit (RAM хоста: $(system_ram_mb) MB)."
}

migrate_env_tags() {
  local env_file="$REPO_DIR/.env"
  local backup

  [[ -f "$env_file" ]] || return 0
  grep -Eq '^[[:space:]]*QUIP_(MINER|DASHBOARD|VALIDATOR|FAUCET)_TAG[[:space:]]*=' "$env_file" || return 0

  backup="$env_file.xnode-backup-$(date -u +%Y%m%d-%H%M%S)"
  cp "$env_file" "$backup"
  sed -i -E 's%^([[:space:]]*QUIP_(MINER|DASHBOARD|VALIDATOR|FAUCET)_TAG[[:space:]]*=.*)$%# xnode: пин снят, образы тянутся по :latest -> \1%' "$env_file"
  warn "Из .env убраны устаревшие пины образов (QUIP_*_TAG). Backup: $backup"
}

# The miner is config-driven: QUIP_VALIDATORS / QUIP_FAUCET_URL were dropped
# from the images back in the v0.2.1-rc line and the v0.3 coordinator reads
# neither. Validators and the faucet live in data/config.toml now, so this
# override carries logging and validator flags only.
write_override_file() {
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
EOF

  cat >> "$override_file" <<'EOF'
  quip-validator:
    logging: *xnode-logging
EOF

  cat >> "$override_file" <<EOF
    command:
      - --chain=/etc/quip/chain-spec.json
      - --base-path=/data
      - --name=\${VALIDATOR_NAME:-quip-validator}
      - --validator
      - --state-pruning=$VALIDATOR_STATE_PRUNING
      - --blocks-pruning=$VALIDATOR_BLOCKS_PRUNING
      - --db-cache=$VALIDATOR_DB_CACHE_MB
      - --rpc-port=9944
      - --unsafe-rpc-external
      - --rpc-cors=*
      - --rpc-methods=safe
      - --prometheus-port=9615
      - --prometheus-external
      - --no-mdns
      - --unsafe-force-node-key-generation
EOF

  cat >> "$override_file" <<'EOF'
  dashboard:
    logging: *xnode-logging
  postgres:
    logging: *xnode-logging
  caddy:
    logging: *xnode-logging
EOF
}

disable_faucet_in_config() {
  set_config_faucet "disabled"
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

backup_config_file() {
  local config_file="$REPO_DIR/data/config.toml"
  local backup_file

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/config.toml.$(date -u +%Y%m%d-%H%M%S).bak"

  if [[ -f "$config_file" ]]; then
    cp "$config_file" "$backup_file"
  else
    : > "$backup_file"
  fi
  echo "$backup_file"
}

restore_config_file() {
  local backup_file="$1"
  local config_file="$REPO_DIR/data/config.toml"

  if [[ -s "$backup_file" ]]; then
    cp "$backup_file" "$config_file"
  else
    rm -f "$config_file"
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

# The v0.2 status payload carried modes.cpu.controller.active_url; the v0.3
# coordinator dropped it and rotates through [miner].validators internally.
# Try the old field first (older images, and in case it comes back), then fall
# back to the configured list — which is the operator-facing truth now.
active_rpc_url() {
  local value=""

  if command -v jq >/dev/null 2>&1 && status_json >/tmp/xnode-quip-status.json 2>/dev/null; then
    value="$(jq -r '.data.modes.cpu.controller.active_url // empty' /tmp/xnode-quip-status.json 2>/dev/null || true)"
  fi

  if [[ -z "$value" ]] && command -v jq >/dev/null 2>&1 && [[ -f "$REPO_DIR/data/runtime/telemetry-stats-cpu.json" ]]; then
    value="$(jq -r '.controller.active_url // empty' "$REPO_DIR/data/runtime/telemetry-stats-cpu.json" 2>/dev/null || true)"
  fi

  if [[ -z "$value" ]]; then
    value="$(current_config_validators 2>/dev/null | cut -d, -f1)"
  fi

  echo "$value"
}

# `quip-coordinator keygen` (v0.3) writes a keystore holding master_seed_hex
# only — the ss58/account_id_hex fields the v0.2 entrypoint recorded are gone,
# and re-deriving them needs sr25519 + ML-DSA, which the host does not have.
# So read the keystore first and fall back to the miner's own REST surface.
wallet_field() {
  local field="$1"
  local keystore="$REPO_DIR/data/keystore.json"
  local value=""

  if [[ -f "$keystore" ]]; then
    value="$(python3 - "$keystore" "$field" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.load(f).get(sys.argv[2], "") or "")
except Exception:
    print("")
PY
)"
  fi

  if [[ -z "$value" ]] && command -v jq >/dev/null 2>&1; then
    case "$field" in
      ss58)            value="$(status_json 2>/dev/null | jq -r '.data.ss58_address // empty' 2>/dev/null || true)" ;;
      account_id_hex)  value="$(status_json 2>/dev/null | jq -r '.data.account_id_hex // empty' 2>/dev/null || true)" ;;
    esac
  fi

  echo "$value"
}

wallet_ss58() { wallet_field ss58; }

wallet_account_hex() { wallet_field account_id_hex; }

miner_logs_tail() {
  local lines="${1:-260}"
  (cd "$REPO_DIR" && docker_cli compose logs --tail="$lines" cpu 2>/dev/null) || docker_cli logs --tail "$lines" quip-cpu 2>/dev/null || true
}

faucet_health_check() {
  curl -fsS --max-time 10 "$FAUCET_URL/health" 2>/dev/null || true
}

faucet_blocker_seen() {
  # The last two patterns are the v0.3 coordinator's wording; it exits rather
  # than crash-looping when it cannot fund the account.
  miner_logs_tail 360 | grep -Eiq 'wallet-faucet-failed|faucet returned 502|transfer failed; see faucet logs|balance is still 0|miner account is (not funded|underfunded)|refusing to start'
}

faucet_retry_seen() {
  miner_logs_tail 360 | grep -Eiq 'requesting [0-9]+ plancks from faucet|retrying up to 300s'
}

topology_blocker_seen() {
  # v0.3 no longer exits on a missing topology — it idles and logs
  # "feeder: chain has no mining snapshot (no registered/mineable topology)".
  miner_logs_tail 360 | grep -Eiq 'chain has no registered topology|no registered/mineable topology|no mining snapshot|DefaultTopology'
}

miner_state() {
  docker_cli inspect --format '{{.State.Status}}' quip-cpu 2>/dev/null || echo "missing"
}

# The v0.2 chain queries ran `python3 -c` inside the miner image against its
# bundled `substrate.client`. The v0.3 image dropped those Python modules, so
# the queries now go straight at a validator's JSON-RPC over HTTP with
# precomputed storage keys — no image, no dependencies beyond curl + python3.
rpc_endpoint_http() {
  local url="${1:-$PUBLIC_RPC}"
  case "$url" in
    # ws://quip-validator:9944 is a compose-network address the host cannot
    # dial; Caddy fronts the same RPC on the published dashboard port.
    ws://quip-validator:*|ws://127.0.0.1:*|ws://localhost:*) echo "$LOCAL_RPC_HTTP" ;;
    wss://*) echo "https://${url#wss://}" ;;
    ws://*)  echo "http://${url#ws://}" ;;
    *)       echo "$url" ;;
  esac
}

# rpc_state_get_storage <validator-url> <hex-key>
# Prints the SCALE-encoded value, or nothing when the key is unset. Returns
# non-zero only when the endpoint itself could not be reached.
rpc_state_get_storage() {
  local endpoint key body
  endpoint="$(rpc_endpoint_http "${1:-$PUBLIC_RPC}")"
  key="$2"
  body="$(curl -fsS --max-time "${XNODE_RPC_TIMEOUT:-12}" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"state_getStorage\",\"params\":[\"$key\"]}" \
    "$endpoint" 2>/dev/null)" || return 1
  [[ -n "$body" ]] || return 1
  printf '%s' "$body" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("result") or "")
except Exception:
    sys.exit(1)'
}

# Substrate map key: twox128(pallet) ++ twox128(item) ++ blake2_128(account) ++ account
account_storage_key() {
  local prefix="$1" account_hex="$2"
  python3 - "$prefix" "$account_hex" <<'PY'
import hashlib, sys
prefix = bytes.fromhex(sys.argv[1])
account = bytes.fromhex(sys.argv[2].removeprefix("0x"))
print("0x" + (prefix + hashlib.blake2b(account, digest_size=16).digest() + account).hex())
PY
}

# Number of entries under a storage-map prefix, capped — enough to tell an
# empty registry from a populated one without pulling 50k keys.
rpc_state_get_keys_count() {
  local endpoint prefix body
  endpoint="$(rpc_endpoint_http "${1:-$PUBLIC_RPC}")"
  prefix="$2"
  body="$(curl -fsS --max-time "${XNODE_RPC_TIMEOUT:-12}" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"state_getKeysPaged\",\"params\":[\"$prefix\",100,\"$prefix\"]}" \
    "$endpoint" 2>/dev/null)" || return 1
  [[ -n "$body" ]] || return 1
  printf '%s' "$body" | python3 -c 'import json, sys
try:
    keys = json.load(sys.stdin).get("result") or []
except Exception:
    sys.exit(1)
print(f"{len(keys)}+" if len(keys) >= 100 else len(keys))'
}

chain_state_query() {
  local validator="${1:-$PUBLIC_RPC}"
  local endpoint account_hex topology registered account miner

  endpoint="$(rpc_endpoint_http "$validator")"
  account_hex="$(wallet_account_hex 2>/dev/null || true)"

  echo "validator: $validator"
  echo "endpoint:  $endpoint"

  topology="$(rpc_state_get_storage "$validator" "$SK_DEFAULT_TOPOLOGY")" || {
    warn "RPC $endpoint не ответил."
    return 1
  }
  registered="$(rpc_state_get_keys_count "$validator" "$SK_REGISTERED_TOPOLOGIES" || true)"

  if [[ -n "$topology" ]]; then
    echo "DefaultTopology: set ($topology)"
  else
    echo "DefaultTopology: None"
  fi
  echo "RegisteredTopologies: ${registered:-unknown}"

  if [[ -z "$account_hex" ]]; then
    echo "Account: wallet unknown (keystore не читается)"
    return 0
  fi

  account="$(rpc_state_get_storage "$validator" "$(account_storage_key "$SK_SYSTEM_ACCOUNT_PREFIX" "$account_hex")" || true)"
  miner="$(rpc_state_get_storage "$validator" "$(account_storage_key "$SK_MINERS_PREFIX" "$account_hex")" || true)"

  if [[ -n "$account" ]]; then
    # AccountInfo: nonce u32, consumers u32, providers u32, sufficients u32,
    # then AccountData { free, reserved, frozen, flags } as u128s.
    python3 - "$account" <<'PY'
import sys
raw = bytes.fromhex(sys.argv[1][2:])
nonce = int.from_bytes(raw[0:4], "little")
free = int.from_bytes(raw[16:32], "little")
reserved = int.from_bytes(raw[32:48], "little")
print(f"Account: nonce={nonce} free={free} ({free / 1e12:.4f} QUIP) reserved={reserved}")
PY
  else
    echo "Account: not found on chain (баланс 0, аккаунт ещё не создан)"
  fi

  if [[ -n "$miner" ]]; then
    echo "Miner: registered"
  else
    echo "Miner: not registered"
  fi
}

# Returns 0 when the chain carries a topology, 1 when it does not, and 2 when
# no validator answered — auto-recover must not stop a miner over an
# unreachable RPC, so the caller has to tell those apart.
chain_default_topology_present() {
  local validator value
  for validator in "${1:-$PUBLIC_RPC}" "$LOCAL_VALIDATOR"; do
    if value="$(rpc_state_get_storage "$validator" "$SK_DEFAULT_TOPOLOGY")"; then
      [[ -n "$value" ]] && return 0
      return 1
    fi
  done
  return 2
}

# --- Stall watchdog ---------------------------------------------------------
#
# The failure this catches, from two months of this node's own miner logs: the
# substrate connection degrades, the client loops "call cancelled" ->
# "rebuilding connection" forever (~940 of each per day, one per 90s timeout),
# and the miner never submits again. It does NOT crash, the container stays
# "running", CPU stays pinned at 100% computing attempts nobody will receive,
# and the REST surface keeps answering is_mining=true. Observed windows with
# zero successful submissions: Jul 24-29 (6 days), Aug 1-6 (6 days), and
# Aug 15-31 (17 days), each ended only by a manual restart.
#
# So process liveness, container state and is_mining are all useless as health
# signals — every one of them stayed green through a 17-day stall. What does
# move is forward progress: the miner's view of the chain head, the heads it
# has observed, and the results it has taken back from its workers. The
# watchdog samples those, and only acts when none of them advanced while the
# real chain did.

# Number of the current best block, in decimal. Empty when the endpoint is
# unreachable.
chain_head_number() {
  local endpoint body
  endpoint="$(rpc_endpoint_http "${1:-$PUBLIC_RPC}")"
  body="$(curl -fsS --max-time "${XNODE_RPC_TIMEOUT:-12}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"chain_getHeader","params":[]}' \
    "$endpoint" 2>/dev/null)" || return 1
  [[ -n "$body" ]] || return 1
  printf '%s' "$body" | python3 -c 'import json, sys
try:
    print(int(json.load(sys.stdin)["result"]["number"], 16))
except Exception:
    sys.exit(1)'
}

# Best block the colocated validator has imported. Empty when its RPC does not
# answer — which is itself one of the shapes the stall takes.
validator_head_number() {
  chain_head_number "$LOCAL_VALIDATOR"
}

# Reference head for the "is the chain itself alive?" guard. Public bootnodes
# first; the colocated validator is the fallback, and it is only a fallback
# because a resyncing validator reports its own catch-up height, not the tip.
reference_head_number() {
  local value
  value="$(chain_head_number "$PUBLIC_RPC" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(chain_head_number "$LOCAL_VALIDATOR" 2>/dev/null || true)"
  fi
  echo "$value"
}

# "<head> <heads_observed> <results_received> <uptime>" from the miner REST, or
# empty when it does not answer. uptime is carried because every other number
# here is a process-lifetime counter that resets to zero on restart, which
# without this would read exactly like a frozen counter.
miner_progress_sample() {
  local body
  body="$(status_json 2>/dev/null)" || return 1
  [[ -n "$body" ]] || return 1
  printf '%s' "$body" | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)["data"]
    c = d.get("modes", {}).get("cpu", {}).get("controller", {})
    print(d.get("chain", {}).get("head_number", 0),
          c.get("heads_observed", 0),
          c.get("results_received", 0),
          d.get("uptime_seconds", 0))
except Exception:
    sys.exit(1)'
}

health_state_get() {
  local key="$1"
  [[ -f "$HEALTH_STATE_FILE" ]] || { echo ""; return 0; }
  python3 - "$HEALTH_STATE_FILE" "$key" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        print(json.load(fh).get(sys.argv[2], "") or "")
except Exception:
    print("")
PY
}

# health_state_put key=value ...
health_state_put() {
  mkdir -p "$(dirname "$HEALTH_STATE_FILE")"
  python3 - "$HEALTH_STATE_FILE" "$@" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        state = json.load(fh)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

for pair in sys.argv[2:]:
    key, _, value = pair.partition("=")
    try:
        state[key] = int(value)
    except ValueError:
        state[key] = value

# Write through a temp file so a crash mid-write cannot leave the watchdog
# with a truncated state file it would then treat as a first run.
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=directory)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
os.replace(tmp, path)
PY
}

# Escalating recovery. A plain restart fixes a wedged connection; recreate
# clears in-container state a restart preserves; the full stack pass covers the
# case where the colocated validator is the wedged party, not the miner.
recover_miner_escalate() {
  local level="$1"

  case "$level" in
    1)
      say "Уровень 1: перезапускаю miner контейнер."
      compose restart cpu
      ;;
    2)
      say "Уровень 2: пересоздаю miner контейнер."
      compose up -d --force-recreate --no-deps cpu
      ;;
    *)
      say "Уровень 3: пересоздаю весь stack."
      compose up -d --force-recreate
      ;;
  esac
}

# Returns 0 healthy, 1 stalled (action taken), 2 undetermined.
# Pass "report" to inspect without touching anything.
miner_stall_check() {
  local mode="${1:-act}"
  local now sample head heads results uptime reference
  local prev_head prev_heads prev_results prev_uptime prev_reference
  local last_progress last_action actions stalled_for progressed

  now="$(date -u +%s)"
  reference="$(reference_head_number)"

  if [[ -z "$reference" ]]; then
    warn "Ни один RPC не ответил — состояние сети неизвестно, watchdog ничего не делает."
    return 2
  fi

  sample="$(miner_progress_sample 2>/dev/null || true)"
  if [[ -n "$sample" ]]; then
    read -r head heads results uptime <<< "$sample"
  else
    # REST silent is itself a stall symptom, but it is also what a container
    # that is merely starting looks like, so it counts as "no progress"
    # rather than as an immediate trigger.
    head=""; heads=""; results=""; uptime=""
  fi

  prev_head="$(health_state_get head_number)"
  prev_heads="$(health_state_get heads_observed)"
  prev_results="$(health_state_get results_received)"
  prev_uptime="$(health_state_get uptime_seconds)"
  prev_reference="$(health_state_get reference_head)"
  last_progress="$(health_state_get last_progress_at)"
  last_action="$(health_state_get last_action_at)"
  actions="$(health_state_get stall_actions)"
  [[ "$last_progress" =~ ^[0-9]+$ ]] || last_progress=0
  [[ "$last_action" =~ ^[0-9]+$ ]] || last_action=0
  [[ "$actions" =~ ^[0-9]+$ ]] || actions=0

  # First run, or a state file from before this feature existed: record and go.
  if (( last_progress == 0 )); then
    if [[ "$mode" == "report" ]]; then
      soft "Watchdog: базовой точки ещё нет, оценка появится после первой проверки таймером."
      return 0
    fi
    health_state_put "head_number=${head:-0}" "heads_observed=${heads:-0}" \
      "results_received=${results:-0}" "uptime_seconds=${uptime:-0}" \
      "reference_head=$reference" \
      "last_progress_at=$now" "last_action_at=0" "stall_actions=0"
    say "Watchdog: базовая точка записана, оценка со следующей проверки."
    return 0
  fi

  # A restart — ours, docker's restart policy, or a host reboot — zeroes every
  # counter below. Rebaseline on it, because "counter is lower than last time"
  # is the opposite of a stall and must never be read as one.
  if [[ -n "$uptime" ]] && [[ "$prev_uptime" =~ ^[0-9]+$ ]] && (( uptime < prev_uptime )); then
    if [[ "$mode" != "report" ]]; then
      health_state_put "head_number=$head" "heads_observed=$heads" \
        "results_received=$results" "uptime_seconds=$uptime" \
        "reference_head=$reference" "last_progress_at=$now"
    fi
    say "Watchdog: miner перезапускался (uptime $uptime с), базовая точка обновлена."
    return 0
  fi

  progressed="no"
  if [[ -n "$head" ]]; then
    (( head > ${prev_head:-0} )) && progressed="yes"
    (( heads > ${prev_heads:-0} )) && progressed="yes"
    (( results > ${prev_results:-0} )) && progressed="yes"
  fi

  if [[ "$progressed" == "yes" ]]; then
    if [[ "$mode" == "report" ]]; then
      ok "Watchdog: miner двигается (head=$head heads=$heads results=$results)."
    else
      health_state_put "head_number=$head" "heads_observed=$heads" \
        "results_received=$results" "uptime_seconds=$uptime" \
        "reference_head=$reference" \
        "last_progress_at=$now" "stall_actions=0"
    fi
    return 0
  fi

  # No local progress. Before blaming the miner, confirm the chain moved — a
  # halted testnet or a dead uplink must not trigger a restart loop.
  if [[ "$prev_reference" =~ ^[0-9]+$ ]] && (( reference <= prev_reference )); then
    [[ "$mode" == "report" ]] || health_state_put "reference_head=$reference"
    warn "Watchdog: chain head не растёт ($reference) — проблема на стороне сети, miner не трогаю."
    return 2
  fi

  [[ "$mode" == "report" ]] || health_state_put "reference_head=$reference"
  stalled_for=$(( now - last_progress ))

  if (( stalled_for < STALL_SECONDS )); then
    if [[ "$mode" == "report" ]]; then
      ok "Watchdog: последний прогресс $stalled_for с назад, порог $STALL_SECONDS с — норма."
    else
      warn "Watchdog: прогресса нет $stalled_for с (порог $STALL_SECONDS с). Жду ещё."
    fi
    return 0
  fi

  if [[ "$mode" == "report" ]]; then
    bad "Watchdog: miner застоялся $stalled_for с, chain при этом идёт (head=$reference)."
    return 1
  fi

  # Widen the cooldown as attempts pile up. If restarting is not fixing it the
  # cause is elsewhere (network, chain, disk), and hammering the container
  # every 15 minutes only adds noise and lost rounds.
  local cooldown=$(( STALL_COOLDOWN_SECONDS * ( actions < 4 ? actions + 1 : 4 ) ))
  if (( now - last_action < cooldown )); then
    warn "Watchdog: застой подтверждён, но с прошлого рестарта прошло $(( now - last_action )) с. Жду окончания cooldown ($cooldown с)."
    return 1
  fi

  if (( actions >= 5 )); then
    warn "Watchdog: рестарты не помогают ($actions подряд). Смотри пункт 6 (диагностика) — причина вне miner."
  fi

  actions=$(( actions + 1 ))
  bad "Watchdog: застой $stalled_for с при живой chain (head=$reference). Восстановление, попытка $actions."
  miner_logs_tail 40 | tail -20
  recover_miner_escalate "$actions"

  # Give the container a moment to come up so the next sample is meaningful
  # rather than a second "REST silent" reading.
  sleep 20
  sample="$(miner_progress_sample 2>/dev/null || true)"
  if [[ -n "$sample" ]]; then
    read -r head heads results uptime <<< "$sample"
    health_state_put "head_number=$head" "heads_observed=$heads" \
      "results_received=$results" "uptime_seconds=$uptime"
  fi

  # last_progress is advanced to now so the next window is measured from the
  # restart, not from the original stall; stall_actions keeps climbing until a
  # sample actually shows progress, which is what drives the escalation.
  health_state_put "last_action_at=$now" "last_progress_at=$now" "stall_actions=$actions"
  return 1
}

# --- Validator stall watchdog ----------------------------------------------
#
# The colocated validator fails the same way and just as silently. On this host
# it stopped at block #942302 with the RPC still listening but never answering,
# logging "Timeout while trying to acquire a write lock for the shared trie
# cache" ~170 times while reporting "Syncing 0.0 bps". Before that the kernel
# had been OOM-killing it every few hours (10 kills in 26 hours, always the
# largest RSS on the box). The miner rides public bootnodes by design, so none
# of this stops mining — it just leaves the dashboard's chain view frozen and a
# CPU core burning on a node that will never catch up.

# Head of the public chain only. reference_head_number() falls back to the local
# validator, which would have the validator grading its own homework.
public_head_number() {
  chain_head_number "$PUBLIC_RPC"
}

# Returns 0 healthy/skipped, 1 stalled (action taken), 2 undetermined.
validator_stall_check() {
  local mode="${1:-act}"
  local now head reference prev_head prev_reference
  local last_progress last_action actions stalled_for cooldown

  # Nothing to judge unless the container is supposed to be up. A validator the
  # operator stopped deliberately must stay stopped.
  [[ "$(docker_cli inspect -f '{{.State.Status}}' quip-validator 2>/dev/null || echo missing)" == "running" ]] || return 0

  now="$(date -u +%s)"
  reference="$(public_head_number 2>/dev/null || true)"
  if [[ -z "$reference" ]]; then
    [[ "$mode" == "report" ]] && warn "Validator: публичный RPC не ответил, оценка невозможна."
    return 2
  fi

  head="$(validator_head_number 2>/dev/null || true)"
  prev_head="$(health_state_get validator_head)"
  prev_reference="$(health_state_get validator_reference)"
  last_progress="$(health_state_get validator_progress_at)"
  last_action="$(health_state_get validator_action_at)"
  actions="$(health_state_get validator_actions)"
  [[ "$last_progress" =~ ^[0-9]+$ ]] || last_progress=0
  [[ "$last_action" =~ ^[0-9]+$ ]] || last_action=0
  [[ "$actions" =~ ^[0-9]+$ ]] || actions=0

  if (( last_progress == 0 )); then
    if [[ "$mode" == "report" ]]; then
      soft "Validator: базовой точки ещё нет."
      return 0
    fi
    health_state_put "validator_head=${head:-0}" "validator_reference=$reference" \
      "validator_progress_at=$now" "validator_action_at=0" "validator_actions=0"
    return 0
  fi

  # Substrate resumes from its on-disk head after a restart, so unlike the
  # miner's counters this number does not reset to zero — but a database reset
  # does move it backwards, and that is a rebaseline, not a stall.
  if [[ -n "$head" ]] && [[ "$prev_head" =~ ^[0-9]+$ ]] && (( head < prev_head )); then
    [[ "$mode" == "report" ]] || health_state_put "validator_head=$head" \
      "validator_reference=$reference" "validator_progress_at=$now"
    say "Validator: head пошёл назад ($prev_head -> $head), база сброшена. Обновляю точку отсчёта."
    return 0
  fi

  if [[ -n "$head" ]] && (( head > ${prev_head:-0} )); then
    if [[ "$mode" == "report" ]]; then
      ok "Validator: синхронизируется (best=$head, сеть=$reference, отставание $(( reference - head )))."
    else
      health_state_put "validator_head=$head" "validator_reference=$reference" \
        "validator_progress_at=$now" "validator_actions=0"
    fi
    return 0
  fi

  if [[ "$prev_reference" =~ ^[0-9]+$ ]] && (( reference <= prev_reference )); then
    [[ "$mode" == "report" ]] || health_state_put "validator_reference=$reference"
    warn "Validator: chain head не растёт — проблема на стороне сети, validator не трогаю."
    return 2
  fi

  [[ "$mode" == "report" ]] || health_state_put "validator_reference=$reference"
  stalled_for=$(( now - last_progress ))

  if (( stalled_for < VALIDATOR_STALL_SECONDS )); then
    if [[ "$mode" == "report" ]]; then
      warn "Validator: прогресса нет $stalled_for с (порог $VALIDATOR_STALL_SECONDS с)."
    fi
    return 0
  fi

  if [[ "$mode" == "report" ]]; then
    bad "Validator: завис на $stalled_for с (best=${head:-нет ответа}, сеть=$reference)."
    return 1
  fi

  cooldown=$(( STALL_COOLDOWN_SECONDS * ( actions < 4 ? actions + 1 : 4 ) ))
  if (( now - last_action < cooldown )); then
    warn "Validator: застой подтверждён, cooldown ещё не вышел ($(( now - last_action ))/$cooldown с)."
    return 1
  fi

  actions=$(( actions + 1 ))
  bad "Validator: застой $stalled_for с при живой chain (сеть=$reference). Восстановление, попытка $actions."
  docker_cli logs --tail 15 quip-validator 2>&1 | tail -10

  if (( actions == 1 )); then
    say "Уровень 1: перезапускаю validator."
    compose restart quip-validator
  elif (( actions == 2 )); then
    say "Уровень 2: пересоздаю validator."
    compose up -d --force-recreate --no-deps quip-validator
  else
    # Deliberately not automatic: recreating the database throws away hours of
    # sync, and a validator that will not run after two restarts usually means
    # a corrupt database or a host problem the operator needs to see.
    warn "Validator не поднимается после $actions попыток. Дальше нужен ручной шаг:"
    warn "  ./xnode-quip.sh validator-reset   # пересоздаёт ТОЛЬКО validator DB, keystore не трогает"
    health_state_put "validator_action_at=$now" "validator_actions=$actions"
    return 1
  fi

  health_state_put "validator_action_at=$now" "validator_progress_at=$now" "validator_actions=$actions"
  return 1
}

show_health_status() {
  need_repo || return
  local sample head heads results uptime reference last_progress actions now stalled_for

  section "Watchdog: живость miner"
  now="$(date -u +%s)"
  reference="$(reference_head_number)"
  sample="$(miner_progress_sample 2>/dev/null || true)"
  last_progress="$(health_state_get last_progress_at)"
  actions="$(health_state_get stall_actions)"
  [[ "$last_progress" =~ ^[0-9]+$ ]] || last_progress=0
  [[ "$actions" =~ ^[0-9]+$ ]] || actions=0

  kv "Порог застоя" "$STALL_SECONDS с"
  kv "Cooldown" "$STALL_COOLDOWN_SECONDS с"
  kv "Chain head (сеть)" "${reference:-нет ответа}"

  if [[ -n "$sample" ]]; then
    read -r head heads results uptime <<< "$sample"
    kv "Miner uptime" "$uptime с"
    kv "Miner head" "$head"
    kv "Heads observed" "$heads"
    kv "Results received" "$results"
    if [[ -n "$reference" ]] && (( reference - head > 50 )); then
      warn "Miner отстаёт от сети на $(( reference - head )) блоков."
    fi
  else
    bad "Miner REST не отвечает."
  fi

  if (( last_progress > 0 )); then
    stalled_for=$(( now - last_progress ))
    kv "Прогресс был" "$stalled_for с назад"
  else
    kv "Прогресс был" "ещё не замерялся"
  fi
  kv "Рестартов подряд" "$actions"
  echo
  miner_stall_check report || true

  section "Watchdog: живость validator"
  local vhead vactions
  vhead="$(validator_head_number 2>/dev/null || true)"
  vactions="$(health_state_get validator_actions)"
  [[ "$vactions" =~ ^[0-9]+$ ]] || vactions=0
  kv "Порог застоя" "$VALIDATOR_STALL_SECONDS с"
  kv "Validator best" "${vhead:-RPC не отвечает}"
  kv "Рестартов подряд" "$vactions"
  echo
  validator_stall_check report || true
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

  local topology_rc=0
  chain_default_topology_present || topology_rc=$?

  if (( topology_rc == 0 )); then
    # Container down (e.g. stopped earlier because topology was missing, and it
    # is back now) is the one case that needs a plain start rather than the
    # progress check, which would just read a silent REST.
    if [[ "$(miner_state)" != "running" ]]; then
      say "Topology есть, а miner контейнер не запущен. Поднимаю stack..."
      compose up -d
      return 0
    fi

    # Container is up. That proves nothing — through every historical stall it
    # stayed up and kept reporting is_mining=true — so judge it on forward
    # progress instead.
    miner_stall_check act || true
    validator_stall_check act || true
    return 0
  fi

  if (( topology_rc == 2 )); then
    warn "Ни один RPC не ответил, состояние topology неизвестно. Miner не трогаю."
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
Description=XNODE Quip miner watchdog: restart on stall, resume when topology returns
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$script_path auto-recover
EOF

  $SUDO tee "$timer_file" >/dev/null <<EOF
[Unit]
Description=Run XNODE Quip miner watchdog every 5 minutes

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
  soft "Проверка каждые 5 минут. Watchdog перезапустит miner, если он перестанет двигаться вперёд"
  soft "(порог $STALL_SECONDS с без прогресса при живой chain), и поднимет его, когда вернётся DefaultTopology."
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
4) Показать живость miner (watchdog)
0) Назад
EOF
    read -r -p "Выбор: " choice
    case "$choice" in
      1) install_auto_recover_timer ;;
      2) disable_auto_recover_timer ;;
      3) auto_recover_once; pause ;;
      4) logo; show_health_status; pause ;;
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
  echo "  Miner не может начать PoW без топологии задач; v0.3 coordinator не падает,"
  echo "  а простаивает и пишет: feeder: chain has no mining snapshot (no registered/mineable topology)"
  echo "  Засев делается со стороны Quip: quip-coordinator seed-chain --validator <ws> --sudo-key <sudo>"
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
  chain_state_query "$PUBLIC_RPC" || warn "Public RPC query failed."
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
  chain_state_query "$PUBLIC_RPC" 2>/dev/null | sed 's/^/    /' || echo "    query failed"
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
    # Every field is coalesced: one missing key used to make jq fail and print
    # nothing at all, which is how a schema change silently blanks the status.
    jq -r '
      "  \u001b[1mwallet\u001b[0m                 " + (.data.ss58_address // "unknown"),
      "  \u001b[1mis_mining\u001b[0m              " + (.data.is_mining|tostring),
      "  \u001b[1mregistered\u001b[0m             " + (.data.miner_registered|tostring),
      "  \u001b[1mhead\u001b[0m                   " + ((.data.chain.head_number // "unknown")|tostring),
      "  \u001b[1mproofs\u001b[0m                 " + ((.data.miner_info.proofs_submitted // 0)|tostring) + " submitted, " + ((.data.miner_info.proofs_won // 0)|tostring) + " won"
    ' /tmp/xnode-quip-status.json 2>/dev/null || true
    kv "rpc" "$(active_rpc_url 2>/dev/null || echo unknown)"
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
    if miner_rest_is_mining; then
      say "Miner запущен и майнит."
      return 0
    fi

    if (cd "$REPO_DIR" && docker_cli compose logs --tail=120 cpu 2>/dev/null | grep -q 'destination already funded'); then
      warn "Поймал баг faucet: destination already funded. Отключаю faucet и пересоздаю miner."
      disable_faucet_in_config
      restart_cpu_only
    fi

    if topology_blocker_seen; then
      local topology_rc=0
      chain_default_topology_present || topology_rc=$?
      # rc 2 means the RPC was unreachable; only a confirmed absence (rc 1) is
      # worth stopping the miner over.
      if (( topology_rc == 1 )); then
        explain_topology_blocker
        stop_cpu_only
        return 1
      fi
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
  (cd "$REPO_DIR" && docker_cli compose logs --since=3m cpu 2>/dev/null | grep -Ei 'fatal|traceback|exception|wallet-underfunded|underfunded|destination already funded|connection refused|failed to connect|panic|invalid config|refusing to start' || true)
}

switch_miner_rpc() {
  need_repo || return
  local mode="$1"
  local validators expected backup_file config_backup_file errors

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
  warn "Это advanced-режим. По умолчанию XNODE держит miner на public bootnodes, а локальный validator синхронизирует pruned-базу в фоне."
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
  config_backup_file="$(backup_config_file)"
  say "Backup override: $backup_file"
  say "Backup config: $config_backup_file"

  ACTIVE_VALIDATORS="$validators"
  write_override_file
  set_config_validators "$validators"
  say "Override обновлён. Пересоздаю miner..."

  if ! restart_cpu_only; then
    warn "Recreate miner не удался. Возвращаю прежний override/config."
    restore_override_file "$backup_file"
    restore_config_file "$config_backup_file"
    restart_cpu_only || true
    return 1
  fi

  if ! wait_for_miner 48; then
    warn "Miner не стал is_mining=true. Возвращаю прежний override/config."
    restore_override_file "$backup_file"
    restore_config_file "$config_backup_file"
    restart_cpu_only || true
    wait_for_miner 24 || true
    return 1
  fi

  if [[ -n "$expected" ]] && ! wait_for_rpc_url "$expected" 36; then
    warn "Переключение RPC не подтвердилось. Возвращаю прежний override/config."
    restore_override_file "$backup_file"
    restore_config_file "$config_backup_file"
    restart_cpu_only || true
    wait_for_miner 24 || true
    return 1
  fi

  if [[ -z "$expected" ]]; then
    say "Public mode включён. Active RPC: $(active_rpc_url 2>/dev/null || echo unknown)"
  fi

  errors="$(recent_miner_errors)"
  if [[ -n "$errors" ]]; then
    warn "В свежих логах есть критичные строки. Возвращаю прежний override/config."
    echo "$errors"
    restore_override_file "$backup_file"
    restore_config_file "$config_backup_file"
    restart_cpu_only || true
    wait_for_miner 24 || true
    return 1
  fi

  say "Переключение успешно."
  status_json 2>/dev/null | jq '{is_mining: .data.is_mining, registered: .data.miner_registered, proofs_submitted: (.data.miner_info.proofs_submitted // 0)}' 2>/dev/null || true
  kv "rpc" "$(active_rpc_url 2>/dev/null || echo unknown)"
  pause
}

install_node() {
  logo
  section "Установка / восстановление Quip CPU node"
  kv "Режим" "CPU miner, GPU не нужен"
  kv "Дашборд" "HTTP на :20049, домен не нужен"
  kv "RPC miner" "по умолчанию public bootnodes, чтобы miner не ждал ресинк локального validator"
  kv "Локальный validator" "запускается pruned и синхронизируется в фоне"
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

  validators="$PUBLIC_VALIDATORS"
  say "RPC miner: $validators (public bootnodes, устойчиво при сбросе/ресинке validator)"
  ACTIVE_VALIDATORS="$validators"

  section "Шаг 6/8: Конфигурация"
  faucet_mode="enabled"
  if [[ "$has_keystore" == "yes" ]]; then
    faucet_mode="disabled"
  fi

  write_env_file "$node_name" "$cpuset"
  write_config_file "$node_name" "$cpu_count" "$validators" "$faucet_mode"
  write_override_file
  ok ".env, config.toml и docker-compose.override.yml записаны"

  section "Шаг 7/8: Настройка хоста"
  apply_sysctl_tuning

  section "Шаг 8/8: Запуск Docker stack"
  start_stack

  if wait_for_miner 72; then
    disable_faucet_in_config
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

  # A keystore written by `quip-coordinator keygen` (v0.3) carries the seed and
  # nothing else, so pull the address off the miner's REST surface instead.
  if ! grep -q '"ss58"' "$keystore" 2>/dev/null; then
    echo
    soft "Keystore v0.3 хранит только master_seed_hex; адрес беру из miner REST."
    echo "  ss58: $(wallet_ss58 2>/dev/null || echo unknown)"
    echo "  account_id_hex: $(wallet_account_hex 2>/dev/null || echo unknown)"
  fi

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
    ss58="$(wallet_ss58 2>/dev/null || true)"
    account="$(wallet_account_hex 2>/dev/null || true)"
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
  - Use menu item 13 or ./xnode-quip.sh cleanup to inspect disk and prune old Docker leftovers.
  - Use ./xnode-quip.sh validator-reset to recreate only validator DB with pruning when archive DB grows too much.
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
  kv "Validator pruning" "state=$VALIDATOR_STATE_PRUNING blocks=$VALIDATOR_BLOCKS_PRUNING db-cache=${VALIDATOR_DB_CACHE_MB}MB"
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
  soft "Важно: если validator DB создавался в archive-режиме, обычная Docker-чистка его не уменьшит. Нужен сброс validator DB и запуск с pruning."
}

path_size_gb() {
  local path="$1"
  if [[ -e "$path" ]]; then
    du -sBG "$path" 2>/dev/null | awk '{gsub("G","",$1); print $1+0}'
  else
    echo 0
  fi
}

root_free_gb() {
  df -BG "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4+0}' || echo 0
}

validator_db_gb() {
  path_size_gb "$REPO_DIR/data/validator-data"
}

current_config_validators() {
  local value
  value="$(config_read miner validators 2>/dev/null || true)"
  echo "${value:-$PUBLIC_VALIDATORS}"
}

# faucet_url = "" is how the v0.3 coordinator is told not to auto-fund. An
# absent key means the image default (the public testnet faucet) applies.
current_faucet_mode() {
  local config_file="$REPO_DIR/data/config.toml"
  local override_file="$REPO_DIR/docker-compose.override.yml"
  local value
  [[ -f "$config_file" ]] || { echo "enabled"; return; }
  if ! grep -Eq '^[[:space:]]*faucet_url[[:space:]]*=' "$config_file"; then
    # Pre-v0.3 installs expressed "faucet off" as QUIP_FAUCET_URL: "" in the
    # override. That env var is inert now, but it still records the operator's
    # intent, so carry it across instead of silently re-enabling funding.
    if [[ -f "$override_file" ]] && grep -Eq 'QUIP_FAUCET_URL:[[:space:]]*""' "$override_file"; then
      echo "disabled"
    else
      echo "enabled"
    fi
    return
  fi
  value="$(config_read miner faucet_url 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    echo "disabled"
  else
    echo "enabled"
  fi
}

apply_log_limits_to_override() {
  need_repo || return
  local recreate="${1:-ask}"

  backup_override_file >/dev/null || true
  write_override_file
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

apply_pruned_validator_override() {
  need_repo || return
  local recreate="${1:-ask}"

  backup_override_file >/dev/null || true
  write_override_file
  ok "Override записан: validator pruning state=$VALIDATOR_STATE_PRUNING blocks=$VALIDATOR_BLOCKS_PRUNING db-cache=${VALIDATOR_DB_CACHE_MB}MB"

  warn "Если текущая validator DB была создана как archive, один override не поможет: Substrate хранит pruning mode внутри DB."
  warn "Для применения pruning к старой archive DB нужен пункт сброса validator DB."

  if [[ "$recreate" == "ask" ]]; then
    read -r -p "Пересоздать stack сейчас без удаления DB? [y/N]: " do_recreate || true
    [[ "$do_recreate" =~ ^[Yy]$ ]] || return 0
  fi

  compose up -d
}

wait_for_validator_container() {
  local attempts="${1:-60}"
  local i status restarts

  say "Жду, пока quip-validator запустится без crash-loop..."
  for ((i = 1; i <= attempts; i++)); do
    status="$(docker_cli inspect --format '{{.State.Status}}' quip-validator 2>/dev/null || echo missing)"
    restarts="$(docker_cli inspect --format '{{.RestartCount}}' quip-validator 2>/dev/null || echo 0)"
    if [[ "$status" == "running" ]]; then
      sleep 3
      status="$(docker_cli inspect --format '{{.State.Status}}' quip-validator 2>/dev/null || echo missing)"
      if [[ "$status" == "running" ]]; then
        ok "quip-validator running, restarts=$restarts"
        return 0
      fi
    fi
    if (( i % 6 == 0 )); then
      echo "  validator status=$status restarts=$restarts ($i/$attempts)"
    fi
    sleep 5
  done

  warn "Validator не стал стабильным за отведённое время."
  docker_cli logs --tail=120 quip-validator 2>&1 || true
  return 1
}

reset_validator_db_pruned() {
  need_repo || return
  local quiet="${1:-no}"
  local validator_dir="$REPO_DIR/data/validator-data"
  local before_size

  if [[ "$validator_dir" != "$REPO_DIR"/data/validator-data ]]; then
    fail "Safety check failed for validator dir: $validator_dir"
    return 1
  fi

  before_size="$(dir_size "$validator_dir")"
  section "Сброс validator DB с pruning"
  warn "Будет удалена только локальная validator chain database: $validator_dir"
  warn "Keystore майнера НЕ трогаю: $REPO_DIR/data/keystore.json"
  warn "После сброса validator начнёт синхронизацию заново, но база больше не будет archive."
  kv "Текущий размер" "$before_size"
  kv "Новый pruning" "state=$VALIDATOR_STATE_PRUNING blocks=$VALIDATOR_BLOCKS_PRUNING db-cache=${VALIDATOR_DB_CACHE_MB}MB"

  if [[ "$quiet" != "yes" ]]; then
    read -r -p "Напиши YES чтобы удалить validator DB и пересоздать её: " confirm || true
    if [[ "$confirm" != "YES" ]]; then
      warn "Сброс validator DB отменён."
      pause
      return 0
    fi
  fi

  backup_override_file >/dev/null || true
  write_override_file

  say "Останавливаю validator/dashboard/caddy..."
  compose stop quip-validator dashboard caddy >/dev/null 2>&1 || true
  docker_cli rm -f quip-validator >/dev/null 2>&1 || true

  say "Удаляю старую validator DB ($before_size)..."
  rm -rf --one-file-system "$validator_dir"
  mkdir -p "$validator_dir"

  say "Запускаю stack с pruned validator..."
  compose up -d
  wait_for_validator_container 60 || true

  echo
  ok "Validator DB пересоздана. Было: $before_size, стало: $(dir_size "$validator_dir")"
  kv "Root disk" "$(df -h "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $3 " used / " $4 " free / " $5}')"
  [[ "$quiet" == "yes" ]] || pause
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

storage_guard_auto() {
  need_repo || return
  local size_gb free_gb

  safe_disk_cleanup "yes"
  size_gb="$(validator_db_gb)"
  free_gb="$(root_free_gb)"

  echo
  say "Storage guard: validator_db=${size_gb}G, root_free=${free_gb}G, threshold=${VALIDATOR_RESET_THRESHOLD_GB}G"
  if (( size_gb >= VALIDATOR_RESET_THRESHOLD_GB || free_gb < 12 )); then
    warn "Validator DB слишком большая или свободного места мало. Запускаю автоматический сброс validator DB."
    reset_validator_db_pruned "yes"
  else
    ok "Сброс validator DB не нужен."
  fi
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
  say "Устанавливаю ежедневную автоочистку и storage guard..."
  $SUDO tee "$service_file" >/dev/null <<EOF
[Unit]
Description=XNODE Quip safe storage cleanup and validator DB guard
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$script_path cleanup-auto
EOF

  $SUDO tee "$timer_file" >/dev/null <<'EOF'
[Unit]
Description=Run XNODE Quip storage cleanup daily

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
  soft "Каждый день чистятся Docker leftovers. Если validator DB превысит ${VALIDATOR_RESET_THRESHOLD_GB}G или места станет меньше 12G, она будет пересоздана с pruning."
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
2) Применить лимит Docker logs + pruned validator override
3) Очистить Docker json logs вручную
4) Сбросить validator DB и пересоздать с pruning
5) Запустить автоочистку + storage guard сейчас
6) Включить ежедневную автоочистку + storage guard
7) Выключить автоочистку
0) Назад
EOF
    read -r -p "Выбор: " choice
    case "$choice" in
      1) safe_disk_cleanup ;;
      2) apply_pruned_validator_override "ask"; pause ;;
      3) truncate_docker_logs ;;
      4) reset_validator_db_pruned ;;
      5) storage_guard_auto; pause ;;
      6) install_cleanup_timer ;;
      7) disable_cleanup_timer ;;
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
  show_health_status || true

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
  local topology_rc
  if topology_blocker_seen; then
    say "Проверяю, появилась ли QuantumPow.DefaultTopology перед запуском miner..."
    topology_rc=0
    chain_default_topology_present || topology_rc=$?
    if (( topology_rc == 1 )); then
      explain_topology_blocker
      warn "Miner сейчас не запускаю автоматически, чтобы не тратить баланс на crash-loop."
      read -r -p "Всё равно принудительно перезапустить stack? [y/N]: " force_restart || true
      if [[ ! "$force_restart" =~ ^[Yy]$ ]]; then
        pause
        return
      fi
    fi
  fi
  migrate_env_tags
  migrate_env_mem_limit
  migrate_config_v03 || warn "Миграция config.toml не удалась, проверь data/config.toml вручную."
  migrate_override_file

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

  # Order matters: the freshly pulled compose file points the miner at the v0.3
  # image path, so the stale .env pin has to go before `compose pull` and the
  # config has to be on the v0.3 schema before `compose up`.
  section "Миграция конфигурации"
  migrate_env_tags
  migrate_env_mem_limit
  # Order matters here too: migrate_config_v03 reads the override's legacy
  # faucet marker, so the override is rewritten only afterwards.
  migrate_config_v03 || warn "Миграция config.toml не удалась, проверь data/config.toml вручную."
  migrate_override_file

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
  # Not `[[ ... ]] && pause`: in non-interactive mode the test is false, the
  # AND list yields 1, and being the last command that becomes the function's
  # — and the script's — exit status. `./xnode-quip.sh update` then reports
  # failure after a completely successful update, which breaks every wrapper
  # that checks the exit code.
  if [[ "$confirm" == "ask" ]]; then
    pause
  fi
  return 0
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
  health) logo; show_health_status ;;
  auto-recover-install) install_auto_recover_timer "yes" ;;
  auto-recover-disable) disable_auto_recover_timer "yes" ;;
  restart) restart_node ;;
  stop) stop_node ;;
  check-updates) check_updates_cli ;;
  update) update_node_cli ;;
  cleanup) logo; safe_disk_cleanup ;;
  cleanup-auto) storage_guard_auto ;;
  cleanup-status) logo; show_cleanup_status ;;
  cleanup-install) install_cleanup_timer "yes" ;;
  cleanup-disable) disable_cleanup_timer "yes" ;;
  log-limits) apply_log_limits_to_override "ask" ;;
  storage-guard) logo; storage_guard_auto ;;
  validator-prune-override) apply_pruned_validator_override "ask" ;;
  validator-reset) logo; reset_validator_db_pruned ;;
  rpc-local) switch_miner_rpc local ;;
  rpc-public) switch_miner_rpc public ;;
  *) echo "Usage: $0 [menu|install|preflight|logs|dashboard|wallet|status|ports|backup|auto-recover|auto-recover-status|auto-recover-install|auto-recover-disable|health|restart|stop|check-updates|update|cleanup|cleanup-auto|cleanup-status|cleanup-install|cleanup-disable|log-limits|storage-guard|validator-prune-override|validator-reset|rpc-local|rpc-public]"; exit 1 ;;
esac
