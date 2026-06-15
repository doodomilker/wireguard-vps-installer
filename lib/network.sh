# shellcheck shell=bash
# lib/network.sh — public IPv4 detection, port check, iptables helpers
# Source guard — do not source twice
[[ -n "${_LIB_NETWORK_LOADED:-}" ]] && return 0
_LIB_NETWORK_LOADED=1

# ----- Detect public IPv4 -----
# Args: --override IP (optional)
# Sets: PUBLIC_IP
detect_public_ip() {
    local override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --override) override="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -n "${override}" ]]; then
        PUBLIC_IP="${override}"
        return 0
    fi

    # Try multiple services in order — prefer IPv4
    local services=(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    for svc in "${services[@]}"; do
        if has_cmd curl; then
            local ip
            ip="$(curl -4 -fsSL --max-time 5 "${svc}" 2>/dev/null | tr -d '[:space:]')"
            if [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                PUBLIC_IP="${ip}"
                msg_info "Detected public IP: ${PUBLIC_IP} (via ${svc})"
                return 0
            fi
        fi
    done

    msg_err "Could not auto-detect public IPv4."
    msg_err "Pass --endpoint <your-ip:port> to install.sh."
    return 1
}

# ----- Port-in-use check -----
# Returns 0 if port is FREE (usable), 1 if IN-USE
port_is_free() {
    local port="$1"
    if has_cmd ss; then
        if ss -lntu 2>/dev/null | awk '{print $5}' | grep -E "[:.]${port}$" &>/dev/null; then
            return 1
        fi
    elif has_cmd netstat; then
        if netstat -lntu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" &>/dev/null; then
            return 1
        fi
    fi
    return 0
}

# ----- Wait until port is listening (for wg-quick bringup) -----
# Args: interface name, timeout seconds
wait_for_interface() {
    local iface="$1"
    local timeout="${2:-15}"
    local elapsed=0
    while (( elapsed < timeout )); do
        if ip link show "${iface}" 2>/dev/null | grep -q "UP"; then
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done
    return 1
}

# ----- Enable IP forwarding (persistent) -----
enable_ip_forward() {
    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would enable IP forwarding + write /etc/sysctl.d/99-wireguard.conf"
        return 0
    fi

    # Apply immediately
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

    # Persist
    local conf="/etc/sysctl.d/99-wireguard.conf"
    if [[ ! -f "${conf}" ]] || ! grep -q "ip_forward=1" "${conf}" 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" > "${conf}"
        msg_ok "Wrote ${conf}"
    else
        msg_info "IP forwarding already persistent in ${conf}"
    fi
}

# ----- Apply iptables NAT rule (Masquerade) -----
apply_nat_rules() {
    local subnet="$1"  # e.g. 10.0.0.0/24
    local iface="${2:-eth0}"  # egress interface

    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would: iptables -t nat -A POSTROUTING -s ${subnet} -o ${iface} -j MASQUERADE"
        return 0
    fi

    # Detect egress iface if user passed default eth0 but it's actually ens3/enp0s3
    if [[ "${iface}" == "eth0" ]] && ! ip link show eth0 &>/dev/null; then
        iface="$(ip route | awk '/default/ {print $5; exit}')"
        msg_info "Auto-detected egress interface: ${iface}"
    fi

    # Add masquerade if not already there
    if ! iptables -t nat -C POSTROUTING -s "${subnet}" -o "${iface}" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "${subnet}" -o "${iface}" -j MASQUERADE
        msg_ok "Added iptables MASQUERADE rule for ${subnet} via ${iface}"
    else
        msg_info "iptables MASQUERADE rule already exists"
    fi

    # Add FORWARD accept for wg subnet (defensive)
    if ! iptables -C FORWARD -s "${subnet}" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -s "${subnet}" -j ACCEPT
        iptables -A FORWARD -d "${subnet}" -j ACCEPT
        msg_ok "Added iptables FORWARD accept for ${subnet}"
    fi

    # Persist rules
    persist_iptables_rules
}

persist_iptables_rules() {
    if [[ "${DRYRUN}" == "1" ]]; then
        return 0
    fi
    case "${PKG_MANAGER}" in
        apt)
            if has_cmd netfilter-persistent; then
                netfilter-persistent save &>/dev/null && msg_ok "Persisted iptables via netfilter-persistent"
            else
                msg_warn "netfilter-persistent not installed — rules will not survive reboot"
            fi
            ;;
        dnf)
            if has_cmd iptables-services; then
                service iptables save &>/dev/null 2>&1 && msg_ok "Persisted iptables via iptables-services"
                systemctl enable iptables &>/dev/null
            else
                msg_warn "iptables-services not installed — rules will not survive reboot"
            fi
            ;;
    esac
}

# ----- Remove iptables NAT rule (for uninstall) -----
remove_nat_rules() {
    local subnet="$1"
    local iface="${2:-eth0}"

    if [[ "${DRYRUN}" == "1" ]]; then
        return 0
    fi

    if [[ "${iface}" == "eth0" ]] && ! ip link show eth0 &>/dev/null; then
        iface="$(ip route | awk '/default/ {print $5; exit}')"
    fi

    iptables -t nat -D POSTROUTING -s "${subnet}" -o "${iface}" -j MASQUERADE 2>/dev/null && \
        msg_ok "Removed MASQUERADE rule" || msg_info "MASQUERADE rule not present"
    iptables -D FORWARD -s "${subnet}" -j ACCEPT 2>/dev/null && \
        msg_ok "Removed FORWARD rule (src)" || true
    iptables -D FORWARD -d "${subnet}" -j ACCEPT 2>/dev/null && \
        msg_ok "Removed FORWARD rule (dst)" || true

    persist_iptables_rules
}
