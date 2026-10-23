set -eo pipefail

  mise cache clean || true
  mise ls-remote --no-versions-host php | tee static-versions.txt

  if [ ! -s static-versions.txt ]; then
  echo "No static versions were returned"
  exit 1
  fi

  if ! grep -Fx "${PHP_TEST_VERSION}" static-versions.txt; then
  echo "Expected PHP ${PHP_TEST_VERSION} in static version list"
  exit 1
  fi

  if [ "${FLAVOR_LABEL}" = "default" ]; then
  # 8.5.12 is the current v3 release, 8.5.9 exists only in v3, and 8.0.30
  # exists only in the legacy static-php-cli (v2) listing.
  for version in 8.5.12 8.5.9 8.0.30; do
  if ! grep -Fx "$version" static-versions.txt; then
  echo "Expected v3/legacy discovery probe PHP $version in static version list"
  exit 1
  fi
  done
  fi
