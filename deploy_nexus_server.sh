#!/usr/bin/env bash
set -euo pipefail

# Nexus 验证者 + RPC 入网部署脚本。
# 适用于一台全新 Ubuntu 服务器接入已存在的 Nexus 网络。
# 服务器密码、GitHub Token、验证者助记词等高敏感信息严禁提交到仓库。

# 全局 trap：捕获未处理的错误，打印失败位置和日志路径
LOG_TS_FORMAT="+%Y-%m-%d %H:%M:%S"

log_info() {
  printf '[%s] [信息] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

log_warn() {
  printf '[%s] [警告] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

log_success() {
  printf '[%s] [成功] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

log_todo() {
  printf '[%s] [待办] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

log_sensitive() {
  printf '[%s] [敏感信息] %s\n' "$(date "$LOG_TS_FORMAT")" "$*"
}

_on_error() {
  local exit_code=$?
  local line_no="${BASH_LINENO[0]}"
  local cmd="${BASH_COMMAND}"
  echo
  echo "========================================"
  echo "[致命错误] 脚本在第 ${line_no} 行意外退出（退出码 ${exit_code}）"
  echo "  失败命令：${cmd}"
  if [[ -n "${DEPLOY_LOG_FILE:-}" ]]; then
    echo "  部署日志：${DEPLOY_LOG_FILE}"
  fi
  echo "========================================"
  echo
  echo "[下一步] 请检查上方错误输出，修复问题后重新运行脚本。"
  echo "  如需帮助，请将以上错误信息和部署日志发送给开发团队。"
}
trap '_on_error' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${BASH_SOURCE[0]}"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[错误] 配置文件不存在：$ENV_FILE"
  echo "请先把 deploy.env.example 复制为 deploy.env 并填写真实参数。"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# 自动解析 Chain spec 路径：
# - 未配置 CHAIN 时，默认使用脚本同目录下的 mainnet-raw.json
# - 配置为相对路径时，按脚本同目录解析
# - 配置为旧的绝对路径但文件不存在时，按脚本同目录查找同名文件
resolve_chain_path() {
  local chain_value="${CHAIN:-mainnet-raw.json}"
  local chain_name

  if [[ -f "$chain_value" ]]; then
    CHAIN="$chain_value"
    return
  fi

  if [[ "$chain_value" = /* ]]; then
    chain_name="$(basename "$chain_value")"
  else
    chain_name="$chain_value"
  fi

  if [[ -f "${SCRIPT_DIR}/${chain_name}" ]]; then
    CHAIN="${SCRIPT_DIR}/${chain_name}"
  elif [[ -f "${SCRIPT_DIR}/${chain_name}-raw.json" ]]; then
    CHAIN="${SCRIPT_DIR}/${chain_name}-raw.json"
  else
    CHAIN="$chain_value"
  fi
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[错误] 必填变量为空：$name"
    case "$name" in
      ADMIN_IP)
        echo "  原因：ENABLE_UFW=true 时必须提供管理员公网 IP。"
        echo "  修复：编辑 deploy.env，将 ADMIN_IP 设为你的公网 IP（如 203.0.113.50）。"
        echo "  查询：curl -s ifconfig.me"
        ;;
      CERTBOT_EMAIL)
        echo "  原因：INSTALL_CERTBOT=true 时必须提供真实邮箱，用于 Let's Encrypt 证书过期通知。"
        echo "  修复：编辑 deploy.env，将 CERTBOT_EMAIL 设为运维团队邮箱。"
        ;;
      RPC_DOMAIN)
        echo "  原因：INSTALL_NGINX=true 时必须提供 RPC 域名。"
        echo "  修复：编辑 deploy.env，设置 RPC_DOMAIN（如 rpc.example.com）。"
        ;;
      VALIDATOR_MNEMONIC)
        echo "  原因：需要验证者助记词来派生密钥和注册验证者。"
        echo "  修复：编辑 deploy.env，填入 12 或 24 个单词的 BIP-39 助记词。"
        echo "  生成新助记词：$BIN_INSTALL_PATH key generate --scheme Sr25519 --words 12"
        ;;
      VALIDATOR_ADDRESS)
        echo "  原因：需要与助记词对应的验证者地址（X 开头，SS58 prefix 273）。"
        echo "  修复：编辑 deploy.env，填入与 VALIDATOR_MNEMONIC 对应的地址。"
        ;;
      BOOTNODES)
        echo "  原因：加入现有网络时必须指定至少一个 bootnode。"
        echo "  修复：编辑 deploy.env，填入现网节点的 multiaddr 地址。"
        ;;
      *)
        echo "  修复：编辑 deploy.env，为 $name 填入有效值。"
        ;;
    esac
    exit 1
  fi
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "[错误] 缺少命令：$name"
    exit 1
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "[错误] 请使用 root 身份运行此脚本。"
    exit 1
  fi
}

require_root

validate_bool() {
  local name="$1"
  local value="${!name:-}"
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "[错误] $name 仅支持 true 或 false，当前值：${value:-<empty>}"
    exit 1
  fi
}

validate_port() {
  local name="$1"
  local value="${!name:-}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "[错误] $name 不是合法端口：${value:-<empty>}"
    exit 1
  fi
}

validate_deploy_mode() {
  case "${DEPLOY_MODE:-both}" in
    validator|rpc|both) ;;
    *)
      echo "[错误] DEPLOY_MODE 仅支持 validator、rpc 或 both，当前值：${DEPLOY_MODE:-<empty>}"
      exit 1
      ;;
  esac
}

deploys_validator() {
  [[ "${DEPLOY_MODE:-both}" == "validator" || "${DEPLOY_MODE:-both}" == "both" ]]
}

deploys_rpc() {
  [[ "${DEPLOY_MODE:-both}" == "rpc" || "${DEPLOY_MODE:-both}" == "both" ]]
}

# [修复9] 校验 BOOTNODES multiaddr 格式，拦截占位符和尖括号
validate_bootnodes() {
  local bn="$1"
  if [[ "$bn" == *"<"* || "$bn" == *">"* ]]; then
    echo "[错误] BOOTNODES 包含占位符尖括号，请替换为真实 IP 和 PeerID：$bn"
    exit 1
  fi
  # 逐个检查（空格分隔多个 bootnode）
  for addr in $bn; do
    if [[ ! "$addr" =~ ^/ip[46]/.+/tcp/[0-9]+/p2p/12D3KooW ]]; then
      echo "[错误] BOOTNODES 格式不合法：$addr"
      echo "  期望格式：/ip4/<IP>/tcp/<PORT>/p2p/12D3KooW..."
      exit 1
    fi
  done
}

validate_config() {
  require_var DEPLOY_REF
  require_var BOOTNODES

  validate_deploy_mode

  # [修复9] 校验 BOOTNODES 格式
  validate_bootnodes "$BOOTNODES"

  validate_bool ENABLE_UFW
  validate_bool WRITE_MNEMONIC_FILE
  validate_bool INSTALL_IPFS
  validate_port SSH_PORT

  if [[ "$NODE_USER" != "root" && deploys_validator ]]; then
    echo "[错误] 当前脚本仅稳定支持 validator 使用 NODE_USER=root；RPC 服务会单独降权运行。"
    exit 1
  fi

  if deploys_rpc; then
    validate_bool OPEN_RPC_P2P
    validate_bool INSTALL_NGINX
    validate_bool INSTALL_CERTBOT

    validate_port RPC_P2P_PORT
    validate_port RPC_RPC_PORT
    validate_port RPC_PROM_PORT

    if [[ "$INSTALL_CERTBOT" == "true" && "$INSTALL_NGINX" != "true" ]]; then
      echo "[错误] INSTALL_CERTBOT=true 时必须同时启用 INSTALL_NGINX=true"
      exit 1
    fi

    if [[ "$INSTALL_NGINX" == "true" ]]; then
      require_var RPC_DOMAIN
    fi

    if [[ "$INSTALL_CERTBOT" == "true" ]]; then
      require_var CERTBOT_EMAIL
      if [[ "$CERTBOT_EMAIL" == "ops@example.com" || "$CERTBOT_EMAIL" == *"@example."* ]]; then
        echo "[警告] CERTBOT_EMAIL 仍是示例值：$CERTBOT_EMAIL"
        echo "  证书过期 / 吊销通知将无人接收，90 天后 HTTPS 可能静默中断。"
        echo "  建议：编辑 deploy.env，将 CERTBOT_EMAIL 替换为真实运维邮箱。"
      fi
    fi
  fi

  if deploys_validator; then
    validate_bool REGISTER_VALIDATOR

    validate_port VALIDATOR_P2P_PORT
    validate_port VALIDATOR_RPC_PORT
    validate_port VALIDATOR_PROM_PORT

    # 校验助记词词数
    require_var VALIDATOR_MNEMONIC
    local word_count
    # shellcheck disable=SC2086
    word_count=$(echo $VALIDATOR_MNEMONIC | wc -w)
    if [[ "$word_count" -ne 12 && "$word_count" -ne 24 ]]; then
      echo "[错误] VALIDATOR_MNEMONIC 词数不合法：${word_count} 个单词（期望 12 或 24）"
      echo "  当前值的前两个词：$(echo $VALIDATOR_MNEMONIC | awk '{print $1, $2}')..."
      echo "  修复：编辑 deploy.env，填入合法的 BIP-39 助记词。"
      echo "  生成新助记词：nexus-node key generate --scheme Sr25519 --words 12"
      exit 1
    fi

    require_var VALIDATOR_ADDRESS
    if [[ "$VALIDATOR_ADDRESS" != X* ]]; then
      echo "[错误] VALIDATOR_ADDRESS 必须是 X 开头的地址（SS58 prefix 273）：$VALIDATOR_ADDRESS"
      exit 1
    fi
  fi

  if [[ "$ENABLE_UFW" == "true" ]]; then
    require_var ADMIN_IP
    # 检查 ADMIN_IP 占位符和格式
    if [[ "$ADMIN_IP" == *"<"* || "$ADMIN_IP" == *">"* ]]; then
      echo "[错误] ADMIN_IP 仍是占位符：$ADMIN_IP"
      echo "  修复：编辑 deploy.env，将 ADMIN_IP 替换为你的真实公网 IP。"
      echo "  查询本机公网 IP：curl -s ifconfig.me"
      exit 1
    fi
    if [[ ! "$ADMIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && ! "$ADMIN_IP" =~ ^[0-9a-fA-F:]+$ ]]; then
      echo "[错误] ADMIN_IP 不是合法的 IPv4 或 IPv6 地址：$ADMIN_IP"
      echo "  修复：编辑 deploy.env，填入正确的 IP 地址（如 203.0.113.50）。"
      exit 1
    fi
  fi

  # 校验 chain spec 文件存在
  if [[ ! -f "$CHAIN" ]]; then
    echo "[错误] Chain spec 文件不存在：$CHAIN"
    echo "请确保 mainnet-raw.json 在脚本同目录下，或通过 CHAIN 变量指定路径。"
    exit 1
  fi
}

: "${DEPLOY_MODE:=validator}"
: "${CHAIN:=mainnet-raw.json}"
resolve_chain_path
: "${AUTO_STORAGE:=true}"
: "${STORAGE_MIN_FREE_GB:=20}"
: "${STORAGE_ROOT:=}"
: "${INSTALL_DIR:=}"
: "${BIN_INSTALL_PATH:=/usr/local/bin/nexus-node}"
: "${DATA_ROOT:=}"
: "${LOG_ROOT:=}"
: "${DEPLOY_LOG_DIR:=}"
: "${REGISTER_STATUS_FILE:=}"
: "${VALIDATOR_NAME:=Validator-1}"
: "${RPC_NAME:=RPC-Public}"
: "${VALIDATOR_BASE_PATH:=${DATA_ROOT}/validator}"
: "${RPC_BASE_PATH:=${DATA_ROOT}/rpc}"
: "${VALIDATOR_P2P_PORT:=30333}"
: "${VALIDATOR_RPC_PORT:=9944}"
: "${VALIDATOR_PROM_PORT:=9615}"
: "${RPC_P2P_PORT:=30334}"
: "${RPC_RPC_PORT:=9947}"
: "${RPC_PROM_PORT:=9616}"
: "${SSH_PORT:=22}"
: "${NODE_USER:=root}"
: "${RPC_SERVICE_USER:=nexusrpc}"
: "${ENABLE_UFW:=true}"
: "${OPEN_RPC_P2P:=true}"
: "${INSTALL_NGINX:=true}"
: "${INSTALL_CERTBOT:=true}"
: "${CERTBOT_EMAIL:=}"
: "${GIT_CLONE_DEPTH:=1}"
: "${WRITE_MNEMONIC_FILE:=false}"
: "${MNEMONIC_FILE:=/root/nexus-validator-mnemonic.txt}"
: "${VALIDATOR_MNEMONIC:=}"
: "${VALIDATOR_ADDRESS:=}"
: "${REGISTER_VALIDATOR:=true}"
: "${VALIDATOR_COMMISSION:=100}"
: "${INSTALL_IPFS:=true}"
: "${IPFS_VERSION:=0.40.1}"
: "${IPFS_DIST_BASE:=https://dist.ipfs.tech/kubo}"
: "${IPFS_INSTALL_ROOT:=/opt}"
: "${IPFS_PATH:=}"
: "${IPFS_USER:=root}"

: "${TMUX_SESSION:=nexus}"
: "${DEPLOY_LOCK_FILE:=/tmp/nexus-deploy.lock}"

: "${GITHUB_REPO_URL:=https://github.com/nexus-blockchain/nexus.git}"

choose_storage_root() {
  if [[ -n "${STORAGE_ROOT:-}" ]]; then
    return
  fi

  if [[ "${AUTO_STORAGE}" != "true" ]]; then
    STORAGE_ROOT="/opt/nexus-runtime"
    return
  fi

  local best_mount=""
  local best_avail=0
  local mount avail
  while read -r mount avail; do
    [[ -z "$mount" || -z "$avail" ]] && continue
    case "$mount" in
      /boot|/run|/dev|/dev/shm|/run/lock|/run/user/*|/snap/*) continue ;;
    esac
    if [[ -w "$mount" && "$avail" =~ ^[0-9]+$ && "$avail" -gt "$best_avail" ]]; then
      best_mount="$mount"
      best_avail="$avail"
    fi
  done < <(df -B1 --output=target,avail 2>/dev/null | tail -n +2)

  if [[ -z "$best_mount" ]]; then
    while read -r _ _ _ avail _ mount; do
      [[ -z "$mount" || -z "$avail" ]] && continue
      case "$mount" in
        /boot|/run|/dev|/dev/shm|/run/lock|/run/user/*|/snap/*) continue ;;
      esac
      avail="${avail%B}"
      if [[ -w "$mount" && "$avail" =~ ^[0-9]+$ && "$avail" -gt "$best_avail" ]]; then
        best_mount="$mount"
        best_avail="$avail"
      fi
    done < <(df -PB1 2>/dev/null | tail -n +2)
  fi

  if [[ -z "$best_mount" ]]; then
    STORAGE_ROOT="/opt/nexus-runtime"
    return
  fi

  STORAGE_ROOT="${best_mount%/}/nexus"

  local min_bytes=$((STORAGE_MIN_FREE_GB * 1024 * 1024 * 1024))
  if (( best_avail < min_bytes )); then
    echo "[警告] 最大可用磁盘挂载点 ${best_mount} 仅剩 $((best_avail / 1024 / 1024 / 1024))GB，低于建议值 ${STORAGE_MIN_FREE_GB}GB。"
  fi
}

apply_storage_layout() {
  choose_storage_root
  INSTALL_DIR="${INSTALL_DIR:-${STORAGE_ROOT}/source}"
  DATA_ROOT="${DATA_ROOT:-${STORAGE_ROOT}/data}"
  LOG_ROOT="${LOG_ROOT:-${STORAGE_ROOT}/logs}"
  DEPLOY_LOG_DIR="${DEPLOY_LOG_DIR:-${LOG_ROOT}/deploy}"
  REGISTER_STATUS_FILE="${REGISTER_STATUS_FILE:-${DEPLOY_LOG_DIR}/register-status.json}"
  IPFS_PATH="${IPFS_PATH:-${STORAGE_ROOT}/ipfs}"
  VALIDATOR_BASE_PATH="${VALIDATOR_BASE_PATH:-${DATA_ROOT}/validator}"
  RPC_BASE_PATH="${RPC_BASE_PATH:-${DATA_ROOT}/rpc}"

  export STORAGE_ROOT INSTALL_DIR DATA_ROOT LOG_ROOT DEPLOY_LOG_DIR REGISTER_STATUS_FILE IPFS_PATH VALIDATOR_BASE_PATH RPC_BASE_PATH
}

apply_storage_layout

# [修复3] 移除无条件 require_var RPC_DOMAIN / ADMIN_IP，已在 validate_config 中按条件校验

# [修复2] 安装 libclang-dev 解决 clang-sys 编译失败
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl wget jq git tmux build-essential pkg-config libssl-dev \
    clang libclang-dev cmake llvm-dev libudev-dev protobuf-compiler

  # 安装 Node.js 18+（@polkadot/api 需要 node:* 前缀，最低 Node.js 16；推荐 18 LTS）
  local node_major=""
  if command -v node >/dev/null 2>&1; then
    node_major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  fi
  if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
    log_info "当前 Node.js 版本不满足要求（需要 ≥18），正在安装 Node.js 18 LTS..."
    if [[ -n "$node_major" ]]; then
      echo "  当前版本：$(node --version)"
    fi
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
    log_info "Node.js 已升级至 $(node --version)"
  else
    log_info "Node.js $(node --version) 满足要求"
  fi

  if [[ "$ENABLE_UFW" == "true" ]]; then
    apt-get install -y ufw
  fi
  if deploys_rpc && [[ "$INSTALL_NGINX" == "true" ]]; then
    apt-get install -y nginx
  fi
  if deploys_rpc && [[ "$INSTALL_CERTBOT" == "true" ]]; then
    apt-get install -y certbot python3-certbot-nginx
  fi
}

install_ipfs() {
  if [[ "$INSTALL_IPFS" != "true" ]]; then
    log_info "已跳过 IPFS 安装（INSTALL_IPFS=false）"
    return
  fi

  local version="$IPFS_VERSION"
  if command -v ipfs >/dev/null 2>&1; then
    local installed_version
    installed_version="$(ipfs --version 2>/dev/null | awk '{print $3}')"
    if [[ "$installed_version" == "$version" ]]; then
      log_info "已安装 IPFS Kubo v${version}，跳过下载安装"
      return
    fi
    log_info "当前 IPFS 版本为 ${installed_version:-未知}，将安装 v${version}"
  fi

  local archive_name="kubo_v${version}_linux-amd64.tar.gz"
  local download_url="${IPFS_DIST_BASE}/v${version}/${archive_name}"
  local workdir="${IPFS_INSTALL_ROOT%/}/kubo-v${version}"
  local extract_dir="${workdir}/kubo"

  log_info "开始安装 IPFS Kubo v${version}"
  rm -rf "$workdir"
  mkdir -p "$workdir"
  wget -O "${workdir}/${archive_name}" "$download_url"
  tar -xzf "${workdir}/${archive_name}" -C "$workdir"

  if [[ ! -x "${extract_dir}/install.sh" ]]; then
    echo "[错误] 未找到 Kubo 安装脚本：${extract_dir}/install.sh"
    exit 1
  fi

  bash "${extract_dir}/install.sh"

  if ! command -v ipfs >/dev/null 2>&1; then
    echo "[错误] IPFS 安装完成后仍找不到 ipfs 命令"
    exit 1
  fi

  echo "[信息] $(ipfs --version)"
}

ensure_ipfs_repo() {
  if [[ "$INSTALL_IPFS" != "true" ]]; then
    return
  fi

  mkdir -p "$IPFS_PATH"

  if [[ ! -f "$IPFS_PATH/config" ]]; then
    log_info "初始化 IPFS 仓库：$IPFS_PATH"
    IPFS_PATH="$IPFS_PATH" ipfs init
  else
    log_info "复用现有 IPFS 仓库：$IPFS_PATH"
  fi
}

ensure_rust() {
  if ! command -v cargo >/dev/null 2>&1; then
    curl https://sh.rustup.rs -sSf | sh -s -- -y
  fi
  # shellcheck disable=SC1091
  source /root/.cargo/env
  require_cmd cargo
  require_cmd rustc
}

# [修复6] 从 chain spec 提取 chain id，用于 network key 路径
get_chain_id() {
  local chain_id
  chain_id="$(jq -r '.id // "nexus"' "$CHAIN" 2>/dev/null || echo "nexus")"
  echo "$chain_id"
}

prepare_dirs() {
  local chain_id
  chain_id="$(get_chain_id)"
  mkdir -p "$DATA_ROOT" "$LOG_ROOT" "$DEPLOY_LOG_DIR"
  if deploys_validator; then
    mkdir -p "$VALIDATOR_BASE_PATH" "$VALIDATOR_BASE_PATH/chains/${chain_id}/network"
  fi
  if deploys_rpc; then
    mkdir -p "$RPC_BASE_PATH" "$RPC_BASE_PATH/chains/${chain_id}/network"
  fi
  if [[ "$INSTALL_IPFS" == "true" ]]; then
    mkdir -p "$IPFS_PATH"
  fi
}

ensure_rpc_runtime_user() {
  if ! deploys_rpc; then
    return
  fi

  if ! id -u "$RPC_SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin "$RPC_SERVICE_USER"
  fi

  touch "$LOG_ROOT/rpc.log"
  chown -R "$RPC_SERVICE_USER:$RPC_SERVICE_USER" "$RPC_BASE_PATH"
  chown "$RPC_SERVICE_USER:$RPC_SERVICE_USER" "$LOG_ROOT/rpc.log"
}

setup_logging() {
  mkdir -p "$DEPLOY_LOG_DIR"
  if [[ -z "${DEPLOY_LOG_FILE:-}" ]]; then
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"
  fi
  touch "$DEPLOY_LOG_FILE"
  chmod 600 "$DEPLOY_LOG_FILE"
  exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date "$LOG_TS_FORMAT")" "$line"; done | tee -a "$DEPLOY_LOG_FILE") 2>&1
  log_info "部署日志文件：$DEPLOY_LOG_FILE"
}

clone_repo() {
  if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    echo "[错误] INSTALL_DIR 已存在且不是目录：$INSTALL_DIR"
    exit 1
  fi

  if [[ ! -d "$INSTALL_DIR" ]]; then
    git clone --depth "$GIT_CLONE_DEPTH" "$GITHUB_REPO_URL" "$INSTALL_DIR"
  elif [[ -d "$INSTALL_DIR/.git" ]]; then
    cd "$INSTALL_DIR"
    git remote set-url origin "$GITHUB_REPO_URL"
    git fetch --all --tags
  else
    echo "[错误] INSTALL_DIR 已存在但不是 Git 仓库，请手动处理：$INSTALL_DIR"
    exit 1
  fi

  cd "$INSTALL_DIR"
  git fetch --all --tags
  if ! git checkout "$DEPLOY_REF" 2>&1; then
    echo "[错误] 无法 checkout DEPLOY_REF=$DEPLOY_REF"
    echo "  可用的远程分支："
    git branch -r | head -20
    echo "  可用的标签（最近 10 个）："
    git tag --sort=-creatordate | head -10
    echo
    echo "  修复：编辑 deploy.env，将 DEPLOY_REF 设为上述有效的分支名或标签。"
    exit 1
  fi
  DEPLOY_COMMIT="$(git rev-parse HEAD)"
  log_info "部署提交：$DEPLOY_COMMIT"
}

# [修复1] --locked 失败时自动回退到不带 --locked
build_binary() {
  cd "$INSTALL_DIR"
  # shellcheck disable=SC1091
  source /root/.cargo/env
  if ! cargo build --locked --release; then
    log_warn "cargo build --locked 失败，尝试不带 --locked 编译"
    if ! cargo build --release; then
      echo
      echo "[错误] 编译失败。"
      echo "  常见原因及修复："
      echo "  1. 内存不足：编译 Substrate 需要至少 4GB RAM，建议 8GB+。"
      echo "     检查：free -h"
      echo "     修复：添加 swap 空间 — fallocate -l 8G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
      echo "  2. 磁盘空间不足：编译产物可能占用 10GB+。"
      echo "     检查：df -h /"
      echo "  3. Rust 版本不兼容："
      echo "     检查：rustc --version"
      echo "     更新：rustup update stable"
      echo "  4. 依赖缺失：确保已安装 clang、libclang-dev、protobuf-compiler。"
      echo "     安装：apt-get install -y clang libclang-dev protobuf-compiler"
      echo
      echo "  编译日志已输出在上方，请根据最后的 error 信息排查。"
      exit 1
    fi
  fi
  install -m 0755 "$INSTALL_DIR/target/release/nexus-node" "$BIN_INSTALL_PATH"
  "$BIN_INSTALL_PATH" --version
}

# 从助记词派生并显示 Sr25519 / Ed25519 公钥
inspect_validator_keys() {
  if ! deploys_validator; then
    return
  fi

  log_info "从助记词派生验证者公钥"
  local sr_out ed_out sr_err ed_err

  sr_err="$(mktemp)"
  sr_out="$($BIN_INSTALL_PATH key inspect --scheme Sr25519 "$VALIDATOR_MNEMONIC" 2>"$sr_err")" || true
  VALIDATOR_SR25519_HEX="$(printf '%s\n' "$sr_out" | awk -F': ' '/Public key \(hex\)/ {print $2}')"

  ed_err="$(mktemp)"
  ed_out="$($BIN_INSTALL_PATH key inspect --scheme Ed25519 "$VALIDATOR_MNEMONIC" 2>"$ed_err")" || true
  VALIDATOR_ED25519_HEX="$(printf '%s\n' "$ed_out" | awk -F': ' '/Public key \(hex\)/ {print $2}')"

  if [[ -z "$VALIDATOR_SR25519_HEX" || -z "$VALIDATOR_ED25519_HEX" ]]; then
    echo "[错误] 无法从助记词派生公钥"
    echo
    if [[ -s "$sr_err" ]]; then
      echo "  Sr25519 inspect 错误输出："
      sed 's/^/    /' "$sr_err"
    fi
    if [[ -s "$ed_err" ]]; then
      echo "  Ed25519 inspect 错误输出："
      sed 's/^/    /' "$ed_err"
    fi
    echo
    echo "  常见原因："
    echo "  1. 助记词包含非 BIP-39 词表中的单词（如占位符）。"
    echo "  2. 助记词词数不是 12 或 24。"
    echo "  3. 助记词校验和不正确（最后一个单词由前面的词决定）。"
    echo
    echo "  当前 VALIDATOR_MNEMONIC 前两个词：$(echo $VALIDATOR_MNEMONIC | awk '{print $1, $2}')..."
    echo
    echo "  修复方法："
    echo "  a) 如果已有助记词：检查拼写，确保每个单词都在 BIP-39 英文词表中。"
    echo "  b) 生成新助记词："
    echo "     $BIN_INSTALL_PATH key generate --scheme Sr25519 --words 12 --network nexus"
    echo "     将输出的 Secret phrase 填入 deploy.env 的 VALIDATOR_MNEMONIC。"
    echo "     将输出的 SS58 Address (X 开头) 填入 VALIDATOR_ADDRESS。"
    rm -f "$sr_err" "$ed_err"
    exit 1
  fi

  rm -f "$sr_err" "$ed_err"
  echo "[信息] Validator Address: $VALIDATOR_ADDRESS"
  echo "[信息] Validator Sr25519 hex: $VALIDATOR_SR25519_HEX"
  echo "[信息] Validator Ed25519 hex: $VALIDATOR_ED25519_HEX"
  export VALIDATOR_SR25519_HEX VALIDATOR_ED25519_HEX
}

# [修复6] 使用动态 chain id 路径
generate_network_keys() {
  log_info "正在生成节点网络密钥"
  local chain_id
  chain_id="$(get_chain_id)"

  if deploys_validator; then
    local val_key_file="$VALIDATOR_BASE_PATH/chains/${chain_id}/network/secret_ed25519"
    mkdir -p "$(dirname "$val_key_file")"
    chmod 700 "$(dirname "$val_key_file")"
    if ! VALIDATOR_PEER_ID="$($BIN_INSTALL_PATH key generate-node-key --file "$val_key_file" 2>&1)"; then
      echo "[错误] 生成 Validator 网络密钥失败"
      echo "  输出：$VALIDATOR_PEER_ID"
      echo "  密钥文件路径：$val_key_file"
      echo "  修复：检查目录权限和磁盘空间 — ls -la $(dirname "$val_key_file") && df -h"
      exit 1
    fi
    export VALIDATOR_PEER_ID
  fi

  if deploys_rpc; then
    local rpc_key_file="$RPC_BASE_PATH/chains/${chain_id}/network/secret_ed25519"
    mkdir -p "$(dirname "$rpc_key_file")"
    chmod 700 "$(dirname "$rpc_key_file")"
    if ! RPC_PEER_ID="$($BIN_INSTALL_PATH key generate-node-key --file "$rpc_key_file" 2>&1)"; then
      echo "[错误] 生成 RPC 网络密钥失败"
      echo "  输出：$RPC_PEER_ID"
      echo "  密钥文件路径：$rpc_key_file"
      echo "  修复：检查目录权限和磁盘空间 — ls -la $(dirname "$rpc_key_file") && df -h"
      exit 1
    fi
    export RPC_PEER_ID
  fi
}

insert_session_keys() {
  if ! deploys_validator; then
    return
  fi

  if [[ -z "${VALIDATOR_MNEMONIC:-}" ]]; then
    echo "[错误] VALIDATOR_MNEMONIC 为空"
    exit 1
  fi

  log_info "插入 BABE (Sr25519) session key..."
  if ! "$BIN_INSTALL_PATH" key insert \
    --base-path "$VALIDATOR_BASE_PATH" \
    --chain "$CHAIN" \
    --key-type babe \
    --scheme Sr25519 \
    --suri "$VALIDATOR_MNEMONIC" 2>&1; then
    echo "[错误] 插入 BABE session key 失败"
    echo "  手动重试："
    echo "  $BIN_INSTALL_PATH key insert --base-path $VALIDATOR_BASE_PATH --chain $CHAIN --key-type babe --scheme Sr25519 --suri \"<MNEMONIC>\""
    exit 1
  fi

  log_info "插入 GRANDPA (Ed25519) session key..."
  if ! "$BIN_INSTALL_PATH" key insert \
    --base-path "$VALIDATOR_BASE_PATH" \
    --chain "$CHAIN" \
    --key-type gran \
    --scheme Ed25519 \
    --suri "$VALIDATOR_MNEMONIC" 2>&1; then
    echo "[错误] 插入 GRANDPA session key 失败"
    echo "  手动重试："
    echo "  $BIN_INSTALL_PATH key insert --base-path $VALIDATOR_BASE_PATH --chain $CHAIN --key-type gran --scheme Ed25519 --suri \"<MNEMONIC>\""
    exit 1
  fi
}

write_systemd_units() {
  local verify_err=""

  if deploys_validator; then
    cat >/etc/systemd/system/nexus-validator.service <<EOF
[Unit]
Description=Nexus Validator Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NODE_USER}
ExecStart=${BIN_INSTALL_PATH} \
  --chain ${CHAIN} \
  --base-path ${VALIDATOR_BASE_PATH} \
  --port ${VALIDATOR_P2P_PORT} \
  --rpc-port ${VALIDATOR_RPC_PORT} \
  --prometheus-port ${VALIDATOR_PROM_PORT} \
  --validator \
  --name ${VALIDATOR_NAME} \
  --bootnodes ${BOOTNODES}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_ROOT}/validator.log
StandardError=append:${LOG_ROOT}/validator.log
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  fi

  if deploys_rpc; then
    local rpc_cors
    if [[ "$INSTALL_NGINX" == "true" ]]; then
      rpc_cors="https://${RPC_DOMAIN},http://${RPC_DOMAIN}"
    else
    log_warn "INSTALL_NGINX=false，RPC 将直接暴露在公网端口上，请确认这是有意为之。"
      rpc_cors="http://127.0.0.1:${RPC_RPC_PORT}"
    fi
    cat >/etc/systemd/system/nexus-rpc.service <<EOF
[Unit]
Description=Nexus Public RPC Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RPC_SERVICE_USER}
ExecStart=${BIN_INSTALL_PATH} \
  --chain ${CHAIN} \
  --base-path ${RPC_BASE_PATH} \
  --port ${RPC_P2P_PORT} \
  --rpc-port ${RPC_RPC_PORT} \
  --prometheus-port ${RPC_PROM_PORT} \
  --rpc-external \
  --rpc-cors ${rpc_cors} \
  --rpc-methods Safe \
  --name ${RPC_NAME} \
  --bootnodes ${BOOTNODES}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_ROOT}/rpc.log
StandardError=append:${LOG_ROOT}/rpc.log
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  fi

  systemctl daemon-reload
  if deploys_validator; then
    systemctl enable nexus-validator
    if ! systemd-analyze verify /etc/systemd/system/nexus-validator.service 2>&1; then
      verify_err="nexus-validator.service"
    fi
  fi
  if deploys_rpc; then
    systemctl enable nexus-rpc
    if ! systemd-analyze verify /etc/systemd/system/nexus-rpc.service 2>&1; then
      verify_err="${verify_err:+$verify_err, }nexus-rpc.service"
    fi
  fi

  if [[ -n "$verify_err" ]]; then
    echo "[警告] systemd unit 文件校验有警告：$verify_err"
    echo "  通常非致命，但如果服务无法启动请检查上方输出。"
  fi
}

# [修复10] 配置 logrotate 防止日志填满磁盘
setup_logrotate() {
  cat >/etc/logrotate.d/nexus <<EOF
${LOG_ROOT}/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
  log_info "已配置 logrotate：/etc/logrotate.d/nexus"
}

write_ipfs_systemd_unit() {
  if [[ "$INSTALL_IPFS" != "true" ]]; then
    return
  fi

  cat >/etc/systemd/system/ipfs.service <<EOF
[Unit]
Description=IPFS Kubo Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${IPFS_USER}
Environment=IPFS_PATH=${IPFS_PATH}
ExecStart=$(command -v ipfs) daemon --migrate=true
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ipfs
  if ! systemd-analyze verify /etc/systemd/system/ipfs.service 2>&1; then
    echo "[警告] systemd unit 文件校验有警告：ipfs.service"
    echo "  通常非致命，但如果服务无法启动请检查上方输出。"
  fi
}

start_ipfs_service() {
  if [[ "$INSTALL_IPFS" != "true" ]]; then
    return
  fi

  systemctl restart ipfs
}

write_nginx_http_site() {
  if ! deploys_rpc || [[ "$INSTALL_NGINX" != "true" ]]; then
    return
  fi

  cat >/etc/nginx/sites-available/nexus-rpc <<EOF
server {
    listen 80;
    server_name ${RPC_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${RPC_RPC_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/nexus-rpc /etc/nginx/sites-enabled/nexus-rpc
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

write_nginx_https_site() {
  if ! deploys_rpc || [[ "$INSTALL_NGINX" != "true" ]]; then
    return
  fi

  cat >/etc/nginx/sites-available/nexus-rpc <<EOF
server {
    listen 80;
    server_name ${RPC_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${RPC_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${RPC_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${RPC_DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${RPC_RPC_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/nexus-rpc /etc/nginx/sites-enabled/nexus-rpc
  nginx -t
  systemctl reload nginx
}

# [修复7+8] certbot 失败不中断部署，记录状态供 summary 使用
CERTBOT_OK="false"

obtain_cert() {
  if ! deploys_rpc || [[ "$INSTALL_NGINX" != "true" || "$INSTALL_CERTBOT" != "true" ]]; then
    return
  fi

  if certbot --nginx --non-interactive --agree-tos -m "$CERTBOT_EMAIL" -d "$RPC_DOMAIN"; then
    CERTBOT_OK="true"
    write_nginx_https_site
  else
    log_warn "Certbot 证书申请失败（DNS 可能尚未解析到本机 IP）。"
    log_warn "节点部署将继续，HTTPS 稍后可手动配置：certbot --nginx -d $RPC_DOMAIN"
  fi
}

ensure_ufw_rule() {
  local rule="$1"
  if ! ufw status | grep -Fqx "$rule"; then
    ufw allow $rule
  fi
}

configure_ufw() {
  if [[ "$ENABLE_UFW" != "true" ]]; then
    return
  fi

  ufw default deny incoming
  ufw default allow outgoing
  ensure_ufw_rule "from $ADMIN_IP to any port $SSH_PORT proto tcp"

  # 启用防火墙前验证 SSH 规则已写入，防止 lockout
  if ! ufw status | grep -q "$SSH_PORT"; then
    echo "[错误] SSH 端口 ${SSH_PORT} 的 UFW 规则未成功写入"
    echo "  如果此时启用防火墙，你将被锁在服务器外面！"
    echo "  修复："
    echo "  1. 检查 ADMIN_IP 是否正确：当前值 = $ADMIN_IP"
    echo "  2. 手动添加规则：ufw allow from $ADMIN_IP to any port $SSH_PORT proto tcp"
    echo "  3. 确认后重新运行脚本。"
    exit 1
  fi

  if deploys_rpc && [[ "$INSTALL_NGINX" == "true" ]]; then
    ensure_ufw_rule "80/tcp"
    ensure_ufw_rule "443/tcp"
  fi
  if deploys_validator; then
    ensure_ufw_rule "${VALIDATOR_P2P_PORT}/tcp"
  fi
  if deploys_rpc && [[ "$OPEN_RPC_P2P" == "true" ]]; then
    ensure_ufw_rule "${RPC_P2P_PORT}/tcp"
  fi
  ufw --force enable
}

start_services() {
  if deploys_validator; then
    systemctl restart nexus-validator
  fi
  if deploys_rpc; then
    ensure_rpc_runtime_user
    systemctl restart nexus-rpc
  fi
}

wait_rpc_ready() {
  local name="$1"
  local port="$2"
  local rpc="http://127.0.0.1:${port}"
  local max_wait=180
  local elapsed=0

  log_info "等待 ${name} RPC 就绪：${rpc}"
  while (( elapsed < max_wait )); do
    local response
    response="$(curl -s -H 'Content-Type: application/json' \
      -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
      "$rpc" 2>/dev/null || echo "")"
    if [[ "$(echo "$response" | jq -r 'has("result")' 2>/dev/null || echo false)" == "true" ]]; then
      log_info "${name} RPC 已就绪"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  log_error "${name} RPC 在 ${max_wait}s 内未就绪：${rpc}"
  return 1
}

verify_public_rpc() {
  if ! deploys_rpc || [[ "$INSTALL_NGINX" != "true" ]]; then
    return 0
  fi

  local scheme="http"
  if [[ "$INSTALL_CERTBOT" == "true" && "$CERTBOT_OK" == "true" ]]; then
    scheme="https"
  fi

  local endpoint="${scheme}://127.0.0.1/"
  local response
  response="$(curl -s -H "Host: ${RPC_DOMAIN}" -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
    "$endpoint" 2>/dev/null || echo "")"

  if [[ "$(echo "$response" | jq -r 'has("result")' 2>/dev/null || echo false)" != "true" ]]; then
    log_error "公网 RPC 反代探测失败：${scheme}://${RPC_DOMAIN}"
    return 1
  fi

  log_success "公网 RPC 反代探测通过：${scheme}://${RPC_DOMAIN}"
  return 0
}

verify_deployment() {
  log_info "开始验证部署结果..."
  local failed=0

  if deploys_validator; then
    if systemctl is-active --quiet nexus-validator; then
      log_success "nexus-validator 服务正在运行"
    else
      log_error "nexus-validator 服务未运行"
      failed=1
    fi

    if wait_rpc_ready "验证者节点" "$VALIDATOR_RPC_PORT"; then
      local rpc="http://127.0.0.1:${VALIDATOR_RPC_PORT}"
      local health sync_state genesis_hash
      health="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
        "$rpc" 2>/dev/null || echo "")"
      sync_state="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_syncState","params":[]}' \
        "$rpc" 2>/dev/null || echo "")"
      genesis_hash="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"chain_getBlockHash","params":[0]}' \
        "$rpc" 2>/dev/null | jq -r '.result // empty')"
      echo "[信息] 验证者节点健康状态：$health"
      echo "[信息] 验证者节点同步状态：$sync_state"
      echo "[信息] 验证者节点 genesis hash：${genesis_hash:-unknown}"
    else
      failed=1
    fi
  fi

  if deploys_rpc; then
    if systemctl is-active --quiet nexus-rpc; then
      log_success "nexus-rpc 服务正在运行"
    else
      log_error "nexus-rpc 服务未运行"
      failed=1
    fi

    if deploys_rpc && [[ "$INSTALL_NGINX" == "true" ]]; then
      if systemctl is-active --quiet nginx; then
        log_success "nginx 服务正在运行"
      else
        log_error "nginx 服务未运行"
        failed=1
      fi
    fi

    if wait_rpc_ready "RPC 节点" "$RPC_RPC_PORT"; then
      local rpc="http://127.0.0.1:${RPC_RPC_PORT}"
      local health sync_state genesis_hash
      health="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
        "$rpc" 2>/dev/null || echo "")"
      sync_state="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_syncState","params":[]}' \
        "$rpc" 2>/dev/null || echo "")"
      genesis_hash="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"chain_getBlockHash","params":[0]}' \
        "$rpc" 2>/dev/null | jq -r '.result // empty')"
      echo "[信息] RPC 节点健康状态：$health"
      echo "[信息] RPC 节点同步状态：$sync_state"
      echo "[信息] RPC 节点 genesis hash：${genesis_hash:-unknown}"
      if ! verify_public_rpc; then
        failed=1
      fi
      if [[ "$INSTALL_NGINX" == "true" && "$INSTALL_CERTBOT" == "true" && "$CERTBOT_OK" != "true" ]]; then
        echo "[错误] 已请求 HTTPS，但证书尚未就绪；公网 HTTPS 交付未完成。"
        failed=1
      fi
    else
      failed=1
    fi
  fi

  if [[ "$INSTALL_IPFS" == "true" ]]; then
    if systemctl is-active --quiet ipfs; then
      log_success "ipfs 服务正在运行"
    else
      log_error "ipfs 服务未运行"
      failed=1
    fi
  fi

  if (( failed != 0 )); then
    log_error "部署结果验证失败，请查看上方日志和 systemd 状态。"
    return 1
  fi

  log_success "部署结果验证通过。"
}

# 等待验证者节点同步到最新区块
wait_sync() {
  log_info "等待验证者节点同步..."
  local rpc="http://127.0.0.1:${VALIDATOR_RPC_PORT}"
  local elapsed=0

  while true; do
    local health
    health="$(curl -s -H 'Content-Type: application/json' \
      -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
      "$rpc" 2>/dev/null || echo "")"

    if [[ -n "$health" ]]; then
      local is_syncing
      is_syncing="$(echo "$health" | jq -r 'if .result.isSyncing == false then "false" else "true" end')"
      if [[ "$is_syncing" == "false" ]]; then
        log_info "节点已同步到最新区块"
        return 0
      fi
    fi

    sleep 10
    elapsed=$((elapsed + 10))
    if (( elapsed % 60 == 0 )); then
      local sync_state
      sync_state="$(curl -s -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_syncState","params":[]}' \
        "$rpc" 2>/dev/null || echo "(无法获取同步状态)")"
      log_info "仍在同步，已等待 ${elapsed}s..."
      echo "  节点健康状态：$health"
      echo "  同步进度：$sync_state"
    fi
  done
}

write_register_status() {
  local status="$1"
  local message="$2"
  local submitted_steps="${3:-[]}"
  local tx_hashes="${4:-[]}"
  local bonded_state="${5:-false}"
  local validate_state="${6:-false}"
  local keys_state="${7:-false}"

  mkdir -p "$(dirname "$REGISTER_STATUS_FILE")"
  cat > "$REGISTER_STATUS_FILE" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "validatorAddress": $(jq -Rn --arg v "$VALIDATOR_ADDRESS" '$v'),
  "status": $(jq -Rn --arg v "$status" '$v'),
  "message": $(jq -Rn --arg v "$message" '$v'),
  "submittedSteps": ${submitted_steps},
  "txHashes": ${tx_hashes},
  "bonded": ${bonded_state},
  "validatorRegistered": ${validate_state},
  "sessionKeysRegistered": ${keys_state}
}
EOF
  chmod 600 "$REGISTER_STATUS_FILE"
}

# 链上注册验证者：bond + setKeys + validate
register_validator() {
  if ! deploys_validator || [[ "$REGISTER_VALIDATOR" != "true" ]]; then
    return
  fi

  log_info "开始链上验证者注册..."
  log_info "注册状态摘要文件：$REGISTER_STATUS_FILE"

  # 安装 @polkadot/api 依赖
  local node_ver
  node_ver="$(node --version 2>/dev/null || echo "未安装")"
  local node_major="${node_ver#v}"
  node_major="${node_major%%.*}"
  if [[ "$node_ver" == "未安装" || "$node_major" -lt 18 ]]; then
    echo "[错误] Node.js 版本不满足要求：当前 $node_ver，需要 ≥18"
    echo "  修复：curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && apt-get install -y nodejs"
    echo "  安装后重新运行脚本。"
    return 1
  fi

  local tmpdir="/tmp/nexus-register-$$"
  mkdir -p "$tmpdir"
  cd "$tmpdir"
  cat > package.json <<'PKGJSON'
{"name":"nexus-register","private":true,"dependencies":{"@polkadot/api":"^16.5.4","@polkadot/keyring":"^14.0.1","@polkadot/util-crypto":"^14.0.1"}}
PKGJSON
  npm install --production 2>&1 | tail -5

  # 执行注册
  local ws_url="ws://127.0.0.1:${VALIDATOR_RPC_PORT}"
  local rpc_http_url="http://127.0.0.1:${VALIDATOR_RPC_PORT}"
  local commission="${VALIDATOR_COMMISSION}"
  local dry_run="${REGISTER_DRY_RUN:-false}"

  RPC_HTTP_URL="$rpc_http_url" REGISTER_STATUS_FILE="$REGISTER_STATUS_FILE" REGISTER_DRY_RUN="$dry_run" node -e "
const fs = require('fs');
const { ApiPromise, WsProvider, Keyring } = require('@polkadot/api');
const { cryptoWaitReady } = require('@polkadot/util-crypto');

function writeRegisterStatus(payload) {
  fs.writeFileSync(process.env.REGISTER_STATUS_FILE, JSON.stringify({
    timestamp: new Date().toISOString(),
    validatorAddress: '${VALIDATOR_ADDRESS}',
    ...payload
  }, null, 2));
}

async function rotateSessionKeys() {
  const response = await fetch(process.env.RPC_HTTP_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'author_rotateKeys', params: [] })
  });
  const payload = await response.json();
  if (!payload.result) {
    throw new Error(payload.error?.message || 'author_rotateKeys 返回空结果');
  }
  return payload.result;
}

function normalizeValue(value) {
  if (value == null) return null;
  if (typeof value === 'string') return value.toLowerCase();
  if (Array.isArray(value)) return value.map(normalizeValue);
  if (typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = normalizeValue(v);
    return out;
  }
  return value;
}

function hasMeaningfulValidatorPrefs(prefs) {
  if (!prefs) return false;
  if (typeof prefs.isEmpty === 'boolean') return !prefs.isEmpty;
  const human = prefs.toHuman ? prefs.toHuman() : prefs;
  if (human == null) return false;
  if (typeof human === 'object' && Object.keys(human).length === 0) return false;
  return true;
}

const dryRun = process.env.REGISTER_DRY_RUN === 'true';

async function main() {
  await cryptoWaitReady();

  const provider = new WsProvider('${ws_url}');
  const api = await ApiPromise.create({ provider });

  const keyring = new Keyring({ type: 'sr25519', ss58Format: 273 });
  const validator = keyring.addFromUri('${VALIDATOR_MNEMONIC}');
  const expectedAddress = '${VALIDATOR_ADDRESS}';

  if (validator.address !== expectedAddress) {
    writeRegisterStatus({
      status: 'failed',
      message: '助记词派生地址与 VALIDATOR_ADDRESS 不匹配',
      submittedSteps: [],
      txHashes: [],
      bonded: false,
      validatorRegistered: false,
      sessionKeysRegistered: false
    });
    console.error('[错误] 助记词派生地址与 VALIDATOR_ADDRESS 不匹配');
    console.error('  派生地址:', validator.address);
    console.error('  期望地址:', expectedAddress);
    console.error();
    console.error('  修复：编辑 deploy.env，确保 VALIDATOR_ADDRESS 与 VALIDATOR_MNEMONIC 对应。');
    console.error('  验证：nexus-node key inspect --scheme Sr25519 \"<MNEMONIC>\"');
    process.exit(1);
  }
  console.log('[信息] 验证者地址:', validator.address);
  if (dryRun) {
    console.log('[信息] dry-run 模式：只检查，不旋转 keys，不提交交易');
  }

  const { data: balance } = await api.query.system.account(validator.address);
  const free = balance.free.toBigInt();
  console.log('[信息] 可用余额:', free.toString());

  const bonded = await api.query.staking.bonded(validator.address);
  const commissionPerbill = ${commission} * 10000000;
  const validatorPrefs = await api.query.staking.validators(validator.address);
  const validateAlreadyDone = hasMeaningfulValidatorPrefs(validatorPrefs);

  if (free === 0n) {
    writeRegisterStatus({
      status: 'failed',
      message: '账户余额为 0，无法质押',
      submittedSteps: [],
      txHashes: [],
      bonded: !bonded.isNone,
      validatorRegistered: validateAlreadyDone,
      sessionKeysRegistered: false
    });
    console.error('[错误] 账户余额为 0，无法质押');
    console.error('  地址:', validator.address);
    console.error();
    console.error('  修复：先向该地址转入 NEX 代币，然后重新运行注册。');
    console.error('  手动注册脚本位于：/tmp/nexus-register-*/');
    console.error('  或设置 REGISTER_VALIDATOR=false 跳过自动注册，后续通过 polkadot.js 手动操作。');
    process.exit(1);
  }

  let nextKeysQueryAvailable = typeof api.query.session?.nextKeys === 'function';
  let onChainNextKeys = null;
  if (nextKeysQueryAvailable) {
    try {
      onChainNextKeys = await api.query.session.nextKeys(validator.address);
    } catch (error) {
      console.log('[警告] 读取 session.nextKeys 失败，将使用保守 fallback:', error.message);
      nextKeysQueryAvailable = false;
    }
  }

  const needsBond = bonded.isNone;
  const needsValidate = !validateAlreadyDone;
  let needsSetKeys = false;

  if (nextKeysQueryAvailable) {
    needsSetKeys = !onChainNextKeys || (typeof onChainNextKeys.isNone === 'boolean' ? onChainNextKeys.isNone : !normalizeValue(onChainNextKeys.toJSON ? onChainNextKeys.toJSON() : onChainNextKeys));
  } else {
    needsSetKeys = !validateAlreadyDone;
    if (!nextKeysQueryAvailable) {
      console.log('[警告] 当前 runtime 不支持稳定读取 session.nextKeys；若已完成 validator 注册，将保守跳过重复 setKeys。');
    }
  }

  const txs = [];
  const submittedSteps = [];
  const txHashes = [];
  let desiredSessionKeys = null;

  if (needsBond) {
    const existentialDeposit = api.consts.balances.existentialDeposit.toBigInt();
    const reserveForFees = free / 100n > existentialDeposit ? free / 100n : existentialDeposit * 10n;
    const bondAmount = free - reserveForFees;
    console.log('[信息] 质押金额:', bondAmount.toString());
    txs.push(api.tx.staking.bond(bondAmount, 'Staked'));
    submittedSteps.push('bond');
  } else {
    console.log('[信息] 已有 bond，跳过 bond 步骤');
  }

  if (needsSetKeys && dryRun) {
    console.log('[信息] dry-run：检测到仍需 setKeys，正式执行时才会 rotateSessionKeys');
  } else if (needsSetKeys) {
    desiredSessionKeys = await rotateSessionKeys();
    console.log('[信息] Session Keys:', desiredSessionKeys);

    if (nextKeysQueryAvailable) {
      const currentKeys = normalizeValue(onChainNextKeys?.toJSON ? onChainNextKeys.toJSON() : onChainNextKeys);
      const desiredKeys = normalizeValue(desiredSessionKeys);
      if (currentKeys && JSON.stringify(currentKeys) === JSON.stringify(desiredKeys)) {
        console.log('[信息] 链上 session keys 已匹配，跳过 setKeys');
        needsSetKeys = false;
      }
    }
  } else {
    console.log('[信息] 已检测到链上 session keys，跳过 setKeys');
  }

  if (needsSetKeys) {
    if (!dryRun) {
      txs.push(api.tx.session.setKeys(desiredSessionKeys, '0x'));
    }
    submittedSteps.push('setKeys');
  }

  if (needsValidate) {
    if (!dryRun) {
      txs.push(api.tx.staking.validate({ commission: commissionPerbill, blocked: false }));
    }
    submittedSteps.push('validate');
  } else {
    console.log('[信息] 已检测到 validator 注册信息，跳过 validate');
  }

  if (dryRun) {
    const message = submittedSteps.length === 0
      ? 'dry-run 检查完成：当前已完成注册，无需提交交易'
      : 'dry-run 检查完成：若正式执行 register，将提交缺失步骤';
    writeRegisterStatus({
      status: 'dry_run',
      message,
      submittedSteps,
      txHashes,
      bonded: !bonded.isNone,
      validatorRegistered: validateAlreadyDone,
      sessionKeysRegistered: !needsSetKeys
    });
    console.log('[信息] dry-run bonded:', !bonded.isNone);
    console.log('[信息] dry-run validatorRegistered:', validateAlreadyDone);
    console.log('[信息] dry-run sessionKeysRegistered:', !needsSetKeys);
    console.log('[信息] dry-run 待补齐步骤:', JSON.stringify(submittedSteps));
    console.log(submittedSteps.length === 0
      ? '[完成] dry-run：当前已完成注册，无需执行任何交易'
      : '[完成] dry-run：如果现在执行 register，将提交上述步骤');
    await api.disconnect();
    return;
  }

  if (txs.length === 0) {
    writeRegisterStatus({
      status: 'already_complete',
      message: '验证者已完成注册配置，无需重复提交交易',
      submittedSteps,
      txHashes,
      bonded: !bonded.isNone,
      validatorRegistered: validateAlreadyDone,
      sessionKeysRegistered: !needsSetKeys
    });
    console.log('[完成] 验证者已完成注册配置，无需重复提交交易');
    await api.disconnect();
    return;
  }

  if (api.tx.utility) {
    const batch = api.tx.utility.batchAll(txs);
    const hash = await batch.signAndSend(validator);
    txHashes.push(hash.toHex());
    console.log('[信息] 批量交易已发送:', hash.toHex());
  } else {
    console.log('[信息] utility pallet 不可用，逐笔发送交易...');
    for (let i = 0; i < txs.length; i++) {
      const hash = await txs[i].signAndSend(validator);
      txHashes.push(hash.toHex());
      console.log('[信息] 交易 ' + (i + 1) + '/' + txs.length + ' 已发送:', hash.toHex());
      if (i < txs.length - 1) {
        await new Promise(r => setTimeout(r, 6000));
      }
    }
  }

  const bondedAfter = await api.query.staking.bonded(validator.address);
  const validatorPrefsAfter = await api.query.staking.validators(validator.address);
  const validateAfterDone = hasMeaningfulValidatorPrefs(validatorPrefsAfter);
  let keysAfterDone = !nextKeysQueryAvailable;
  if (nextKeysQueryAvailable) {
    const nextKeysAfter = await api.query.session.nextKeys(validator.address);
    const normalizedAfter = normalizeValue(nextKeysAfter?.toJSON ? nextKeysAfter.toJSON() : nextKeysAfter);
    const normalizedDesired = normalizeValue(desiredSessionKeys);
    keysAfterDone = normalizedDesired ? JSON.stringify(normalizedAfter) === JSON.stringify(normalizedDesired) : !!normalizedAfter;
  }

  if ((!needsBond || !bondedAfter.isNone) && (!needsValidate || validateAfterDone) && (!needsSetKeys || keysAfterDone)) {
    writeRegisterStatus({
      status: 'submitted_missing_steps',
      message: '验证者注册状态已补齐或保持正确，可安全重复执行本命令',
      submittedSteps,
      txHashes,
      bonded: !bondedAfter.isNone,
      validatorRegistered: validateAfterDone,
      sessionKeysRegistered: keysAfterDone
    });
    console.log('[完成] 验证者注册状态已补齐或保持正确，可安全重复执行本命令');
  } else {
    writeRegisterStatus({
      status: 'partially_confirmed',
      message: '注册交易已提交；若链上状态尚未完全更新，可稍后重试本命令补齐剩余步骤。',
      submittedSteps,
      txHashes,
      bonded: !bondedAfter.isNone,
      validatorRegistered: validateAfterDone,
      sessionKeysRegistered: keysAfterDone
    });
    console.log('[信息] 注册交易已提交；若链上状态尚未完全更新，可稍后重试本命令补齐剩余步骤。');
  }

  await api.disconnect();
}

main().catch(e => {
  writeRegisterStatus({
    status: 'failed',
    message: e.message,
    submittedSteps: typeof submittedSteps !== 'undefined' ? submittedSteps : [],
    txHashes: typeof txHashes !== 'undefined' ? txHashes : [],
    bonded: false,
    validatorRegistered: false,
    sessionKeysRegistered: false
  });
  console.error('[错误] 验证者注册失败:', e.message);
  console.error();
  console.error('  常见原因：');
  console.error('  1. 节点未完全同步 — 等待同步完成后重试。');
  console.error('  2. WebSocket 连接失败 — 检查节点是否在运行：systemctl status nexus-validator');
  console.error('  3. 交易被拒绝 — 检查账户余额和 nonce。');
  console.error();
  console.error('  手动注册步骤：');
  console.error('  1. 打开 polkadot.js Apps 连接到 ws://127.0.0.1:${VALIDATOR_RPC_PORT}');
  console.error('  2. 导入验证者账户助记词');
  console.error('  3. 执行 staking.bond → session.setKeys → staking.validate');
  process.exit(1);
});
"

  # 清理临时目录
  rm -rf "$tmpdir"
}

print_summary() {
  local rpc_http_url="http://127.0.0.1:${RPC_RPC_PORT}"
  local public_http_url="http://${RPC_DOMAIN:-127.0.0.1}"
  local public_ws_url="ws://${RPC_DOMAIN:-127.0.0.1}"

  if [[ "$CERTBOT_OK" == "true" ]]; then
    public_http_url="https://${RPC_DOMAIN}"
    public_ws_url="wss://${RPC_DOMAIN}"
  fi

  cat <<EOF

[完成] 部署步骤已执行完成。

部署模式：
  DEPLOY_MODE=${DEPLOY_MODE}

代码仓库：
  GITHUB_REPO_URL=${GITHUB_REPO_URL}
  DEPLOY_REF=${DEPLOY_REF}
  DEPLOY_COMMIT=${DEPLOY_COMMIT:-unknown}

Chain Spec：
  CHAIN=${CHAIN}
EOF

  if deploys_validator; then
    cat <<EOF

验证者账户：
  地址=${VALIDATOR_ADDRESS}
  Sr25519 hex=${VALIDATOR_SR25519_HEX:-unknown}
  Ed25519 hex=${VALIDATOR_ED25519_HEX:-unknown}

验证者 PeerId：
  VALIDATOR_PEER_ID=${VALIDATOR_PEER_ID:-unknown}

验证者服务状态命令：
  systemctl status nexus-validator --no-pager

验证者日志查看命令：
  tail -f ${LOG_ROOT}/validator.log
EOF
  fi

  if deploys_rpc; then
    cat <<EOF

RPC PeerId：
  RPC_PEER_ID=${RPC_PEER_ID:-unknown}

RPC 服务状态命令：
  systemctl status nexus-rpc --no-pager
  systemctl status nginx --no-pager

RPC 日志查看命令：
  tail -f ${LOG_ROOT}/rpc.log
  journalctl -u nginx -n 100 --no-pager

IPFS 服务状态命令：
  systemctl status ipfs --no-pager

IPFS 日志查看命令：
  journalctl -u ipfs -f

RPC 访问地址：
  本机直连：${rpc_http_url}
  公网 HTTP/HTTPS：${public_http_url}
  公网 WS/WSS：${public_ws_url}
EOF
  fi

  cat <<EOF

现网 Bootnodes：
  BOOTNODES=${BOOTNODES}

部署日志文件：
  ${DEPLOY_LOG_FILE}

重要提醒：
- 立即离线备份验证者助记词。
- 不要把助记词、keystore、network secret key 提交到 Git。
- 当前节点通过 BOOTNODES 接入现有网络，不创建也不修改创世配置。
EOF

  if deploys_validator; then
    cat <<EOF
- 请按现网治理 / staking 流程完成验证者账户充值、bond、session key 注册、validate 等链上操作。
EOF
  fi

  if [[ "$CERTBOT_OK" != "true" && "$INSTALL_CERTBOT" == "true" ]] && deploys_rpc; then
    echo
    log_warn "HTTPS 证书未成功申请，公网 HTTPS 交付未完成。DNS 解析就绪后请补跑 certbot。"
    echo "  certbot --nginx --non-interactive --agree-tos -m $CERTBOT_EMAIL -d $RPC_DOMAIN"
    echo "  systemctl status nexus-rpc nginx --no-pager"
    echo "  curl -s -H 'Host: $RPC_DOMAIN' -H 'Content-Type: application/json' -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"system_health\",\"params\":[]}' http://127.0.0.1/ | jq"
  fi

  if [[ "$WRITE_MNEMONIC_FILE" == "true" ]] && deploys_validator; then
    echo
    echo "[敏感信息] 验证者助记词已写入受限文件：$MNEMONIC_FILE"
  fi
}

print_runtime_status() {
  log_info "tmux 会话："
  if command -v tmux >/dev/null 2>&1; then
    tmux ls 2>/dev/null || echo "未发现 tmux 会话"
  else
    echo "tmux 未安装"
  fi

  echo
  log_info "相关进程："
  pgrep -af 'cargo|rustc|nexus-node|wasm-opt|rocksdb' || echo "未发现相关进程"

  echo
  log_info "监听端口："
  ss -lntp 2>/dev/null | grep -E '9944|9947|9933|30333|30334|nexus' || echo "未发现常见节点端口"

  echo
  log_info "systemd 服务："
  systemctl --no-pager --full status nexus-validator nexus-rpc ipfs 2>/dev/null || true

  if deploys_rpc && [[ "$INSTALL_NGINX" == "true" ]]; then
    echo
    log_info "Nginx 状态："
    systemctl status nginx --no-pager || true
  fi

  echo
  log_info "最近一次注册摘要："
  if [[ -f "$REGISTER_STATUS_FILE" ]]; then
    jq . "$REGISTER_STATUS_FILE" 2>/dev/null || cat "$REGISTER_STATUS_FILE"
  else
    echo "未找到注册摘要文件：$REGISTER_STATUS_FILE"
  fi
}

print_recent_logs() {
  local log_file="${DEPLOY_LOG_FILE:-}"
  if [[ -z "$log_file" && -d "$DEPLOY_LOG_DIR" ]]; then
    log_file="$(ls -t "$DEPLOY_LOG_DIR"/deploy-*.log 2>/dev/null | head -1 || true)"
  fi

  if [[ -n "$log_file" && -f "$log_file" ]]; then
    echo "[信息] 最新部署日志：$log_file"
    tail -f "$log_file"
  else
    echo "[错误] 未找到部署日志。"
    echo "  默认目录：$DEPLOY_LOG_DIR"
    exit 1
  fi
}

start_in_tmux() {
  require_root

  if ! command -v tmux >/dev/null 2>&1; then
    echo "[信息] 正在安装 tmux..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y tmux
  fi

  mkdir -p "$DEPLOY_LOG_DIR"
  if [[ -z "${DEPLOY_LOG_FILE:-}" ]]; then
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"
  fi

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[信息] 部署 tmux 会话已存在：$TMUX_SESSION"
    echo "[提示] 说明后台可能仍在编译或部署，请勿重复启动。"
    echo "[提示] 查看状态：bash $SCRIPT_PATH status"
    echo "[提示] 查看日志：bash $SCRIPT_PATH logs"
    echo "[提示] 进入会话：bash $SCRIPT_PATH attach"
    exit 0
  fi

  if pgrep -af 'cargo|rustc|wasm-opt|rocksdb' >/dev/null 2>&1; then
    echo "[警告] 检测到编译相关进程正在运行，可能已有部署任务："
    pgrep -af 'cargo|rustc|wasm-opt|rocksdb' || true
    echo
    echo "[提示] 如确认不是本次部署，可手动处理后再运行。"
    echo "[提示] 查看状态：bash $SCRIPT_PATH status"
    exit 1
  fi

  echo "[信息] 启动后台部署 tmux 会话：$TMUX_SESSION"
  echo "[信息] 部署日志文件：$DEPLOY_LOG_FILE"
  tmux new-session -d -s "$TMUX_SESSION" "cd '$SCRIPT_DIR' && DEPLOY_LOG_FILE='$DEPLOY_LOG_FILE' flock -n '$DEPLOY_LOCK_FILE' bash '$SCRIPT_PATH' run"
  echo "[完成] 部署已在后台运行。SSH 断开不会中断部署。"
  echo "[提示] 查看日志：bash $SCRIPT_PATH logs"
  echo "[提示] 查看状态：bash $SCRIPT_PATH status"
  echo "[提示] 进入会话：bash $SCRIPT_PATH attach"
}

attach_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "[错误] tmux 未安装。"
    exit 1
  fi
  tmux attach -t "$TMUX_SESSION"
}

main() {
  # [修复] 先安装基础依赖，再检查
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    echo "[信息] 正在安装基础依赖 (jq, curl, git)..."
    apt-get update -qq
    apt-get install -y -qq jq curl git >/dev/null 2>&1
  fi
  require_cmd awk
  require_cmd jq
  require_cmd curl
  require_cmd git

  echo "[信息] 存储规划："
  echo "  STORAGE_ROOT=$STORAGE_ROOT"
  echo "  INSTALL_DIR=$INSTALL_DIR"
  echo "  DATA_ROOT=$DATA_ROOT"
  echo "  LOG_ROOT=$LOG_ROOT"
  echo "  IPFS_PATH=$IPFS_PATH"

  validate_config
  prepare_dirs
  setup_logging
  apt_install
  install_ipfs
  ensure_ipfs_repo
  ensure_rust
  clone_repo
  build_binary
  inspect_validator_keys
  generate_network_keys
  insert_session_keys
  write_systemd_units
  write_ipfs_systemd_unit
  setup_logrotate
  write_nginx_http_site
  obtain_cert
  configure_ufw
  start_services
  start_ipfs_service
  verify_deployment
  if deploys_validator && [[ "$REGISTER_VALIDATOR" == "true" ]]; then
    wait_sync
    register_validator
  fi
  print_summary
}

wait_for_validator_registration() {
  require_cmd curl
  require_cmd jq
  require_cmd node

  local dry_run="${1:-false}"
  REGISTER_DRY_RUN="$dry_run"
  export REGISTER_DRY_RUN

  validate_config
  prepare_dirs
  setup_logging

  if ! deploys_validator; then
    echo "[错误] 当前 DEPLOY_MODE=${DEPLOY_MODE}，未启用 validator，无法执行 register"
    return 1
  fi

  if [[ ! -x "$BIN_INSTALL_PATH" ]]; then
    echo "[错误] 未找到 nexus-node 可执行文件：$BIN_INSTALL_PATH"
    echo "  请先完成 validator 部署，再执行 register。"
    return 1
  fi

  if ! systemctl is-active --quiet nexus-validator; then
    echo "[错误] nexus-validator 服务未运行"
    echo "  检查：systemctl status nexus-validator --no-pager"
    return 1
  fi

  wait_rpc_ready "验证者节点" "$VALIDATOR_RPC_PORT"
  wait_sync
  REGISTER_VALIDATOR=true register_validator
}

# 支持单独调用函数：
#   bash deploy_nexus_server.sh                  — 在 tmux 后台启动完整部署
#   bash deploy_nexus_server.sh start            — 在 tmux 后台启动完整部署
#   bash deploy_nexus_server.sh run              — 前台执行完整部署（通常由 tmux 调用）
#   bash deploy_nexus_server.sh status           — 查看 tmux、编译进程、端口和 systemd 服务
#   bash deploy_nexus_server.sh logs             — 跟踪最新部署日志
#   bash deploy_nexus_server.sh attach           — 进入部署 tmux 会话
#   bash deploy_nexus_server.sh register         — 仅注册验证者
#   bash deploy_nexus_server.sh register --dry-run — 仅检查注册状态，不提交交易
#   source deploy_nexus_server.sh noop           — 仅加载函数，不执行
case "${1:-start}" in
  start|"")
    start_in_tmux
    ;;
  run)
    main "${@:2}"
    ;;
  status)
    print_runtime_status
    ;;
  logs)
    print_recent_logs
    ;;
  attach)
    attach_tmux
    ;;
  register)
    case "${2:-}" in
      --dry-run)
        wait_for_validator_registration true
        ;;
      "")
        wait_for_validator_registration false
        ;;
      *)
        echo "用法：$0 register [--dry-run]"
        exit 1
        ;;
    esac
    ;;
  noop)
    : # 仅加载函数
    ;;
  *)
    echo "用法：$0 {start|run|status|logs|attach|register [--dry-run]|noop}"
    exit 1
    ;;
esac
