#!/bin/bash
#
# Diagnose why RHACS OpenShift Console security integration is not working.
# Safe to rerun; does not modify cluster state.
#
# Usage:
#   source ~/.bashrc
#   bash basic-setup/diagnose-console-plugin.sh
#

set -euo pipefail

_ACS_SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${_ACS_SETUP_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

# shellcheck disable=SC1090
source "${_ACS_SETUP_ROOT}/basic-setup/01-verify-rhacs-install.sh"

main() {
    echo ""
    echo "RHACS OpenShift Console Plugin Diagnostics"
    echo "=========================================="
    echo ""
    diagnose_rhacs_console_plugin
    echo ""
}

main "$@"
