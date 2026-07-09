#!/usr/bin/env bash
set -euo pipefail

output_file="${RUNNER_TEMP:-/tmp}/mise-php-install-output-${RANDOM:-0}.log"

set +e
"$@" 2>&1 | tee "$output_file"
status=${PIPESTATUS[0]}
set -e

bash "$(dirname "$0")/check-install-output.sh" "$output_file"

exit "$status"
