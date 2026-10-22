#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/mise-php-static-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

plugin="$work/plugin"
mkdir -p "$plugin"
cp "$repo/metadata.lua" "$plugin/"
cp -R "$repo/lib" "$repo/hooks" "$repo/tests" "$plugin/"
cp "$plugin/hooks/available.lua" "$plugin/lib/test_available.lua"
printf '\nreturn PLUGIN.Available\n' >> "$plugin/lib/test_available.lua"

cat > "$plugin/hooks/available.lua" <<'LUA'
function PLUGIN:Available(_ctx)
    if not self.static_discovery_tested then
        STATIC_TEST_PLUGIN_DIR = RUNTIME.pluginDirPath
        dofile(STATIC_TEST_PLUGIN_DIR .. "/tests/static_php_discovery.lua")
        self.static_discovery_tested = true
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
mise -C "$work" ls-remote --no-versions-host php-dev
