#!/usr/bin/env bash
# scripts/dryrun.sh — convenience wrapper: runs the install flow end-to-end
# with all system-touching operations stubbed out, in a temp dir.
#
# Use this for quick smoke-testing after editing lib/* or install.sh.
# For real installation, run install.sh on a fresh VPS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

bash "${ROOT_DIR}/tests/test_install_flow.sh" "$@"
