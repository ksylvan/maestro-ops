# maestro-ops

A small toolkit of shell scripts that set up isolated git worktrees and
Maestro agents for any GitHub repository. Point a script at a repository
and a pull request, and it clones the repository if needed, creates a
worktree and a Maestro agent, and, on request, runs a Code Review
playbook against the pull request.

## Overview

The `maestro_*` scripts set up worktrees and agents on demand:

- `maestro_pr.sh` sets up a full PR review environment and can launch a
  Code Review playbook automatically.
- `maestro_wt.sh` sets up (or tears down) a plain worktree and agent, with
  no PR or playbook involved, for general feature work.
- `maestro_watch.sh`, `maestro_id.sh`, and `maestro_doctor.sh` support the
  two setup scripts: they watch a run to completion, look up an agent's
  UUID, and check your environment.

## Requirements

- [`gh`](https://cli.github.com/), the GitHub CLI, authenticated
- [`jq`](https://stedolan.github.io/jq/)
- [`node`](https://nodejs.org/), to run the Maestro CLI
- `git`
- The [Maestro](https://github.com/RunMaestro/Maestro) CLI, either the
  installed app or a checked-out preview build (see
  [Maestro CLI resolution](#maestro-cli-resolution) below)
- The `${MAESTRO_REPOS_DIR}` directory tree that holds your repository
  clones and worktrees (see [Directory layout](#directory-layout) below)

`maestro_pr.sh` also uses Code Review playbooks. Check them out locally, or
let the script fetch them from GitHub automatically (see
[Code Review playbook source](#code-review-playbook-source) below).

The worktree helpers live in [`_worktree_helpers.sh`](./_worktree_helpers.sh)
and the shared environment logic in [`_maestro_env.sh`](./_maestro_env.sh).
Both files are sourced by the scripts directly, so no shell dotfile setup is
necessary.

## Configuration

### Environment variables

Set these in your shell environment, or in a `.env` file next to the
scripts (see [Maestro CLI resolution](#maestro-cli-resolution)).

| Variable | Default | Description |
| --- | --- | --- |
| `MAESTRO_REPOS_DIR` | `$HOME/src` | Root directory for repository clones and worktrees |
| `MAESTRO_GH_SEARCH` | (empty → your GitHub user) | Colon-separated GitHub owners to search when resolving a repository name, e.g. `myorg:myuser`. When empty, `maestro_pr.sh` defaults to your authenticated GitHub user |
| `MAESTRO_PLAYBOOKS_DIR` | `${MAESTRO_REPOS_DIR}/Maestro-Playbooks` | Local directory for Maestro Code Review playbooks |
| `MAESTRO_PLAYBOOKS_GH_REPO` | `RunMaestro/Maestro-Playbooks` | GitHub repository to clone when the local playbooks directory is missing |
| `MAESTRO_DEFAULT_AGENT_TYPE` | `claude` | Agent type used when a script call does not name one |

### Directory layout

All scripts derive their paths from `${MAESTRO_REPOS_DIR}`:

- Base clones: `${MAESTRO_REPOS_DIR}/<repo>`
- Worktrees: `${MAESTRO_REPOS_DIR}/worktrees/<repo>/<name>`
- Autorun playbook directories: `${MAESTRO_REPOS_DIR}/worktrees/autorun/<repo>/<name>`

`<name>` is the composed name `<repo>-<label>-<agent_type>`, for example
`myrepo-pr-209-claude`.

### Maestro CLI resolution

All scripts resolve the `maestro-cli.js` to run (and whether to override
`MAESTRO_USER_DATA`) through the shared helper
[`_maestro_env.sh`](./_maestro_env.sh), which they source on startup.
Resolution order:

1. **`.env`** — if a `.env` file sits next to the scripts, the scripts
   source it first. Use it to point at a checked-out rc or preview build
   (see below).
2. **`MAESTRO_CLI_JS`** — if set (typically from `.env` or the
   environment), this path wins, and `MAESTRO_USER_DATA` is honored as
   given. `maestro_watch.sh` also honors the legacy `MAESTRO_JS` as an
   alias for `MAESTRO_CLI_JS`.
3. **Installed app** — otherwise, if
   `/Applications/Maestro.app/Contents/Resources/maestro-cli.js` exists,
   the scripts use that CLI and leave `MAESTRO_USER_DATA` unset, so the
   app uses its own data directory.
4. **Dev fallback** — otherwise the scripts fall back to
   `~/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js` with
   `MAESTRO_USER_DATA` pointed at `~/Library/Application Support/maestro-dev`.

#### Running against a checked-out rc branch (developers)

When you develop Maestro itself, point the scripts at your checked-out rc
or preview build and its dev data directory. Copy the example file and
adjust the paths to your worktree:

```zsh
cp .env.example .env
# then edit .env if your worktree lives somewhere else
```

The two variables that matter for a dev build:

```sh
export MAESTRO_CLI_JS="$HOME/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"
export MAESTRO_USER_DATA="$HOME/Library/Application Support/maestro-dev"
```

`.env.example` documents every other variable as a commented default; the
scripts also honor the legacy `MAESTRO_JS` as an alias for `MAESTRO_CLI_JS`.
`.env` is git-ignored, so a local override never reaches the repository.
Delete `.env` (or unset the variables) to switch back to the installed
app.

## Agent types

Every script that creates an agent accepts an `agent_type` argument, one
of:

- `claude` (default)
- `codex`
- `grok`
- `hermes`
- `opencode`

## Scripts

### `maestro_pr.sh` — PR review setup

Sets up a full, isolated PR review environment for a repository and a PR
number.

**Usage:**

```zsh
./maestro_pr.sh [--no-run] [--draft-ok] <repo> <pr_number> [agent_type]
```

**Arguments:**

| Argument | Description |
| --- | --- |
| `repo` | Repository name, resolved through `MAESTRO_GH_SEARCH` and cloned on demand |
| `pr_number` | The PR number (numeric) |
| `agent_type` | Optional. One of `claude`, `codex`, `grok`, `hermes`, `opencode`. Defaults to `${MAESTRO_DEFAULT_AGENT_TYPE:-claude}` |

**Options:**

| Flag | Description |
| --- | --- |
| `--no-run` | Set up the agent and playbooks, but skip the final auto-run launch. The script prints the manual launch command instead |
| `--draft-ok` | Allow a draft PR (skip the draft check) |

**Examples:**

```zsh
./maestro_pr.sh myrepo 209
./maestro_pr.sh otherrepo 42
./maestro_pr.sh myrepo 456 codex
./maestro_pr.sh --no-run myrepo 209
./maestro_pr.sh --draft-ok myrepo 209
```

**What it does:**

1. Resolves the repository slug: if `${MAESTRO_REPOS_DIR}/<repo>` already
   exists, the script reads the slug from its `origin` remote; otherwise
   it tries each owner in `MAESTRO_GH_SEARCH` in order, keeps the first
   one that resolves on GitHub, and clones the repository into
   `${MAESTRO_REPOS_DIR}/<repo>`. When `MAESTRO_GH_SEARCH` is empty, it
   defaults to your authenticated GitHub user (`gh api user`).
2. Finds where the PR lives, then validates that it is open (and, unless
   `--draft-ok` is given, not a draft). The clone may be a fork whose PR
   only exists upstream, so the script tries, in order: the clone's own
   slug, its upstream parent, then each `MAESTRO_GH_SEARCH` owner (empty →
   your GitHub user). The first repo that has the PR wins, and every later
   PR call targets it. Example: `fabric` is cloned from your fork
   `ksylvan/fabric`, but PR 2200 exists only in `danielmiessler/fabric`,
   so the script resolves the PR upstream.
3. Delegates to [`maestro_wt.sh`](#maestro_wtsh--named-worktree--maestro-agent)
   to create the worktree, named `<repo>-pr-<pr_number>-<agent_type>`, set
   up the autorun directory, and create a Maestro agent with the nudge
   "Do not make any changes this is only a review task."
4. Copies Code Review playbooks into
   `${MAESTRO_REPOS_DIR}/worktrees/autorun/<repo>/<worktree>/development/code-review/`
   (see [Code Review playbook source](#code-review-playbook-source)).
5. Patches the real PR URL into `1_ANALYZE_CHANGES.md`.
6. Checks out the PR head into a uniquely named review branch in the
   worktree, using `gh pr checkout --repo <pr_slug>` (the repo found in
   step 2) so forked and upstream PRs resolve correctly.
7. Launches the auto-run against the playbooks, unless `--no-run` is
   given.

Worktree cleanup is left to you after the review completes; run
`maestro_wt.sh --delete` when you are done.

#### Code Review playbook source

The playbooks come from one of two places, in this order:

1. **Local checkout** — if `*.md` files exist under
   `${MAESTRO_PLAYBOOKS_DIR}/Development/Code-Review`, the script copies
   them from there.
2. **GitHub fallback** — otherwise the script clones
   `MAESTRO_PLAYBOOKS_GH_REPO` (default
   [`RunMaestro/Maestro-Playbooks`](https://github.com/RunMaestro/Maestro-Playbooks))
   into `MAESTRO_PLAYBOOKS_DIR` and uses the same path from there on.

Either way, the script drops the playbook `README.md` and patches the PR
URL into `1_ANALYZE_CHANGES.md`.

### `maestro_wt.sh` — named worktree + Maestro agent

Sets up, or tears down, a named git worktree wired to a Maestro agent,
with no PR review or playbook scaffolding. Use it for an isolated
workspace for general feature work, experiments, or refactors driven by a
Maestro agent.

**Usage:**

```zsh
./maestro_wt.sh [--nudge MSG] [--json-out PATH] <repo> <worktree_name> [agent_type]
./maestro_wt.sh --delete [--force] <repo> <worktree_name> [agent_type]
```

**Arguments:**

| Argument | Description |
| --- | --- |
| `repo` | Any repository already cloned under `${MAESTRO_REPOS_DIR}` |
| `worktree_name` | Free-form label for the worktree. Allowed characters: letters, digits, `.`, `_`, `-` |
| `agent_type` | Optional. One of `claude`, `codex`, `grok`, `hermes`, `opencode`. Defaults to `${MAESTRO_DEFAULT_AGENT_TYPE:-claude}` |

The finished worktree and agent share the name
`<repo>-<worktree_name>-<agent_type>`.

**Options:**

| Flag | Description |
| --- | --- |
| `--nudge MSG` | Pass `MSG` as the nudge message when creating the agent. Without this flag, the agent starts with no nudge |
| `--json-out PATH` | Write the `create-agent` JSON response to `PATH`. Without this flag, the script writes the JSON to a temporary file and removes it on exit |
| `--delete` | Tear down the worktree and its Maestro agent instead of creating them. Cannot combine with `--nudge` or `--json-out` |
| `--force` | Only with `--delete`: skip the confirmation prompt, remove the worktree even with uncommitted changes, and delete the autorun directory without prompting |

**Examples:**

```zsh
./maestro_wt.sh myrepo my-feature
./maestro_wt.sh myapp refactor-auth
./maestro_wt.sh myservice experiment codex
./maestro_wt.sh --nudge "review only" --json-out /tmp/a.json myrepo pr-209
./maestro_wt.sh --delete myrepo my-feature
./maestro_wt.sh --delete --force myservice experiment codex
```

**What it does (create):**

1. Creates a git worktree named `<repo>-<worktree_name>-<agent_type>`
   under `${MAESTRO_REPOS_DIR}/worktrees/<repo>/`.
2. Creates the matching autorun directory under
   `${MAESTRO_REPOS_DIR}/worktrees/autorun/<repo>/<worktree>/`.
3. Creates a Maestro agent scoped to the worktree, using the selected
   `agent_type`, pointed at the autorun directory.

Unlike `maestro_pr.sh`, this script copies no playbooks, checks out no
PR, and launches no auto-run. The worktree starts on the default branch,
and the agent starts with no nudge. Drop your own playbooks into the
autorun directory when you want to run them.

**What it does (`--delete`):**

1. Reconstructs the same `<repo>-<worktree_name>-<agent_type>` name.
2. Prompts for confirmation, unless `--force` is given.
3. Removes the git worktree and prunes it (with `--force`, also removes a
   worktree with uncommitted changes).
4. Prompts whether to also delete the worktree's autorun directory
   (with `--force`, deletes it without asking).
5. Looks up the agent by name, through `maestro_id.sh`, and removes it.

The teardown is best-effort. If the worktree is already gone, the script
still tries to remove the agent; if no matching agent exists, it skips
that step. Run the same command again to finish a partial cleanup.

### `maestro_watch.sh` — auto-run completion watcher

Watches a Maestro auto-run agent and prints a running log until the run
finishes, then fires a desktop toast notification.

Maestro reports an auto-run agent as idle between iterations, because each
iteration runs as a detached, headless process rather than a tracked
desktop session. This watcher follows that process directly instead, by
agent ID (for `claude`) or by worktree directory (for `codex`, `grok`,
`hermes`, and `opencode`). Because auto-run exits after every task and relaunches for the
next one, the watcher declares the run "done" only after the process has
stayed gone for the full grace window with no new iteration starting.

**Usage:**

```zsh
./maestro_watch.sh <agent_id> [grace_seconds] [poll_seconds] [agent_type]
```

**Arguments:**

| Argument | Description |
| --- | --- |
| `agent_id` | The UUID of the Maestro agent to watch, for example from [`maestro_id.sh`](#maestro_idsh--agent-uuid-lookup) |
| `grace_seconds` | How long the process must stay gone before the watcher declares "done". Default: `60` |
| `poll_seconds` | Polling interval. Default: `5` |
| `agent_type` | Optional agent type: `claude`, `codex`, `grok`, `hermes`, or `opencode`. Maestro usually reports this on its own; pass it only when that metadata is unavailable |

**Options:**

| Flag | Description |
| --- | --- |
| `-h, --help` | Show help and exit |

**Examples:**

```zsh
./maestro_watch.sh 14fcd1d2-19ee-482b-8e4a-b521aca9a7e6
./maestro_watch.sh 14fcd1d2-19ee-482b-8e4a-b521aca9a7e6 120 10
./maestro_watch.sh "$(./maestro_id.sh myrepo-pr-345-claude)"
```

**What it does:**

1. Resolves the Maestro CLI and data directory through
   [`_maestro_env.sh`](#maestro-cli-resolution). Because it reads the
   agent history file directly off disk, it defaults `MAESTRO_USER_DATA`
   to the installed app's location when the helper leaves it unset.
2. Polls every `poll_seconds` for the agent's process, logging each new
   iteration as it starts.
3. When the process disappears, opens a grace window of `grace_seconds`,
   watching for the next iteration to start.
4. Once the grace window passes with no new iteration, declares the run
   done, reports the iteration count and the number of completed tasks,
   and fires a desktop toast notification.

The watcher runs until the agent finishes, or until you stop it with
`Ctrl-C`.

### `maestro_id.sh` — agent UUID lookup

Looks up a Maestro agent's UUID by its exact name. Use this when a
script, or a `maestro-cli send` call, needs an `agentId`.

**Usage:**

```zsh
./maestro_id.sh <agent_name>
```

**Arguments:**

| Argument | Description |
| --- | --- |
| `agent_name` | The exact name of the Maestro agent |

**Options:**

| Flag | Description |
| --- | --- |
| `-h, --help` | Show help and exit |

**Examples:**

```zsh
./maestro_id.sh myrepo-pr-345-claude
./maestro_id.sh myservice-issue-12-codex
```

**What it does:**

Parses the output of `maestro-cli list agents` and prints the UUID of the
named agent to stdout. Exits non-zero if no agent matches, or if more than
one agent shares the name (and, in that case, prints a warning with every
matching UUID).

### `maestro_doctor.sh` — environment diagnostic

Prints the resolved environment, the directory model, and a prerequisite
check, so you can confirm your setup before running the other scripts.

**Usage:**

```zsh
./maestro_doctor.sh [-h|--help]
```

**What it prints:**

1. The resolved configuration variables (`MAESTRO_REPOS_DIR`,
   `MAESTRO_GH_SEARCH`, `MAESTRO_PLAYBOOKS_DIR`,
   `MAESTRO_PLAYBOOKS_GH_REPO`, `MAESTRO_DEFAULT_AGENT_TYPE`) and the
   resolved `maestro_cli` path.
2. A worked example of the directory model: the base, worktree, and
   autorun paths for a sample repository, worktree name, and agent type.
3. A check for `git`, `gh`, `jq`, and `node`, plus the current `gh`
   authentication status.

`maestro_doctor.sh` always exits `0`. It is a read-only diagnostic, not a
hard prerequisite check, so a missing tool is reported, not treated as a
failure.
