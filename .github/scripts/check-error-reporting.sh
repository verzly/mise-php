#!/usr/bin/env bash
set -euo pipefail

# Every scenario below fails on purpose and asserts that the message a user sees
# explains what broke, which command ran, and where the log
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

# The point of these tests is that reviewers can read the message in the Actions
# log, so the captured output is always printed, not only on failure.
show() {
    printf -- '--- captured output ---\n%s\n--- end captured output ---\n' "$output"
}

pass() {
    printf 'PASS [%s]\n' "$scenario"
}

# Isolated mise state per scenario. No debug flag is set unless the caller
# explicitly enables PHP_VERBOSE=1 or MISE_VERBOSE=1 for a local probe.
run_isolated() {
    local name="$1"
    shift
    local -a verbose=()
    [[ "${PHP_VERBOSE:-}" == 1 ]] && verbose+=(PHP_VERBOSE=1)
    [[ "${MISE_VERBOSE:-}" == 1 ]] && verbose+=(MISE_VERBOSE=1)

    env \
        -u PHP_VERBOSE \
        -u MISE_VERBOSE \
        MISE_DATA_DIR="$base/$name/data" \
        MISE_CONFIG_DIR="$base/$name/config" \
        MISE_STATE_DIR="$base/$name/state" \
        MISE_CACHE_DIR="$base/$name/cache" \
        "${verbose[@]}" \
        "$@"
}

assert_no_redundant_verbose_tip() {
    if [[ "${PHP_VERBOSE:-}" == 1 || "${MISE_VERBOSE:-}" == 1 ]]; then
        expect_not_contains "Run 'PHP_VERBOSE=1 mise install"
    fi
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
    show
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
    show
    pass
}

# 3. Dependency installer failure (issue #91). The real
#    bin/install-dependencies.sh runs; only the package manager binary is
#    shimmed, so the failure path is the same as a broken repository or a
#    conflicting package. The sudo shim runs commands unprivileged and keeps the
#    PATH shim visible, so no system package is ever touched.
scenario_dependency_failure() {
    begin "dependency installer failure"
    local shim="$base/dependency-shim"
    mkdir -p "$shim"

    cat > "$shim/sudo" <<'SHIM'
#!/bin/sh
# Satisfy mise's non-interactive probe, then run the command unprivileged so the
# package manager shim on PATH is visible.
if [ "$1" = "-n" ] && [ "$2" = "-v" ]; then
    exit 0
fi
exec "$@"
SHIM

    local pm=""
    local candidate
    for candidate in apt-get dnf microdnf yum pacman apk; do
        if command -v "$candidate" > /dev/null 2>&1; then
            pm="$candidate"
            break
        fi
    done
    [[ -n "$pm" ]] || fail "no supported package manager found to shim"

    cat > "$shim/$pm" <<'SHIM'
#!/bin/sh
# Read-only subcommands succeed so the installer reaches the install step.
for arg in "$@"; do
    case "$arg" in
        update|config-manager|enable|group|groupinstall) exit 0 ;;
    esac
done
echo "E: Unable to locate package libgd-dev" >&2
echo "E: Package libjpeg-dev has no installation candidate" >&2
exit 100
SHIM
    chmod +x "$shim/sudo" "$shim/$pm"

    link_plugin dependency "$workspace"
    capture_install dependency env PATH="$shim:$PATH" mise install "php@$version"

    [[ "$status" -ne 0 ]] || fail "expected a nonzero exit code"
    expect_contains "Failed to install PHP build dependencies."
    if [[ "${PHP_VERBOSE:-}" != 1 && "${MISE_VERBOSE:-}" != 1 ]]; then
        expect_contains "----- dependency installer output -----"
    fi
    expect_contains "E: Unable to locate package libgd-dev"
    expect_contains "E: Package libjpeg-dev has no installation candidate"
    expect_contains "Exit code: 100"
    expect_contains "PHP_BUILD_VERSION='$version'"
    # The real installer ran from mise's linked plugin copy.
    expect_contains "plugins/php/bin/install-dependencies.sh"
    expect_not_contains "plugin-dependency-failure"
    expect_contains "💡 Full log: "
    expect_not_contains "Check the output above"
    assert_no_redundant_verbose_tip

    local log_path
    log_path="$(printf '%s\n' "$output" | sed -n 's/.*Full log: \([^[:space:]]*\).*/\1/p' | head -n 1)"
    [[ -n "$log_path" ]] || fail "failure message did not include a log path"
    [[ -f "$log_path" ]] || fail "log file does not exist: $log_path"
    grep -Fq "E: Unable to locate package libgd-dev" "$log_path" || fail "log file is missing the package manager error"
    grep -Fq "E: Package libjpeg-dev has no installation candidate" "$log_path" || fail "log file is missing the second package manager error"
    show
    pass
}

# 4. Real PHP configure failure: reject an invalid host before optional build
#    tools like re2c are checked. Normal Ubuntu source installs test dependencies.
scenario_build_failure() {
    begin "php build failure"
    link_plugin build "$workspace"
    local capture_file="$base/build/output.log"
    mkdir -p "$(dirname "$capture_file")"
    set +e
    run_isolated build env PHP_SKIP_DEPS=1 PHP_CONFIGURE_OPTIONS=--host=invalid-target-for-ci \
        timeout 10m mise install "php@$version" 2>&1 | tee "$capture_file"
    status=${PIPESTATUS[0]}
    set -e
    output="$(<"$capture_file")"
    if [[ "$status" -eq 124 ]]; then
        fail "PHP configure exceeded 10-minute timeout"
    fi
    [[ "$status" -ne 0 ]] || fail "expected a nonzero exit code"
    expect_contains "Failed to configure PHP."
    expect_matches "mise-php-.*-configure-output\\.log"
    expect_contains "build/config.sub invalid-target-for-ci failed"
    assert_no_redundant_verbose_tip

    local configure_log
    configure_log="$(printf '%s\n' "$output" | grep -oEm1 '/[^[:space:]]*mise-php-[^[:space:]]*-configure-output\.log' || true)"
    [[ -n "$configure_log" && -f "$configure_log" ]] || fail "configure output log is missing: $configure_log"
    grep -Fq "Invalid configuration 'invalid-target-for-ci'" "$configure_log" || fail "configure log is missing the root cause"
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
