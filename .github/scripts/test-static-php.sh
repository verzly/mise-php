#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/mise-php-static-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

plugin="$work/plugin"
mkdir -p "$plugin"
cp "$repo/metadata.lua" "$plugin/"
cp -R "$repo/lib" "$repo/hooks" "$repo/tests" "$plugin/"
cp "$repo/hooks/available.lua" "$plugin/lib/test_available.lua"
printf '\nreturn PLUGIN.Available\n' >> "$plugin/lib/test_available.lua"

# Run assertions in mise's Lua runtime, without adding a test framework/interpreter.
cat > "$plugin/hooks/available.lua" <<'LUA'
local available = require("lib/test_available")

function PLUGIN:Available(ctx)
    local tests = require("tests/static_php_test")
    if not tests.passed then
        tests.run(available)
        tests.passed = true
    end
    return { { version = "1.0.0" } }
end
LUA

export MISE_DATA_DIR="$work/data"
export MISE_CACHE_DIR="$work/cache"
export MISE_CONFIG_DIR="$work/config"
export MISE_STATE_DIR="$work/state"
export MISE_GLOBAL_CONFIG_FILE="$work/config/config.toml"
export MISE_TRUSTED_CONFIG_PATHS="$work"
unset PHP_PREBUILT_STATIC PHP_PREBUILT_STATIC_FLAVOR PHP_SKIP_DEPS

touch "$work/mise.toml"
mise -C "$work" plugin link php-dev "$plugin"
mise -C "$work" config set env._.php-dev.verbose true
mise -C "$work" ls-remote --no-versions-host php-dev
