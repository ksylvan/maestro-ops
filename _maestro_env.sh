#!/usr/bin/env bash
# _maestro_env.sh — Maestro environment: CLI path resolution and generic directory model.
#
# Source (do NOT execute) this from the maestro_*.sh scripts or standalone to access
# the Maestro CLI path and generic directory helpers. After sourcing, the variable
# `maestro_cli` holds the path to the maestro-cli.js to invoke with `node`, and
# MAESTRO_USER_DATA is exported only when appropriate.
#
# The generic directory model is rooted at ${MAESTRO_REPOS_DIR} (default $HOME/src):
#   • Base repository clones: ${MAESTRO_REPOS_DIR}/<repo>
#   • Git worktrees: ${MAESTRO_REPOS_DIR}/worktrees/<repo>/<name>
#   • Autorun playbook dirs: ${MAESTRO_REPOS_DIR}/worktrees/autorun/<repo>/<name>
#
# Configuration variables (set in .env or the environment before sourcing):
#   MAESTRO_REPOS_DIR — Root directory for all repository clones and worktrees
#     (default: $HOME/src)
#   MAESTRO_GH_SEARCH — Colon-separated GitHub owners/orgs for code-search queries
#     (default: empty; example: danielmiessler:ksylvan). When empty,
#     maestro_pr.sh falls back to the authenticated GitHub user.
#   MAESTRO_PLAYBOOKS_GH_REPO — GitHub repo containing Maestro playbooks
#     (default: RunMaestro/Maestro-Playbooks)
#   MAESTRO_PLAYBOOKS_DIR — Local directory for Maestro playbooks
#     (default: ${MAESTRO_REPOS_DIR}/Maestro-Playbooks)
#   MAESTRO_DEFAULT_AGENT_TYPE — Default Maestro agent type when creating agents
#     (default: claude)
#
# Maestro CLI resolution order:
#   1. A sibling .env file (next to this helper) is sourced if present, so a
#      developer can point the scripts at a checked-out rc/preview branch.
#      See .env.example.
#   2. If MAESTRO_CLI_JS is set (typically from .env or the environment), it
#      wins, and MAESTRO_USER_DATA is honored as given.
#   3. Otherwise, if the installed Maestro.app CLI exists, use it and leave
#      MAESTRO_USER_DATA untouched — the app manages its own data location.
#   4. Otherwise fall back to the dev preview worktree CLI + maestro-dev data.

# Directory holding this helper (and any sibling .env).
_maestro_env_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Source a sibling .env, if present.
if [[ -f "${_maestro_env_dir}/.env" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${_maestro_env_dir}/.env"
fi

# Directory model defaults and configuration.
export MAESTRO_REPOS_DIR="${MAESTRO_REPOS_DIR:-${HOME}/src}"
export MAESTRO_GH_SEARCH="${MAESTRO_GH_SEARCH:-}"
export MAESTRO_PLAYBOOKS_GH_REPO="${MAESTRO_PLAYBOOKS_GH_REPO:-RunMaestro/Maestro-Playbooks}"
export MAESTRO_PLAYBOOKS_DIR="${MAESTRO_PLAYBOOKS_DIR:-${MAESTRO_REPOS_DIR}/Maestro-Playbooks}"
export MAESTRO_DEFAULT_AGENT_TYPE="${MAESTRO_DEFAULT_AGENT_TYPE:-claude}"

# Path helper functions (pure string builders, no filesystem side effects).
# These are safe to call multiple times and in any context.

# maestro_full_name — Compose a fully-qualified name from repo, worktree, and agent type.
# Usage: maestro_full_name <repo> <worktree> <agent_type>
# Output: <repo>-<worktree>-<agent_type>
maestro_full_name() {
    [[ $# -eq 3 ]] || return 1
    echo "${1}-${2}-${3}"
}

# maestro_base_dir — Path to a repository's base clone directory.
# Usage: maestro_base_dir <repo>
# Output: ${MAESTRO_REPOS_DIR}/<repo>
maestro_base_dir() {
    [[ $# -eq 1 ]] || return 1
    echo "${MAESTRO_REPOS_DIR}/${1}"
}

# maestro_worktree_dir — Path to a named worktree within a repository.
# Usage: maestro_worktree_dir <repo> <full_name>
# Output: ${MAESTRO_REPOS_DIR}/worktrees/<repo>/<full_name>
maestro_worktree_dir() {
    [[ $# -eq 2 ]] || return 1
    echo "${MAESTRO_REPOS_DIR}/worktrees/${1}/${2}"
}

# maestro_autorun_dir — Path to a worktree's autorun playbook directory.
# Usage: maestro_autorun_dir <repo> <full_name>
# Output: ${MAESTRO_REPOS_DIR}/worktrees/autorun/<repo>/<full_name>
maestro_autorun_dir() {
    [[ $# -eq 2 ]] || return 1
    echo "${MAESTRO_REPOS_DIR}/worktrees/autorun/${1}/${2}"
}

_maestro_installed_cli="/Applications/Maestro.app/Contents/Resources/maestro-cli.js"

# maestro_cli is consumed by the script that sources this helper.
# shellcheck disable=SC2034
if [[ -n "${MAESTRO_CLI_JS:-}" ]]; then
    # 2. Explicit override (env or .env) wins; honor MAESTRO_USER_DATA as given.
    maestro_cli="${MAESTRO_CLI_JS}"
elif [[ -f "${_maestro_installed_cli}" ]]; then
    # 3. Installed app: use its CLI, do NOT override MAESTRO_USER_DATA.
    maestro_cli="${_maestro_installed_cli}"
else
    # 4. Dev fallback: preview worktree CLI + maestro-dev data dir.
    maestro_cli="${HOME}/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"
    export MAESTRO_USER_DATA="${MAESTRO_USER_DATA:-${HOME}/Library/Application Support/maestro-dev}"
fi

unset _maestro_env_dir _maestro_installed_cli
