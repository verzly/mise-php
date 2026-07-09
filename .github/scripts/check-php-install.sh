#!/usr/bin/env bash
set -euo pipefail

mode="${1:-source}"
require_pecl="${2:-0}"

mise exec -- php --version
mise exec -- composer --version

php_version="$(mise exec -- php -r 'echo PHP_VERSION;')"
major="${php_version%%.*}"
rest="${php_version#*.}"
minor="${rest%%.*}"
echo "Detected PHP ${php_version}"

if [ "${RUNNER_OS:-}" = "Windows" ]; then
  if [[ "${MISE_DATA_DIR:-}" != *" "* ]]; then
    echo "Windows install smoke tests must use a spaced MISE_DATA_DIR"
    exit 1
  fi

  php_binary="$(mise exec -- php -r 'echo PHP_BINARY;')"
  if [[ "${php_binary}" != *" "* ]]; then
    echo "PHP_BINARY should contain a space to cover Windows quoting regressions: ${php_binary}"
    exit 1
  fi
fi

if [ "${major}" -gt 8 ] || { [ "${major}" -eq 8 ] && [ "${minor}" -ge 1 ]; }; then
  mise exec -- php -m | grep -i '^iconv$'
  mise exec -- pie --version
else
  echo "Skipping PIE check for PHP ${php_version}: PIE requires PHP 8.1 or newer."
fi

if [ "${mode}" = "static" ]; then
  if [ "${require_pecl}" = "1" ]; then
    echo "PECL was required, but PECL is intentionally skipped for prebuilt static PHP installs."
    exit 1
  fi
  echo "Skipping PECL check for prebuilt static PHP."
  exit 0
fi

php_modules="$(mise exec -- php -m)"
require_php_module() {
  module="$1"
  if ! printf '%s\n' "${php_modules}" | grep -i "^${module}$" >/dev/null; then
    echo "Expected PHP extension is not loaded: ${module}"
    exit 1
  fi
}

require_php_module zip
require_php_module pdo_pgsql
require_php_module pgsql

if [ "${RUNNER_OS:-}" = "Windows" ]; then
  if [ "${require_pecl}" = "1" ]; then
    echo "PECL was required, but the Windows installer path does not provision PEAR/PECL."
    exit 1
  fi
  echo "Skipping PECL check on Windows."
  exit 0
fi

if [ "${major}" -gt 8 ] || { [ "${major}" -eq 8 ] && [ "${minor}" -ge 5 ]; }; then
  if [ "${require_pecl}" = "1" ]; then
    echo "PECL was required, but PHP ${php_version} is not PECL-capable in this plugin."
    exit 1
  fi
  echo "Skipping PECL check for PHP ${php_version}: PECL is not available from PHP 8.5 onward."
  exit 0
fi

if [ "${require_pecl}" = "1" ]; then
  mise exec -- pecl version
fi
