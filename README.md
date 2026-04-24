# Nexus 现网节点部署脚本使用文档

本文档说明 `docs/scripts/` 目录下部署脚本的用途、配置方式、执行步骤和常见排查方法。

## 5 分钟快速部署版

> 适合已经拿到现网 `BOOTNODES`、验证者助记词、验证者地址、RPC 域名的情况。第一次部署前仍建议通读后文的安全注意事项。

### 1. 准备服务器

使用 root 登录一台 Ubuntu 服务器，确保：

- 内存 4GB+，推荐 8GB+
- 磁盘可用空间 20GB+
- 域名已解析到服务器公网 IP（如果要启用 HTTPS）
- 已准备好现网 bootnode multiaddr
- 如果部署验证者节点：已准备好验证者助记词和对应 `X...` 地址

### 2. 上传脚本目录

把本目录上传到服务器，例如放到：

```bash
/root/nexus-deploy
```

目录内应包含：

```text
deploy_nexus_server.sh
deploy.env.example
mainnet-raw.json
```

### 3. 准备并编辑配置

进入部署目录：

```bash
cd /root/nexus-deploy
```

如果目录里已经有填写好的 `deploy.env`，直接编辑或确认即可：

```bash
chmod 600 deploy.env
nano deploy.env
```

如果是第一次部署，且还没有 `deploy.env`，先从模板复制：

```bash
cp deploy.env.example deploy.env
chmod 600 deploy.env
nano deploy.env
```

最少确认这些项：

```bash
DEPLOY_REF="main"
DEPLOY_MODE="both"   # 可选：validator / rpc / both
BOOTNODES="/ip4/<bootnode-ip>/tcp/30333/p2p/12D3KooW..."

# DEPLOY_MODE=validator 或 both 时需要
VALIDATOR_MNEMONIC="word1 word2 ... word12"
VALIDATOR_ADDRESS="X..."
REGISTER_VALIDATOR="true"
VALIDATOR_COMMISSION="100"

# DEPLOY_MODE=rpc 或 both 时需要
RPC_DOMAIN="rpc.example.com"
CERTBOT_EMAIL="ops@example.com"
INSTALL_NGINX="true"
INSTALL_CERTBOT="true"

ENABLE_UFW="false"
```

三种模式如下：

- `DEPLOY_MODE="validator"`：仅部署验证者节点
- `DEPLOY_MODE="rpc"`：仅部署 RPC 节点
- `DEPLOY_MODE="both"`：同时部署验证者 + RPC 节点（默认）

如果暂时不想自动注册验证者，改为：

```bash
REGISTER_VALIDATOR="false"
```

如果 DNS 还没生效，先关闭证书申请：

```bash
INSTALL_CERTBOT="false"
```

### 4. 执行部署

```bash
chmod +x deploy_nexus_server.sh
bash deploy_nexus_server.sh
```

部署过程会自动安装依赖、编译 `nexus-node`，并根据 `DEPLOY_MODE` 写入和启动对应的 systemd 服务。默认还会安装 IPFS Kubo、初始化 `IPFS_PATH` 并启用 `ipfs.service` 自启动；如需跳过可设置 `INSTALL_IPFS="false"`。`DEPLOY_MODE=validator|both` 时会处理验证者密钥，并在 `REGISTER_VALIDATOR=true` 时尝试提交 `bond + setKeys + validate`；`DEPLOY_MODE=rpc|both` 时会处理 RPC 节点和可选的 Nginx / HTTPS。

### 5. 检查结果

```bash
# DEPLOY_MODE=both
systemctl status nexus-validator --no-pager
systemctl status nexus-rpc --no-pager

# 任意模式，如启用了 INSTALL_IPFS=true
systemctl status ipfs --no-pager

# DEPLOY_MODE=validator
systemctl status nexus-validator --no-pager

# DEPLOY_MODE=rpc
systemctl status nexus-rpc --no-pager
```

```bash
# DEPLOY_MODE=both
tail -f /var/log/nexus/validator.log
tail -f /var/log/nexus/rpc.log

# 任意模式，如启用了 INSTALL_IPFS=true
journalctl -u ipfs -f

# DEPLOY_MODE=validator
tail -f /var/log/nexus/validator.log

# DEPLOY_MODE=rpc
tail -f /var/log/nexus/rpc.log
```

检查 RPC：

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
  http://127.0.0.1:9947 | jq
```

如果前面设置了 `DEPLOY_MODE="validator"` 或 `DEPLOY_MODE="both"`，且 `REGISTER_VALIDATOR="false"`，节点同步且账户充值后执行：

```bash
bash deploy_nexus_server.sh register
```

### 快速部署检查清单

- `deploy.env` 权限是 `600`
- `DEPLOY_MODE` 是 `validator`、`rpc` 或 `both`
- `BOOTNODES` 没有保留 `<...>` 占位符
- `DEPLOY_MODE=validator|both` 时，`VALIDATOR_MNEMONIC` 是真实 12/24 词助记词
- `DEPLOY_MODE=validator|both` 时，`VALIDATOR_ADDRESS` 和助记词匹配，且地址有 NEX 余额
- `mainnet-raw.json` 与现网一致
- `DEPLOY_MODE=rpc|both` 且启用 HTTPS 时，`RPC_DOMAIN` 已解析到本机公网 IP
- 不要提交 `deploy.env`、助记词、keystore、network secret key

## 适用范围

`deploy_nexus_server.sh` 用于在一台全新的 Ubuntu 服务器上部署 Nexus 节点，并接入已经存在的 Nexus 网络。

脚本会部署两类本机服务，可通过 `DEPLOY_MODE` 选择：

- `DEPLOY_MODE=validator`：仅部署 `nexus-validator`
- `DEPLOY_MODE=rpc`：仅部署 `nexus-rpc`
- `DEPLOY_MODE=both`：同时部署两者（默认）

服务说明：

- `nexus-validator`：验证者节点，使用 `--validator` 启动。
- `nexus-rpc`：公网 RPC 节点，使用 `--rpc-external --rpc-cors all --rpc-methods Safe` 启动。

脚本不会创建新的创世链，也不会修改现网创世配置。它默认通过 `BOOTNODES` 加入已有网络。

## 目录文件

```text
docs/scripts/
├── deploy_nexus_server.sh   # 部署脚本
├── deploy.env.example       # 非敏感配置模板
├── deploy.env               # 本地真实配置，不应提交
└── mainnet-raw.json         # 默认 chain spec
```

> 注意：`deploy.env` 通常包含助记词、服务器参数等敏感信息，不要提交到 Git，也不要发到公开渠道。

## 服务器要求

建议环境：

- Ubuntu 22.04 或兼容版本
- root 用户执行
- 至少 4GB 内存，推荐 8GB+
- 至少 20GB 可用磁盘空间
- 能访问 GitHub、Rustup、NodeSource、npm registry
- 如果启用 HTTPS，域名 DNS 需要提前解析到服务器公网 IP

脚本会自动安装或检查：

- `curl`、`wget`、`jq`、`git`
- Rust / Cargo
- Node.js 18+
- Substrate 编译依赖：`clang`、`libclang-dev`、`protobuf-compiler` 等
- 可选：`ufw`、`nginx`、`certbot`

## 快速开始

### 1. 上传脚本目录

将 `docs/scripts/` 目录上传到目标服务器，例如：

```bash
/root/nexus-deploy/
```

确保目录内至少包含：

```text
deploy_nexus_server.sh
deploy.env.example
mainnet-raw.json
```

### 2. 创建配置文件

```bash
cd /root/nexus-deploy
cp deploy.env.example deploy.env
chmod 600 deploy.env
```

编辑 `deploy.env`：

```bash
nano deploy.env
```

至少需要确认以下配置。

### 3. 填写现网 bootnodes

```bash
BOOTNODES="/ip4/1.2.3.4/tcp/30333/p2p/12D3KooWxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

多个 bootnode 用空格分隔，并放在同一对引号内：

```bash
BOOTNODES="/ip4/1.2.3.4/tcp/30333/p2p/12D3KooWxxx /ip4/5.6.7.8/tcp/30333/p2p/12D3KooWyyy"
```

不要保留 `<IP>`、`<PORT>`、`<PEER_ID>` 这类尖括号占位符。

### 4. 填写验证者助记词和地址

```bash
VALIDATOR_MNEMONIC="word1 word2 ... word12"
VALIDATOR_ADDRESS="X..."
```

要求：

- 助记词必须是合法 BIP-39 12 或 24 个单词。
- `VALIDATOR_ADDRESS` 必须是该助记词派生出的 Nexus 地址，通常以 `X` 开头。
- 地址需要有足够 NEX 余额，否则自动注册验证者时无法 bond。

如果只是先部署节点，不立即注册验证者，可以设置：

```bash
REGISTER_VALIDATOR="false"
```

### 5. 配置 RPC 域名和 HTTPS

如果启用 Nginx：

```bash
INSTALL_NGINX="true"
RPC_DOMAIN="rpc.example.com"
```

如果同时启用 Certbot：

```bash
INSTALL_CERTBOT="true"
CERTBOT_EMAIL="ops@example.com"
```

要求：

- `RPC_DOMAIN` 已解析到服务器公网 IP。
- 服务器 80 / 443 端口可访问。

如果 DNS 尚未准备好，可先关闭证书申请：

```bash
INSTALL_CERTBOT="false"
```

部署完成后再手动执行：

```bash
certbot --nginx --non-interactive --agree-tos -m <email> -d <domain>
```

### 6. 配置防火墙

默认模板中 `ENABLE_UFW="false"`，如果要让脚本配置 UFW：

```bash
ENABLE_UFW="true"
ADMIN_IP="你的公网 IP"
SSH_PORT="22"
```

脚本会放行：

- 管理员 IP 到 SSH 端口
- `80/tcp`、`443/tcp`
- Validator P2P 端口，默认 `30333/tcp`
- RPC P2P 端口，默认 `30334/tcp`，受 `OPEN_RPC_P2P` 控制

启用 UFW 前请确认 `ADMIN_IP` 正确，避免 SSH 被锁在服务器外。

### 7. 执行完整部署

```bash
chmod +x deploy_nexus_server.sh
bash deploy_nexus_server.sh
```

脚本会按顺序执行：

1. 校验配置。
2. 创建数据目录和日志目录。
3. 安装系统依赖。
4. 安装或加载 Rust。
5. 克隆 Nexus 仓库并 checkout `DEPLOY_REF`。
6. 编译 `nexus-node`。
7. 从助记词派生验证者公钥。
8. 生成 validator / rpc 节点网络密钥。
9. 插入 BABE / GRANDPA session keys。
10. 写入 systemd 服务。
11. 配置 logrotate。
12. 配置 Nginx HTTP 反代。
13. 可选申请 HTTPS 证书。
14. 可选配置 UFW。
15. 启动 `nexus-validator` 和 `nexus-rpc`。
16. 如果 `REGISTER_VALIDATOR=true`，等待同步并提交 `bond + setKeys + validate`。
17. 打印部署摘要。

## 重要配置项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_REPO_URL` | `https://github.com/nexus-blockchain/nexus.git` | Nexus 代码仓库地址 |
| `DEPLOY_REF` | `main` | 要部署的分支、tag 或 commit |
| `DEPLOY_MODE` | `both` | 部署模式：`validator` / `rpc` / `both` |
| `CHAIN` | 脚本目录下 `mainnet-raw.json` | chain spec 路径 |
| `BOOTNODES` | 无 | 现网 bootnode multiaddr，必填 |
| `INSTALL_DIR` | `/opt/nexus` | 代码 clone 和编译目录 |
| `BIN_INSTALL_PATH` | `/usr/local/bin/nexus-node` | 编译后二进制安装路径 |
| `DATA_ROOT` | `/data/nexus` | 节点数据根目录 |
| `LOG_ROOT` | `/var/log/nexus` | 节点日志目录 |
| `VALIDATOR_NAME` | `Validator-1` | 验证者节点名称，仅 `validator` / `both` 使用 |
| `RPC_NAME` | `RPC-Public` | RPC 节点名称，仅 `rpc` / `both` 使用 |
| `VALIDATOR_P2P_PORT` | `30333` | 验证者 P2P 端口，仅 `validator` / `both` 使用 |
| `VALIDATOR_RPC_PORT` | `9944` | 验证者本机 RPC 端口，仅 `validator` / `both` 使用 |
| `RPC_P2P_PORT` | `30334` | RPC 节点 P2P 端口，仅 `rpc` / `both` 使用 |
| `RPC_RPC_PORT` | `9947` | RPC 节点本机 RPC 端口，仅 `rpc` / `both` 使用 |
| `INSTALL_NGINX` | `true` | 是否安装并配置 Nginx，仅 `rpc` / `both` 使用 |
| `INSTALL_CERTBOT` | `true` | 是否申请 HTTPS 证书，仅 `rpc` / `both` 使用 |
| `INSTALL_IPFS` | `true` | 是否安装 Kubo、初始化 `IPFS_PATH` 并启用 `ipfs.service` |
| `IPFS_VERSION` | `0.40.1` | 安装的 Kubo 版本 |
| `IPFS_PATH` | `/data/ipfs` | 本机 IPFS repo 路径 |
| `IPFS_USER` | `root` | 运行 `ipfs.service` 的系统用户 |
| `ENABLE_UFW` | `false` | 是否启用 UFW 防火墙 |
| `REGISTER_VALIDATOR` | `true` | 是否自动执行链上验证者注册，仅 `validator` / `both` 使用 |
| `VALIDATOR_COMMISSION` | `100` | 验证者佣金百分比，0-100，仅 `validator` / `both` 使用 |
| `WRITE_MNEMONIC_FILE` | `false` | 是否额外把助记词写入 root-only 文件，仅 `validator` / `both` 使用 |

## 部署模式说明

| 模式 | 验证者服务 | RPC 服务 | 验证者注册 | Nginx / HTTPS | 典型用途 |
| --- | --- | --- | --- | --- | --- |
| `validator` | 是 | 否 | 可选，受 `REGISTER_VALIDATOR` 控制 | 否 | 单独部署出块 / 验证者节点 |
| `rpc` | 否 | 是 | 否 | 可选，受 `INSTALL_NGINX` / `INSTALL_CERTBOT` 控制 | 单独部署公网 RPC 节点 |
| `both` | 是 | 是 | 可选，受 `REGISTER_VALIDATOR` 控制 | 可选 | 同一台服务器同时部署验证者和 RPC |

## Chain spec 路径规则

`CHAIN` 支持三种写法：

1. 不设置：默认使用脚本同目录下的 `mainnet-raw.json`。
2. 文件名：例如 `CHAIN="mainnet"`，脚本会尝试查找 `mainnet` 或 `mainnet-raw.json`。
3. 绝对路径：例如 `CHAIN="/root/nexus-deploy/mainnet-raw.json"`。

## 部署后的检查命令

查看服务状态（按 `DEPLOY_MODE` 选择对应命令）：

```bash
# DEPLOY_MODE=both
systemctl status nexus-validator --no-pager
systemctl status nexus-rpc --no-pager

# 任意模式，如启用了 INSTALL_IPFS=true
systemctl status ipfs --no-pager

# DEPLOY_MODE=validator
systemctl status nexus-validator --no-pager

# DEPLOY_MODE=rpc
systemctl status nexus-rpc --no-pager
```

查看日志（按 `DEPLOY_MODE` 选择对应命令）：

```bash
# DEPLOY_MODE=both
tail -f /var/log/nexus/validator.log
tail -f /var/log/nexus/rpc.log

# 任意模式，如启用了 INSTALL_IPFS=true
journalctl -u ipfs -f

# DEPLOY_MODE=validator
tail -f /var/log/nexus/validator.log

# DEPLOY_MODE=rpc
tail -f /var/log/nexus/rpc.log
```

查看部署日志：

```bash
ls -lh /var/log/nexus/deploy/
tail -100 /var/log/nexus/deploy/deploy-*.log
```

检查本机 RPC：

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
  http://127.0.0.1:9947 | jq
```

检查同步状态：

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_syncState","params":[]}' \
  http://127.0.0.1:9944 | jq
```

检查 session keys：

```bash
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"author_rotateKeys","params":[]}' \
  http://127.0.0.1:9944
```

## 仅注册验证者

如果完整部署时设置了：

```bash
REGISTER_VALIDATOR="false"
```

后续可以在节点同步完成、账户充值后执行：

```bash
bash deploy_nexus_server.sh register
```

该模式只执行验证者注册逻辑，提交：

- `staking.bond`
- `session.setKeys`
- `staking.validate`

如果账户已经 bonded，脚本会跳过 bond，只提交 session keys 和 validate。

## 重新部署或升级

如需切换部署版本，修改：

```bash
DEPLOY_REF="<branch-or-tag-or-commit>"
```

然后重新运行：

```bash
bash deploy_nexus_server.sh
```

脚本会在 `INSTALL_DIR` 中 fetch 并 checkout 指定 ref，重新编译并覆盖安装 `BIN_INSTALL_PATH`。

重新运行前建议先查看当前服务：

```bash
systemctl status nexus-validator --no-pager
systemctl status nexus-rpc --no-pager
```

## 常见问题

### 1. 提示 `配置文件不存在：deploy.env`

脚本默认读取同目录下的 `deploy.env`。如果服务器上已经有填写好的 `deploy.env`，可以直接使用，不需要重新复制模板。

只有在第一次部署或 `deploy.env` 不存在时，才需要执行：

```bash
cp deploy.env.example deploy.env
chmod 600 deploy.env
```

然后填写真实参数。

### 2. BOOTNODES 格式不合法

检查是否仍保留尖括号占位符，正确格式类似：

```text
/ip4/1.2.3.4/tcp/30333/p2p/12D3KooW...
```

多个地址用空格分隔。

### 3. Chain spec 文件不存在

确认 `mainnet-raw.json` 和脚本在同一目录，或显式设置：

```bash
CHAIN="/root/nexus-deploy/mainnet-raw.json"
```

### 4. 编译失败

常见原因：

- 内存不足：建议添加 swap。
- 磁盘空间不足：确认至少有 10GB+ 编译空间。
- Rust 版本或依赖不完整。

可检查：

```bash
free -h
df -h /
rustc --version
```

添加 8GB swap 示例：

```bash
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

### 5. 助记词无法派生公钥

检查：

- 是否为合法 BIP-39 英文助记词。
- 词数是否为 12 或 24。
- 是否有拼写错误。
- `VALIDATOR_ADDRESS` 是否和助记词匹配。

可用已编译二进制检查：

```bash
nexus-node key inspect --scheme Sr25519 "<MNEMONIC>" --network nexus
```

### 6. 自动注册失败：余额为 0

先向 `VALIDATOR_ADDRESS` 转入 NEX，再重新执行：

```bash
bash deploy_nexus_server.sh register
```

也可以把 `REGISTER_VALIDATOR="false"`，后续通过 Polkadot.js 手动执行 staking 流程。

### 7. Certbot 证书申请失败

脚本会继续完成节点部署。常见原因：

- DNS 尚未解析到本机 IP。
- 80 / 443 端口未放行。
- 域名配置错误。

DNS 就绪后执行：

```bash
certbot --nginx --non-interactive --agree-tos -m <email> -d <domain>
```

### 8. 节点 peers 为 0

重点检查：

- `BOOTNODES` 是否可达。
- `mainnet-raw.json` 是否与现网一致。
- P2P 端口是否被安全组或防火墙阻断。
- bootnode 是否在线。

可查看：

```bash
tail -100 /var/log/nexus/validator.log
curl -s -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' \
  http://127.0.0.1:9944 | jq
```

## 安全注意事项

- 不要提交 `deploy.env`。
- 不要提交验证者助记词、keystore、network secret key。
- `WRITE_MNEMONIC_FILE` 默认应保持 `false`。
- 如果必须在服务器保存助记词文件，确保只允许 root 读取，并做好离线备份和访问控制。
- 公网 RPC 使用 `--rpc-methods Safe`，不要暴露 unsafe RPC。
- 启用 UFW 前确认 SSH 放行规则正确。

## 卸载或清理

如需停止服务：

```bash
systemctl stop nexus-validator nexus-rpc
systemctl disable nexus-validator nexus-rpc
```

如需删除 systemd unit：

```bash
rm -f /etc/systemd/system/nexus-validator.service
rm -f /etc/systemd/system/nexus-rpc.service
systemctl daemon-reload
```

数据目录默认在：

```text
/data/nexus/validator
/data/nexus/rpc
```

删除数据目录会丢失节点本地数据库、keystore 和 network key。执行前必须确认已经备份必要密钥。
