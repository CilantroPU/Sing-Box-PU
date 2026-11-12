# sing-box 一键脚本

一条命令安装 sing-box 并生成节点，全程菜单管理：添加 / 更改 / 查看 / 删除节点、服务启停、核心与脚本更新、卸载。小规格 VPS 优化：自编译精简核心、纯 IPv6 机器可装可用。

当前版本：脚本 **v5.18**，核心 **sing-box 1.14.4（精简版）**。

## 功能特点

- **8 种协议**：TUIC / Naive / AnyTLS / Snell v6 / Hysteria2 / Shadowsocks / VLESS Reality / Direct（端口转发）
- **精简核心**：自编译 sing-box，只保留所需功能（`with_quic` / `with_utls` / `with_acme`），二进制 amd64 **41 MB** / arm64 **38 MB**（官方版 81 MB），待机内存约 **38 MB**；64M 内存 / 128M 磁盘的小机器轻负载可跑
- **纯 IPv6 友好**：脚本、核心、工具全部托管在 Cloudflare 双栈源，纯 v6 机器首次安装不依赖 GitHub；检测到无 IPv4 出口时自动建立常驻 IPv4 出口（usque + Cloudflare WARP）
- **首次安装极简**：只问节点地址（IP 或域名，回车自动检测），端口随机生成，装完直接给出节点链接和客户端配置
- **输出完整**：每个节点都给分享链接 + sing-box 客户端格式（JSON，可直接粘进客户端配置的 outbounds）
- **全菜单管理**：装完后运行 `sb` 进入管理菜单，节点的增删改查、改端口 / 密码 / UUID 都在菜单里完成
- **多系统兼容**：Debian / Ubuntu / Alpine 等，支持 systemd / OpenRC，无 init 系统时自动用 nohup + cron 兜底

## 快速安装
需要 root 权限：
```sh
curl -fsSL https://raw.githubusercontent.com/CilantroPU/Sing-Box-PU/main/install.sh | sh
```
## 纯 IPv6 机器一键脚本
```sh
curl -fsSL https://sb.shabby.skin/install.sh | sh
```
## 备用
```sh
curl -fsSL https://cdn.jsdelivr.net/gh/CilantroPU/Sing-Box-PU@main/install.sh | sh
```


安装流程：

1. 选择 `1) 安装`
2. 输入节点地址（机器的 IP 或域名，直接回车 = 自动检测公网地址）
3. 完成。终端会打印 VLESS Reality 节点链接和 sing-box 客户端配置

> 首次安装只装一条 VLESS Reality 节点。其他协议装完后运行 `sb`，在 `1) 添加配置` 里添加。

## 管理菜单

安装完成后，任意终端运行：

```sh
sb
```

| 菜单 | 说明 |
|---|---|
| 1) 添加配置 | 添加新节点（支持 8 种协议） |
| 2) 更改配置 | 改已有节点的端口 / 密码 / UUID / 转发目标等 |
| 3) 查看配置 | 查看单个或全部节点的链接 + 客户端格式 |
| 4) 删除配置 | 删除节点 |
| 5) 运行管理 | 启动 / 停止 / 重启服务 |
| 6) 版本更新 | 更新 sing-box 核心，或更新脚本本身 |
| 7) 安装加速 | BBR+FQ / Skyline / IPv4 出口 |
| 8) 卸载脚本 | 删除服务、二进制、全部节点配置与已装加速 |

### 协议说明（添加顺序）

| # | 协议 | 说明 |
|---|---|---|
| 1 | TUIC | QUIC，自签证书，链接可直接导入 |
| 2 | Naive | **需要域名**：域名须解析到本机、80 端口可达，证书由 Let's Encrypt 自动签发和续期；签发失败会自动回滚本次添加，不留坏节点 |
| 3 | AnyTLS | 自签证书 |
| 4 | Snell v6 | 输出 Surge 配置行 |
| 5 | Hysteria2 | QUIC，自签证书 |
| 6 | Shadowsocks | 加密方式二选一：`aes-256-gcm`（默认）或 `2022-blake3-aes-256-gcm` |
| 7 | VLESS Reality | 默认 `www.amazon.com` |(可更改)
| 8 | Direct | 端口转发（TCP+UDP），把本机端口转发到任意目标地址:端口，无分享链接 |

## 纯 IPv6 支持

- **分发双栈可达**：脚本、精简核心、usque 工具都存放在 GitHub 仓库，经 jsDelivr 双栈分发（脚本内部下载也是 GitHub 主源 + jsDelivr 兜底），纯 v6 机器可直达，不必直连只有 IPv4 的 GitHub
- **自动 IPv4 出口**：安装时检测到机器没有 IPv4 出口，会自动按 usque 方案建立常驻出口：注册 Cloudflare WARP、装 `usque` 系统服务跑隧道、把 IPv4 默认路由指向隧道，节点从此能访问 IPv4 目标站。要求机器有 tun 设备权限（无权限时会明确提示并跳过，不影响安装）。已装机器也可以在菜单 `7) 安装加速 → 3) IPv4 出口` 手动补装；卸载脚本时一并清理
- **Skyline 兜底**：Skyline 加速需从 GitHub 拉取源码，在纯 v6 且没有 IPv4 出口时，脚本会先用临时 NAT64 解析、再用临时 WARP 通道重试

## 精简核心

- 精简核心存放在本仓库 `core/` 目录（GitHub）；安装和菜单更新首选 GitHub 仓库、其次 jsDelivr 双栈分发，下载后做 sha256 校验，两者都不可用时自动回退 sing-box 官方版
- 编译配方见 `build-slim.sh`（改版本号即可为新版本 sing-box 重新编译双架构精简核心）

## 系统要求

- 架构：amd64 / arm64
- 系统：Debian / Ubuntu / Alpine 等主流发行版（systemd 或 OpenRC；都没有也能装）
- 权限：root
- Naive 协议另需：一个解析到本机的域名 + 80 端口可达

## 文件说明

| 文件 | 说明 |
|---|---|
| `install.sh` | 一键安装脚本（内嵌 `sb` 管理脚本） |
| `sb` | 管理脚本源码（安装后位于 `/usr/local/bin/sb`） |
| `build-slim.sh` | 精简核心编译配方 |
| `core/` | 精简核心文件（gz + sha256）与版本清单 `latest.txt` |
| `tools/` | usque 工具（纯 IPv6 机器建 IPv4 出口用） |
| `README.md` | 本文件 |

## 注意事项

- 节点配置保存在目标机器的 `/opt/sing-box-nodes/`，随机生成的密码、UUID 等记录在同目录 `info.txt`，请自行备份
- Hy2 / TUIC / AnyTLS 使用自签证书，客户端链接默认带跳过证书验证参数，属正常现象；Naive 使用真实证书，无此问题
- Skyline 为源码编译安装，约需 1–3 分钟，且部分容器机型不支持，脚本会给出明确结果
