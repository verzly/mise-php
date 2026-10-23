#!/usr/bin/env bash
set -euo pipefail

install_and_check_version() {
  expected="$1"
  mise use -g "php@${expected}"
  actual="$(mise exec -- php -r 'echo PHP_VERSION;')"
  if [ "$actual" != "$expected" ]; then
    echo "Expected static PHP ${expected}, got ${actual}"
    exit 1
  fi
  echo "Verified static PHP ${actual}"
}

install_and_check_version 8.5.12
install_and_check_version 8.0.30
