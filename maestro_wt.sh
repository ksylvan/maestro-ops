#!/bin/bash

# maestro_wt.sh — Set up (or tear down) a named worktree for a Maestro agent.
#
# Usage: maestro_wt.sh <repo> <worktree_name> [agent_type]
#        maestro_wt.sh --delete [--force] <repo> <worktree_name> [agent_type]

# maestro_tool_type — Map an accepted agent type to the Maestro CLI's -t tool-type
# spelling. Every accepted type is also a Maestro tool-type ID, except "claude",
# which the CLI spells "claude-code". This is the one place that mapping lives;
# add a case here if the accepted set and the CLI tool-type IDs diverge again.
maestro_tool_type() {
    case "$1" in
        claude) echo "claude-code" ;;
        *)      echo "$1" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--nudge MSG] [--json-out PATH] <repo> <worktree_name> [agent_type]
       $(basename "$0") --delete [--force] <repo> <worktree_name> [agent_type]

Set up (or tear down) a named worktree for use with a Maestro agent.

Arguments:
    repo            Repository name. Any repository checked out under \${MAESTRO_REPOS_DIR}.
    worktree_name   The name of the worktree (will be part of the final name)
    agent_type      Optional Maestro agent type.
                    Valid options: $(format_options "${VALID_AGENT_TYPES[@]}").
                    Default: \${MAESTRO_DEFAULT_AGENT_TYPE:-claude}

Options:
  -h, --help        Show this help message and exit
  --nudge MSG       Pass MSG as the nudge message when creating the agent
  --json-out PATH   Write the create-agent JSON response to PATH (caller-managed).
                    Without this flag the JSON is written to a temp file that is
                    removed on exit.
  --delete          Tear down the worktree and its Maestro agent instead of
                    creating them. Removes the git worktree (prompting whether to
                    also delete the autorun directory) then removes the agent.
                    Mutually exclusive with --nudge / --json-out.
  --force           Only with --delete: skip the confirmation prompt and force
                    removal of the worktree even if it has uncommitted changes.
                    Also removes the autorun directory without prompting.

Examples:
  $(basename "$0") myrepo my-feature
  $(basename "$0") myapp refactor-auth
  $(basename "$0") myservice experiment codex
  $(basename "$0") --nudge "review only" --json-out /tmp/a.json myrepo pr-209
  $(basename "$0") --delete myrepo my-feature
  $(basename "$0") --delete --force myservice experiment codex
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# ---------- resolve Maestro CLI ----------

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_maestro_env.sh
source "${_script_dir}/_maestro_env.sh" || die "Cannot source _maestro_env.sh"

# ---------- argument parsing ----------

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

nudge_message=""
json_out=""
delete_mode=false
force=false
positional=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --nudge)
            [[ $# -ge 2 ]] || die "--nudge requires an argument"
            nudge_message="$2"
            shift 2
            ;;
        --json-out)
            [[ $# -ge 2 ]] || die "--json-out requires an argument"
            json_out="$2"
            shift 2
            ;;
        --delete)
            delete_mode=true
            shift
            ;;
        --force)
            force=true
            shift
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                positional+=("$1")
                shift
            done
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

set -- "${positional[@]}"

# --delete is exclusive to the normal create flow.
if [[ "$delete_mode" == "true" ]]; then
    [[ -z "$nudge_message" ]] || die "--nudge cannot be combined with --delete"
    [[ -z "$json_out" ]] || die "--json-out cannot be combined with --delete"
elif [[ "$force" == "true" ]]; then
    die "--force is only valid with --delete"
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Error: Expected 2 or 3 positional arguments, got $#." >&2
    usage >&2
    exit 1
fi

repo="$1"
wt_name="$2"
agent_type="${3:-${MAESTRO_DEFAULT_AGENT_TYPE:-claude}}"
# Track whether the caller explicitly supplied an agent type (vs. the default),
# so full-name normalization below can safely adopt the suffix's agent type.
agent_type_explicit=false
[[ $# -ge 3 ]] && agent_type_explicit=true

# Validate the repo by confirming its base clone exists. maestro_wt.sh does not
# clone, so the repo must already be checked out under ${MAESTRO_REPOS_DIR}.
repo_base_dir="$(maestro_base_dir "$repo")"
[[ -d "$repo_base_dir" ]] \
    || die "Base clone not found under ${MAESTRO_REPOS_DIR}: no directory at '${repo_base_dir}'. Clone '${repo}' there first."

# Accept the FULL composed worktree name (what Maestro displays for the agent /
# worktree dir, e.g. "myrepo-pr-574-claude") in place of the bare
# middle segment ("pr-574"). Without this, passing the full name would re-wrap
# it into "<repo>-<full>-<agent_type>", doubling the prefix and suffix.
#
# Only normalize when the name unambiguously looks composed: it starts with
# "<repo>-" AND ends with "-<valid_agent_type>". That dual guard avoids
# mangling a legitimate bare name that merely happens to start with the repo.
if [[ "$wt_name" == "${repo}-"* ]]; then
    matched_agent_type=""
    for valid_agent_type in "${VALID_AGENT_TYPES[@]}"; do
        if [[ "$wt_name" == *"-${valid_agent_type}" ]]; then
            matched_agent_type="$valid_agent_type"
            break
        fi
    done

    if [[ -n "$matched_agent_type" ]]; then
        normalized="${wt_name#"${repo}-"}"
        normalized="${normalized%"-${matched_agent_type}"}"

        # Adopt the agent type from the suffix unless one was given explicitly.
        if [[ "$agent_type_explicit" != "true" ]]; then
            agent_type="$matched_agent_type"
        fi

        echo "Note: '${wt_name}' looks like a full worktree name; interpreting as" >&2
        echo "      repo='${repo}', name='${normalized}', agent_type='${agent_type}'." >&2
        wt_name="$normalized"
    fi
fi

# Validate worktree name
[[ -n "$wt_name" ]] || die "worktree_name cannot be empty"
[[ "$wt_name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "worktree_name must contain only letters, digits, '.', '_', or '-' (got '${wt_name}')"

# Validate agent type
validate_agent_type "$agent_type"

# ---------- source helper functions ----------

# shellcheck source=_worktree_helpers.sh
source "${_script_dir}/_worktree_helpers.sh" || die "Cannot source _worktree_helpers.sh"

worktree_name="$(maestro_full_name "$repo" "$wt_name" "$agent_type")"
agent_name="${worktree_name}"
worktree_dir="$(maestro_worktree_dir "$repo" "$worktree_name")"
autorun_dir="$(maestro_autorun_dir "$repo" "$worktree_name")"

# ---------- delete flow (mutually exclusive with create) ----------

if [[ "$delete_mode" == "true" ]]; then
    echo "About to tear down:"
    echo "  Worktree : ${worktree_dir}"
    echo "  Agent    : ${agent_name}"

    if [[ "$force" != "true" ]]; then
        printf "Proceed? (y/n) [n] "
        read -r confirm
        [[ "$confirm" == "y" ]] || die "Aborted."
    fi

    printf "\n%s\n" "Changing to ${repo_base_dir}..."
    cd "${repo_base_dir}" || die "Cannot cd to ${repo_base_dir}"

    # cleanup_work_tree_here removes the worktree and prompts about the autorun dir.
    # --force is passed through to `git worktree remove` for dirty worktrees and
    # also skips the autorun-dir prompt, deleting it outright.
    if [[ "$force" == "true" ]]; then
        cleanup_work_tree_here "${worktree_name}" --force \
            || echo "Warning: worktree cleanup did not complete; continuing to agent removal." >&2
    else
        cleanup_work_tree_here "${worktree_name}" \
            || echo "Warning: worktree cleanup did not complete; continuing to agent removal." >&2
    fi

    # Remove the Maestro agent (reuse maestro_id.sh for the name -> UUID lookup).
    printf "\n%s\n" "Removing Maestro agent '${agent_name}'..."
    if agent_id=$("${_script_dir}/maestro_id.sh" "${agent_name}" 2>/dev/null) && [[ -n "$agent_id" ]]; then
        if node "${maestro_cli}" remove-agent "${agent_id}"; then
            echo "Removed agent '${agent_name}' (${agent_id})."
        else
            die "Failed to remove agent '${agent_name}' (${agent_id})."
        fi
    else
        echo "No unique agent named '${agent_name}' found — skipping agent removal."
    fi

    printf "\n%s\n" "Teardown complete."
    exit 0
fi

# ---------- create worktree ----------

printf "\n%s" "Changing to ${repo_base_dir}..."
cd "${repo_base_dir}" || die "Cannot cd to ${repo_base_dir}"

echo "Creating worktree '${worktree_name}'..."
make_worktree_here "${worktree_name}" || die "make_worktree_here failed"

printf "\n%s" "Creating autorun directories..."
# shellcheck disable=SC2119  # make_autorun_dirs takes no args by design
make_autorun_dirs || die "make_autorun_dirs failed"

printf "\n%s" "Worktree and auto-run setup done!"
echo "  Worktree : ${worktree_dir}"
echo "  Autorun  : ${autorun_dir}"

# --------- create Maestro agent ----------

if [[ -n "$json_out" ]]; then
    out_path="$json_out"
else
    out_path="/tmp/maestro_agent$$.json"
    trap 'rm -f "${out_path}"' EXIT INT TERM
fi

tool_type="$(maestro_tool_type "${agent_type}")"
create_args=(create-agent -d "${worktree_dir}" -t "${tool_type}")
if [[ -n "$nudge_message" ]]; then
    create_args+=(--nudge "${nudge_message}")
fi
create_args+=(--auto-run-folder "${autorun_dir}" "${agent_name}" --json)

node "${maestro_cli}" "${create_args[@]}" > "${out_path}"

cat "${out_path}"

printf "\n%s" "Agent Created!"
jq . "${out_path}"
