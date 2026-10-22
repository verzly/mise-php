#!/usr/bin/env bash
set -euo pipefail

# Every scenario below fails on purpose and asserts that the message a user sees
# without PHP_VERBOSE explains what broke, which command ran, and where the log
# is. Issue #91: dependency installer output used to be discarded, so the error
# only said "check the output above" with no output.
#
# Usage: check-error-reporting.sh PHP_VERSION [SCENARIO...]
# CI passes no scenario names and runs all of them.

version="${1:?usage: check-error-reporting.sh PHP_VERSION [SCENARIO...]}"
shift
selected=("$@")

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
base="$(mktemp -d "${RUNNER_TEMP:-/tmp}/mise-error-reporting.XXXXXX")"
trap 'rm -rf "$base"' EXIT

scenario=""
output=""
status=0

begin() {
    scenario="$1"
    printf '\n=== %s ===\n' "$scenario"
}

fail() {
    printf 'FAIL [%s] %s\n' "$scenario" "$1" >&2
    printf -- '--- captured output ---\n%s\n--- end captured output ---\n' "$output" >&2
    exit 1
}

expect_contains() {
    if [[ "$output" != *"$1"* ]]; then
        fail "expected text not found: $1"
    fi
}

expect_not_contains() {
    if [[ "$output" == *"$1"* ]]; then
        fail "unexpected text still present: $1"
    fi
}

expect_matches() {
    if ! printf '%s\n' "$output" | grep -Eq -- "$1"; then
        fail "expected pattern not found: $1"
    fi
}

pass() {
    printf 'PASS [%s]\n' "$scenario"
}

# Isolated mise state per scenario. Debug env vars are cleared on purpose: the
# whole point is that users see the cause without them.
run_isolated() {
    local name="$1"
    shift

    env \
        -u PHP_VERBOSE \
        -u MISE_VERBOSE \
        MISE_DATA_DIR="$base/$name/data" \
        MISE_CONFIG_DIR="$base/$name/config" \
        MISE_STATE_DIR="$base/$name/state" \
        MISE_CACHE_DIR="$base/$name/cache" \
        "$@"
}

link_plugin() {
    local name="$1"
    local plugin_dir="$2"

    run_isolated "$name" mise plugin link --force php "$plugin_dir" > /dev/null
}

capture_install() {
    local name="$1"
    shift

    set +e
    output="$(run_isolated "$name" "$@" 2>&1)"
    status=$?
    set -e
}

# 1. Unknown version: the message must name the requested version instead of
#    leaving users with a bare Lua runtime error.
scenario_unknown_version() {
    begin "unknown version"
    link_plugin unknown "$workspace"
    capture_install unknown mise install "php@0.1.2"
    [[ "$status" -ne 0 ]] || fail "expected a nonzero exit code"
    expect_contains "Version not found: 0.1.2"
    pass
}

# 2. Unauthenticated sudo: the guard must tell users to run 'sudo -v' before
#    they retry. The shim keeps this test from touching the real sudo state.
scenario_unauthenticated_sudo() {
    begin "unauthenticated sudo"
    local shim="$base/sudo-shim"
    mkdir -p "$shim"
    printf '#!/bin/sh\nexit 1\n' > "$shim/sudo"
    chmod +x "$shim/sudo"
    link_plugin sudo "$workspace"
    set +e
    output="$(run_isolated sudo env PATH="$shim:$PATH" mise install "php@$version" 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "expected a nonzero exit code"
    expect_contains "Run 'sudo -v' manually first"
    pass
}

# 3. Dependency installer failure (issue #91). The stub stands in for a broken
#    package manager, so this needs no root access and no real apt state.
scenario_dependency_failure() {
    begin "dependency installer failure"
    local plugin_copy="$base/plugin-dependency-failure"
    mkdir -p "$plugin_copy"
    tar -C "$workspace" --exclude=.git --exclude=.planning -cf - . | tar -C "$plugin_copy" -xf -
    cat > "$plugin_copy/bin/install-dependencies.sh" <<'STUB'
#!/bin/sh
set -eu
echo "Reading package lists..."
echo "E: Unable to locate package libgd-dev" >&2
echo "E: Unable to locate package libjpeg-dev" >&2
exit 100
STUB
    chmod +x "$plugin_copy/bin/install-dependencies.sh"
    link_plugin dependency "$plugin_copy"
    capture_install dependency mise install "php@$version"

    [[ "$status" -ne 0 ]] || fail "expected a nonzero exit code"
    expect_contains "Failed to install PHP build dependencies."
    expect_contains "----- dependency installer output -----"
    expect_contains "E: Unable to locate package libgd-dev"
    expect_contains "E: Unable to locate package libjpeg-dev"
    expect_contains "Exit code: 100"
    expect_contains "PHP_BUILD_VERSION='$version'"
    # mise runs the hook from its linked copy, not from the source checkout.
    expect_contains "$base/dependency/data/plugins/php/bin/install-dependencies.sh"
    expect_contains "💡 Full log: "
    expect_not_contains "Check the output above"

    local log_path
    log_path="$(printf '%s\n' "$output" | sed -n 's/.*Full log: \([^[:space:]]*\).*/\1/p' | head -n 1)"
    [[ -n "$log_path" ]] || fail "failure message did not include a log path"
    [[ -f "$log_path" ]] || fail "log file does not exist: $log_path"
    grep -Fq "E: Unable to locate package libgd-dev" "$log_path" || fail "log file is missing the package manager error"
    grep -Fq "E: Unable to locate package libjpeg-dev" "$log_path" || fail "log file is missing the second package manager error"
    pass
}

# 4. Real PHP build failure: dependencies install normally, then configure
#    rejects a bogus flag. This proves the end-to-end build error path is
#    actionable without debug flags. Skipped when sudo is unavailable, because
#    the dependency stage would fail first and the check would prove nothing.
scenario_build_failure() {
    begin "php build failure"
    if ! command -v sudo > /dev/null 2>&1 || ! sudo -n -v > /dev/null 2>&1; then
        printf 'SKIP [%s] passwordless sudo is unavailable; cannot reach configure in CI\n' "$scenario"
        return
    fi

    link_plugin build "$workspace"
    capture_install build env PHP_CONFIGURE_OPTIONS=--enable-mise-error-reporting-probe \
        mise install "php@$version"
    [[ "$status" -ne 0 ]] || fail "expected a nonzero exit code"
    expect_contains "Failed to configure PHP."
    expect_matches "mise-php-.*-configure-output\\.log"
    pass
}

scenarios=(unknown_version unauthenticated_sudo dependency_failure build_failure)

if [[ ${#selected[@]} -gt 0 ]]; then
    wanted=("${selected[@]}")
else
    wanted=("${scenarios[@]}")
fi

for name in "${wanted[@]}"; do
    case "$name" in
        unknown_version|unauthenticated_sudo|dependency_failure|build_failure)
            "scenario_$name"
            ;;
        *)
            printf 'Unknown scenario: %s\nValid scenarios: %s\n' "$name" "${scenarios[*]}" >&2
            exit 2
            ;;
    esac
done

printf '\nError reporting scenarios passed.\n'
