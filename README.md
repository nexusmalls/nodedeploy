# nodedeploy

Nexus 节点一键部署仓库。推荐用法：**本机直接克隆仓库，编辑 `deploy.env`，然后执行 `bash remote_deploy.sh start`，自动同步到服务器并在 tmux 后台部署。**

详细说明请看：
- [新手操作使用文档](./新手操作使用文档.md)

## 适用场景

支持把一台 Ubuntu 服务器接入现有 Nexus 网络，可选三种模式：

- `validator`：仅部署验证者节点
- `rpc`：仅部署 RPC 节点
- `both`：同时部署验证者 + RPC

默认不会创建新链，也不会修改创世配置，而是通过 `BOOTNODES` 接入现网。

## 仓库内容

```text
.
├── remote_deploy.sh         # 本机执行：同步到服务器并触发远程部署
├── deploy_nexus_server.sh   # 服务器执行：真正的部署脚本
├── deploy.env.example       # 配置模板
├── deploy.env               # 本地真实配置，不应提交
└── nexus-mainnet-raw.json   # 默认 chain spec
```

## 源代码链接

- [Nexus 源代码仓库](https://github.com/nexusmalls/nexus.git)

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/nexusmalls/nodedeploy.git
cd nodedeploy
```

### 2. 创建配置文件

```bash
cp deploy.env.example deploy.env
chmod 600 deploy.env
nano deploy.env
```

至少填写这些配置：

```bash
SERVER_HOST="你的服务器IP"
SERVER_USER="root"
SERVER_PORT="22"
SERVER_DIR="/root/nodedeploy"

DEPLOY_MODE="validator"
BOOTNODES="/ip4/你的bootnodeIP/tcp/30333/p2p/12D3KooW..."
VALIDATOR_MNEMONIC="word1 word2 ... word12"
VALIDATOR_ADDRESS="X..."
REGISTER_VALIDATOR="false"
```

如果要部署 RPC，再补充：

```bash
RPC_DOMAIN="rpc.example.com"
CERTBOT_EMAIL="ops@example.com"
INSTALL_NGINX="true"
INSTALL_CERTBOT="true"
```

## 一键部署

在本机执行：

```bash
bash remote_deploy.sh start
```

这个命令会：

- 校验 `deploy.env`
- 把当前仓库同步到远程 `SERVER_DIR`
- 在服务器安装或使用 tmux
- 在服务器后台执行部署
- 保持部署在 SSH 断开后继续运行

## 常用命令

```bash
bash remote_deploy.sh start    # 启动远程部署
bash remote_deploy.sh status   # 查看远程状态
bash remote_deploy.sh logs     # 查看远程日志
bash remote_deploy.sh attach   # 进入远程 tmux 会话
bash remote_deploy.sh sync     # 只同步代码
bash remote_deploy.sh register # 后续单独注册验证者
```

如果你已经登录到服务器，也可以直接运行：

```bash
bash deploy_nexus_server.sh run
```

如果只想检查验证者注册还缺哪些步骤，不提交交易：

```bash
bash deploy_nexus_server.sh register --dry-run
```

## 服务器要求

- Ubuntu 22.04 或兼容版本
- root 用户执行部署
- 至少 4GB 内存，推荐 8GB+
- 至少 20GB 可用磁盘空间
- 能访问 GitHub、Rustup、NodeSource、npm registry

脚本会自动安装或检查：

- `curl`、`wget`、`jq`、`git`、`tmux`
- Rust / Cargo
- Node.js 18+
- Substrate 编译依赖
- 可选：`ufw`、`nginx`、`certbot`
- 默认：IPFS Kubo

## 安全提醒

- 不要提交 `deploy.env`
- 不要提交验证者助记词、keystore、network secret key
- `WRITE_MNEMONIC_FILE` 默认应保持 `false`
- 启用 UFW 前确认 SSH 放行规则正确

## 更多说明

更详细的部署步骤、截图式说明、排查方法和新手操作顺序，请看：

- [新手操作使用文档](./新手操作使用文档.md)
