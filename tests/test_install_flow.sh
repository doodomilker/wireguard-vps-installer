#!/usr/bin/env bash
# tests/test_install_flow.sh — end-to-end dryrun of install pipeline on macOS
#
# Mocks /usr/bin/{wg,qrencode,systemctl,iptables,sysctl,ip,curl,id,apt-get,dnf,service,modprobe,ss}
# Stubs live in a temp dir, prepended to PATH. Real /etc untouched.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

# Build mock dir
MOCK_DIR="$(mktemp -d)"
FAKE_ROOT="${MOCK_DIR}/fakeroot"
trap 'rm -rf "${MOCK_DIR}" /tmp/wgmgr_dryrun_*' EXIT

mkdir -p "${FAKE_ROOT}/etc/wireguard/clients" "${FAKE_ROOT}/etc/sysctl.d"

# ---- Mock binaries ----

cat > "${MOCK_DIR}/wg" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    genkey)    printf 'mock-wg-privkey-%s\n' "$(date +%N%N)" ;;
    pubkey)    printf 'mock-wg-pubkey-from-%s\n' "$(cat)" ;;
    genpsk)    printf 'mock-wg-psk-%s\n'     "$(date +%N%N)" ;;
    show)      echo "(mock) interface: wg0  public key: mock  peers: 0" ;;
    *)         echo "(mock) wg $*" ;;
esac
EOF

cat > "${MOCK_DIR}/qrencode" <<'EOF'
#!/usr/bin/env bash
# Mock qrencode: supports both
#   qrencode -t png -l M -o OUT < IN
#   qrencode -t png -o OUT < IN
#   qrencode -t ansiutf8 < IN
mode="${1:-}"
outflag="${2:-}"
# Find -o OUT anywhere in args (skip the input redirect)
out=""
prev=""
for arg in "$@"; do
    if [[ "${prev}" == "-o" ]]; then
        out="${arg}"
        break
    fi
    prev="${arg}"
done
if [[ "${mode}" == "-t" && "${outflag}" == "png" && -n "${out}" ]]; then
    printf '\x89PNG\r\n\x1a\n%sgenerated_by_test' > "${out}"
elif [[ "${mode}" == "-t" && "${outflag}" == "ansiutf8" ]]; then
    cat <<'QR'
[QR CODE ASCII ART - mock]
█▀▀▀▀▀█ ▀▀█ █▀▀▀▀▀█
█ ███ █ █▀▀ █ ███ █
█ ▀▀▀ █ ▀▀▀ █ ▀▀▀ █
▀▀▀▀▀▀▀ █ █ ▀▀▀▀▀▀▀
▀▀█ ▀▀█ ▀▀█ ▀▀█
▀ █ ▀ █▀▀ █▀ █ ▀ █
▀▀▀▀▀▀▀ ▀ ▀ ▀ ▀ ▀
QR
else
    echo "(mock) qrencode $*"
fi
EOF

cat > "${MOCK_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    is-active|--quiet)  echo "active"; exit 0 ;;
    enable|disable|reload|restart) echo "(mock) systemctl $*" >&2; exit 0 ;;
    status) echo "(mock) wg-quick@wg0.service — active (mocked)"; exit 0 ;;
    *) echo "(mock) systemctl $*"; exit 0 ;;
esac
EOF

cat > "${MOCK_DIR}/iptables" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -C) exit 1 ;;  # check: not present
    -A|-D|-I) exit 0 ;;
    -L) echo "(mock) Chain INPUT (policy ACCEPT)" ;;
    *) exit 0 ;;
esac
EOF

cat > "${MOCK_DIR}/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "net.ipv4.ip_forward = 1"
EOF

cat > "${MOCK_DIR}/ip" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    link)
        if [[ "${2:-}" == "show" && "${3:-}" == "eth0" ]]; then exit 1; fi
        echo "(mock) ip $*"
        ;;
    route) echo "default via 10.0.0.1 dev eth0" ;;
    *) echo "(mock) ip $*" ;;
esac
EOF

cat > "${MOCK_DIR}/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "(mock) apt-get $*"
exit 0
EOF

cat > "${MOCK_DIR}/dnf" <<'EOF'
#!/usr/bin/env bash
echo "(mock) dnf $*"
exit 0
EOF

cat > "${MOCK_DIR}/service" <<'EOF'
#!/usr/bin/env bash
echo "(mock) service $*"
exit 0
EOF

cat > "${MOCK_DIR}/modprobe" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${MOCK_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
echo "203.0.113.42"
EOF

cat > "${MOCK_DIR}/ss" <<'EOF'
#!/usr/bin/env bash
echo "(mock) ss: nothing listening on 51820"
EOF

cat > "${MOCK_DIR}/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then echo "0"; else echo "uid=0(root)"; fi
EOF

# Make all mocks executable
chmod +x "${MOCK_DIR}"/*

# Prepend mocks to PATH
export PATH="${MOCK_DIR}:${PATH}"

# ---- Orchestrator: same code path as install.sh, but with overrides ----
# In a real install, install.sh sources lib/ from its own dir. Here we replicate that.

cat > "${MOCK_DIR}/install_orchestrator.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# NOTE: no DRYRUN=1 here — we want file ops to execute against FAKE_ROOT.
# System-touching ops (iptables / systemctl / install) are wrapped in 'run'.

WG_DIR="${FAKE_ROOT}/etc/wireguard"
WG_CONF="\${WG_DIR}/wg0.conf"
WG_CLIENTS_DIR="\${WG_DIR}/clients"
export WG_DIR WG_CONF WG_CLIENTS_DIR

source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/network.sh"
source "${ROOT_DIR}/lib/server.sh"
source "${ROOT_DIR}/lib/client.sh"

# Re-apply overrides (lib may have reassigned defaults on source)
WG_DIR="${FAKE_ROOT}/etc/wireguard"
WG_CONF="\${WG_DIR}/wg0.conf"
WG_CLIENTS_DIR="\${WG_DIR}/clients"

# Force-fake OS detection
PKG_MANAGER="apt"
OS_PRETTY="Debian GNU/Linux 12 (bookworm) [mock]"

# Detect public IP (uses our mocked curl)
detect_public_ip
echo "[+] Public IP: \${PUBLIC_IP}"

# Generate server keys
gen_keypair SERVER
echo "[+] Server pubkey: \${SERVER_PUBLIC}"

# Write wg0.conf
write_server_conf "\${SERVER_PRIVATE}" 51820 "10.0.0.0/24" "1.1.1.1, 8.8.8.8"
echo "[+] wg0.conf contents:"
cat "\${WG_CONF}"

# IP forward + NAT (these use 'run' inside, so they print dryrun-style but don't actually iptables)
DRYRUN=1
enable_ip_forward
apply_nat_rules "10.0.0.0/24" "eth0"
DRYRUN=0

# Generate default client (writes conf + PNG to FAKE_ROOT)
DRYRUN=0
deliver_client "client1" "\${SERVER_PUBLIC}" "\${PUBLIC_IP}:51820" "10.0.0.0/24" "1.1.1.1, 8.8.8.8" 1
echo "[+] client1 conf at: \${WG_CLIENTS_DIR}/client1.conf"
echo "[+] client1 png at: \${WG_CLIENTS_DIR}/client1.png"

# Add peer to server (file op, no DRYRUN skip needed)
add_peer_to_server "client1" "mock-from-orch" "10.0.0.2" ""
EOF
chmod +x "${MOCK_DIR}/install_orchestrator.sh"

# ---- Run ----
echo "=== install_orchestrator.sh (mocked end-to-end) ==="
echo ""
bash "${MOCK_DIR}/install_orchestrator.sh" 2>&1

echo ""
echo ""
echo "=== Validating generated artifacts ==="

PASS=0
FAIL=0
chk() {
    local label="$1"
    shift
    if "$@"; then
        printf "  \033[32m✓\033[0m %s\n" "${label}"
        ((PASS++))
        return 0
    else
        printf "  \033[31m✗\033[0m %s\n" "${label}"
        ((FAIL++))
        return 0   # do not let set -e kill the loop
    fi
}

chk "wg0.conf exists"          test -f "${FAKE_ROOT}/etc/wireguard/wg0.conf"
chk "client1.conf exists"      test -f "${FAKE_ROOT}/etc/wireguard/clients/client1.conf"
chk "client1.png exists"       test -f "${FAKE_ROOT}/etc/wireguard/clients/client1.png"

conf="${FAKE_ROOT}/etc/wireguard/clients/client1.conf"
chk "conf has [Interface]"     grep -q "^\[Interface\]$" "${conf}"
chk "conf has [Peer]"          grep -q "^\[Peer\]$"     "${conf}"
chk "conf has correct endpoint" grep -q "Endpoint = 203.0.113.42:51820" "${conf}"
chk "conf has DNS"             grep -q "DNS = 1.1.1.1, 8.8.8.8" "${conf}"
chk "conf has full-tunnel AllowedIPs" grep -q "AllowedIPs = 0.0.0.0/0" "${conf}"
chk "conf has client IP .2 or .3" grep -qE "Address = 10\.0\.0\.[23]/32" "${conf}"

# Check wg0.conf has [Interface] + PostUp + ListenPort
wgc="${FAKE_ROOT}/etc/wireguard/wg0.conf"
chk "wg0.conf has ListenPort"  grep -q "^ListenPort = 51820$" "${wgc}"
chk "wg0.conf has PostUp"      grep -q "^PostUp" "${wgc}"

# Bonus: verify [Peer] got added to wg0.conf via add_peer_to_server
chk "wg0.conf has client1 peer block"  grep -q "^# client: client1$" "${wgc}"

echo ""
TOTAL=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "\033[32m=== install_flow: ALL %d ARTIFACTS VALIDATED ===\033[0m\n" "${TOTAL}"
    exit 0
else
    printf "\033[31m=== install_flow: %d/%d FAILED ===\033[0m\n" "${FAIL}" "${TOTAL}"
    exit 1
fi
