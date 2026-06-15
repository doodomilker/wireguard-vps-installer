# shellcheck shell=bash
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
check_os_supported() {
    case "${OS_ID}" in
        debian)
            # 11+ supported
            if [[ -n "${OS_VERSION}" ]] && (( OS_VERSION < 11 )); then
                msg_err "Debian ${OS_VERSION} is EOL. Please use Debian 11 or 12."
                exit 3
            fi
            ;;
        ubuntu)
            # 20.04+ supported
            if [[ -n "${OS_VERSION}" ]] && (( OS_VERSION < 2004 )); then
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
            if [[ -n "${OS_VERSION}" ]] && (( OS_VERSION < 39 )); then
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
    read -r -p "$(printf '%s' "${prompt} [y/N]: ' ")" reply
    case "${reply:-${default}}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}
