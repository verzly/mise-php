#!/usr/bin/env bash
set -euo pipefail

: "${DISTRO_IMAGE:?DISTRO_IMAGE is required}"
: "${PHP_PECL_TEST_VERSION:?PHP_PECL_TEST_VERSION is required}"
: "${PHP_VERBOSE:?PHP_VERBOSE is required}"

docker run --rm \
  -v "${PWD}:/workspace" \
  -w /workspace \
  -e PHP_PECL_TEST_VERSION \
  -e PHP_VERBOSE \
  "$DISTRO_IMAGE" \
  sh -lc '
    set -eux

    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q
      apt-get install -q -y --no-install-recommends bash ca-certificates curl git tar gzip xz-utils unzip sudo findutils
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y --allowerasing --nobest bash ca-certificates curl git tar gzip xz unzip sudo findutils which
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y bash ca-certificates curl git tar gzip xz unzip sudo findutils which
    elif command -v yum >/dev/null 2>&1; then
      yum install -y bash ca-certificates curl git tar gzip xz unzip sudo findutils which
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache bash ca-certificates curl git tar gzip xz unzip sudo findutils which gcompat libstdc++
    elif command -v pacman >/dev/null 2>&1; then
      pacman -Syu --noconfirm --needed bash ca-certificates curl git tar gzip xz unzip sudo which
    else
      echo "Unsupported container package manager"
      exit 1
    fi

    curl https://mise.run | sh
    export PATH="$HOME/.local/bin:$HOME/.local/share/mise/bin:$HOME/.local/share/mise/shims:$PATH"
    mise --version
    mise plugin link php /workspace
    mise cache clean || true
    bash .github/scripts/run-install-and-check-output.sh mise use -g "php@$PHP_PECL_TEST_VERSION"
    bash .github/scripts/check-php-install.sh source 1
  '
