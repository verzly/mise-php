set -eo pipefail

  mise cache clean || true
  mise ls-remote --no-versions-host --prerelease php | tee source-prerelease-versions.txt

  if ! awk '/^[0-9]/ && $0 !~ /^[0-9]+[.][0-9]+[.][0-9]+$/ { found = 1 } END { exit found ? 0 : 1 }' source-prerelease-versions.txt; then
  echo "Prerelease source version list must include at least one prerelease version"
  exit 1
  fi

  if ! grep -Fx '8.5.8RC1' source-prerelease-versions.txt; then
  echo "Prerelease source version list must include 8.5.8RC1"
  exit 1
  fi

  expected_aliases=$'stable\nlatest\nprerelease'
  actual_aliases="$(tail -n 3 source-prerelease-versions.txt | tr -d '\r')"
  if [ "$actual_aliases" != "$expected_aliases" ]; then
  echo "Expected source prerelease aliases at the end of the list:"
  printf '%s\n' "$expected_aliases"
  echo "Actual tail:"
  printf '%s\n' "$actual_aliases"
  exit 1
  fi
