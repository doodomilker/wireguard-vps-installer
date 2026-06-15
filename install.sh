#!/usr/bin/env bash
# wireguard-vps-installer — one-shot install for Debian/Ubuntu/CentOS Stream
# Usage: sudo ./install.sh [--port N] [--subnet CIDR] [--dns LIST] [--endpoint IP:PORT] [--no-psk] [--expose-download]
#
# This script is meant to be runnable via `curl ... | sudo bash`, so it embeds
# the lib/* functions inline (no dependency on a local checkout).

set -euo pipefail

# ---------- Embedded lib (single-file friendly) ----------
# We embed by sourcing relative paths when running from a checkout,
# or fall back to inline minimal copies if piped via curl.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo ".")"

# Source libs: try local checkout first, fallback to GitHub raw (curl|bash mode)
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/network.sh"
    source "${SCRIPT_DIR}/lib/server.sh"
    source "${SCRIPT_DIR}/lib/client.sh"
    WGMGR_SOURCE="${SCRIPT_DIR}/wgmgr"
    WGMGR_LIB_SOURCE="${SCRIPT_DIR}/lib"
elif [[ -f "/tmp/wg-install-lib/common.sh" ]]; then
    # Already downloaded in this session
    source "/tmp/wg-install-lib/common.sh"
    source "/tmp/wg-install-lib/network.sh"
    source "/tmp/wg-install-lib/server.sh"
    source "/tmp/wg-install-lib/client.sh"
    WGMGR_LIB_SOURCE="/tmp/wg-install-lib"
else
    # curl | bash mode: download libs from GitHub raw
    echo "[i] Downloading library files from GitHub..."
    TMP_LIB="/tmp/wg-install-lib"
    rm -rf "${TMP_LIB}"
    mkdir -p "${TMP_LIB}"
    GH_RAW="https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/lib"
    for f in common.sh network.sh server.sh client.sh; do
        if ! curl -fsSL "${GH_RAW}/${f}" -o "${TMP_LIB}/${f}" 2>/dev/null; then
            echo "[✗] Failed to download lib/${f} from GitHub. Check your internet connection." >&2
            echo "    Alternative: git clone https://github.com/doodomilker/wireguard-vps-installer.git && cd wireguard-vps-installer && sudo ./install.sh" >&2
            exit 1
        fi
    done
    source "${TMP_LIB}/common.sh"
    source "${TMP_LIB}/network.sh"
    source "${TMP_LIB}/server.sh"
    source "${TMP_LIB}/client.sh"
    WGMGR_SOURCE="${TMP_LIB}/.."
    WGMGR_LIB_SOURCE="${TMP_LIB}"
fi

# ---------- Defaults ----------
WG_PORT="${WG_PORT_DEFAULT}"
WG_SUBNET="${WG_SUBNET_DEFAULT}"
WG_DNS="${WG_DNS_DEFAULT}"
SERVER_ENDPOINT_OVERRIDE=""
USE_PSK=1
EXPOSE_DOWNLOAD=0
SKIP_INSTALL=0

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)            WG_PORT="$2"; shift 2 ;;
        --subnet)          WG_SUBNET="$2"; shift 2 ;;
        --dns)             WG_DNS="$2"; shift 2 ;;
        --endpoint)        SERVER_ENDPOINT_OVERRIDE="$2"; shift 2 ;;
        --no-psk)          USE_PSK=0; shift ;;
        --expose-download) EXPOSE_DOWNLOAD=1; shift ;;
        --public)          EXPOSE_DOWNLOAD=1; shift ;;
        --dryrun)          DRYRUN=1; shift ;;
        -h|--help)
            cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --port N              UDP ListenPort (default 51820)
  --subnet CIDR         WireGuard subnet, /24 recommended (default 10.0.0.0/24)
  --dns LIST            Comma-separated DNS for clients (default "1.1.1.1, 8.8.8.8")
  --endpoint IP:PORT    Override detected public endpoint
  --no-psk              Skip generating preshared keys
  --expose-download     Bind temporary HTTP download server on 0.0.0.0 (default 127.0.0.1)
  --dryrun              Print actions without making changes
  -h, --help            This message
EOF
            exit 0
            ;;
        *)
            msg_err "Unknown arg: $1 (try --help)"
            exit 1
            ;;
    esac
done

# ---------- Banner ----------
msg_banner "wireguard-vps-installer"
echo "  Config: port=${WG_PORT}  subnet=${WG_SUBNET}  dns=${WG_DNS}  psk=${USE_PSK}"
echo ""

# ---------- Pre-flight ----------
require_root
detect_os
check_os_supported
msg_ok "OS: ${OS_PRETTY}  (pkg: ${PKG_MANAGER})"

# ---------- Idempotency: if already installed, prompt ----------
if [[ -f "${WG_CONF}" && "${DRYRUN}" != "1" ]]; then
    msg_warn "Existing WireGuard install detected at ${WG_CONF}"
    if ! confirm "Reconfigure? (This will add a new client and reload wg0)" "N"; then
        msg_info "Aborting."
        exit 0
    fi
fi

# ---------- Install packages ----------
msg_step "Installing WireGuard and helpers"

WG_REQUIRED_PKGS=()
case "${PKG_MANAGER}" in
    apt)
        WG_REQUIRED_PKGS=(wireguard qrencode iptables-persistent)
        ;;
    dnf)
        # Enable EPEL for qrencode on RHEL-based
        if ! has_cmd qrencode; then
            dnf install -y epel-release || msg_warn "epel-release install failed (qrencode may not be available)"
        fi
        WG_REQUIRED_PKGS=(wireguard-tools qrencode iptables-services)
        ;;
esac

run pkg_install "${WG_REQUIRED_PKGS[@]}"

# ---------- Detect public IP ----------
msg_step "Detecting public endpoint"

if [[ -n "${SERVER_ENDPOINT_OVERRIDE}" ]]; then
    PUBLIC_IP="${SERVER_ENDPOINT_OVERRIDE%:*}"
    WG_PORT="${SERVER_ENDPOINT_OVERRIDE##*:}"
    msg_info "Using override endpoint: ${PUBLIC_IP}:${WG_PORT}"
else
    if ! detect_public_ip; then
        msg_err "Cannot detect public IPv4 and no --endpoint given."
        exit 1
    fi
fi

# Sanity: port not in use
if ! port_is_free "${WG_PORT}"; then
    msg_warn "Port ${WG_PORT} appears to be in use on this host."
    if ! confirm "Continue anyway?" "N"; then
        exit 1
    fi
fi

# ---------- Generate server keys ----------
msg_step "Generating server keys"

# Load kernel module on dnf systems (apt loads it automatically via wireguard-dkms)
if [[ "${PKG_MANAGER}" == "dnf" ]]; then
    run modprobe wireguard 2>/dev/null || true
fi

run gen_keypair "SERVER"
SERVER_PRIVATE="${SERVER_PRIVATE}"
SERVER_PUBLIC="${SERVER_PUBLIC}"

# ---------- Write server conf ----------
run write_server_conf "${SERVER_PRIVATE}" "${WG_PORT}" "${WG_SUBNET}" "${WG_DNS}"

# ---------- IP forwarding + NAT ----------
run enable_ip_forward
run apply_nat_rules "${WG_SUBNET}" "eth0"

# ---------- Enable + start wg-quick ----------
if ! run enable_and_start_wg; then
    if [[ "${DRYRUN}" != "1" ]]; then
        msg_err "wg-quick@wg0 failed to start. Check: journalctl -u wg-quick@wg0"
        exit 1
    fi
fi

# ---------- Generate first client ----------
msg_step "Generating default client 'client1'"

run deliver_client "client1" "${SERVER_PUBLIC}" "${PUBLIC_IP}:${WG_PORT}" "${WG_SUBNET}" "${WG_DNS}" "${USE_PSK}"

# ---------- Install wgmgr command ----------
msg_step "Installing wgmgr command"

if [[ "${WGMGR_SOURCE}" != "${SCRIPT_DIR}/wgmgr" ]]; then
    # curl | bash mode: download wgmgr and install libs permanently
    WGMGR_TARGET="/usr/local/bin/wgmgr"
    run rm -f /tmp/wgmgr-download
    run curl -fsSL "https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/wgmgr" -o /tmp/wgmgr-download
    run install -m 0755 /tmp/wgmgr-download "${WGMGR_TARGET}"
    run rm -f /tmp/wgmgr-download
    # Install libs for wgmgr runtime lookup
    run mkdir -p /usr/local/share/wgmgr/lib
    run cp "${WGMGR_LIB_SOURCE}"/*.sh /usr/local/share/wgmgr/lib/
    run chmod 644 /usr/local/share/wgmgr/lib/*.sh
    msg_ok "Installed ${WGMGR_TARGET} (curl|bash mode)"
elif [[ -f "${SCRIPT_DIR}/wgmgr" ]]; then
    run install -m 0755 "${SCRIPT_DIR}/wgmgr" /usr/local/bin/wgmgr
    # Also install libs for wgmgr runtime (in case user runs from curl|bash later)
    run mkdir -p /usr/local/share/wgmgr/lib
    run cp "${SCRIPT_DIR}/lib"/*.sh /usr/local/share/wgmgr/lib/
    run chmod 644 /usr/local/share/wgmgr/lib/*.sh
    msg_ok "Installed /usr/local/bin/wgmgr"
else
    msg_warn "wgmgr not found — skipping global install"
fi

# ---------- Print summary ----------
SERVER_ENDPOINT="${PUBLIC_IP}:${WG_PORT}"
print_server_summary "${SERVER_PUBLIC}" "${WG_PORT}" "${WG_SUBNET}" "${WG_DNS}" "${SERVER_ENDPOINT}"

# ---------- Final reminder ----------
msg_step "NEXT STEPS"
cat <<EOF
  1) Open UDP ${WG_PORT} in your cloud provider's security group
     (AWS / DO / Vultr / Aliyun / Tencent — see docs/cloud-firewall.md)
  2) Import client1.conf on your device:
       - Phone:  scan the QR code above with the WireGuard app
       - Mac/Win/Linux:  scp root@${PUBLIC_IP}:${WG_CLIENTS_DIR:-/etc/wireguard/clients}/client1.conf ./
  3) Manage clients anytime:  sudo wgmgr
EOF

msg_ok "Install complete."
