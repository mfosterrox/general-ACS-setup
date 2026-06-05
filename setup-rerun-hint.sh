#!/usr/bin/env bash
#
# Shared helpers for general-ACS-setup install scripts: remember how the script was invoked and print a
# copy-paste re-run command after failures.
#
# Usage (near top of an installer, after sourcing this file):
#   source "${PROJECT_ROOT}/setup-rerun-hint.sh"
#   setup_rerun_register "${BASH_SOURCE[0]}" "$@"
#
# Call setup_rerun_hint_print from error paths or an ERR trap.
#
# Optional: setup_rerun_set_script is an alias of setup_rerun_register (legacy name).
# Optional: setup_rerun_restore_trap is a no-op placeholder for scripts that temporarily run
#   trap - ERR and want to restore default ERR handling afterward.

RERUN_SCRIPT=""
declare -a RERUN_CMDLINE=()

setup_rerun_register() {
    RERUN_SCRIPT="${1:-}"
    shift || true
    RERUN_CMDLINE=("$@")
}

setup_rerun_set_script() {
    setup_rerun_register "$@"
}

setup_rerun_hint_print() {
    if [ -z "${RERUN_SCRIPT}" ]; then
        return 0
    fi
    local line shell_q
    shell_q=$(printf '%q' "${RERUN_SCRIPT}")
    line="${shell_q}"
    local a
    for a in "${RERUN_CMDLINE[@]}"; do
        line+=" $(printf '%q' "$a")"
    done
    echo "" >&2
    echo "[HINT] Re-run: ${line}" >&2
    echo "[HINT] Trace: bash -x ${shell_q}" >&2
}

setup_rerun_restore_trap() {
    :
}
