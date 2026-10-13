#!/usr/bin/env bash
# relay-entry.sh — ENTRY-node side of relay (中转) mode for wireguard-vps-installer
#
# Run this ON THE OLD VPS (the entry node that clients already dial). It does NOT
# touch your existing wg0 / clients. It only adds a second interface (wg1) that
# carries the client subnet to the exit node, plus policy routing + NAT.
#
# Usage (online, one line — nothing to install first):
#   curl -fsSL https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main/relay-entry.sh \
#     | sudo bash -s -- --enroll '<PAYLOAD printed by the exit node>'
#
# Usage (local checkout):
#   sudo ./relay-entry.sh --enroll '<PAYLOAD>'
#   sudo ./relay-entry.sh --status
#   sudo ./relay-entry.sh --disable [--yes]
#
# Everything it configures is reversible: --disable removes wg1, its routes,
# rules and NAT entry, and clients go back to exiting this machine directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo ".")"
REPO_RAW="${WG_RELAY_REPO_RAW:-https://raw.githubusercontent.com/doodomilker/wireguard-vps-installer/main}"
SHARE_DIR="/usr/local/share/wgmgr"

usage() {
    cat <<'EOF'
relay-entry.sh — 入口机（旧 VPS）中转配置

用法:
  sudo relay-entry.sh --enroll '<PAYLOAD>'        接入一个出口节点（落地机）
  sudo relay-entry.sh --enroll-file <文件|->      同上，payload 从文件读（- 表示 stdin）
  sudo relay-entry.sh --status                    查看当前中转状态
  sudo relay-entry.sh --disable [--yes]           关闭中转（可逆，客户端恢复直连本机出网）

说明:
  - 本脚本只新增 wg1 中转隧道，不改动现有 wg0 / 客户端配置。
  - PAYLOAD 由落地机安装时打印；payload 很长，粘贴时容易被折行/截断。
    粘贴报错时改用文件方式：把落地机的 /etc/wireguard/relay-payload.txt
    传过来（scp / 复制内容到文件），然后 --enroll-file 指向它。
  - 关闭中转后，客户端仍连本机 IP，只是不再经过落地机。
EOF
}

MODE=""
PAYLOAD=""
PAYLOAD_FILE=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --enroll|--apply)
            MODE="enroll"; PAYLOAD="${2:-}"; shift 2 || true ;;
        --enroll-file|--file)
            MODE="enroll"; PAYLOAD_FILE="${2:-}"; shift 2 || true ;;
        --status|-s)
            MODE="status"; shift ;;
        --disable|-d)
            MODE="disable"; shift ;;
        --yes|-y)
            ASSUME_YES=1; shift ;;
        -h|--help|help)
            usage; exit 0 ;;
        *)
            echo "[✗] 未知参数: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    usage >&2
    exit 1
fi

# ---------- lib discovery / autoload ----------
# Order mirrors wgmgr: explicit env → local checkout → installed share dir → download.
_LIB_DIR=""
for candidate in \
    "${WG_INSTALL_LIB_DIR:-}" \
    "${SCRIPT_DIR}/lib" \
    "${SHARE_DIR}/lib" \
    "/etc/wireguard/.wgmgr/lib"; do
    if [[ -n "${candidate}" && -f "${candidate}/common.sh" && -f "${candidate}/relay.sh" ]]; then
        _LIB_DIR="${candidate}"
        break
    fi
done

if [[ -z "${_LIB_DIR}" ]]; then
    echo "[i] lib/ 不在本机，正在从 GitHub 下载（curl | bash 模式）..."
    if ! command -v curl >/dev/null 2>&1; then
        echo "[✗] 需要 curl 才能下载 lib/（或用 git clone 后本地运行）" >&2
        exit 1
    fi
    mkdir -p "${SHARE_DIR}/lib"
    for libf in common.sh network.sh server.sh relay.sh; do
        curl -fsSL "${REPO_RAW}/lib/${libf}" -o "${SHARE_DIR}/lib/${libf}" || {
            echo "[✗] 下载 lib/${libf} 失败" >&2
            exit 1
        }
    done
    chmod 644 "${SHARE_DIR}/lib/"*.sh
    _LIB_DIR="${SHARE_DIR}/lib"
    echo "[✓] lib/ 已安装到 ${_LIB_DIR}"
fi

# shellcheck disable=SC1091
source "${_LIB_DIR}/common.sh"
source "${_LIB_DIR}/network.sh"
source "${_LIB_DIR}/server.sh"
export WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
# shellcheck disable=SC1091
source "${_LIB_DIR}/relay.sh"

require_root

# Installed copy so `wgmgr relay ...` and later runs work without the checkout.
if [[ "${DRYRUN:-0}" != "1" && "${BASH_SOURCE[0]:-$0}" != "${SHARE_DIR}/relay-entry.sh" ]]; then
    mkdir -p "${SHARE_DIR}"
    if [[ -f "${SCRIPT_DIR}/relay-entry.sh" ]]; then
        install -m 0755 "${SCRIPT_DIR}/relay-entry.sh" "${SHARE_DIR}/relay-entry.sh" 2>/dev/null || true
    fi
fi

case "${MODE}" in
    enroll)
        # --enroll-file: paste-free path (scp the payload file over, or pipe it).
        # Useful exactly because a 380-char single-line payload is easy to mangle
        # when copy/pasted; '-' reads from stdin.
        if [[ -n "${PAYLOAD_FILE}" ]]; then
            if [[ "${PAYLOAD_FILE}" == "-" ]]; then
                PAYLOAD="$(tr -d '[:space:]')"
            elif [[ -f "${PAYLOAD_FILE}" ]]; then
                PAYLOAD="$(tr -d '[:space:]' < "${PAYLOAD_FILE}")"
            else
                echo "[✗] 找不到 payload 文件: ${PAYLOAD_FILE}" >&2
                exit 1
            fi
        fi
        if [[ -z "${PAYLOAD}" ]]; then
            echo "[✗] --enroll 需要一个 payload（落地机安装结束时会打印；也可用 --enroll-file <文件>）" >&2
            exit 1
        fi
        echo "[i] 接入中转出口节点 ..."
        if ! relay_entry_apply "${PAYLOAD}"; then
            echo "[✗] 接入失败 — 本机现有 wg0 / 客户端未受影响" >&2
            exit 1
        fi
        echo ""
        echo "[✓] 入口机侧配置完成。落地机那边的验证：wg show wg1 应出现最新握手。"
        echo "    手机连上后打开 https://ifconfig.me —— 显示的应是【落地机】的 IP。"
        ;;
    status)
        relay_entry_status
        ;;
    disable)
        if [[ "${ASSUME_YES}" != "1" ]]; then
            if ! confirm "关闭中转？客户端将恢复为直接从本机出网（wg0 与客户端配置不动）" "N"; then
                echo "[i] 已取消"
                exit 0
            fi
        fi
        relay_entry_disable
        ;;
esac
