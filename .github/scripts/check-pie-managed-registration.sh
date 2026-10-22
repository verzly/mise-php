#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: check-pie-managed-registration.sh PHP_VERSION}"
ambient_scan="${2:?usage: check-pie-managed-registration.sh PHP_VERSION AMBIENT_SCAN_DIR}"
mkdir -p "$ambient_scan"
printf 'extension=mise_pie_not_installed_during_source_verification.so\n' > "$ambient_scan/hostile.ini"

system_snapshot() {
    if [ -d /etc/php ]; then
        find /etc/php -type l -printf '%p -> %l\n' | LC_ALL=C sort
        find -L /etc/php -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum
    fi
}

before_system="$(system_snapshot)"
PHP_INI_SCAN_DIR="$ambient_scan" PHP_PREBUILT_STATIC=0 PHP_PIE_EXTENSIONS='xdebug/xdebug,asgrim/example-pie-extension' \
    PHP_VERBOSE=1 mise install "php@$version"

sdk="$(realpath "$(mise where "php@$version")")"
php="$sdk/bin/php"

loaded_modules() {
    PHPRC="$sdk" PHP_INI_SCAN_DIR="$sdk/conf.d" "$php" -m 2>&1
}

assert_loaded() {
    module="$1"
    if ! loaded_modules | grep -Fxi "$module" > /dev/null; then
        echo "Expected managed PHP to load $module" >&2
        exit 1
    fi
}

assert_managed_ini_and_binary() {
    module="$1"
    pattern="^[[:space:]]*(zend_)?extension[[:space:]]*=[[:space:]]*(.*/)?${module}([.]so)?([[:space:]]*;.*)?$"
    ini="$(grep -RliE "$pattern" "$sdk/conf.d" || true)"
    [ -n "$ini" ] || { echo "No managed ini enables $module" >&2; exit 1; }
    while IFS= read -r ini_path; do
        case "$(realpath "$ini_path")" in "$sdk"/*) ;; *) echo "Extension ini escapes SDK: $ini_path" >&2; exit 1 ;; esac
    done <<< "$ini"
    [ "$(grep -RhiE "$pattern" "$sdk/conf.d" | wc -l)" -eq 1 ] || { echo "Duplicate ini entries enable $module" >&2; exit 1; }
    binary="$(PHPRC="$sdk" PHP_INI_SCAN_DIR="$sdk/conf.d" "$php" -r 'echo ini_get("extension_dir");')/${module}.so"
    [ -f "$binary" ] || { echo "Managed extension binary missing: $binary" >&2; exit 1; }
    case "$(realpath "$binary")" in "$sdk"/*) ;; *) echo "Extension binary escapes SDK: $binary" >&2; exit 1 ;; esac
}

assert_loaded example_pie_extension
assert_loaded xdebug
assert_managed_ini_and_binary example_pie_extension
assert_managed_ini_and_binary xdebug

# Disable PIE's two per-extension ini files, keeping them for diagnostics.
disabled_ini="$(mktemp -d "${RUNNER_TEMP:?}/pie-disabled-ini.XXXXXX")"
for module in example_pie_extension xdebug; do
    while IFS= read -r ini; do
        [ -n "$ini" ] || continue
        mv "$ini" "$disabled_ini/"
    done < <(grep -RliE "^[[:space:]]*(zend_)?extension[[:space:]]*=.*${module}([.]so)?([[:space:]]*;.*)?$" "$sdk/conf.d" || true)
done
if loaded_modules | grep -Fxi example_pie_extension > /dev/null || loaded_modules | grep -Fxi xdebug > /dev/null; then
    echo 'Managed extension disable probe did not disable both modules' >&2
    exit 1
fi

# Exercise the manual wrapper with the same hostile ambient configuration.
PHP_INI_SCAN_DIR="$ambient_scan" mise exec "php@$version" -- pie install xdebug/xdebug asgrim/example-pie-extension --force --no-interaction
PHP_INI_SCAN_DIR="$ambient_scan" mise exec "php@$version" -- pie install xdebug/xdebug asgrim/example-pie-extension --no-interaction
assert_loaded example_pie_extension
assert_loaded xdebug
assert_managed_ini_and_binary example_pie_extension
assert_managed_ini_and_binary xdebug

after_system="$(system_snapshot)"
if [ "$before_system" != "$after_system" ]; then
    echo 'System PHP configuration changed during managed PIE install/retry' >&2
    diff -u <(printf '%s\n' "$before_system") <(printf '%s\n' "$after_system") || true
    exit 1
fi

echo 'Managed normal/Zend registration, disabled-state retry, and system config isolation passed'
