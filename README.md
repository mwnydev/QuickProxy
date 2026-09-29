# QuickProxy

一键部署 **VLESS + Reality** / **Hysteria2** 代理节点的 Bash 脚本，支持 **Debian 10/11/12+** 与 **Alpine 3.21+**。

## 简介

- **协议**
  - VLESS + Reality（TCP，`xtls-rprx-vision`），内核可选 Xray-core 或 sing-box
  - Hysteria2（UDP/QUIC），仅 sing-box 内核
  - 两者同时部署（sing-box 内核）
- **Hysteria2 证书**：自签证书（无需域名），或域名 + ACME 自动申请正规证书
- **自动完成**：安装依赖、开启 BBR、调大 UDP 缓冲区、生成 UUID / Reality 密钥 / 密码 / 证书、写入并校验配置、放行 ufw 端口、启动服务并设置开机自启
- **输出**：节点参数与分享链接，保存在 `/root/vless-reality-info.txt`
- **安全可靠**：配置先校验再替换；安装中途失败会自动回滚到安装前的状态；带并发锁，防止多个实例同时运行
- **系统适配**：Debian 使用 systemd + apt；Alpine 使用 OpenRC + apk（日志位于 `/var/log/xray.log`、`/var/log/sing-box.log`）

## 系统要求

- root 用户
- Debian 10/11/12+（systemd）或 Alpine 3.21+（OpenRC）
- CPU 架构：amd64 / arm64 / armv7
- 服务器能访问 GitHub（下载内核）
- 开启 BBR 需内核 ≥ 4.9（OpenVZ/LXC 等虚拟化可能不支持，不影响节点使用）

## 快速开始

### Debian

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mwnydev/QuickProxy/main/QuickProxy.sh)
```

### Alpine

Alpine 默认没有 bash 和 curl，先安装：

```sh
apk add bash curl
bash <(curl -fsSL https://raw.githubusercontent.com/mwnydev/QuickProxy/main/QuickProxy.sh)
```

也可以先下载再运行（用 `sh` 运行时，若缺少 bash 会自动 `apk add bash`）：

```sh
wget -O QuickProxy.sh https://raw.githubusercontent.com/mwnydev/QuickProxy/main/QuickProxy.sh
sh QuickProxy.sh
```

运行后按菜单提示操作即可：

```
===== VLESS-Reality / Hysteria2 一键脚本 (Xray / sing-box) =====
  1) 安装 / 重装节点
  2) 查看节点信息
  3) 重启服务并查看状态
  4) 卸载
  0) 退出
```

安装过程中依次选择：协议 → 内核 → 端口（默认随机）→ Reality 伪装域名 SNI（默认 `www.microsoft.com`）→ Hysteria2 证书方式 → sing-box 安装来源，最后确认即可。

## 子命令

```bash
bash QuickProxy.sh            # 交互菜单
bash QuickProxy.sh install    # 安装 / 重装
bash QuickProxy.sh info       # 查看节点信息
bash QuickProxy.sh restart    # 重启服务并查看状态
bash QuickProxy.sh uninstall  # 卸载
```

## 无人值守安装（环境变量）

预先设置环境变量后，对应的问题会被跳过；全部设置后可在非交互环境（如 cloud-init）中直接安装。

| 变量 | 取值 | 说明 |
| --- | --- | --- |
| `PROTO` | `reality` / `hy2` / `both` | 部署的协议 |
| `CORE` | `xray` / `singbox` | 内核（Hysteria2 固定为 sing-box） |
| `PORT` | 1-65535 | Reality 端口（TCP） |
| `HY2_PORT` | 1-65535 | Hysteria2 端口（UDP） |
| `SNI` | 域名 | Reality 伪装域名，需支持 TLS 1.3 |
| `HY2_MODE` | `self` / `acme` | Hysteria2 证书：自签 / 域名自动申请 |
| `HY2_DOMAIN` | 域名 | `acme` 模式下的域名（需已解析到本机） |
| `HY2_EMAIL` | 邮箱 | `acme` 模式下的证书通知邮箱，可留空 |
| `SB_SOURCE` | `github` / `apt` | sing-box 安装来源（Alpine 仅支持 `github`） |
| `SB_VERSION` | 如 `1.12.0` | 指定 sing-box 版本，默认最新正式版 |

示例：

```bash
# 仅 Reality（Xray 内核）
PROTO=reality CORE=xray PORT=443 SNI=www.microsoft.com \
  bash QuickProxy.sh install

# Reality + Hysteria2（自签证书）
PROTO=both PORT=443 HY2_PORT=8443 SNI=www.apple.com HY2_MODE=self SB_SOURCE=github \
  bash QuickProxy.sh install

# Hysteria2 + 域名证书
PROTO=hy2 HY2_PORT=443 HY2_MODE=acme HY2_DOMAIN=hy2.example.com SB_SOURCE=github \
  bash QuickProxy.sh install
```

最后一步“确认开始安装”在非交互环境下默认为是。

## 客户端

安装完成后会输出 `vless://` 与 `hysteria2://` 分享链接，可直接导入：

v2rayN / v2rayNG / NekoBox / Shadowrocket / Hiddify / Clash Meta (mihomo) 等。

- Hysteria2 使用自签证书时，客户端需勾选「允许不安全 / 跳过证书验证」，或使用输出中的证书指纹（`pinSHA256`）。

## 注意事项

- **云服务商安全组**：脚本只处理 ufw，云控制台的安全组 / 防火墙需要手动放行所用端口（Reality 为 TCP，Hysteria2 为 UDP，ACME 模式还需 TCP 80）。
- **ACME 模式**：域名需先添加 A 记录指向服务器 IP，且不能开启 CDN 代理；80 端口需空闲。
- **切换内核**：安装新内核时会自动停止并禁用另一个内核的服务，避免端口冲突。
- **查看日志**：
  - Debian：`journalctl -u xray -f` 或 `journalctl -u sing-box -f`
  - Alpine：`tail -f /var/log/xray.log` 或 `tail -f /var/log/sing-box.log`
- **Alpine 容器**：若 OpenRC 未启动，服务将无法运行，可先执行 `openrc default`。
- **卸载**：会删除所选内核、配置与服务；BBR / UDP 缓冲区设置（`/etc/sysctl.d/`）和 ufw 规则会保留，如需清理请手动处理。

## 文件位置

| 内容 | 路径 |
| --- | --- |
| 节点信息 | `/root/vless-reality-info.txt` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| sing-box 配置 | `/etc/sing-box/config.json` |
| Hysteria2 自签证书 | `/etc/sing-box/hy2.crt`、`/etc/sing-box/hy2.key` |
| sysctl 设置 | `/etc/sysctl.d/99-bbr.conf`、`/etc/sysctl.d/99-udp-buffer.conf` |

## 免责声明

本脚本仅供学习与研究网络技术使用，请遵守所在地法律法规。
