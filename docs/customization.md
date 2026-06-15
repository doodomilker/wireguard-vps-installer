# Customization

Defaults chosen to work for 90% of users. Override at install time.

## Port (ListenPort)

Default: `51820` (community standard). Change if your ISP/network blocks it, or for stealth.

```bash
sudo ./install.sh --port 443        # stealth as HTTPS
sudo ./install.sh --port 51999      # random non-standard
```

**Don't forget**: cloud security group must open the same UDP port.

## Subnet

Default: `10.0.0.1/24` (server=.1, clients=.2 onwards).

If this collides with your home network or another VPN you have, change it:

```bash
sudo ./install.sh --subnet 10.10.0.0/24
sudo ./install.sh --subnet 192.168.100.0/24
```

**Don't forget**: clients' home network must NOT overlap with the WireGuard subnet, or you get "split horizon" issues.

## DNS

Default: `1.1.1.1, 8.8.8.8` (Cloudflare + Google). Override for privacy / local DNS:

```bash
sudo ./install.sh --dns "9.9.9.9, 149.112.112.112"      # Quad9
sudo ./install.sh --dns "1.0.0.1, 1.1.1.1"              # Cloudflare family
sudo ./install.sh --dns ""                              # use system DNS (rare)
```

## AllowedIPs (per-client)

Default: `0.0.0.0/0` (full tunnel — all client traffic goes through VPN).

Edit `/etc/wireguard/clients/<name>.conf` post-install:

| Use case | AllowedIPs |
|---|---|
| Full tunnel (default) | `0.0.0.0/0` |
| Split tunnel — only home LAN | `192.168.0.0/24, 10.0.0.0/24` |
| Split tunnel — only VPS services | `10.0.0.1/32` |

Router scenarios (OpenWrt) almost always want `0.0.0.0/0` so all home devices go through VPN.

## Server endpoint

Auto-detected via `curl -4 ifconfig.me` at install time. Override if:

- You have a domain pointing to the VPS: `--endpoint vpn.example.com:51820`
- Behind NAT with port forward: `--endpoint your-public-ip:forwarded-port`

```bash
sudo ./install.sh --endpoint vpn.example.com:51820
```

## Public download (scp + temporary HTTP)

By default, the script prints `scp` commands and binds any temporary HTTP server to `127.0.0.1`.

For LAN-only or public download (e.g., download from phone on same WiFi without scp):

```bash
sudo ./install.sh --expose-download           # bind 0.0.0.0 (LAN + public if SG open)
sudo ./install.sh --expose-download --public  # same as above, explicit
```

The HTTP server is **time-limited** (default 5 minutes) and **token-gated** (random URL path).
