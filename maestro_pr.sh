#!/bin/bash

# maestro_pr.sh — Set up a PR review worktree with Maestro autorun playbooks.
#
# Usage: maestro_pr.sh [--no-run] [--draft-ok] <repo> <pr_number> [agent_type]
#
# Delegates worktree, autorun-dir, and agent creation to ./maestro_wt.sh,
# then layers in the PR-specific bits: playbook copy, PR-URL substitution,
# `gh pr checkout`, and the auto-run launch.

script_dir="$(cd "$(dirname "$0")" && pwd)"
MAESTRO_WT="${script_dir}/maestro_wt.sh"

# Resolve maestro_cli (and MAESTRO_USER_DATA when appropriate); sources .env.
# Also provides VALID_AGENT_TYPES, format_options, validate_agent_type.
# shellcheck source=_maestro_env.sh
source "${script_dir}/_maestro_env.sh"

# Local checkout of the Code Review playbooks, cloned on demand from
# MAESTRO_PLAYBOOKS_GH_REPO into MAESTRO_PLAYBOOKS_DIR if missing. See
# ensure_playbooks below.
PLAYBOOKS_SOURCE="${MAESTRO_PLAYBOOKS_DIR}/Development/Code-Review"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--no-run] [--draft-ok] <repo> <pr_number> [agent_type]

Set up a PR review worktree with Maestro autorun playbooks.

Arguments:
    repo        Repository name, resolved via MAESTRO_GH_SEARCH and cloned on demand.
    pr_number   Pull request number (numeric)
    agent_type  Optional Maestro agent type.
                Valid options: $(format_options "${VALID_AGENT_TYPES[@]}").
                Default: \${MAESTRO_DEFAULT_AGENT_TYPE:-claude}

Options:
  -h, --help    Show this help message and exit
  --no-run      Set up the agent but skip the final auto-run launch
  --draft-ok    Allow reviewing draft PRs (skip the draft check)

Examples:
  $(basename "$0") myrepo 456 grok
  $(basename "$0") myrepo 209
  $(basename "$0") otherrepo 42
  $(basename "$0") --no-run myrepo 209
  $(basename "$0") --draft-ok myrepo 209
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# resolve_repo — Find the repository owner on GitHub and make sure it is cloned.
#
# Usage: resolve_repo <repo>
# Result: sets the global `resolved_slug` to "<owner>/<repo>" (the clone). This
#         stays repo-agnostic — no specific org is ever assumed. The PR itself
#         may live elsewhere; resolve_pr_slug finds its home separately.
#
# The function takes one of two paths:
#   1. If the base clone already exists under ${MAESTRO_REPOS_DIR}, use it and
#      skip owner resolution. Read the slug from the clone's `origin` remote.
#   2. If the base clone is missing, try each owner in MAESTRO_GH_SEARCH in
#      order. Keep the FIRST owner whose "<owner>/<repo>" resolves on GitHub,
#      then clone that repo into the base directory. First match wins; the loop
#      stops as soon as an owner resolves. When MAESTRO_GH_SEARCH is empty,
#      default to the authenticated GitHub user (`gh api user`).
resolve_repo() {
    local repo="$1"
    local base_dir
    base_dir="$(maestro_base_dir "$repo")"

    # --- Path 1: existing clone. Read the slug from origin; skip resolution. ---
    if [[ -d "$base_dir" ]]; then
        local origin_url slug
        origin_url="$(git -C "$base_dir" remote get-url origin 2>/dev/null)"
        # Reduce an ssh or https GitHub URL to "<owner>/<repo>":
        #   git@github.com:owner/repo.git        -> owner/repo
        #   https://github.com/owner/repo(.git)  -> owner/repo
        slug="$(printf '%s\n' "$origin_url" | sed -E 's#\.git$##; s#^.*github\.com[:/]+##')"
        [[ "$slug" =~ ^[^/]+/[^/]+$ ]] \
            || die "Existing clone at ${base_dir} has no usable GitHub 'origin' remote; fix the remote or remove the directory to re-clone."
        resolved_slug="$slug"
        echo "Using existing clone at ${base_dir} (${resolved_slug})."
        return 0
    fi

    # --- Path 2: resolve the owner via MAESTRO_GH_SEARCH, then clone on demand. ---
    # When the search list is empty, default to the authenticated GitHub user,
    # so a solo user who owns the repo needs no configuration.
    local search="$MAESTRO_GH_SEARCH"
    if [[ -z "$search" ]]; then
        search="$(gh api user --jq .login 2>/dev/null)"
        [[ -n "$search" ]] \
            || die "Cannot resolve repo '${repo}': MAESTRO_GH_SEARCH is empty and the authenticated GitHub user could not be determined. Run 'gh auth login', or set MAESTRO_GH_SEARCH to a colon-separated list of GitHub owners, e.g. export MAESTRO_GH_SEARCH=myorg:myuser"
        echo "MAESTRO_GH_SEARCH is empty; defaulting to your GitHub user '${search}'."
    fi

    local -a owners tried=()
    IFS=':' read -r -a owners <<< "$search"

    resolved_slug=""
    local owner
    for owner in "${owners[@]}"; do
        [[ -n "$owner" ]] || continue   # tolerate empty fields (a::b, or a trailing ':')
        tried+=("$owner")
        # Probe "<owner>/<repo>" quietly; the first owner that resolves wins.
        if gh repo view "${owner}/${repo}" --json nameWithOwner >/dev/null 2>&1; then
            resolved_slug="${owner}/${repo}"
            break
        fi
    done

    [[ -n "$resolved_slug" ]] \
        || die "Could not resolve repo '${repo}' under any MAESTRO_GH_SEARCH owner (tried: $(format_options "${tried[@]}")). Check the repo name or add its owner to MAESTRO_GH_SEARCH."

    # Clone the resolved repo into the base dir. Create the parent first: gh makes
    # the leaf directory but not the intermediate ${MAESTRO_REPOS_DIR} path.
    echo "Resolved ${resolved_slug}; cloning into ${base_dir}..."
    mkdir -p "$(dirname "$base_dir")" || die "Cannot create $(dirname "$base_dir")"
    gh repo clone "$resolved_slug" "$base_dir" \
        || die "Failed to clone ${resolved_slug} into ${base_dir}"
}

# resolve_pr_slug — Find the "<owner>/<repo>" where PR <n> actually lives.
#
# Usage: resolve_pr_slug <pr_number> <clone_slug>
# Result: sets the globals `pr_slug` (the repo that owns the PR) and `pr_json`
#         (its `gh pr view` output). Dies if no candidate has the PR.
#
# The clone may be a FORK whose PR only exists upstream: `ksylvan/fabric` is a
# fork of `danielmiessler/fabric`, but PR 2200 is upstream only. So the search
# is tried for PRs too. Candidates, in order, de-duplicated:
#   1. The clone's own slug.
#   2. Its upstream parent, when the clone is a fork.
#   3. Each MAESTRO_GH_SEARCH owner (empty -> the authenticated GitHub user),
#      paired with the repo name.
# The first candidate that has the PR wins.
resolve_pr_slug() {
    local pr="$1" clone_slug="$2"
    local repo_name="${clone_slug#*/}"

    # Build the ordered candidate list. `seen` de-dupes while preserving order,
    # so no owner is probed twice (bash 3.2: no associative arrays).
    local -a candidates=()
    local seen=":"
    local cand
    _add_pr_candidate() {
        cand="$1"
        [[ -n "$cand" && "$seen" != *":${cand}:"* ]] || return 0
        candidates+=("$cand")
        seen+="${cand}:"
    }

    _add_pr_candidate "$clone_slug"

    # `--json parent` exposes owner.login and name separately, not nameWithOwner.
    local parent
    parent="$(gh repo view "$clone_slug" --json parent \
        --jq 'if .parent then .parent.owner.login + "/" + .parent.name else empty end' 2>/dev/null)"
    _add_pr_candidate "$parent"

    local search="$MAESTRO_GH_SEARCH"
    [[ -n "$search" ]] || search="$(gh api user --jq .login 2>/dev/null)"
    local -a owners
    IFS=':' read -r -a owners <<< "$search"
    local owner
    for owner in "${owners[@]}"; do
        [[ -n "$owner" ]] && _add_pr_candidate "${owner}/${repo_name}"
    done

    # First candidate that has the PR wins.
    local slug json
    for slug in "${candidates[@]}"; do
        if json="$(gh pr view "$pr" --repo "$slug" --json state,isDraft,headRefName 2>/dev/null)"; then
            pr_slug="$slug"
            pr_json="$json"
            [[ "$slug" == "$clone_slug" ]] \
                || echo "PR #${pr} is not in ${clone_slug}; found it in ${slug}."
            return 0
        fi
    done

    die "PR #${pr} not found in any candidate repo (tried: $(format_options "${candidates[@]}")). Check the PR number, or add its owner to MAESTRO_GH_SEARCH."
}

# ensure_playbooks — Make sure the Code Review playbooks are checked out
# locally at PLAYBOOKS_SOURCE, cloning MAESTRO_PLAYBOOKS_GH_REPO into
# MAESTRO_PLAYBOOKS_DIR on demand when they are not.
ensure_playbooks() {
    compgen -G "${PLAYBOOKS_SOURCE}/"'*.md' > /dev/null && return 0

    echo "Local playbooks not found at ${PLAYBOOKS_SOURCE}; cloning ${MAESTRO_PLAYBOOKS_GH_REPO} into ${MAESTRO_PLAYBOOKS_DIR}..."
    mkdir -p "$(dirname "${MAESTRO_PLAYBOOKS_DIR}")" || die "Cannot create $(dirname "${MAESTRO_PLAYBOOKS_DIR}")"
    gh repo clone "${MAESTRO_PLAYBOOKS_GH_REPO}" "${MAESTRO_PLAYBOOKS_DIR}" \
        || die "Failed to clone ${MAESTRO_PLAYBOOKS_GH_REPO} into ${MAESTRO_PLAYBOOKS_DIR}"

    compgen -G "${PLAYBOOKS_SOURCE}/"'*.md' > /dev/null \
        || die "Cloned ${MAESTRO_PLAYBOOKS_GH_REPO} but found no playbooks at ${PLAYBOOKS_SOURCE}"
}

# ---------- argument parsing ----------

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

# Parse optional flags before positional arguments
no_run=false
draft_ok=false
args=()
for arg in "$@"; do
    case "$arg" in
        --no-run)   no_run=true ;;
        --draft-ok) draft_ok=true ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Error: Expected 2 or 3 arguments, got $#." >&2
    usage >&2
    exit 1
fi

repo="$1"
pr_number="$2"
agent_type="${3:-${MAESTRO_DEFAULT_AGENT_TYPE:-claude}}"

# Validate PR number is numeric
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "PR number must be numeric, got '${pr_number}'"

# Validate agent type up front so a typo doesn't waste a gh call
validate_agent_type "$agent_type"

# ---------- resolve repo (owner search + clone on demand) ----------

# Set resolved_slug ("<owner>/<repo>") and make sure the base clone exists, so the
# PR validation, the maestro_wt.sh delegation, and the PR checkout below all have
# a repo to work with. See resolve_repo for the two resolution paths.
resolved_slug=""
resolve_repo "$repo"

# ---------- resolve + validate PR ----------

# The PR may live in the clone itself or in its upstream/another search owner
# (forks). resolve_pr_slug sets pr_slug (PR's home) and pr_json.
echo "Validating PR #${pr_number} (clone: ${resolved_slug})..."
pr_slug=""
pr_json=""
resolve_pr_slug "$pr_number" "$resolved_slug"

pr_state=$(echo "$pr_json" | jq -r '.state')
pr_is_draft=$(echo "$pr_json" | jq -r '.isDraft')
pr_head_ref=$(echo "$pr_json" | jq -r '.headRefName')
[[ -n "$pr_head_ref" && "$pr_head_ref" != "null" ]] \
    || die "Could not determine head branch for PR #${pr_number}"

[[ "$pr_state" == "OPEN" ]] \
    || die "PR #${pr_number} is not open (state: ${pr_state})"
if [[ "$draft_ok" == "false" ]]; then
    [[ "$pr_is_draft" == "false" ]] \
        || die "PR #${pr_number} is a draft (use --draft-ok to allow)"
fi

if [[ "$pr_is_draft" == "true" ]]; then
    echo "PR #${pr_number} validated: open (draft, --draft-ok set)."
else
    echo "PR #${pr_number} validated: open, not a draft."
fi

# ---------- delegate worktree + agent creation to maestro_wt.sh ----------

[[ -x "$MAESTRO_WT" ]] || die "maestro_wt.sh not found or not executable at ${MAESTRO_WT}"

worktree_label="pr-${pr_number}"
nudge_message="Do not make any changes this is only a review task."
agent_json="/tmp/maestro_pr_agent$$.json"
trap 'rm -f "${agent_json}"' EXIT INT TERM

"${MAESTRO_WT}" \
    --nudge "${nudge_message}" \
    --json-out "${agent_json}" \
    "${repo}" "${worktree_label}" "${agent_type}" \
    || die "maestro_wt.sh failed"

worktree_name="$(maestro_full_name "$repo" "$worktree_label" "$agent_type")"
worktree_dir="$(maestro_worktree_dir "$repo" "$worktree_name")"
autorun_dir="$(maestro_autorun_dir "$repo" "$worktree_name")"

agent_id=$(jq -r .agentId "${agent_json}") \
    || die "Failed to extract agentId from ${agent_json}"
[[ -n "$agent_id" && "$agent_id" != "null" ]] || die "agentId missing in ${agent_json}"

# ---------- set up playbooks ----------

playbook_dest="${autorun_dir}/development/code-review"

printf "\n%s\n" "Setting up Code Review playbooks in ${playbook_dest}..."
mkdir -p "${playbook_dest}" || die "Cannot create ${playbook_dest}"

ensure_playbooks
cp "${PLAYBOOKS_SOURCE}/"*.md "${playbook_dest}/" || die "Failed to copy playbooks"

rm -f "${playbook_dest}/README.md"

[[ -f "${playbook_dest}/1_ANALYZE_CHANGES.md" ]] \
    || die "Playbooks missing 1_ANALYZE_CHANGES.md after setup"

# Substitute ONLY the displayed placeholder PR URL. The validation task below
# intentionally keeps the literal USER/PROJECT/pull/XXXX sentinel; replacing it
# too makes the real PR URL compare equal to "the placeholder" and stalls every
# literal agent (observed with Codex).
perl -pi -e \
    'if (/^\*\*Pull Request\*\*:/) { s@https://github\.com/USER/PROJECT/pull/XXXX@https://github.com/'"${pr_slug}"'/pull/'"${pr_number}"'@; }' \
    "${playbook_dest}/1_ANALYZE_CHANGES.md" \
    || die "Failed to update PR URL in 1_ANALYZE_CHANGES.md"
# The URL is configured by this script, so remove the template's human setup note.
perl -pi -e 's@^NOTE: \*\(Update the URL above before running this playbook\)\*$@NOTE: *(Configured automatically by maestro_pr.sh)*@' \
    "${playbook_dest}/1_ANALYZE_CHANGES.md" \
    || die "Failed to update PR configuration note"

echo "Playbooks configured."

# ---------- checkout PR in worktree ----------

# Check the PR out into a uniquely-named review branch instead of the PR's real
# head branch. This avoids "fatal: '<head>' is already checked out" when the
# author already has the head branch checked out in another clone/worktree.
# The generated branch's upstream is not authoritative: gh may point it at a
# same-named remote review branch. Re-review synchronization therefore fetches
# the exact GitHub pull ref instead of relying on `git pull`.
review_branch="${pr_head_ref}-review-$(date +%Y%m%d-%H%M%S)"

printf "\n%s" "Checking out PR #${pr_number} as '${review_branch}' in worktree at ${worktree_dir}..."
pushd "${worktree_dir}" || die "Cannot cd to ${worktree_dir}"
# Pass --repo explicitly: the PR's home (${pr_slug}) may differ from the
# worktree's remote, e.g. a fork clone whose PR lives upstream. Without --repo,
# `gh pr checkout` resolves the PR against the worktree's remote (the wrong repo)
# and fails with "Could not resolve to a PullRequest". Anchoring to ${pr_slug}
# fetches the PR from wherever resolve_pr_slug found it.
gh pr checkout "$pr_number" --repo "${pr_slug}" --branch "$review_branch" \
    || { popd || exit ; die "gh pr checkout failed"; }
popd || exit

printf "\n%s\n" "PR review setup done!"
echo "  Worktree : ${worktree_dir}"
echo "  Branch   : ${review_branch} (PR head: ${pr_head_ref}; re-review syncs the exact pull ref)"
echo "  Playbooks: ${playbook_dest}"
echo "  Agent ID : ${agent_id}"

# --------- Trigger the auto-run ----------

if [[ "$no_run" == "true" ]]; then
    printf "\n%s\n" "--no-run specified: skipping auto-run launch."
    echo "  To launch manually: node ${maestro_cli} auto-run -a ${agent_id} ${playbook_dest}/* --launch"
else
    sleep 5
    node "${maestro_cli}" auto-run -a "${agent_id}" "${playbook_dest}"/* --launch
fi
