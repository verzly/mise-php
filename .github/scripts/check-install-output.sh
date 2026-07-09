#!/usr/bin/env bash
set -euo pipefail

file="${1:?usage: check-install-output.sh <output-file>}"

if grep -E \
  'PIE installation did not complete successfully|PIE verification failed|PIE verification timed out|Composer installation did not complete successfully|Composer verification failed|PECL extension installation failed|Failed to install .* PECL extension|Failed to write configuration for PECL extension' \
  "$file"; then
  echo "mise-php install reported post-install failure output"
  exit 1
fi
