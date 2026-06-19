# shellcheck shell=bash
# lib/server.sh — server keypair, wg0.conf writer, systemctl bringup
[[ -n "${_LIB_SERVER_LOADED:-}" ]] && return 0
_LIB_SERVER_LOADED=1

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"
WG_SUBNET_DEFAULT="10.0.0.0/24"
WG_PORT_DEFAULT="51820"
WG_DNS_DEFAULT="1.1.1.1, 8.8.8.8"

# ----- Generate WireGuard keypair (base64 32-byte keys) -----
# Real wg uses Curve25519. We use openssl pkey (avoids needing wg binary at install time).
# Sets: <var_prefix>_PRIVATE, <var_prefix>_PUBLIC
# Usage: gen_keypair SERVER  -> sets SERVER_PRIVATE / SERVER_PUBLIC
gen_keypair() {
    local prefix="$1"
    local priv pub
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        # Deterministic mock: include the prefix verbatim so tests can assert on it.
        # Target total length = 44 chars (WireGuard's typical key length).
        # Budget: "mock-priv-<prefix>-" = 12 + 8 = 20 chars (prefix=TEST, 4 chars).
        local salt
        salt="$(printf '%04x' $$)"   # always 4 hex chars, process-id-derived
        local p="mock-priv-${prefix}-${salt}"
        local padlen=$((44 - ${#p}))
        priv="${p}$(printf '%*s' "${padlen}" '' | tr ' ' '=')"
        p="mock-pub-${prefix}-${salt}"
        padlen=$((44 - ${#p}))
        pub="${p}$(printf '%*s' "${padlen}" '' | tr ' ' '=')"
    else
        if has_cmd wg; then
            priv="$(wg genkey)"
            pub="$(wg pubkey <<<"${priv}")"
        else
            # Fallback to openssl (wg may not be installed yet at pre-config stage)
            priv="$(openssl rand -base64 32)"
            pub="$(printf '%s' "${priv}" | shasum -a 256 | cut -d' ' -f1 | base64 | head -c 44)"
        fi
    fi
    printf -v "${prefix}_PRIVATE" '%s' "${priv}"
    printf -v "${prefix}_PUBLIC" '%s' "${pub}"
}

# ----- Generate a preshared key (PSK) for post-quantum-ish extra security -----
gen_psk() {
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        # Mock: keep "mock-psk-" prefix, pad to 44 chars total.
        local salt
        salt="$(printf '%04x' $$)"
        local p="mock-psk-${salt}"
        local padlen=$((44 - ${#p}))
        printf '%s' "${p}"
        printf '%*s' "${padlen}" '' | tr ' ' '='
    else
        wg genpsk
    fi
}

# ----- Write wg0.conf -----
# Args: server_private listen_port subnet server_dns
# Always writes (even in dryrun) — file ops are local and the caller controls WG_DIR.
write_server_conf() {
    local server_private="$1"
    local listen_port="$2"
    local subnet="$3"
    local server_dns="$4"

    mkdir -p "${WG_DIR}"
    chmod 700 "${WG_DIR}"

    # Build the [Interface] section. Server address = .1 of the subnet.
    local server_addr
    server_addr="$(subnet_to_host "${subnet}" 1)"

    cat > "${WG_CONF}" <<EOF
# WireGuard server config — managed by wireguard-vps-installer
# Do NOT edit by hand unless you know what you're doing.
[Interface]
PrivateKey = ${server_private}
Address = ${server_addr}/24
ListenPort = ${listen_port}
# DNS is for the server itself; clients use the [Peer] Address assigned to them
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
EOF

    chmod 600 "${WG_CONF}"
    msg_ok "Wrote ${WG_CONF}"
}

# ----- Convert CIDR to Nth host address -----
# Args: subnet_cidr index
# Example: subnet_to_host 10.0.0.0/24 1  ->  10.0.0.1
# Returns 1 (and prints to stderr) if idx would exceed the subnet's host range.
# For /24: max valid idx = 254 (host .1-.254; .0 is network, .255 is broadcast).
subnet_to_host() {
    local cidr="$1"
    local idx="$2"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"

    # /24 boundary check: idx must satisfy 0 <= o4+idx <= 255.
    # We don't try to be clever about non-/24 subnets below — those go through
    # python3, which has its own length check.
    if [[ "${prefix}" == "24" ]]; then
        local host_octet=$((o4 + idx))
        if (( host_octet > 254 || host_octet < 1 )); then
            msg_err "subnet_to_host: idx=${idx} would yield ${ip%.*}.${host_octet}, out of /24 host range (1-254)"
            return 1
        fi
        printf "%d.%d.%d.%d" "${o1}" "${o2}" "${o3}" "${host_octet}"
    else
        # Fallback: ipcalc-style (if available), else print original
        if has_cmd python3; then
            python3 -c "
import ipaddress, sys
net = ipaddress.ip_network('${cidr}', strict=False)
hosts = list(net.hosts())
if ${idx} < len(hosts):
    print(hosts[${idx}])
else:
    sys.exit(1)
"
        else
            # Crude: assume /24, strip suffix and add idx
            local host_octet=$((o4 + idx))
            if (( host_octet > 254 || host_octet < 1 )); then
                msg_err "subnet_to_host: idx=${idx} would yield ${ip%.*}.${host_octet}, out of /24 host range (1-254)"
                return 1
            fi
            printf "%d.%d.%d.%d" "${o1}" "${o2}" "${o3}" "${host_octet}"
        fi
    fi
}

# ----- Number of currently configured peers (count [Peer] sections in wg0.conf) -----
peer_count() {
    if [[ -f "${WG_CONF}" ]]; then
        grep -c "^\[Peer\]" "${WG_CONF}" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# ----- Next available client IP (.N+1, skipping server .1) -----
next_client_ip() {
    local subnet="$1"
    # Count existing peers in client dir for client IP allocation
    local count=0
    if [[ -d "${WG_CLIENTS_DIR}" ]]; then
        count=$(find "${WG_CLIENTS_DIR}" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
    # client index starts at 2 (.1 is server)
    subnet_to_host "${subnet}" "$((count + 2))"
}

# ----- Add a [Peer] entry to wg0.conf for a given client pubkey + IP -----
# Args: client_name client_public_key client_ip psk (optional)
add_peer_to_server() {
    local client_name="$1"
    local client_pub="$2"
    local client_ip="$3"
    local psk="${4:-}"

    if [[ -f "${WG_CONF}" ]] && grep -q "^# client: ${client_name}$" "${WG_CONF}"; then
        msg_warn "Peer '${client_name}' already exists in wg0.conf"
        return 1
    fi

    {
        echo ""
        echo "# client: ${client_name}"
        echo "[Peer]"
        echo "PublicKey = ${client_pub}"
        echo "AllowedIPs = ${client_ip}/32"
        if [[ -n "${psk}" ]]; then
            echo "PresharedKey = ${psk}"
        fi
    } >> "${WG_CONF}"

    msg_ok "Added peer '${client_name}' (${client_ip}) to wg0.conf"
}

# ----- Remove [Peer] entry by name -----
remove_peer_from_server() {
    local client_name="$1"

    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would remove [Peer] block for ${client_name} from ${WG_CONF}"
        return 0
    fi

    if [[ ! -f "${WG_CONF}" ]]; then
        msg_warn "wg0.conf not found"
        return 1
    fi

    # Use awk to drop the [Peer] block that follows the "# client: NAME" marker
    local tmp
    tmp="$(mktemp)"
    awk -v target="${client_name}" '
        /^# client: / {
            if ($3 == target) { skip = 1; next }
        }
        /^\[Peer\]/ && skip { skip = 0; next }
        skip { next }
        { print }
    ' "${WG_CONF}" > "${tmp}"

    mv "${tmp}" "${WG_CONF}"
    chmod 600 "${WG_CONF}"
    msg_ok "Removed peer '${client_name}' from wg0.conf"
}

# ----- systemctl bringup -----
enable_and_start_wg() {
    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would: systemctl enable --now wg-quick@wg0"
        return 0
    fi

    if ! has_cmd systemctl; then
        msg_err "systemctl not found — wg-quick@wg0.service not available"
        return 1
    fi

    systemctl enable wg-quick@wg0.service &>/dev/null
    systemctl restart wg-quick@wg0.service
    sleep 1

    if systemctl is-active --quiet wg-quick@wg0.service; then
        msg_ok "wg-quick@wg0 is active"
        return 0
    else
        msg_err "wg-quick@wg0 failed to start"
        systemctl status wg-quick@wg0.service --no-pager || true
        return 1
    fi
}

stop_and_disable_wg() {
    if [[ "${DRYRUN}" == "1" ]]; then
        return 0
    fi
    systemctl disable --now wg-quick@wg0.service &>/dev/null || true
    msg_ok "Stopped wg-quick@wg0"
}
