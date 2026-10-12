# shellcheck shell=bash
# lib/relay.sh — relay (中转) mode helpers: entry node + exit node sides.
#
# Topology this implements (client sees the ENTRY IP, the internet sees the EXIT IP):
#
#   phone/client --wg0--> [ENTRY VPS]  --wg1-->  [EXIT VPS] --eth0--> internet
#                         旧机器/入口机              新机器/落地机
#
#   * The client's WireGuard endpoint does NOT change (still the entry's IP:PORT).
#   * The entry keeps serving wg0 exactly as before; it only ADDS a second
#     interface (wg1 by default) plus policy routing for the client subnet.
#   * The entry's own traffic (SSH / apt / wg handshakes) stays on the primary
#     NIC, so enabling the relay can never lock the operator out.
#   * The exit LISTENS (UDP 51821 by default) and the entry DIALS it. That keeps
#     the entry's cloud firewall untouched (outbound only); only the exit needs
#     one inbound rule for its relay port.
#
# Key/secret flow (one direction, no private key ever travels):
#   The EXIT machine generates BOTH keypairs (its own + the entry's) and a PSK,
#   then prints a base64 "payload". The entry machine consumes that payload once
#   with `relay-entry.sh --enroll <payload>`.
[[ -n "${_LIB_RELAY_LOADED:-}" ]] && return 0
_LIB_RELAY_LOADED=1

# All paths/ports are env-overridable so tests can point them at a temp dir.
WG_RELAY_IF="${WG_RELAY_IF:-wg1}"
WG_RELAY_ENTRY_IF="${WG_RELAY_ENTRY_IF:-wg0}"
WG_RELAY_DIR="${WG_RELAY_DIR:-/etc/wireguard}"
WG_RELAY_CONF="${WG_RELAY_CONF:-${WG_RELAY_DIR}/wg1.conf}"
WG_RELAY_PAYLOAD_FILE="${WG_RELAY_PAYLOAD_FILE:-${WG_RELAY_DIR}/relay-payload.txt}"
WG_RELAY_PORT_DEFAULT="${WG_RELAY_PORT_DEFAULT:-51821}"
WG_RELAY_SUBNET="${WG_RELAY_SUBNET:-10.77.0.0/24}"
WG_RELAY_ENTRY_ADDR="${WG_RELAY_ENTRY_ADDR:-10.77.0.1}"
WG_RELAY_EXIT_ADDR="${WG_RELAY_EXIT_ADDR:-10.77.0.2}"
WG_RELAY_TABLE="${WG_RELAY_TABLE:-100}"
WG_RELAY_RULE_PRIO="${WG_RELAY_RULE_PRIO:-1000}"
WG_RELAY_REPO_RAW="${WG_RELAY_REPO_RAW:-https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main}"

# ----- base64 helpers (BSD/macOS `base64 -D` vs GNU `base64 -d`) -----
relay_b64_encode() {
    base64 | tr -d '\n'
}

relay_b64_decode() {
    local data="$1" out=""
    if out="$(printf '%s' "${data}" | base64 -d 2>/dev/null)"; then
        printf '%s' "${out}"
        return 0
    fi
    if out="$(printf '%s' "${data}" | base64 -D 2>/dev/null)"; then
        printf '%s' "${out}"
        return 0
    fi
    msg_err "relay: payload base64 解码失败（复制时被截断？）"
    return 1
}

# ----- Payload build (exit side) -----
# Args: exit_endpoint exit_pubkey entry_privkey entry_addr exit_addr psk [client_subnet] [name]
# Prints a single-line base64 payload on stdout.
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

# ----- Payload parse (entry side) -----
# Args: payload (base64)
# Sets: RELAY_NAME RELAY_EXIT_ENDPOINT RELAY_EXIT_PUBKEY RELAY_ENTRY_PRIVKEY
#       RELAY_ENTRY_ADDR RELAY_EXIT_ADDR RELAY_PSK RELAY_CLIENT_SUBNET
relay_payload_parse() {
    local payload="$1"
    local decoded

    if [[ -z "${payload}" ]]; then
        msg_err "relay: payload 为空"
        return 1
    fi
    if ! decoded="$(relay_b64_decode "${payload}")"; then
        return 1
    fi
    if [[ "${decoded}" != *"kind=wg-relay"* ]]; then
        msg_err "relay: 这不是一个中转 payload（缺少 kind=wg-relay）"
        return 1
    fi

    RELAY_NAME=""
    RELAY_EXIT_ENDPOINT=""
    RELAY_EXIT_PUBKEY=""
    RELAY_ENTRY_PRIVKEY=""
    RELAY_ENTRY_ADDR=""
    RELAY_EXIT_ADDR=""
    RELAY_PSK=""
    RELAY_CLIENT_SUBNET=""

    local line key val
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        case "${key}" in
            v|kind)          ;;
            name)            RELAY_NAME="${val}" ;;
            exit_endpoint)   RELAY_EXIT_ENDPOINT="${val}" ;;
            exit_pubkey)     RELAY_EXIT_PUBKEY="${val}" ;;
            entry_privkey)   RELAY_ENTRY_PRIVKEY="${val}" ;;
            entry_addr)      RELAY_ENTRY_ADDR="${val}" ;;
            exit_addr)       RELAY_EXIT_ADDR="${val}" ;;
            psk)             RELAY_PSK="${val}" ;;
            client_subnet)   RELAY_CLIENT_SUBNET="${val}" ;;
            *)               msg_warn "relay: 忽略未知 payload 字段 '${key}'" ;;
        esac
    done <<<"${decoded}"

    local missing=()
    [[ -z "${RELAY_EXIT_ENDPOINT}" ]] && missing+=(exit_endpoint)
    [[ -z "${RELAY_EXIT_PUBKEY}"   ]] && missing+=(exit_pubkey)
    [[ -z "${RELAY_ENTRY_PRIVKEY}" ]] && missing+=(entry_privkey)
    [[ -z "${RELAY_ENTRY_ADDR}"    ]] && missing+=(entry_addr)
    [[ -z "${RELAY_EXIT_ADDR}"     ]] && missing+=(exit_addr)
    if (( ${#missing[@]} > 0 )); then
        msg_err "relay: payload 缺少字段: ${missing[*]}"
        return 1
    fi

    # Endpoint must be IP:PORT — a bare IP silently produces an unroutable peer.
    if [[ "${RELAY_EXIT_ENDPOINT}" != *:* ]]; then
        msg_err "relay: exit_endpoint '${RELAY_EXIT_ENDPOINT}' 不是 IP:PORT 格式"
        return 1
    fi
    local port="${RELAY_EXIT_ENDPOINT##*:}"
    if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        msg_err "relay: exit_endpoint 端口非法: '${port}'"
        return 1
    fi
    return 0
}

# ----- Detect the client-facing subnet from the entry's wg0.conf -----
# Prints e.g. 10.0.0.0/24; falls back to WG_SUBNET_DEFAULT (or 10.0.0.0/24).
relay_detect_client_subnet() {
    local conf="${WG_CONF:-${WG_RELAY_DIR}/wg0.conf}"
    local addr="" ip="" o1 o2 o3 o4
    if [[ -f "${conf}" ]]; then
        addr="$(grep -E '^Address' "${conf}" 2>/dev/null | head -1 | awk '{print $3}' || true)"
    fi
    if [[ -n "${addr}" ]]; then
        ip="${addr%%/*}"
        IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
        if [[ -n "${o1}" && -n "${o2}" && -n "${o3}" ]]; then
            printf '%s.%s.%s.0/24' "${o1}" "${o2}" "${o3}"
            return 0
        fi
        msg_warn "relay: 无法从 '${addr}' 推断 IPv4 客户端网段，回退默认值"
    fi
    printf '%s' "${WG_SUBNET_DEFAULT:-10.0.0.0/24}"
}

# ----- Detect the primary egress interface (the one carrying the default route) -----
relay_detect_egress_iface() {
    local iface
    iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || true)"
    if [[ -z "${iface}" ]]; then
        iface="eth0"
    fi
    printf '%s' "${iface}"
}

# ----- ENTRY side: wg1.conf render -----
# Args: entry_privkey exit_pubkey psk exit_endpoint entry_addr client_subnet
#       [iface] [entry_if] [table] [rule_prio]
relay_entry_conf_render() {
    local entry_priv="$1"
    local exit_pub="$2"
    local psk="$3"
    local exit_endpoint="$4"
    local entry_addr="$5"
    local client_subnet="$6"
    local iface="${7:-${WG_RELAY_IF}}"
    local entry_if="${8:-${WG_RELAY_ENTRY_IF}}"
    local table="${9:-${WG_RELAY_TABLE}}"
    local prio="${10:-${WG_RELAY_RULE_PRIO}}"

    cat <<EOF
# WireGuard relay uplink (${iface}) — ENTRY node, managed by wireguard-vps-installer
# Clients still dial THIS machine (their endpoint is unchanged). Packets arriving
# on ${entry_if} from ${client_subnet} are policy-routed into ${iface} and reach the
# internet through the exit node. This machine's own traffic keeps using the
# primary NIC, so enabling/disabling this file cannot lock you out of SSH.
[Interface]
PrivateKey = ${entry_priv}
Address = ${entry_addr}/24
# Table = off: wg-quick must NOT install a default route here (that would break
# the entry's own connectivity). Routes/rules below are exact and reversible.
Table = off
MTU = 1420
PostUp = sysctl -w net.ipv4.conf.%i.rp_filter=2; iptables -t nat -A POSTROUTING -s ${client_subnet} -o %i -j MASQUERADE; ip route add ${client_subnet} dev ${entry_if} table ${table}; ip route add default dev %i table ${table}; ip rule add from ${client_subnet} lookup ${table} priority ${prio}
PostDown = iptables -t nat -D POSTROUTING -s ${client_subnet} -o %i -j MASQUERADE; ip rule del from ${client_subnet} lookup ${table} priority ${prio} 2>/dev/null; ip route flush table ${table}

[Peer]
# Exit node — entry dials out to it (exit listens), so no inbound port is needed here.
PublicKey = ${exit_pub}
$(if [[ -n "${psk}" ]]; then printf 'PresharedKey = %s\n' "${psk}"; fi)
Endpoint = ${exit_endpoint}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}

# ----- EXIT side: wg1.conf render -----
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

# ----- Persist ip_forward for the exit node -----
relay_persist_ip_forward() {
    local conf="/etc/sysctl.d/99-wireguard-relay.conf"
    if [[ "${DRYRUN:-0}" == "1" ]]; then
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

# ----- EXIT side: write conf + bring up the listener -----
# Args: exit_privkey entry_pubkey psk port exit_addr entry_tunnel_ip relay_subnet egress_if
relay_exit_write_conf() {
    local exit_priv="$1" entry_pub="$2" psk="$3" port="$4" exit_addr="$5"
    local entry_tunnel_ip="$6" relay_subnet="$7" egress_if="$8"

    mkdir -p "$(dirname "${WG_RELAY_CONF}")"
    chmod 700 "$(dirname "${WG_RELAY_CONF}")" 2>/dev/null || true
    relay_exit_conf_render "${exit_priv}" "${entry_pub}" "${psk}" "${port}" \
        "${exit_addr}" "${entry_tunnel_ip}" "${relay_subnet}" "${egress_if}" >"${WG_RELAY_CONF}"
    chmod 600 "${WG_RELAY_CONF}"
    msg_ok "Wrote ${WG_RELAY_CONF}"
}

# ----- ENTRY side: apply a payload (write conf + bring up wg1) -----
# Args: payload [client_subnet_override]
relay_entry_apply() {
    local payload="$1"
    local subnet_override="${2:-}"

    if ! relay_payload_parse "${payload}"; then
        return 1
    fi

    local client_subnet="${subnet_override}"
    if [[ -z "${client_subnet}" ]]; then
        client_subnet="${RELAY_CLIENT_SUBNET}"
    fi
    if [[ -z "${client_subnet}" ]]; then
        client_subnet="$(relay_detect_client_subnet)"
        msg_warn "relay: payload 未带客户端网段，按本机 wg0 推断为 ${client_subnet}"
    fi

    local entry_addr="${RELAY_ENTRY_ADDR:-${WG_RELAY_ENTRY_ADDR}}"

    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would write ${WG_RELAY_CONF} and bring up wg-quick@${WG_RELAY_IF}"
        relay_entry_conf_render "${RELAY_ENTRY_PRIVKEY}" "${RELAY_EXIT_PUBKEY}" \
            "${RELAY_PSK}" "${RELAY_EXIT_ENDPOINT}" "${entry_addr}" "${client_subnet}"
        return 0
    fi

    # The entry node must already be a working server, otherwise there is nothing
    # to relay (no wg0 clients) and the client subnet detection is meaningless.
    local entry_conf="${WG_RELAY_DIR}/wg0.conf"
    if [[ ! -f "${entry_conf}" ]]; then
        msg_err "relay: 本机没有 ${entry_conf} — 入口机必须先装好服务端模式（wg0）"
        return 1
    fi

    if [[ -f "${WG_RELAY_CONF}" ]]; then
        msg_warn "relay: ${WG_RELAY_CONF} 已存在 — 将覆盖（旧接口先下线）"
        relay_iface_down || true
    fi

    relay_entry_conf_render "${RELAY_ENTRY_PRIVKEY}" \
        "${RELAY_EXIT_PUBKEY}" "${RELAY_PSK}" "${RELAY_EXIT_ENDPOINT}" \
        "${entry_addr}" "${client_subnet}" >"${WG_RELAY_CONF}"
    chmod 600 "${WG_RELAY_CONF}"
    msg_ok "Wrote ${WG_RELAY_CONF}"

    relay_iface_up || return 1
    relay_entry_status
}

# ----- systemctl helpers for the relay interface -----
relay_iface_up() {
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would: systemctl enable --now wg-quick@${WG_RELAY_IF}"
        return 0
    fi
    if ! has_cmd systemctl; then
        msg_err "systemctl 不存在 — 无法启用 wg-quick@${WG_RELAY_IF}"
        return 1
    fi
    systemctl enable "wg-quick@${WG_RELAY_IF}.service" &>/dev/null || true
    if ! systemctl restart "wg-quick@${WG_RELAY_IF}.service"; then
        msg_err "wg-quick@${WG_RELAY_IF} 启动失败"
        systemctl status "wg-quick@${WG_RELAY_IF}.service" --no-pager || true
        return 1
    fi
    sleep 1
    if systemctl is-active --quiet "wg-quick@${WG_RELAY_IF}.service"; then
        msg_ok "wg-quick@${WG_RELAY_IF} is active"
        return 0
    fi
    msg_err "wg-quick@${WG_RELAY_IF} 未处于 active"
    systemctl status "wg-quick@${WG_RELAY_IF}.service" --no-pager || true
    return 1
}

relay_iface_down() {
    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would: systemctl disable --now wg-quick@${WG_RELAY_IF}"
        return 0
    fi
    if has_cmd systemctl; then
        systemctl disable --now "wg-quick@${WG_RELAY_IF}.service" &>/dev/null || true
    fi
    return 0
}

# ----- Role detection from the local relay conf -----
relay_role_detect() {
    local conf="${WG_RELAY_CONF}"
    if [[ ! -f "${conf}" ]]; then
        printf 'none'
        return 0
    fi
    if grep -qE '^Endpoint' "${conf}" 2>/dev/null; then
        printf 'entry'
    elif grep -qE '^ListenPort' "${conf}" 2>/dev/null; then
        printf 'exit'
    else
        printf 'unknown'
    fi
}

# ----- Status (works on both sides) -----
relay_entry_status() {
    local conf="${WG_RELAY_CONF}"
    if [[ ! -f "${conf}" ]]; then
        msg_warn "relay: 未配置（${conf} 不存在）"
        return 1
    fi

    local role
    role="$(relay_role_detect)"
    msg_step "中转状态（本机角色: ${role}）"
    printf '  %-16s %s\n' "Config:"  "${conf}"
    printf '  %-16s %s\n' "Interface:" "${WG_RELAY_IF}"
    printf '  %-16s %s\n' "Service:" "wg-quick@${WG_RELAY_IF}.service"

    if [[ "${DRYRUN:-0}" != "1" ]]; then
        if has_cmd systemctl; then
            printf '  %-16s %s\n' "Service state:" "$(systemctl is-active "wg-quick@${WG_RELAY_IF}.service" 2>/dev/null || echo unknown)"
        fi
        if has_cmd wg; then
            echo ""
            wg show "${WG_RELAY_IF}" 2>/dev/null || msg_warn "wg show ${WG_RELAY_IF} 无输出（接口未启动？）"
            echo ""
            # `wg show` hides an empty peer list behind the interface section;
            # the dump form is the proof that a peer is really registered.
            local peers
            peers="$(wg show "${WG_RELAY_IF}" dump 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
            if [[ "${peers}" == "0" ]]; then
                msg_warn "peer 列表为空（wg show dump 只有接口行）— 对端还没连上来"
            else
                msg_ok "peer 已注册（${peers} 个）"
            fi
        fi
        if [[ "${role}" == "entry" ]]; then
            echo ""
            echo "── 策略路由（只有客户端网段走中转）──"
            ip rule show 2>/dev/null | grep -E "lookup ${WG_RELAY_TABLE}\b" || msg_warn "未找到 lookup ${WG_RELAY_TABLE} 的 ip rule"
            ip route show table "${WG_RELAY_TABLE}" 2>/dev/null || true
            echo ""
            echo "── NAT ──"
            iptables -t nat -S POSTROUTING 2>/dev/null | grep -E -- "-o ${WG_RELAY_IF} .*MASQUERADE" || msg_warn "未找到到 ${WG_RELAY_IF} 的 MASQUERADE 规则"
            echo ""
            msg_info "验证：手机连上后打开 https://ifconfig.me —— 应该显示【出口机】的 IP"
            msg_info "抓包确认：tcpdump -i ${WG_RELAY_IF} -n -c 20"
        fi
    fi
    return 0
}

# ----- Teardown (entry side) -----
relay_entry_disable() {
    local conf="${WG_RELAY_CONF}"
    local subnet
    subnet="$(relay_detect_client_subnet)"

    if [[ "${DRYRUN:-0}" == "1" ]]; then
        msg_info "[dryrun] would: down wg-quick@${WG_RELAY_IF}, remove ${conf}, flush table ${WG_RELAY_TABLE}, drop NAT rule for ${subnet}"
        return 0
    fi

    # Bring the interface down FIRST: wg-quick runs PostDown from the conf, which
    # removes the NAT rule + ip rule + table 100 routes. Then delete the conf.
    relay_iface_down
    if [[ -f "${conf}" ]]; then
        rm -f "${conf}"
        msg_ok "Removed ${conf}"
    fi
    rm -f "${WG_RELAY_PAYLOAD_FILE}"

    # Belt & braces: PostDown can only undo what it recorded; if the conf was
    # replaced by hand, residue is possible. These are idempotent.
    ip rule del from "${subnet}" lookup "${WG_RELAY_TABLE}" priority "${WG_RELAY_RULE_PRIO}" 2>/dev/null || true
    ip route flush table "${WG_RELAY_TABLE}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "${subnet}" -o "${WG_RELAY_IF}" -j MASQUERADE 2>/dev/null || true

    # Verify + report honestly.
    local residue=0
    if [[ -f "${conf}" ]]; then residue=1; fi
    if ip link show "${WG_RELAY_IF}" &>/dev/null; then residue=1; fi
    if ip rule show 2>/dev/null | grep -qE "lookup ${WG_RELAY_TABLE}\b"; then residue=1; fi
    if (( residue == 1 )); then
        msg_warn "relay: 关闭后仍有残留（检查 ${WG_RELAY_IF} / table ${WG_RELAY_TABLE}）"
        return 1
    fi
    msg_ok "中转已关闭，客户端恢复为直接走本机 eth0 出网（端的原配置未改动）"
    return 0
}
