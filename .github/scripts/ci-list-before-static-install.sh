#!/usr/bin/env bash
set -euo pipefail

: "${PHP_STATIC_TEST_VERSION:?PHP_STATIC_TEST_VERSION is required}"

mise cache clean || true
mise ls-remote --no-versions-host php | tee static-install-versions.txt

if [ ! -s static-install-versions.txt ]; then
  echo "No static versions were returned before install"
  exit 1
fi

if ! grep -Fx "${PHP_STATIC_TEST_VERSION}" static-install-versions.txt; then
  echo "Expected PHP ${PHP_STATIC_TEST_VERSION} in static version list before install"
  exit 1
fi
