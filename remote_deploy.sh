#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
REMOTE_SCRIPT="deploy_nexus_server.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[错误] 配置文件不存在：$ENV_FILE"
  echo "请先复制配置模板：cp deploy.env.example deploy.env"
  echo "然后编辑 deploy.env，至少填写 SERVER_HOST、BOOTNODES 等配置。"
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${SERVER_USER:=root}"
: "${SERVER_PORT:=22}"
: "${SERVER_DIR:=/root/nodedeploy}"
: "${SERVER_HOST:=}"

usage() {
  cat <<EOF
用法：bash remote_deploy.sh {start|sync|status|logs|attach|run|register}

常用命令：
  bash remote_deploy.sh start    同步本机代码到服务器，并在服务器后台启动部署
  bash remote_deploy.sh status   查看服务器部署/节点状态
  bash remote_deploy.sh logs     查看服务器最新部署日志
  bash remote_deploy.sh attach   进入服务器 tmux 部署会话

其他命令：
  bash remote_deploy.sh sync     只同步代码，不启动部署
  bash remote_deploy.sh run      同步后在服务器前台执行部署，不推荐新手使用
  bash remote_deploy.sh register 同步后仅执行验证者注册

请先在 deploy.env 中填写：
  SERVER_HOST="服务器IP"
  SERVER_USER="root"
  SERVER_PORT="22"
  SERVER_DIR="/root/nodedeploy"
EOF
}

require_remote_config() {
  if [[ -z "$SERVER_HOST" || "$SERVER_HOST" == "服务器IP" || "$SERVER_HOST" == "<SERVER_IP>" ]]; then
    echo "[错误] 请先在 deploy.env 中填写 SERVER_HOST=服务器IP"
    exit 1
  fi
}

remote_target() {
  printf '%s@%s' "$SERVER_USER" "$SERVER_HOST"
}

ssh_remote() {
  ssh -p "$SERVER_PORT" "$(remote_target)" "$@"
}

sync_files() {
  require_remote_config
  echo "[信息] 正在同步本机代码到服务器：$(remote_target):$SERVER_DIR"
  ssh_remote "mkdir -p '$SERVER_DIR'"
  rsync -avz \
    -e "ssh -p $SERVER_PORT" \
    --exclude='.git' \
    --exclude='.claude' \
    --exclude='*.log' \
    "${SCRIPT_DIR}/" "$(remote_target):${SERVER_DIR}/"
  echo "[完成] 同步完成"
}

remote_script_cmd() {
  local action="$1"
  ssh_remote "cd '$SERVER_DIR' && chmod +x '$REMOTE_SCRIPT' && bash '$REMOTE_SCRIPT' '$action'"
}

cmd="${1:-}"
case "$cmd" in
  start)
    sync_files
    remote_script_cmd start
    ;;
  sync)
    sync_files
    ;;
  status)
    require_remote_config
    remote_script_cmd status
    ;;
  logs)
    require_remote_config
    remote_script_cmd logs
    ;;
  attach)
    require_remote_config
    ssh -t -p "$SERVER_PORT" "$(remote_target)" "cd '$SERVER_DIR' && chmod +x '$REMOTE_SCRIPT' && bash '$REMOTE_SCRIPT' attach"
    ;;
  run)
    sync_files
    remote_script_cmd run
    ;;
  register)
    sync_files
    remote_script_cmd register
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "[错误] 未知命令：$cmd"
    echo
    usage
    exit 1
    ;;
esac
