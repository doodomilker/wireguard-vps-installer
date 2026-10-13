#!/usr/bin/env bash
# wireguard-vps-installer — one-shot install (standalone, self-contained)
# Usage A (online):  curl -fsSL .../install.sh | sudo bash
# Usage B (offline): git clone https://github.com/doodomilker/wireguard-vps-installer.git
#                   && cd wireguard-vps-installer && sudo ./install.sh
# Note: not using 'set -u' because we have many optional CLI flags
set -eo pipefail

# ===== Inline library functions =====
# These are the lib/*.sh contents, embedded for curl | bash compatibility.
# When running from a local checkout (lib/ exists), the functions below
# are NOT used — the lib/*.sh are sourced directly.

# lib/common.sh — color output, logging, OS detection, package manager
# Sourced by install.sh / uninstall.sh / wgmgr. Do NOT execute directly.

# ----- Colors (auto-disable on non-tty) -----
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD=""
fi

# ----- Logging -----
msg_info()  { printf "%s[i]%s %s\n" "${C_BLUE}" "${C_RESET}" "$*"; }
msg_ok()    { printf "%s[✓]%s %s\n" "${C_GREEN}" "${C_RESET}" "$*"; }
msg_warn()  { printf "%s[!]%s %s\n" "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
msg_err()   { printf "%s[✗]%s %s\n" "${C_RED}" "${C_RESET}" "$*" >&2; }
msg_step()  { printf "\n%s== %s ==%s\n" "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
msg_banner() {
    printf "%s%s%s\n" "${C_BOLD}${C_BLUE}" "------------------------------------------------" "${C_RESET}"
    printf "%s%s %s%s\n" "${C_BOLD}" "$1" "${C_RESET}"
    printf "%s%s%s\n" "${C_BOLD}${C_BLUE}" "------------------------------------------------" "${C_RESET}"
}

# ----- Root check -----
require_root() {
    # In dryrun mode, skip the root check so we can test on macOS dev machines.
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        msg_err "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ----- OS detection -----
# Sets: OS_ID, OS_VERSION, OS_LIKE, PKG_MANAGER, OS_PRETTY
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        msg_err "Cannot detect OS: /etc/os-release not found."
        exit 3
    fi
    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
    OS_LIKE="${ID_LIKE:-}"
    OS_PRETTY="${PRETTY_NAME:-${ID}}"

    case "${OS_ID}" in
        debian|ubuntu)
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            PKG_MANAGER="dnf"
            ;;
        *)
            # Fallback via ID_LIKE
            if [[ "${OS_LIKE}" == *"debian"* ]]; then
                msg_err "Unsupported Debian-derivative: ${OS_PRETTY}. Use Debian/Ubuntu."
                exit 3
            elif [[ "${OS_LIKE}" == *"rhel"* || "${OS_LIKE}" == *"fedora"* ]]; then
                msg_err "Unsupported RHEL-derivative: ${OS_PRETTY}. Use CentOS Stream 8/9, Rocky 8/9, Fedora, or RHEL 8/9."
                exit 3
            else
                msg_err "Unsupported OS: ${OS_PRETTY}"
                msg_err "Supported: Debian 11+, Ubuntu 20.04+, CentOS Stream 8/9, Rocky 8/9, Fedora 39+, RHEL 8/9"
                exit 3
            fi
            ;;
    esac
}

# ----- EOL check -----
check_os_ok() {
    case "${OS_ID}" in
        debian)
            # 11+ supported
            local major="${OS_VERSION%%.*}"
            if [[ -n "${major}" ]] && (( major < 11 )); then
                msg_err "Debian ${OS_VERSION} is EOL. Please use Debian 11 or 12."
                exit 3
            fi
            ;;
        ubuntu)
            # 20.04+ supported
            local major="${OS_VERSION%%.*}"
            if [[ -n "${major}" ]] && (( major < 20 )); then
                msg_err "Ubuntu ${OS_VERSION} is EOL. Please use Ubuntu 20.04 or newer."
                exit 3
            fi
            ;;
        centos|rhel|rocky|almalinux)
            # 8+ supported (CentOS 7 not supported)
            if [[ "${OS_VERSION}" == "7" ]]; then
                msg_err "${OS_PRETTY} is EOL (CentOS 7 reached EOL 2024-06-30). Please upgrade to CentOS Stream 8/9 or Rocky 8/9."
                exit 3
            fi
            ;;
        fedora)
            # 39+ supported
            local major="${OS_VERSION%%.*}"
            if [[ -n "${major}" ]] && (( major < 39 )); then
                msg_err "Fedora ${OS_VERSION} is EOL. Please use Fedora 39 or newer."
                exit 3
            fi
            ;;
    esac
}

# ----- Package installation -----
# Args: package names...
pkg_install() {
    if [[ "$#" -eq 0 ]]; then
        return 0
    fi
    msg_info "Installing packages: $*"
    case "${PKG_MANAGER}" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y --no-install-recommends "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        *)
            msg_err "Unknown package manager: ${PKG_MANAGER}"
            exit 1
            ;;
    esac
}

# ----- WireGuard package set (shared by server mode + relay mode) -----
install_wg_packages() {
    msg_step "Installing WireGuard and helpers"

    local pkgs=()
    case "${PKG_MANAGER}" in
        apt)
            pkgs=(wireguard qrencode iptables-persistent)
            ;;
        dnf)
            # Enable EPEL for qrencode on RHEL-based
            if ! has_cmd qrencode; then
                dnf install -y epel-release || msg_warn "epel-release install failed (qrencode may not be available)"
            fi
            pkgs=(wireguard-tools qrencode iptables-services)
            ;;
    esac

    run pkg_install "${pkgs[@]}"
}

# ----- Command exists -----
has_cmd() {
    command -v "$1" &>/dev/null
}

# ----- Dryrun-aware command runner -----
# In dryrun mode, prints command instead of executing.
# Sets: DRYRUN (0 or 1)
DRYRUN="${DRYRUN:-0}"
run() {
    if [[ "${DRYRUN}" == "1" ]]; then
        printf "  [dryrun] $ %s\n" "$*"
        return 0
    fi
    "$@"
}

# ----- Confirm prompt (defaults to no) -----
# Usage: confirm "Message" [y/N]
confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-N}"
    local reply
    if [[ ! -t 0 ]]; then
        # Non-interactive stdin — assume no
        return 1
    fi
    read -r -p "$(printf '%s' "${prompt} [y/N]: ")" reply
    case "${reply:-${default}}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# lib/network.sh — public IPv4 detection, port check, iptables helpers
# Source guard — do not source twice
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
    local added_forward=0
    if ! iptables -C FORWARD -s "${subnet}" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -s "${subnet}" -j ACCEPT
        added_forward=1
    fi
    if ! iptables -C FORWARD -d "${subnet}" -j ACCEPT 2>/dev/null; then
        iptables -A FORWARD -d "${subnet}" -j ACCEPT
        added_forward=1
    fi
    if (( added_forward )); then
        msg_ok "Added missing iptables FORWARD accept rule(s) for ${subnet}"
    else
        msg_info "iptables FORWARD accept rules already exist"
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

# lib/server.sh — server keypair, wg0.conf writer, systemctl bringup
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

    # Drop the WHOLE "[Peer]" block that follows the "# client: NAME" marker.
    # NB: dropping only the marker + the [Peer] header leaves the block BODY
    # (PublicKey / PresharedKey / AllowedIPs) behind; those dangling fields then
    # sit inside [Interface] and wg-quick refuses to start the interface at all
    # ("Line unrecognized: `PublicKey = ...'") — the whole client-facing service
    # goes down. Skip to the next marker/header/blank line instead.
    local tmp
    tmp="$(mktemp)"
    awk -v target="${client_name}" '
        /^# client: / && $3 == target { skip = 1; next }
        skip && /^\[Peer\]/ { next }
        skip {
            if ($0 ~ /^# client: / || $0 ~ /^\[/ || $0 ~ /^[[:space:]]*$/) { skip = 0 } else { next }
        }
        { print }
    ' "${WG_CONF}" > "${tmp}"

    # Guard: never install a conf whose [Interface] section carries peer fields
    # (that is exactly the corruption described above). Refuse and keep the
    # original file, so a removal can never take the interface offline.
    if awk '
        /^\[Interface\]/ { i = 1 }
        /^\[Peer\]/ { i = 0 }
        i && /^(PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[[:space:]]*=/ { bad = 1 }
        END { exit bad ? 0 : 1 }
    ' "${tmp}"; then
        rm -f "${tmp}"
        msg_err "移除 '${client_name}' 后配置出现游离 peer 字段 — 已放弃写入，${WG_CONF} 未改动"
        return 1
    fi

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

# lib/client.sh — client keypair, conf writer, QR (terminal ASCII + PNG), base64
_LIB_CLIENT_LOADED=1

WG_DIR="/etc/wireguard"
WG_CLIENTS_DIR="${WG_DIR}/clients"

# ----- Validate client name (no spaces, no special chars) -----
# Args: name -> exits 1 if invalid
validate_client_name() {
    local name="$1"
    if [[ -z "${name}" ]]; then
        msg_err "Client name cannot be empty"
        return 1
    fi
    if [[ ! "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        msg_err "Client name must match [a-zA-Z0-9_-]+ (got: '${name}')"
        return 1
    fi
    if [[ ${#name} -gt 32 ]]; then
        msg_err "Client name too long (max 32 chars)"
        return 1
    fi
    return 0
}

# ----- Generate client keypair, write conf -----
# Args: client_name server_public server_endpoint server_subnet server_dns use_psk
# Writes: /etc/wireguard/clients/<name>.conf (chmod 600)
# Returns: 0 on success; client_private/client_public set in caller scope via globals
generate_client() {
    local name="$1"
    local server_public="$2"
    local server_endpoint="$3"
    local subnet="$4"
    local dns="$5"
    local use_psk="${6:-1}"

    if ! validate_client_name "${name}"; then
        return 1
    fi

    local conf_path="${WG_CLIENTS_DIR}/${name}.conf"
    if [[ -f "${conf_path}" && "${DRYRUN:-0}" != "1" ]]; then
        msg_err "Client '${name}' already exists at ${conf_path}"
        return 1
    fi

    # Allocate IP
    local client_ip
    client_ip="$(next_client_ip "${subnet}")"

    # Generate keys (uses gen_keypair from server.sh)
    gen_keypair "CLIENT"
    local priv="${CLIENT_PRIVATE}"
    local pub="${CLIENT_PUBLIC}"
    local psk=""
    if [[ "${use_psk}" == "1" ]]; then
        psk="$(gen_psk)"
    fi

    # In dryrun, do not write the conf (we just want keys + IP for inspection).
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would write ${conf_path} (client ${name}, IP ${client_ip})"
        CLIENT_IP="${client_ip}"
        CLIENT_PRIVATE="${priv}"
        CLIENT_PUBLIC="${pub}"
        CLIENT_PSK="${psk}"
        return 0
    fi

    mkdir -p "${WG_CLIENTS_DIR}"
    chmod 700 "${WG_CLIENTS_DIR}"

    cat > "${conf_path}" <<EOF
# WireGuard client config: ${name}
# Generated by wireguard-vps-installer
[Interface]
PrivateKey = ${priv}
Address = ${client_ip}/32
DNS = ${dns}

[Peer]
PublicKey = ${server_public}
$(if [[ -n "${psk}" ]]; then printf 'PresharedKey = %s\n' "${psk}"; fi)
Endpoint = ${server_endpoint}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "${conf_path}"
    CLIENT_IP="${client_ip}"
    CLIENT_PRIVATE="${priv}"
    CLIENT_PUBLIC="${pub}"
    CLIENT_PSK="${psk}"
    msg_ok "Generated client '${name}' at ${conf_path} (${client_ip})"
}

# ----- Render terminal ASCII QR code -----
# Args: conf_path
render_qr_terminal() {
    local conf_path="$1"
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would print terminal ASCII QR for ${conf_path}"
        return 0
    fi
    if ! has_cmd qrencode; then
        msg_warn "qrencode not installed — skipping terminal QR"
        return 1
    fi
    echo ""
    qrencode -t ansiutf8 < "${conf_path}"
}

# ----- Render PNG QR code -----
# Args: conf_path output_png
render_qr_png() {
    local conf_path="$1"
    local out_png="$2"
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would write PNG QR to ${out_png}"
        return 0
    fi
    if ! has_cmd qrencode; then
        msg_warn "qrencode not installed — skipping PNG QR"
        return 1
    fi
    # Use level M error correction for better compatibility with mobile
    # WireGuard clients (default L sometimes produces codes that Android/iOS
    # apps refuse to scan, especially for configs containing PSK + DNS).
    qrencode -t png -l M -o "${out_png}" < "${conf_path}"
    chmod 600 "${out_png}"
    msg_ok "Wrote PNG QR: ${out_png}"
}

# ----- Base64 encode conf (for sharing via terminal paste) -----
# Args: conf_path
render_base64() {
    local conf_path="$1"
    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would print base64 of ${conf_path}"
        return 0
    fi
    base64 "${conf_path}"
}

# ----- Full client delivery: writes conf, renders all 3 outputs -----
# Args: client_name server_public server_endpoint subnet dns use_psk
# In dryrun mode, conf is NOT written (caller still gets CLIENT_* globals), but
# QR rendering is skipped entirely (since terminal ASCII would clutter tests).
deliver_client() {
    local name="$1"
    local server_public="$2"
    local server_endpoint="$3"
    local subnet="$4"
    local dns="$5"
    local use_psk="${6:-1}"

    if ! generate_client "${name}" "${server_public}" "${server_endpoint}" "${subnet}" "${dns}" "${use_psk}"; then
        return 1
    fi

    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_ok "[dryrun] client '${name}' deliverable built (IP ${CLIENT_IP})"
        return 0
    fi

    local conf_path="${WG_CLIENTS_DIR}/${name}.conf"
    local png_path="${WG_CLIENTS_DIR}/${name}.png"

    render_qr_png "${conf_path}" "${png_path}"

    msg_step "Client '${name}' ready"
    echo ""
    echo "Config file : ${conf_path}"
    echo "PNG QR      : ${png_path}"
    echo ""
    echo "── conf ──────────────────────────────────────────"
    cat "${conf_path}"
    echo "──────────────────────────────────────────────────"
    echo ""

    render_qr_terminal "${conf_path}"
}

# ----- List existing clients (from clients/ dir) -----
list_clients() {
    if [[ ! -d "${WG_CLIENTS_DIR}" ]]; then
        echo "(no clients yet)"
        return 0
    fi
    local found=0
    while IFS= read -r -d '' f; do
        local name
        name="$(basename "${f}" .conf)"
        local ip
        ip="$(grep -E '^Address' "${f}" | awk '{print $3}' || echo '?')"
        printf "  %-24s  %s\n" "${name}" "${ip}"
        found=1
    done < <(find "${WG_CLIENTS_DIR}" -maxdepth 1 -name "*.conf" -type f -print0 2>/dev/null | sort -z)
    if [[ ${found} -eq 0 ]]; then
        echo "(no clients yet)"
    fi
}

# ----- Get client name from conf path -----
client_name_from_path() {
    basename "$1" .conf
}

# ----- Remove client: conf + png + peer from wg0.conf -----
remove_client() {
    local name="$1"

    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would remove client '${name}'"
        return 0
    fi

    local conf="${WG_CLIENTS_DIR}/${name}.conf"
    local png="${WG_CLIENTS_DIR}/${name}.png"

    if [[ ! -f "${conf}" ]]; then
        msg_err "Client '${name}' does not exist (no conf at ${conf})"
        return 1
    fi

    remove_peer_from_server "${name}"

    rm -f "${conf}" "${conf}.bak" "${png}"
    msg_ok "Removed client '${name}'"

    # Reload wg-quick so the running interface reflects removal
    if has_cmd systemctl && systemctl is-active --quiet wg-quick@wg0.service 2>/dev/null; then
        systemctl reload wg-quick@wg0.service 2>/dev/null || \
            systemctl restart wg-quick@wg0.service 2>/dev/null || true
    fi
}

# ----- Print current server config summary -----
print_server_summary() {
    local server_pub="$1"
    local listen_port="$2"
    local subnet="$3"
    local dns="$4"
    local endpoint="$5"

    msg_banner "WireGuard Server Configuration"
    printf "  %-18s %s\n" "Server PublicKey:" "${server_pub}"
    printf "  %-18s %s\n" "Endpoint:"        "${endpoint}"
    printf "  %-18s %s\n" "ListenPort:"      "${listen_port}"
    printf "  %-18s %s\n" "Subnet:"          "${subnet}"
    printf "  %-18s %s\n" "DNS:"             "${dns}"
    printf "  %-18s %s\n" "Config:"          "${WG_DIR}/wg0.conf"
    printf "  %-18s %s\n" "Clients dir:"     "${WG_CLIENTS_DIR}"
    printf "  %-18s %s\n" "Service:"         "wg-quick@wg0.service"
}
# ===== Inline relay subset (mirrors lib/relay.sh — EXIT node side) =====
# install.sh must stay runnable as `curl | bash`, so the relay helpers it needs
# are inlined here exactly like the other lib sections above.
# Keep in sync with lib/relay.sh — same function names, same rendered output.
WG_RELAY_IF="${WG_RELAY_IF:-wg1}"
WG_RELAY_DIR="${WG_RELAY_DIR:-/etc/wireguard}"
WG_RELAY_CONF="${WG_RELAY_CONF:-${WG_RELAY_DIR}/wg1.conf}"
WG_RELAY_PAYLOAD_FILE="${WG_RELAY_PAYLOAD_FILE:-${WG_RELAY_DIR}/relay-payload.txt}"
WG_RELAY_PORT_DEFAULT="${WG_RELAY_PORT_DEFAULT:-51821}"
WG_RELAY_SUBNET="${WG_RELAY_SUBNET:-10.77.0.0/24}"
WG_RELAY_ENTRY_ADDR="${WG_RELAY_ENTRY_ADDR:-10.77.0.1}"
WG_RELAY_EXIT_ADDR="${WG_RELAY_EXIT_ADDR:-10.77.0.2}"
WG_RELAY_REPO_RAW="${WG_RELAY_REPO_RAW:-https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main}"

relay_b64_encode() {
    base64 | tr -d '\n'
}

# Args: exit_endpoint exit_pubkey entry_privkey entry_addr exit_addr psk [client_subnet] [name]
relay_payload_build() {
    local exit_endpoint="$1"
    local exit_pubkey="$2"
    local entry_privkey="$3"
    local entry_addr="$4"
    local exit_addr="$5"
    local psk="$6"
    local client_subnet="${7:-}"
    local name="${8:-exit1}"

    {
        printf 'v=1\n'
        printf 'kind=wg-relay\n'
        printf 'name=%s\n'          "${name}"
        printf 'exit_endpoint=%s\n' "${exit_endpoint}"
        printf 'exit_pubkey=%s\n'   "${exit_pubkey}"
        printf 'entry_privkey=%s\n' "${entry_privkey}"
        printf 'entry_addr=%s\n'    "${entry_addr}"
        printf 'exit_addr=%s\n'     "${exit_addr}"
        printf 'psk=%s\n'           "${psk}"
        printf 'client_subnet=%s\n' "${client_subnet}"
    } | relay_b64_encode
}

# Args: exit_privkey entry_pubkey psk port exit_addr entry_tunnel_ip relay_subnet egress_if
relay_exit_conf_render() {
    local exit_priv="$1"
    local entry_pub="$2"
    local psk="$3"
    local port="$4"
    local exit_addr="$5"
    local entry_tunnel_ip="$6"
    local relay_subnet="$7"
    local egress_if="$8"

    cat <<EOF
# WireGuard relay listener (${WG_RELAY_IF}) — EXIT node, managed by wireguard-vps-installer
# This machine is the internet-facing egress for the entry node's clients.
# Traffic arrives from the entry (${entry_tunnel_ip}) and is NATed out ${egress_if}.
[Interface]
PrivateKey = ${exit_priv}
Address = ${exit_addr}/24
ListenPort = ${port}
MTU = 1420
PostUp = sysctl -w net.ipv4.conf.%i.rp_filter=2; sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i %i -o ${egress_if} -j ACCEPT; iptables -A FORWARD -i ${egress_if} -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${relay_subnet} -o ${egress_if} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o ${egress_if} -j ACCEPT; iptables -D FORWARD -i ${egress_if} -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${relay_subnet} -o ${egress_if} -j MASQUERADE

[Peer]
# Entry node — it is the only peer allowed to enter this listener.
PublicKey = ${entry_pub}
$(if [[ -n "${psk}" ]]; then printf 'PresharedKey = %s\n' "${psk}"; fi)
AllowedIPs = ${entry_tunnel_ip}/32
EOF
}

relay_detect_egress_iface() {
    local iface
    iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || true)"
    if [[ -z "${iface}" ]]; then
        iface="eth0"
    fi
    printf '%s' "${iface}"
}

# Args: exit_privkey entry_pubkey psk port exit_addr entry_tunnel_ip relay_subnet egress_if
relay_exit_write_conf() {
    local exit_priv="$1" entry_pub="$2" psk="$3" port="$4" exit_addr="$5"
    local entry_tunnel_ip="$6" relay_subnet="$7" egress_if="$8"

    mkdir -p "$(dirname "${WG_RELAY_CONF}")"
    chmod 700 "$(dirname "${WG_RELAY_CONF}")" 2>/dev/null || true
    relay_exit_conf_render "${exit_priv}" "${entry_pub}" "${psk}" "${port}" \
        "${exit_addr}" "${entry_tunnel_ip}" "${relay_subnet}" "${egress_if}" \
        >"${WG_RELAY_CONF}"
    chmod 600 "${WG_RELAY_CONF}"
    msg_ok "Wrote ${WG_RELAY_CONF}"
}

relay_persist_ip_forward() {
    local conf="/etc/sysctl.d/99-wireguard-relay.conf"
    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would write ${conf} (net.ipv4.ip_forward=1)"
        return 0
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if [[ ! -f "${conf}" ]] || ! grep -q "ip_forward=1" "${conf}" 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >"${conf}"
        msg_ok "Wrote ${conf}"
    else
        msg_info "IP forwarding already persistent in ${conf}"
    fi
}

relay_iface_up() {
    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would: systemctl enable --now wg-quick@${WG_RELAY_IF}"
        return 0
    fi
    if ! has_cmd systemctl; then
        msg_err "systemctl not found — cannot enable wg-quick@${WG_RELAY_IF}"
        return 1
    fi
    systemctl enable "wg-quick@${WG_RELAY_IF}.service" &>/dev/null || true
    if ! systemctl restart "wg-quick@${WG_RELAY_IF}.service"; then
        msg_err "wg-quick@${WG_RELAY_IF} failed to start"
        systemctl status "wg-quick@${WG_RELAY_IF}.service" --no-pager || true
        return 1
    fi
    sleep 1
    if systemctl is-active --quiet "wg-quick@${WG_RELAY_IF}.service"; then
        msg_ok "wg-quick@${WG_RELAY_IF} is active"
        return 0
    fi
    msg_err "wg-quick@${WG_RELAY_IF} not active"
    systemctl status "wg-quick@${WG_RELAY_IF}.service" --no-pager || true
    return 1
}

relay_payload_save() {
    local payload="$1"
    if [[ "${DRYRUN}" == "1" ]]; then
        msg_info "[dryrun] would save payload to ${WG_RELAY_PAYLOAD_FILE}"
        return 0
    fi
    mkdir -p "$(dirname "${WG_RELAY_PAYLOAD_FILE}")"
    printf '%s\n' "${payload}" >"${WG_RELAY_PAYLOAD_FILE}"
    chmod 600 "${WG_RELAY_PAYLOAD_FILE}"
    msg_ok "Payload saved: ${WG_RELAY_PAYLOAD_FILE}"
}

# ---------- Role selection (server vs relay exit node) ----------
install_usage() {
    cat <<EOF
wireguard-vps-installer — install.sh

Usage:
  sudo ./install.sh                     交互选择角色（默认: 服务端）
  curl -fsSL .../install.sh | sudo bash  同上（非交互时默认服务端）

角色 / 模式:
  --mode server        本机作为 WireGuard 服务端（默认，客户端直连本机出网）
  --mode relay-exit    本机作为中转到落地机（客户端仍连【入口 VPS】，出网走本机）

选项:
  --port <port>              服务端模式监听端口（默认 51820）
  --subnet <cidr>            服务端子网（默认 10.0.0.0/24）
  --dns "<dns1, dns2>"       客户端 DNS（默认 1.1.1.1, 8.8.8.8）
  --endpoint <ip:port>       公网 endpoint 覆盖（NAT/域名场景）
  --relay-port <port>        中转模式监听端口（默认 51821）
  --yes, -y                  跳过确认（脚本模式）
  -h, --help                 显示本帮助
EOF
}

# Sets INSTALL_MODE=server|relay-exit. Prompts only on an interactive tty and
# only when --mode was not passed — so `curl | bash`, cron and CI keep the
# original server behaviour untouched.
install_select_mode() {
    case "${INSTALL_MODE}" in
        ""|server)     INSTALL_MODE="${INSTALL_MODE:-server}" ;;
        relay|relay-exit) INSTALL_MODE="relay-exit" ;;
        *)
            msg_err "Unknown --mode: '${INSTALL_MODE}' (expected: server | relay-exit)"
            exit 1
            ;;
    esac

    # --mode given → explicit choice, never prompt.
    [[ -n "${INSTALL_MODE_EXPLICIT:-}" ]] && return 0
    # Non-interactive (curl | bash, cron) → keep the historical default.
    [[ ! -t 0 ]] && return 0

    printf '\n%s== 选择本机角色 ==%s\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
    printf '  1) 服务端（默认）：客户端直连本机，出网 IP = 本机\n'
    printf '  2) 中转落地机：客户端仍连【入口 VPS】的 IP，出网走本机(美国 VPS 场景)\n'
    printf '请选择 [1/2] (默认 1): '
    local choice=""
    read -r choice || true
    case "${choice}" in
        2|relay|relay-exit|Relay|R) INSTALL_MODE="relay-exit" ;;
        *) INSTALL_MODE="server" ;;
    esac
    msg_ok "模式: ${INSTALL_MODE}"
}

# ---------- Relay EXIT node main flow (mode 2) ----------
relay_exit_main() {
    msg_banner "Relay EXIT node — 中转落地机模式"

    local relay_port="${WG_RELAY_PORT:-${WG_RELAY_PORT_DEFAULT}}"
    if [[ -t 0 && -z "${WG_RELAY_PORT:-}" ]]; then
        printf '中转隧道监听端口 (回车用默认 %s): ' "${WG_RELAY_PORT_DEFAULT}"
        local answer=""
        read -r answer || true
        [[ -n "${answer}" ]] && relay_port="${answer}"
    fi
    if ! [[ "${relay_port}" =~ ^[0-9]+$ ]] || (( relay_port < 1 || relay_port > 65535 )); then
        msg_err "非法中转端口: '${relay_port}'"
        exit 1
    fi
    if ! port_is_free "${relay_port}"; then
        msg_err "端口 ${relay_port} 已被占用 — 用 --relay-port <port> 另选一个"
        exit 1
    fi

    # ---------- Packages ----------
    install_wg_packages

    # ---------- Public IP (this node is the endpoint the entry dials) ----------
    msg_step "Detecting public endpoint"
    if ! detect_public_ip; then
        msg_err "无法探测本机公网 IPv4，请用 --endpoint <ip:port> 指定"
        exit 1
    fi

    # ---------- Keys ----------
    # Called directly (not via run) because gen_keypair sets globals in the
    # caller's scope and has its own DRYRUN mock branch.
    msg_step "Generating relay keys (entry side + exit side + PSK)"
    if [[ "${PKG_MANAGER}" == "dnf" ]]; then
        run modprobe wireguard 2>/dev/null || true
    fi
    gen_keypair "RELAY_ENTRY"
    gen_keypair "RELAY_EXIT"
    local psk=""
    if [[ "${USE_PSK}" == "1" ]]; then
        psk="$(gen_psk)"
    fi

    # ---------- Listener config ----------
    msg_step "Writing relay listener config"
    local egress_if
    egress_if="$(relay_detect_egress_iface)"
    msg_info "Egress interface: ${egress_if}"
    relay_exit_write_conf "${RELAY_EXIT_PRIVATE}" "${RELAY_ENTRY_PUBLIC}" "${psk}" \
        "${relay_port}" "${WG_RELAY_EXIT_ADDR}" "${WG_RELAY_ENTRY_ADDR}" \
        "${WG_RELAY_SUBNET}" "${egress_if}"
    relay_persist_ip_forward

    # ---------- Bring up the listener ----------
    if ! relay_iface_up; then
        msg_err "中转接口启动失败 — 检查: journalctl -u wg-quick@${WG_RELAY_IF}"
        exit 1
    fi

    # ---------- Enrollment payload for the entry node ----------
    local endpoint="${PUBLIC_IP}:${relay_port}"
    local payload
    payload="$(relay_payload_build "${endpoint}" "${RELAY_EXIT_PUBLIC}" "${RELAY_ENTRY_PRIVATE}" \
        "${WG_RELAY_ENTRY_ADDR}" "${WG_RELAY_EXIT_ADDR}" "${psk}" "" "exit1")"
    relay_payload_save "${payload}"

    relay_print_enroll_summary "${payload}" "${endpoint}" "${relay_port}" "${PUBLIC_IP}" "${egress_if}"
    exit 0
}

relay_print_enroll_summary() {
    local payload="$1" endpoint="$2" port="$3" public_ip="$4" egress_if="$5"

    msg_banner "中转落地机（EXIT）已就绪"
    printf "  %-18s %s\n" "Public IP:"   "${public_ip}"
    printf "  %-18s %s\n" "Relay endpoint:" "${endpoint}"
    printf "  %-18s %s\n" "ListenPort:"   "${port}"
    printf "  %-18s %s\n" "Tunnel subnet:" "${WG_RELAY_SUBNET}"
    printf "  %-18s %s\n" "Config:"       "${WG_RELAY_CONF}"
    printf "  %-18s %s\n" "Service:"      "wg-quick@${WG_RELAY_IF}.service"
    printf "  %-18s %s\n" "Egress iface:" "${egress_if}"

    msg_step "NEXT STEPS"
    cat <<EOF
  1) 在本机云防火墙放行 UDP ${port}（入口机要拨进来；入口机侧不需要任何入站改动）
  2) 把下面这条命令【整行复制】到【旧 VPS / 入口机】执行一次 — 它会自己下载所需脚本，无需预装：
       ⚠️ 一定整行复制：不要把 URL 和 | 拆成两行，也不要在 URL 后面留空格
          （拆行会报 `curl: (3) URL rejected: Malformed input to a URL function`）
       curl -fsSL ${WG_RELAY_REPO_RAW}/relay-entry.sh | sudo bash -s -- --enroll '${payload}'
     粘贴 payload 总出问题（折行/被截断）？改用文件方式，完全不粘贴：
       把本机 ${WG_RELAY_PAYLOAD_FILE} 传到入口机（scp 或复制内容存成文件），然后执行
       sudo bash relay-entry.sh --enroll-file /path/to/relay-payload.txt
       （也可以管道： cat relay-payload.txt | sudo bash relay-entry.sh --enroll-file -）
  3) 入口机执行完成后回到本机验证握手：
       wg show ${WG_RELAY_IF}          # 应看到 latest handshake: N seconds ago
  4) 手机连上 VPN 后打开 https://ifconfig.me —— 显示的应该是本机 IP ${public_ip}
     （拨号 endpoint 仍是入口机 IP，客户端配置一个字都不用改）
  5) 关闭中转：去入口机执行  sudo relay-entry.sh --disable --yes

  PAYLOAD（已在 ${WG_RELAY_PAYLOAD_FILE}，0600；含入口机侧私钥，别外传）:
  ${payload}
EOF
}
# ===== Script setup =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo ".")"
if [[ -f "${SCRIPT_DIR}/wgmgr" ]]; then
    WGMGR_SOURCE="${SCRIPT_DIR}"
else
    WGMGR_SOURCE=""
fi

# ===== Main install logic =====
# ---------- CLI parsing ----------
# Historically install.sh parsed NO flags at all: docs/customization.md advertised
# --port / --subnet / --dns / --endpoint, but they were silently ignored and the
# defaults always won. This parser makes those documented flags real and adds the
# relay flags. Everything here only overrides the defaults below.
INSTALL_MODE="${INSTALL_MODE:-}"
INSTALL_MODE_EXPLICIT=""
ASSUME_YES="${ASSUME_YES:-0}"
WG_RELAY_PORT="${WG_RELAY_PORT:-}"

while [[ $# -gt 0 ]]; do
    # Normalise --flag=value into --flag value
    case "$1" in
        --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case "$1" in
        --mode|--relay-port|--port|--subnet|--dns|--endpoint)
            if [[ $# -lt 2 ]]; then
                msg_err "$1 缺少取值"
                exit 1
            fi
            case "$1" in
                --mode)       INSTALL_MODE="$2"; INSTALL_MODE_EXPLICIT=1 ;;
                --relay-port) WG_RELAY_PORT="$2" ;;
                --port)       WG_PORT="$2" ;;
                --subnet)     WG_SUBNET="$2" ;;
                --dns)        WG_DNS="$2" ;;
                --endpoint)   SERVER_ENDPOINT_OVERRIDE="$2" ;;
            esac
            shift 2
            ;;
        --yes|-y)        ASSUME_YES=1; shift ;;
        -h|--help|help)  install_usage; exit 0 ;;
        *)               shift ;;   # unknown flags keep the old ignore behaviour
    esac
done

# ---------- Defaults ----------
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.0.0.0/24}"
WG_DNS="${WG_DNS:-1.1.1.1, 8.8.8.8}"
SERVER_ENDPOINT_OVERRIDE="${SERVER_ENDPOINT_OVERRIDE:-}"
USE_PSK="${USE_PSK:-1}"
EXPOSE_DOWNLOAD="${EXPOSE_DOWNLOAD:-0}"
DRYRUN="${DRYRUN:-0}"
WGMGR_LIB_SOURCE="${WGMGR_LIB_SOURCE:-}"

require_root
detect_os
check_os_ok
msg_ok "OS: ${OS_PRETTY}  (pkg: ${PKG_MANAGER})"

# ---------- Role selection: server (default) vs relay exit node ----------
# Mode 2 keeps the client endpoint unchanged (still the ENTRY VPS) and makes this
# machine the internet-facing egress. Server mode below is untouched.
install_select_mode
if [[ "${INSTALL_MODE}" == "relay-exit" ]]; then
    relay_exit_main
fi

# ---------- Idempotency: if already installed, prompt ----------
if [[ -f "${WG_CONF}" && "${DRYRUN}" != "1" ]]; then
    msg_warn "Existing WireGuard install detected at ${WG_CONF}"
    if [[ "${ASSUME_YES}" != "1" ]] && ! confirm "Reconfigure? (This will add a new client and reload wg0)" "N"; then
        msg_info "Aborting."
        exit 0
    fi
fi

# ---------- Install packages ----------
install_wg_packages

# ---------- Detect public IP ----------
msg_step "Detecting public endpoint"

if [[ -n "${SERVER_ENDPOINT_OVERRIDE}" ]]; then
    PUBLIC_IP="${SERVER_ENDPOINT_OVERRIDE%:*}"
    WG_PORT="${SERVER_ENDPOINT_OVERRIDE##*:}"
    msg_info "Using override endpoint: ${PUBLIC_IP}:${WG_PORT}"

    # Validate format — catch "ip:port" mistakes like ":51820" (empty IP)
    # or "1.2.3.4" (no port → WG_PORT becomes the whole string).
    # We don't enforce IPv4 specifically (IPv6 with [..]:port also valid) — just
    # check that both sides are non-empty and the port is numeric + in range.
    if [[ -z "${PUBLIC_IP}" || -z "${WG_PORT}" ]]; then
        msg_err "Invalid --endpoint: '${SERVER_ENDPOINT_OVERRIDE}' (expected IP:PORT, got empty IP or port)"
        exit 1
    fi
    if ! [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || (( WG_PORT < 1 || WG_PORT > 65535 )); then
        msg_err "Invalid --endpoint port: '${WG_PORT}' (must be numeric 1-65535)"
        exit 1
    fi
    # Reject the "no colon" case explicitly: "1.2.3.4" → WG_PORT="1.2.3.4" passes
    # the numeric regex only if someone wrote WG_PORT=${SERVER_ENDPOINT_OVERRIDE##*:}
    # which returns the whole string. The numeric check above catches this.
    if [[ "${SERVER_ENDPOINT_OVERRIDE}" != *:* ]]; then
        msg_err "Invalid --endpoint: '${SERVER_ENDPOINT_OVERRIDE}' (missing :PORT suffix)"
        exit 1
    fi
else
    if ! detect_public_ip; then
        msg_err "Cannot detect public IPv4 and no --endpoint given."
        exit 1
    fi
fi

# Sanity: port not in use
if ! port_is_free "${WG_PORT}"; then
    msg_warn "Port ${WG_PORT} appears to be in use on this host."
    if [[ "${ASSUME_YES}" != "1" ]] && ! confirm "Continue anyway?" "N"; then
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

# ---------- Generate first client + register as peer on server ----------
# IMPORTANT: generate + add_peer_to_server MUST happen BEFORE enable_and_start_wg,
# so the kernel wg table gets client1's PublicKey/AllowedIPs on first bringup.
# Otherwise the server listens on 51820 but has no peer registered, and client1
# handshakes will be silently dropped.
msg_step "Generating default client 'client1'"

run deliver_client "client1" "${SERVER_PUBLIC}" "${PUBLIC_IP}:${WG_PORT}" "${WG_SUBNET}" "${WG_DNS}" "${USE_PSK}"
run add_peer_to_server "client1" "${CLIENT_PUBLIC}" "${CLIENT_IP}" "${CLIENT_PSK}"

# ---------- Enable + start wg-quick ----------
if ! run enable_and_start_wg; then
    if [[ "${DRYRUN}" != "1" ]]; then
        msg_err "wg-quick@wg0 failed to start. Check: journalctl -u wg-quick@wg0"
        exit 1
    fi
fi

# ---------- Install wgmgr command ----------
msg_step "Installing wgmgr command"

# Mode detection:
#   WGMGR_SOURCE empty            → curl|bash mode (download wgmgr + libs from GitHub)
#   WGMGR_SOURCE = ${SCRIPT_DIR}  → git clone mode (install wgmgr + libs from local checkout)
# The original logic compared "${WGMGR_SOURCE}" != "${SCRIPT_DIR}/wgmgr" — but
# WGMGR_SOURCE never included the "/wgmgr" suffix, so the comparison was ALWAYS
# true and the local-install elif branch was unreachable. Fix: gate on
# emptiness, not string mismatch.
if [[ -z "${WGMGR_SOURCE}" ]]; then
    # curl | bash mode: download wgmgr and install libs permanently
    WGMGR_TARGET="/usr/local/bin/wgmgr"
    run rm -f /tmp/wgmgr-download
    run curl -fsSL "https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/wgmgr" -o /tmp/wgmgr-download
    run install -m 0755 /tmp/wgmgr-download "${WGMGR_TARGET}"
    run rm -f /tmp/wgmgr-download
    # Install libs for wgmgr runtime lookup (download if not present)
    run mkdir -p /usr/local/share/wgmgr/lib
    if [[ -z "${WGMGR_LIB_SOURCE}" || ! -d "${WGMGR_LIB_SOURCE}" ]]; then
        # curl | bash with no local lib: download each lib
        for libf in common.sh network.sh server.sh client.sh relay.sh; do
            run curl -fsSL "https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/lib/${libf}" -o "/usr/local/share/wgmgr/lib/${libf}"
        done
    else
        run cp "${WGMGR_LIB_SOURCE}"/*.sh /usr/local/share/wgmgr/lib/
    fi
    run chmod 644 /usr/local/share/wgmgr/lib/*.sh
    # Relay entry-node tool (used on the ENTRY machine: relay-entry.sh --enroll).
    # Non-fatal: a server-mode install must not fail because this extra download did.
    run curl -fsSL "https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/relay-entry.sh" -o /usr/local/share/wgmgr/relay-entry.sh || msg_warn "relay-entry.sh download failed (relay mode unavailable until updated)"
    run chmod 755 /usr/local/share/wgmgr/relay-entry.sh
    msg_ok "Installed ${WGMGR_TARGET} (curl|bash mode)"
elif [[ -n "${WGMGR_SOURCE}" && -f "${SCRIPT_DIR}/wgmgr" ]]; then
    # git clone mode: install wgmgr + libs from local checkout (no network)
    run install -m 0755 "${SCRIPT_DIR}/wgmgr" /usr/local/bin/wgmgr
    # Also install libs for wgmgr runtime (in case user runs from curl|bash later)
    run mkdir -p /usr/local/share/wgmgr/lib
    run cp "${SCRIPT_DIR}/lib"/*.sh /usr/local/share/wgmgr/lib/
    run chmod 644 /usr/local/share/wgmgr/lib/*.sh
    # Relay entry-node tool (used on the ENTRY machine: relay-entry.sh --enroll)
    if [[ -f "${SCRIPT_DIR}/relay-entry.sh" ]]; then
        run install -m 0755 "${SCRIPT_DIR}/relay-entry.sh" /usr/local/share/wgmgr/relay-entry.sh
    fi
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
EOF

# ===== Big banner for the manage command (most important reminder) =====
printf '\n'
printf '\033[1;36m╔══════════════════════════════════════════════════════════════╗\033[0m\n'
printf '\033[1;36m║\033[0m                                                              \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m    \033[1;33m📱 后续管理客户端，全部用这个命令：\033[0m                       \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m                                                              \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m        \033[1;32m╔══════════════════════════════════════╗\033[0m          \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m        \033[1;32m║\033[0m                                      \033[1;32m║\033[0m          \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m        \033[1;32m║\033[0m    \033[1;37;42m     sudo wgmgr     \033[0m          \033[1;32m║\033[0m          \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m        \033[1;32m║\033[0m                                      \033[1;32m║\033[0m          \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m        \033[1;32m╚══════════════════════════════════════╝\033[0m          \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m                                                              \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m    \033[33m功能:\033[0m 查看账户 / 添加新设备 / 删除设备 / 重启服务     \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m                                                              \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m    \033[33m快捷子命令:\033[0m                                      \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m      \033[36msudo wgmgr list\033[0m     \033[90m# 列出所有账户\033[0m              \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m      \033[36msudo wgmgr add <名>\033[0m  \033[90m# 添加新设备\033[0m              \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m      \033[36msudo wgmgr qr <名>\033[0m   \033[90m# 查看配置+二维码\033[0m        \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m      \033[36msudo wgmgr remove <名>\033[0m \033[90m# 删除设备\033[0m            \033[1;36m║\033[0m\n'
printf '\033[1;36m║\033[0m                                                              \033[1;36m║\033[0m\n'
printf '\033[1;36m╚══════════════════════════════════════════════════════════════╝\033[0m\n'
printf '\n'

msg_ok "Install complete."

