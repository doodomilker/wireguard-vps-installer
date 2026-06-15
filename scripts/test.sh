#!/usr/bin/env bash
# scripts/test.sh — run all unit + integration tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  wireguard-vps-installer — full test suite           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

FAILED=0
for t in "${ROOT_DIR}/tests/test_"*.sh; do
    echo ""
    echo "┌── $(basename "$t") ──"
    if ! bash "$t"; then
        echo "└── ✗ $(basename "$t") FAILED"
        FAILED=$((FAILED + 1))
    else
        echo "└── ✓ $(basename "$t") PASSED"
    fi
done

echo ""
if (( FAILED == 0 )); then
    printf "\033[32m═══ ALL TEST FILES PASSED ═══\033[0m\n"
    exit 0
else
    printf "\033[31m═══ %d TEST FILE(S) FAILED ═══\033[0m\n" "${FAILED}"
    exit 1
fi
