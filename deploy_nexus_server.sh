#!/usr/bin/env bash
set -euo pipefail

# Nexus 验证者 + RPC 入网部署脚本。
# 适用于一台全新 Ubuntu 服务器接入已存在的 Nexus 网络。
# 服务器密码、GitHub Token、验证者助记词等高敏感信息严禁提交到仓库。

# 全局 trap：捕获未处理的错误，打印失败位置和日志路径
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
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[错误] 配置文件不存在：$ENV_FILE"
  echo "请先把 deploy.env.example 复制为 deploy.env 并填写真实参数。"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# [修复] CHAIN 默认值：如果 deploy.env 设了相对路径或无效值，自动修正为脚本同目录下的绝对路径
if [[ -n "${CHAIN:-}" && ! -f "$CHAIN" ]]; then
  # 尝试在脚本目录下查找同名文件
  if [[ -f "${SCRIPT_DIR}/${CHAIN}" ]]; then
    CHAIN="${SCRIPT_DIR}/${CHAIN}"
  elif [[ -f "${SCRIPT_DIR}/${CHAIN}-raw.json" ]]; then
    CHAIN="${SCRIPT_DIR}/${CHAIN}-raw.json"
  fi
fi

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

  if [[ "$NODE_USER" != "root" ]]; then
    echo "[错误] 当前脚本仅稳定支持 NODE_USER=root，请先使用 root。"
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

: "${DEPLOY_MODE:=both}"
: "${CHAIN:=${SCRIPT_DIR}/mainnet-raw.json}"
: "${INSTALL_DIR:=/opt/nexus}"
: "${BIN_INSTALL_PATH:=/usr/local/bin/nexus-node}"
: "${DATA_ROOT:=/data/nexus}"
: "${LOG_ROOT:=/var/log/nexus}"
: "${DEPLOY_LOG_DIR:=${LOG_ROOT}/deploy}"
: "${DEPLOY_LOG_FILE:=}"
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
: "${IPFS_PATH:=/data/ipfs}"
: "${IPFS_USER:=root}"

: "${GITHUB_REPO_URL:=https://github.com/nexus-blockchain/nexus.git}"

# [修复3] 移除无条件 require_var RPC_DOMAIN / ADMIN_IP，已在 validate_config 中按条件校验

# [修复2] 安装 libclang-dev 解决 clang-sys 编译失败
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl wget jq git build-essential pkg-config libssl-dev \
    clang libclang-dev cmake llvm-dev libudev-dev protobuf-compiler

  # 安装 Node.js 18+（@polkadot/api 需要 node:* 前缀，最低 Node.js 16；推荐 18 LTS）
  local node_major=""
  if command -v node >/dev/null 2>&1; then
    node_major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  fi
  if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
    echo "[信息] 当前 Node.js 版本不满足要求（需要 ≥18），正在安装 Node.js 18 LTS..."
    if [[ -n "$node_major" ]]; then
      echo "  当前版本：$(node --version)"
    fi
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt-get install -y nodejs
    echo "[信息] Node.js 已升级至 $(node --version)"
  else
    echo "[信息] Node.js $(node --version) 满足要求"
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
    echo "[信息] 已跳过 IPFS 安装（INSTALL_IPFS=false）"
    return
  fi

  local version="$IPFS_VERSION"
  local archive_name="kubo_v${version}_linux-amd64.tar.gz"
  local download_url="${IPFS_DIST_BASE}/v${version}/${archive_name}"
  local workdir="${IPFS_INSTALL_ROOT%/}/kubo-v${version}"
  local extract_dir="${workdir}/kubo"

  echo "[信息] 开始安装 IPFS Kubo v${version}"
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
    echo "[信息] 初始化 IPFS 仓库：$IPFS_PATH"
    IPFS_PATH="$IPFS_PATH" ipfs init
  else
    echo "[信息] 复用现有 IPFS 仓库：$IPFS_PATH"
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
  if [[ "$INSTALL_IPFS" == "true" ]]; then
    mkdir -p "$IPFS_PATH"
  fi
}

setup_logging() {
  mkdir -p "$DEPLOY_LOG_DIR"
  if [[ -z "$DEPLOY_LOG_FILE" ]]; then
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"
  fi
  touch "$DEPLOY_LOG_FILE"
  chmod 600 "$DEPLOY_LOG_FILE"
  exec > >(tee -a "$DEPLOY_LOG_FILE") 2>&1
  echo "[信息] 部署日志文件：$DEPLOY_LOG_FILE"
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
  echo "[信息] 部署提交：$DEPLOY_COMMIT"
}

# [修复1] --locked 失败时自动回退到不带 --locked
build_binary() {
  cd "$INSTALL_DIR"
  # shellcheck disable=SC1091
  source /root/.cargo/env
  if ! cargo build --locked --release; then
    echo "[警告] cargo build --locked 失败，尝试不带 --locked 编译"
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

  echo "[信息] 从助记词派生验证者公钥"
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
  echo "[信息] 正在生成节点网络密钥"
  local chain_id
  chain_id="$(get_chain_id)"

  if deploys_validator; then
    local val_key_file="$VALIDATOR_BASE_PATH/chains/${chain_id}/network/secret_ed25519"
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

  echo "[信息] 插入 BABE (Sr25519) session key..."
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

  echo "[信息] 插入 GRANDPA (Ed25519) session key..."
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
    cat >/etc/systemd/system/nexus-rpc.service <<EOF
[Unit]
Description=Nexus Public RPC Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NODE_USER}
ExecStart=${BIN_INSTALL_PATH} \
  --chain ${CHAIN} \
  --base-path ${RPC_BASE_PATH} \
  --port ${RPC_P2P_PORT} \
  --rpc-port ${RPC_RPC_PORT} \
  --prometheus-port ${RPC_PROM_PORT} \
  --rpc-external \
  --rpc-cors all \
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
  cat >/etc/logrotate.d/nexus <<'LOGROTATE'
/var/log/nexus/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
  echo "[信息] 已配置 logrotate：/etc/logrotate.d/nexus"
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
    echo "[警告] Certbot 证书申请失败（DNS 可能尚未解析到本机 IP）。"
    echo "[警告] 节点部署将继续，HTTPS 稍后可手动配置：certbot --nginx -d $RPC_DOMAIN"
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
    systemctl restart nexus-rpc
  fi
}

# 等待验证者节点同步到最新区块
wait_sync() {
  echo "[信息] 等待验证者节点同步..."
  local rpc="http://127.0.0.1:${VALIDATOR_RPC_PORT}"
  local max_wait=1800  # 最长等待 30 分钟
  local elapsed=0

  while (( elapsed < max_wait )); do
    local health
    health="$(curl -s -H 'Content-Type: application/json' \
      -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
      "$rpc" 2>/dev/null || echo "")"

    if [[ -n "$health" ]]; then
      local is_syncing
      is_syncing="$(echo "$health" | jq -r '.result.isSyncing // true')"
      if [[ "$is_syncing" == "false" ]]; then
        echo "[信息] 节点已同步到最新区块"
        return 0
      fi
    fi

    sleep 10
    elapsed=$((elapsed + 10))
    if (( elapsed % 60 == 0 )); then
      echo "[信息] 仍在同步，已等待 ${elapsed}s..."
    fi
  done

  echo "[警告] 等待同步超时（${max_wait}s），继续尝试注册..."
  echo
  # 输出诊断信息帮助运维排查
  local diag_health diag_peers diag_sync
  diag_health="$(curl -s -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
    "$rpc" 2>/dev/null || echo "(无法连接 RPC)")"
  diag_sync="$(curl -s -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"system_syncState","params":[]}' \
    "$rpc" 2>/dev/null || echo "(无法获取同步状态)")"
  echo "  节点健康状态：$diag_health"
  echo "  同步进度：$diag_sync"
  echo
  echo "  排查建议："
  echo "  1. 检查节点日志：tail -100 ${LOG_ROOT}/validator.log"
  echo "  2. 确认 bootnodes 可达：curl -s telnet://<bootnode_ip>:30333 或 nc -zv <bootnode_ip> 30333"
  echo "  3. 检查防火墙是否放行 P2P 端口 ${VALIDATOR_P2P_PORT}"
  echo "  4. 如果 peers=0，可能是 chain spec 不匹配或 bootnodes 已下线。"
  echo "  5. 同步可能需要更长时间。节点会在后台继续同步，可稍后手动注册。"
}

# 链上注册验证者：bond + setKeys + validate
register_validator() {
  if ! deploys_validator || [[ "$REGISTER_VALIDATOR" != "true" ]]; then
    return
  fi

  echo "[信息] 开始链上验证者注册..."

  # 获取 session keys
  local rotate_result
  rotate_result="$(curl -s -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"author_rotateKeys","params":[]}' \
    "http://127.0.0.1:${VALIDATOR_RPC_PORT}")"

  SESSION_KEYS="$(echo "$rotate_result" | jq -r '.result // empty')"
  if [[ -z "$SESSION_KEYS" ]]; then
    local rpc_error
    rpc_error="$(echo "$rotate_result" | jq -r '.error.message // empty')"
    echo "[错误] 无法获取 session keys"
    echo "  RPC 响应：$rotate_result"
    if [[ -n "$rpc_error" ]]; then
      echo "  错误信息：$rpc_error"
    fi
    echo
    echo "  常见原因："
    echo "  1. 节点尚未完全启动 — 检查：systemctl status nexus-validator"
    echo "  2. RPC 端口 ${VALIDATOR_RPC_PORT} 未监听 — 检查：ss -tlnp | grep ${VALIDATOR_RPC_PORT}"
    echo "  3. keystore 中缺少 session key 文件。"
    echo
    echo "  手动重试："
    echo "  curl -s -H 'Content-Type: application/json' -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"author_rotateKeys\",\"params\":[]}' http://127.0.0.1:${VALIDATOR_RPC_PORT}"
    return 1
  fi
  echo "[信息] Session Keys: $SESSION_KEYS"

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
  local commission="${VALIDATOR_COMMISSION}"

  node -e "
const { ApiPromise, WsProvider, Keyring } = require('@polkadot/api');
const { cryptoWaitReady } = require('@polkadot/util-crypto');

async function main() {
  await cryptoWaitReady();

  const provider = new WsProvider('${ws_url}');
  const api = await ApiPromise.create({ provider });

  const keyring = new Keyring({ type: 'sr25519', ss58Format: 273 });
  const validator = keyring.addFromUri('${VALIDATOR_MNEMONIC}');
  const expectedAddress = '${VALIDATOR_ADDRESS}';

  if (validator.address !== expectedAddress) {
    console.error('[错误] 助记词派生地址与 VALIDATOR_ADDRESS 不匹配');
    console.error('  派生地址:', validator.address);
    console.error('  期望地址:', expectedAddress);
    console.error();
    console.error('  修复：编辑 deploy.env，确保 VALIDATOR_ADDRESS 与 VALIDATOR_MNEMONIC 对应。');
    console.error('  验证：nexus-node key inspect --scheme Sr25519 \"<MNEMONIC>\"');
    process.exit(1);
  }
  console.log('[信息] 验证者地址:', validator.address);

  // 查询余额
  const { data: balance } = await api.query.system.account(validator.address);
  const free = balance.free.toBigInt();
  console.log('[信息] 可用余额:', free.toString());

  if (free === 0n) {
    console.error('[错误] 账户余额为 0，无法质押');
    console.error('  地址:', validator.address);
    console.error();
    console.error('  修复：先向该地址转入 NEX 代币，然后重新运行注册。');
    console.error('  手动注册脚本位于：/tmp/nexus-register-*/');
    console.error('  或设置 REGISTER_VALIDATOR=false 跳过自动注册，后续通过 polkadot.js 手动操作。');
    process.exit(1);
  }

  // 检查是否已经 bonded
  const bonded = await api.query.staking.bonded(validator.address);
  const sessionKeys = '${SESSION_KEYS}';
  const commissionPerbill = ${commission} * 10000000;  // 百分比转 Perbill

  const txs = [];

  if (bonded.isNone) {
    // 预留一部分作为手续费
    const existentialDeposit = api.consts.balances.existentialDeposit.toBigInt();
    const reserveForFees = free / 100n > existentialDeposit ? free / 100n : existentialDeposit * 10n;
    const bondAmount = free - reserveForFees;
    console.log('[信息] 质押金额:', bondAmount.toString());
    txs.push(api.tx.staking.bond(bondAmount, 'Staked'));
  } else {
    console.log('[信息] 已有 bond，跳过 bond 步骤');
  }

  txs.push(api.tx.session.setKeys(sessionKeys, '0x'));
  txs.push(api.tx.staking.validate({ commission: commissionPerbill, blocked: false }));

  if (txs.length === 1) {
    const hash = await txs[0].signAndSend(validator);
    console.log('[信息] 交易已发送:', hash.toHex());
  } else if (api.tx.utility) {
    const batch = api.tx.utility.batchAll(txs);
    const hash = await batch.signAndSend(validator);
    console.log('[信息] 批量交易已发送:', hash.toHex());
  } else {
    console.log('[信息] utility pallet 不可用，逐笔发送交易...');
    for (let i = 0; i < txs.length; i++) {
      const hash = await txs[i].signAndSend(validator);
      console.log('[信息] 交易 ' + (i + 1) + '/' + txs.length + ' 已发送:', hash.toHex());
      if (i < txs.length - 1) {
        await new Promise(r => setTimeout(r, 6000));
      }
    }
  }

  console.log('[完成] 验证者注册交易已提交，等待下个 era 生效');
  await api.disconnect();
}

main().catch(e => {
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

RPC 日志查看命令：
  tail -f ${LOG_ROOT}/rpc.log

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
    echo "[待办] HTTPS 证书未成功申请。DNS 解析就绪后执行："
    echo "  certbot --nginx --non-interactive --agree-tos -m $CERTBOT_EMAIL -d $RPC_DOMAIN"
  fi

  if [[ "$WRITE_MNEMONIC_FILE" == "true" ]] && deploys_validator; then
    echo
    echo "[敏感信息] 验证者助记词已写入受限文件：$MNEMONIC_FILE"
  fi
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
  if deploys_validator && [[ "$REGISTER_VALIDATOR" == "true" ]]; then
    wait_sync
    register_validator
  fi
  print_summary
}

# 支持单独调用函数：
#   bash deploy_nexus_server.sh                  — 完整部署
#   bash deploy_nexus_server.sh register         — 仅注册验证者
#   source deploy_nexus_server.sh noop           — 仅加载函数，不执行
case "${1:-}" in
  register)
    source "$(dirname "$0")/deploy.env" 2>/dev/null || true
    REGISTER_VALIDATOR=true register_validator
    ;;
  noop)
    : # 仅加载函数
    ;;
  *)
    main "$@"
    ;;
esac
