# wireguard-vps-installer（中文）

一键安装 WireGuard 的 VPS 脚本。适用于 Debian / Ubuntu / CentOS Stream。

> [English](README.md) | 中文版

## 功能

- **一行命令装完**：`curl ... | sudo bash`（或本地 `./install.sh`）
- **自动生成** server 密钥对 + 默认第一个 client（`client1`）
- **三种输出格式**：终端 `.conf` / scp 命令 / 二维码（PNG + 终端 ASCII）
- **全局 `wgmgr` 命令**：交互菜单，支持增删 client、查看配置、下载、重启、卸载
- **系统支持**：Debian 11+ / Ubuntu 20.04+ / CentOS Stream 8/9（CentOS 7 EOL 不支持）

## 快速开始

```bash
# 在 VPS 上（Debian/Ubuntu/CentOS Stream），root 用户：
curl -fsSL https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/install.sh | sudo bash
```

或本地 clone：

```bash
git clone https://github.com/doodomilker/wireguard-vps-installer.git
cd wireguard-vps-installer
sudo ./install.sh
```

## 装完之后

```bash
sudo wgmgr
```

交互菜单：
- 查看当前账户
- 获取下载链接（scp / HTTP / 二维码）
- 查看各项配置
- 添加新账户
- 删除账户
- 查看服务状态
- 重启服务
- 卸载 wireguard

## 云厂商安全组放行（必须手动做）

脚本只配 OS 层防火墙。**云厂商安全组也要放行 UDP 51820**：

| 厂商 | 路径 |
|---|---|
| AWS Lightsail / EC2 | 实例 → Networking → Add rule → Custom UDP 51820 |
| DigitalOcean | Networking → Firewalls → Inbound Rules → UDP 51820 |
| Vultr | Firewall → Add Firewall Group → UDP 51820 |
| Hetzner | Firewalls → Add rule → UDP 51820 |
| 阿里云 / 腾讯云 | 安全组 → 入方向 → UDP:51820 |

详见 `docs/cloud-firewall.md`。

## 文档

- [系统支持说明](docs/os-support.md)
- [云厂商防火墙指南](docs/cloud-firewall.md)
- [自定义配置（DNS / 子网 / 端口）](docs/customization.md)

## 协议

MIT — 见 [LICENSE](LICENSE)。

## 免责声明

仅在你拥有 / 被授权管理的服务器上运行。搭建 VPN 可能受当地法规约束，请自行确认。
