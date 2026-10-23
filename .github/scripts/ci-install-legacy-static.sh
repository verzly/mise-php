#!/usr/bin/env bash
set -euo pipefail

mise use -g php@8.0.30
actual="$(mise exec -- php -r 'echo PHP_VERSION;')"
if [ "$actual" != "8.0.30" ]; then
  echo "Expected legacy static PHP 8.0.30, got ${actual}"
  exit 1
fi
echo "Verified legacy static PHP ${actual}"
bash .github/scripts/check-php-install.sh static
