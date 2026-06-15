#!/usr/bin/env bash
# tests/test_lib_common.sh — unit tests for lib/common.sh + lib/server.sh helpers
# Runs without root, without real wg/iptables. Mocks commands via PATH override.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

# Source libs (DRYRUN auto-enabled by passing DRYRUN=1)
DRYRUN=1
export DRYRUN
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/server.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        printf "  \033[32m✓\033[0m %s\n" "${label}"
        PASS=$((PASS + 1))
    else
        printf "  \033[31m✗\033[0m %s\n        expected: %q\n        actual:   %q\n" \
            "${label}" "${expected}" "${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local label="$1" cond="$2"
    if [[ "${cond}" == "true" ]] || [[ "${cond}" == "0" ]]; then
        printf "  \033[32m✓\033[0m %s\n" "${label}"
        PASS=$((PASS + 1))
    elif [[ "${cond}" == "false" ]] || [[ "${cond}" == "1" ]]; then
        printf "  \033[31m✗\033[0m %s\n" "${label}"
        FAIL=$((FAIL + 1))
    else
        # Numeric or other — use bash truth: non-zero / non-empty = true
        if [[ -n "${cond}" ]] && [[ "${cond}" != "0" ]]; then
            printf "  \033[32m✓\033[0m %s\n" "${label}"
            PASS=$((PASS + 1))
        else
            printf "  \033[31m✗\033[0m %s\n" "${label}"
            FAIL=$((FAIL + 1))
        fi
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        printf "  \033[32m✓\033[0m %s\n" "${label}"
        PASS=$((PASS + 1))
    else
        printf "  \033[31m✗\033[0m %s\n        needle:   %q\n        haystack: %q\n" \
            "${label}" "${needle}" "${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== test_lib_common.sh ==="
echo ""

# ---- subnet_to_host ----
echo "[subnet_to_host]"
ip="$(subnet_to_host 10.0.0.0/24 1)"
assert_eq "subnet /24 + 1 → 10.0.0.1" "10.0.0.1" "${ip}"

ip="$(subnet_to_host 10.0.0.0/24 5)"
assert_eq "subnet /24 + 5 → 10.0.0.5" "10.0.0.5" "${ip}"

ip="$(subnet_to_host 192.168.10.0/24 100)"
assert_eq "subnet 192.168.10.0/24 + 100 → 192.168.10.100" "192.168.10.100" "${ip}"

# ---- gen_keypair (dryrun mode) ----
echo ""
echo "[gen_keypair (dryrun)]"
gen_keypair TEST
assert_contains "TEST_PRIVATE looks like base64" "mock-priv-TEST-" "${TEST_PRIVATE}"
assert_contains "TEST_PUBLIC  looks like base64" "mock-pub-TEST-"  "${TEST_PUBLIC}"
if [[ ${#TEST_PRIVATE} -eq 44 ]]; then
    assert_true "private length = 44 chars" "true"
else
    assert_true "private length = 44 chars (got ${#TEST_PRIVATE})" "false"
fi

# ---- gen_psk (dryrun mode) ----
echo ""
echo "[gen_psk (dryrun)]"
psk="$(gen_psk)"
assert_contains "PSK starts with mock-psk-" "mock-psk-" "${psk}"

# ---- validate_client_name (from client.sh) ----
echo ""
echo "[validate_client_name]"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/client.sh"

if validate_client_name "iphone-15" 2>/dev/null; then
    assert_true "valid name 'iphone-15' accepted" "true"
else
    assert_true "valid name 'iphone-15' accepted" "false"
fi

if validate_client_name "bad name with space" 2>/dev/null; then
    assert_true "invalid name with space rejected" "false"
else
    assert_true "invalid name with space rejected" "true"
fi

if validate_client_name "" 2>/dev/null; then
    assert_true "empty name rejected" "false"
else
    assert_true "empty name rejected" "true"
fi

if validate_client_name "name;rm-rf" 2>/dev/null; then
    assert_true "shell-injection-looking name rejected" "false"
else
    assert_true "shell-injection-looking name rejected" "true"
fi

# ---- next_client_ip (no dir => count=0 => idx=2) ----
echo ""
echo "[next_client_ip]"
WG_CLIENTS_DIR="/tmp/wgmgr_test_clients_$$"
rm -rf "${WG_CLIENTS_DIR}"
ip="$(next_client_ip 10.0.0.0/24)"
assert_eq "fresh dir → 10.0.0.2" "10.0.0.2" "${ip}"

mkdir -p "${WG_CLIENTS_DIR}"
echo dummy > "${WG_CLIENTS_DIR}/a.conf"
echo dummy > "${WG_CLIENTS_DIR}/b.conf"
ip="$(next_client_ip 10.0.0.0/24)"
assert_eq "2 existing clients → 10.0.0.4" "10.0.0.4" "${ip}"
rm -rf "${WG_CLIENTS_DIR}"

# ---- colors / logging don't crash ----
echo ""
echo "[logging]"
msg_info "info"
msg_ok "ok"
msg_warn "warn"
msg_err "err"
msg_step "step"
msg_banner "banner"
assert_true "logging functions don't error out" "true"

# ---- has_cmd ----
echo ""
echo "[has_cmd]"
if has_cmd bash; then
    assert_true "has_cmd bash → true" "true"
else
    assert_true "has_cmd bash → true" "false"
fi
if has_cmd definitely-not-a-real-cmd-xyz; then
    assert_true "has_cmd bogus → false" "false"
else
    assert_true "has_cmd bogus → false" "true"
fi

# ---- run (dryrun prints, doesn't exec) ----
echo ""
echo "[run dryrun]"
output="$(run echo "hello-from-dryrun")"
assert_contains "dryrun output contains marker" "[dryrun]" "${output}"
assert_contains "dryrun output contains command" "echo"  "${output}"
assert_contains "dryrun output contains arg"     "hello-from-dryrun" "${output}"

# ---- Summary ----
echo ""
TOTAL=$((PASS + FAIL))
if (( FAIL == 0 )); then
    printf "\033[32m=== ALL %d TESTS PASSED ===\033[0m\n" "${TOTAL}"
    exit 0
else
    printf "\033[31m=== %d/%d TESTS FAILED ===\033[0m\n" "${FAIL}" "${TOTAL}"
    exit 1
fi
