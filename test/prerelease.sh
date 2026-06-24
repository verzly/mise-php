#!/usr/bin/env bash
set -euo pipefail

TOOL="${1:-php}"

plain_versions() {
  mise ls-remote --no-versions-host "$TOOL"
}

prerelease_versions() {
  mise ls-remote --no-versions-host --prerelease "$TOOL"
}

json_versions() {
  mise ls-remote -J --no-versions-host --strict-metadata --prerelease "$TOOL"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if ! grep -Fxq "$needle" <<< "$haystack"; then
    echo "FAIL: expected to find '$needle'" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  if grep -Fxq "$needle" <<< "$haystack"; then
    echo "FAIL: did not expect to find '$needle'" >&2
    exit 1
  fi
}

assert_aliases_at_end() {
  local haystack="$1"
  local expected

  expected=$'stable
latest
prerelease'

  if [[ "$(tail -n 3 <<< "$haystack")" != "$expected" ]]; then
    echo "FAIL: expected stable/latest/prerelease aliases to be the final list entries" >&2
    echo "Actual final entries:" >&2
    tail -n 6 <<< "$haystack" >&2
    exit 1
  fi
}

plain="$(plain_versions)"
with_pre="$(prerelease_versions)"
json="$(json_versions)"

assert_contains "$plain" "8.5.7"
assert_not_contains "$plain" "8.5.8RC1"
assert_not_contains "$plain" "8.5.0alpha1"
assert_not_contains "$plain" "8.5.0beta1"

assert_contains "$with_pre" "8.5.8RC1"
assert_contains "$with_pre" "8.5.0alpha1"
assert_contains "$with_pre" "8.5.0beta1"
assert_contains "$with_pre" "8.5.7"

assert_aliases_at_end "$plain"
assert_aliases_at_end "$with_pre"

jq -e '.[] | select((.version // .) == "8.5.8RC1")' <<< "$json" >/dev/null
jq -e '.[] | select((.version // .) == "8.5.7")' <<< "$json" >/dev/null

echo "OK: prerelease ls-remote filtering works for $TOOL"
echo "Note: vfox/tool-plugin JSON output may only contain .version; do not assert .prerelease metadata for this backend."
