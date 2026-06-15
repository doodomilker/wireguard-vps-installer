# OS Support Matrix

| OS | Version | Package manager | Status |
|---|---|---|---|
| Debian | 11 (Bullseye) | apt | ✅ Tested |
| Debian | 12 (Bookworm) | apt | ✅ Tested |
| Ubuntu | 20.04 LTS | apt | ✅ Tested |
| Ubuntu | 22.04 LTS | apt | ✅ Tested |
| Ubuntu | 24.04 LTS | apt | ✅ Tested |
| CentOS Stream | 8 | dnf | ✅ Tested |
| CentOS Stream | 9 | dnf | ✅ Tested |
| Rocky / AlmaLinux | 8/9 | dnf | ✅ Compatible (same as CentOS Stream) |
| Fedora | 39+ | dnf | ✅ Compatible |
| CentOS | 7 | yum | ❌ EOL 2024-06-30, not supported |
| RHEL | 7 | yum | ❌ EOL, not supported |
| Alpine | any | apk | ❌ Not supported in v1 |
| Arch | any | pacman | ❌ Not supported in v1 |
| openSUSE | any | zypper | ❌ Not supported in v1 |
| macOS | any | brew | ⚠ Dev only via `scripts/dryrun.sh` (mocked) |

## Detection logic

The script reads `/etc/os-release` and branches on `ID` and `ID_LIKE`:

```
ID=debian|ubuntu  → PKG=apt
ID=centos|rhel|rocky|almalinux|fedora  → PKG=dnf
ID_LIKE contains "rhel" but ID unsupported  → error, suggest CentOS Stream
ID_LIKE contains "debian" but ID unsupported  → error, suggest Debian/Ubuntu
unknown  → error, list supported distros
```

## Why CentOS 7 is out

- EOL 2024-06-30 (no security updates)
- Kernel 3.10 doesn't include upstream WireGuard module → requires `kmod-wireguard` from ELRepo, extra dance
- `iptables-services` package works but integration is fiddly
- Not worth the support burden; users should upgrade to CentOS Stream 9 / Rocky 9 / Debian 12.

## Adding a new distro

1. Add row to the matrix above.
2. Add `ID` pattern to `lib/common.sh::detect_os()`.
3. Add `install_packages` branch for the new package manager.
4. Test on a fresh VM (LXC / cloud-init).
5. Update README.
