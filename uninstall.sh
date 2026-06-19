#!/usr/bin/env bash
# uninstall.sh — clean removal of wireguard-vps-installer managed components

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo ".")"

if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/network.sh"
    source "${SCRIPT_DIR}/lib/server.sh"
else
    echo "[✗] lib/ not found next to uninstall.sh." >&2
    exit 1
fi

require_root
detect_os

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"
WG_SUBNET_DEFAULT="10.0.0.0/24"

# Try to detect subnet from existing conf; else default
WG_SUBNET="${WG_SUBNET_DEFAULT}"
if [[ -f "${WG_CONF}" ]]; then
    detected="$(grep -E '^Address' "${WG_CONF}" | awk '{print $3}' | head -1 || true)"
    if [[ -n "${detected}" ]]; then
        # /24 assumed
        ip="${detected%/*}"
        last_octet="${ip##*.}"
        WG_SUBNET="${ip%.*}.0/24"
    fi
fi

msg_banner "Uninstalling WireGuard (managed by wireguard-vps-installer)"
echo "  Detected subnet: ${WG_SUBNET}"
echo ""

if ! confirm "This will STOP the VPN, REMOVE all keys, clients, iptables rules, and the wgmgr command. Continue?" "N"; then
    msg_info "Aborted."
    exit 0
fi

msg_step "Stopping and disabling wg-quick@wg0"
run stop_and_disable_wg

msg_step "Removing iptables NAT rules"
run remove_nat_rules "${WG_SUBNET}" "eth0"

msg_step "Removing wireguard configs and clients"
if [[ -d "${WG_DIR}" ]]; then
    run rm -rf "${WG_DIR}"
    msg_ok "Removed ${WG_DIR}/"
fi

msg_step "Removing /usr/local/bin/wgmgr"
run rm -f /usr/local/bin/wgmgr

# Also remove the lib directory (mirrors wgmgr's do_full_uninstall behavior —
# keeps uninstall.sh and wgmgr cmd_uninstall in sync, so neither leaves residue)
msg_step "Removing /usr/local/share/wgmgr (lib dir)"
if [[ -d /usr/local/share/wgmgr ]]; then
    run rm -rf /usr/local/share/wgmgr
    msg_ok "Removed /usr/local/share/wgmgr/"
fi

msg_step "Removing IP forwarding sysctl"
run rm -f /etc/sysctl.d/99-wireguard.conf

msg_step "Uninstalling packages (optional)"
if confirm "Also remove wireguard-tools, qrencode, iptables-persistent packages?" "N"; then
    case "${PKG_MANAGER}" in
        apt) apt-get purge -y --auto-remove wireguard qrencode iptables-persistent || true ;;
        dnf) dnf remove -y wireguard-tools qrencode iptables-services || true ;;
    esac
    msg_ok "Packages removed"
else
    msg_info "Skipped package removal"
fi

msg_ok "Uninstall complete. Reboot recommended if kernel modules were loaded."
