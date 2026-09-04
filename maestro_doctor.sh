#!/usr/bin/env bash
# maestro_doctor.sh — Diagnostic for the Maestro generic environment model.
#
# Print the resolved environment, show the directory model in action, and check
# that required tools are available. Exit 0 even if tools are missing — this is
# a read-only diagnostic that reports the current state, not a hard prerequisite check.
#
# Usage: ./maestro_doctor.sh [-h|--help]

set -uo pipefail

usage() {
    cat <<EOF
Usage: $0 [-h|--help]

Print the Maestro environment, verify the directory model, and check for
required tools. Exits 0 even if prerequisites are missing — this is a
read-only diagnostic tool, not a hard dependency check.

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            # Diagnostic tool: report issues but always exit 0
            exit 0
            ;;
    esac
done

# Source the environment helper to resolve configuration and get path functions.
_maestro_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_maestro_env_dir}/_maestro_env.sh"

echo "=== Maestro Environment ==="
echo ""
echo "MAESTRO_REPOS_DIR:         $MAESTRO_REPOS_DIR"
echo "MAESTRO_GH_SEARCH:         ${MAESTRO_GH_SEARCH:-(empty)}"
echo "MAESTRO_PLAYBOOKS_GH_REPO: $MAESTRO_PLAYBOOKS_GH_REPO"
echo "MAESTRO_PLAYBOOKS_DIR:     $MAESTRO_PLAYBOOKS_DIR"
echo "MAESTRO_DEFAULT_AGENT_TYPE: $MAESTRO_DEFAULT_AGENT_TYPE"
echo ""
echo "Platform:             $(uname -s)"
echo "Resolved maestro_cli: $maestro_cli"
if [[ -f "$maestro_cli" ]]; then
    echo "                      OK (file exists)"
else
    echo "                      MISSING"
    echo "  Dev build:     run 'npm run build:cli' in the Maestro worktree."
    echo "  Installed app: macOS Maestro.app, or Linux deb/rpm (lands in /opt/Maestro)."
    echo "                 AppImage: run --appimage-extract and set MAESTRO_CLI_JS."
fi
echo "MAESTRO_USER_DATA:    $MAESTRO_USER_DATA"
if [[ -d "$MAESTRO_USER_DATA" ]]; then
    if [[ -f "$MAESTRO_USER_DATA/cli-server.json" ]]; then
        echo "                      OK (dir exists; Maestro app appears to be running)"
    else
        echo "                      OK (dir exists; Maestro app not running: no cli-server.json)"
    fi
else
    echo "                      MISSING (start the Maestro app once to create it)"
fi
echo ""

echo "=== Directory Model Example ==="
echo ""
sample_repo="myrepo"
sample_wt="my-feature"
sample_agent="claude-code"
echo "Sample repo: $sample_repo"
echo "Sample worktree name: $sample_wt"
echo "Sample agent type: $sample_agent"
echo ""

full_name=$(maestro_full_name "$sample_repo" "$sample_wt" "$sample_agent")
echo "Fully-qualified name: $full_name"
echo ""

base_dir=$(maestro_base_dir "$sample_repo")
echo "Base directory:        $base_dir"

wt_dir=$(maestro_worktree_dir "$sample_repo" "$full_name")
echo "Worktree directory:    $wt_dir"

ar_dir=$(maestro_autorun_dir "$sample_repo" "$full_name")
echo "Autorun directory:     $ar_dir"
echo ""

echo "=== Prerequisites Check ==="
echo ""

# Check for required tools
check_tool() {
    local tool="$1"
    if command -v "$tool" &>/dev/null; then
        local version
        version=$("$tool" --version 2>&1 | grep -m1 .)
        echo "$tool:  OK ($version)"
        return 0
    else
        echo "$tool:  MISSING"
        return 1
    fi
}

check_tool "git"
check_tool "gh"
check_tool "jq"
check_tool "node"
check_tool "perl"
check_tool "python3"
if [[ "$(uname -s)" != "Darwin" ]]; then
    check_tool "notify-send" || echo "  (optional: maestro_watch.sh desktop notification fallback)"
fi
echo ""

# Best-effort GitHub authentication status
echo "GitHub authentication status:"
if gh auth status 2>/dev/null; then
    echo "(Authenticated)"
else
    echo "(Not authenticated or gh not available)"
fi
echo ""

echo "=== Diagnostic Complete ==="
exit 0
