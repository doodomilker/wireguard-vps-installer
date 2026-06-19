# wireguard-vps-installer

## 状态

**状态**: `done` — 已收口，默认不继续推进。
- 状态：`done`

继续工作先看 `PROGRESS.md` 顶部接续卡片.

One-command WireGuard installer for Debian / Ubuntu / CentOS Stream VPS.  
Generates server config, a default client, prints conf + QR code + scp command, and installs a global `wgmgr` menu for ongoing management.

> English below | [中文文档](README.zh-CN.md)

## Features

- **One-line install**: `curl ... | sudo bash` (or `./install.sh`)
- **Auto-generates** server keypair + first client (`client1`)
- **Three output formats**: terminal `.conf` / scp command / QR code (PNG + terminal ASCII)
- **Global `wgmgr` command**: interactive menu for adding/removing clients, viewing config, downloading, restart, uninstall
- **OS support**: Debian 11+ / Ubuntu 20.04+ / CentOS Stream 8/9 (CentOS 7 EOL — not supported)

## Two install modes

### A) Online one-liner (recommended for fresh VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/install.sh | sudo bash
```

### B) Offline git clone (for restricted networks / air-gapped VPS)

```bash
git clone https://github.com/doodomilker/wireguard-vps-installer.git
cd wireguard-vps-installer
sudo ./install.sh
```

After `git clone`, **all script files are local** — `install.sh` never reaches
out to the internet for code. It still calls `apt-get install` / `dnf install`
to pull wireguard packages, which is unavoidable unless you pre-download
the .deb/.rpm files and use `dpkg -i` / `rpm -i` instead.

## After install

```bash
sudo wgmgr
```

Interactive menu:
- View current clients
- Get download link (scp / HTTP / QR)
- View server config
- Add new client
- Remove client
- View service status
- Restart service
- Uninstall

## Cloud firewall (you must do this manually)

The script only configures OS-level firewall. **You also need to open UDP 51820 in your cloud provider's security group**:

| Provider | Path |
|---|---|
| AWS Lightsail / EC2 | Instance → Networking → Add rule → Custom UDP 51820 |
| DigitalOcean | Networking → Firewalls → Inbound Rules → UDP 51820 |
| Vultr | Firewall → Add Firewall Group → UDP 51820 |
| Hetzner | Firewalls → Add rule → UDP 51820 |
| Aliyun / Tencent Cloud | Security Group → Inbound → UDP:51820 |

See `docs/cloud-firewall.md` for screenshots and provider-specific quirks.

## Documentation

- [Chinese README](README.zh-CN.md)
- [OS support matrix](docs/os-support.md)
- [Cloud firewall guide](docs/cloud-firewall.md)
- [Customization (DNS / subnet / port)](docs/customization.md)

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Run only on servers you own / are authorized to manage. Generating VPN endpoints may be subject to local laws; check your jurisdiction.
