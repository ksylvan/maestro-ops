#!/usr/bin/env bash
# env_test.sh — Check _maestro_env.sh resolves the CLI and data dir per platform.
# Run: bash tests/env_test.sh   (fails on the first wrong value)
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# resolve <uname> <var> [env assignments...] — source the helper under a fake
# uname and a scratch HOME, in a clean subshell, and print the value of <var>.
resolve() {
    local os="$1" var="$2"; shift 2
    env -i HOME="$scratch" PATH="$PATH" "$@" bash -c '
        os="$1"; uname() { echo "$os"; }
        source "$2" >/dev/null
        eval "printf \"%s\" \"\${$3}\""' _ "$os" "${here}/_maestro_env.sh" "$var"
}
check() {  # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'" >&2; exit 1; fi
}

scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
dev_cli="${scratch}/src/worktrees/Maestro/preview/dist/cli/maestro-cli.js"

# Dev fallback (no installed app under the scratch paths, no MAESTRO_CLI_JS).
check "linux dev cli"   "$dev_cli" "$(resolve Linux maestro_cli)"
check "linux dev data"  "${scratch}/.config/maestro-dev" "$(resolve Linux MAESTRO_USER_DATA)"
check "linux xdg data"  "${scratch}/xdg/maestro-dev" "$(resolve Linux MAESTRO_USER_DATA XDG_CONFIG_HOME="${scratch}/xdg")"
check "darwin dev data" "${scratch}/Library/Application Support/maestro-dev" "$(resolve Darwin MAESTRO_USER_DATA)"

# Explicit MAESTRO_CLI_JS: honored, and the data dir defaults to the app's prod dir.
check "linux cli override"   "/x/cli.js" "$(resolve Linux maestro_cli MAESTRO_CLI_JS=/x/cli.js)"
check "linux prod data"      "${scratch}/.config/maestro" "$(resolve Linux MAESTRO_USER_DATA MAESTRO_CLI_JS=/x/cli.js)"
check "darwin prod data"     "${scratch}/Library/Application Support/maestro" "$(resolve Darwin MAESTRO_USER_DATA MAESTRO_CLI_JS=/x/cli.js)"
check "data override wins"   "/y/data" "$(resolve Linux MAESTRO_USER_DATA MAESTRO_CLI_JS=/x/cli.js MAESTRO_USER_DATA=/y/data)"
echo "all ok"
