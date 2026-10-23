set -eo pipefail

  mise cache clean || true
  mise ls-remote --no-versions-host php | tee source-versions.txt

  if [ ! -s source-versions.txt ]; then
  echo "No source versions were returned"
  exit 1
  fi

  if ! grep -Fx "${PHP_TEST_VERSION}" source-versions.txt; then
  echo "Expected PHP ${PHP_TEST_VERSION} in source version list"
  exit 1
  fi

  if awk '/^[0-9]/ && $0 !~ /^[0-9]+[.][0-9]+[.][0-9]+$/ { print; found = 1 } END { exit found ? 0 : 1 }' source-versions.txt; then
  echo "Default source version list must not include prerelease versions"
  exit 1
  fi

  expected_aliases=$'stable\nlatest\nprerelease'
  actual_aliases="$(tail -n 3 source-versions.txt | tr -d '\r')"
  if [ "$actual_aliases" != "$expected_aliases" ]; then
  echo "Expected source aliases at the end of the list:"
  printf '%s\n' "$expected_aliases"
  echo "Actual tail:"
  printf '%s\n' "$actual_aliases"
  exit 1
  fi
