#!/bin/bash
# Diagnose RHACS operator catalog / subscription settings blocking 4.10 upgrades.
set -euo pipefail

_ACS_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${_ACS_SETUP_ROOT}/basic-setup/01-verify-rhacs-install.sh" 2>/dev/null || true

if declare -F diagnose_rhacs_operator_catalog &>/dev/null; then
    diagnose_rhacs_operator_catalog
    exit 0
fi

echo "[ERROR] Could not load diagnose_rhacs_operator_catalog from 01-verify-rhacs-install.sh" >&2
exit 1
