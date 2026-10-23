#!/usr/bin/env bash
set -euo pipefail

curl -fsSL -H 'User-Agent: verzly-mise-php' \
  https://dl.static-php.dev/v3/php-bin/bulk/ -o current-bulk.html
curl -fsSL -H 'User-Agent: verzly-mise-php' \
  https://dl.static-php.dev/static-php-cli/bulk/ -o legacy-bulk.html

current_artifact='href="/v3/php-bin/bulk/php-8.5.12-cli-linux-x86_64.tar.gz"'
legacy_artifact='href="/static-php-cli/bulk/php-8.0.30-cli-linux-x86_64.tar.gz"'
old_current_artifact='href="/v3/php-bin/bulk/php-8.0.30-cli-linux-x86_64.tar.gz"'

grep -Fq "$current_artifact" current-bulk.html || {
  echo 'Current v3 PHP 8.5.12 bulk artifact is missing'
  exit 1
}
grep -Fq "$legacy_artifact" legacy-bulk.html || {
  echo 'Legacy v2 PHP 8.0.30 bulk artifact is missing'
  exit 1
}
if grep -Fq "$old_current_artifact" current-bulk.html; then
  echo 'PHP 8.0.30 also appears in current v3; legacy-only install probe is invalid'
  exit 1
fi
