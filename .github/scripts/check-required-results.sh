#!/usr/bin/env bash
set -euo pipefail

# Fails unless every Ubuntu logic job produced its required result. Jobs that a
# disabled manual-dispatch selector intentionally skipped are allowed to be
# skipped; each one reports its result so a real failure is obvious.
#
# Expected: RESULTS (JSON from toJSON(needs)), SOURCE_EXPECTED, STATIC_EXPECTED,
# TOOL_EXPECTED (true/false).

python3 - <<'PY'
import json
import os
import sys

results = json.loads(os.environ["RESULTS"])


def flag(name):
    return os.environ.get(name, "false") == "true"


source_expected = flag("SOURCE_EXPECTED")
static_expected = flag("STATIC_EXPECTED")
# Tool checks run their own PHP install, but they only run inside the Ubuntu
# stage after the Ubuntu source install proved the plugin can build PHP.
tool_expected = flag("TOOL_EXPECTED") and source_expected

if flag("TOOL_EXPECTED") and not source_expected:
    print("note: Ubuntu tool checks are skipped because source installs are disabled.")

required = {
    "ubuntu-env-options": "success",
    "ubuntu-list-source-versions": "success",
    "ubuntu-list-static-versions": "success",
    "ubuntu-install-source": "success" if source_expected else "skipped",
    "ubuntu-install-static": "success" if static_expected else "skipped",
    "ubuntu-install-pecl": "success" if tool_expected else "skipped",
    "ubuntu-pie-diagnostics": "success" if tool_expected else "skipped",
    "ubuntu-error-reporting": "success" if tool_expected else "skipped",
}

failed = False
for job, expected in required.items():
    actual = results.get(job, {}).get("result", "missing")
    ok = actual == expected
    print(f"{'ok  ' if ok else 'FAIL'} {job}: expected {expected}, got {actual}")
    failed = failed or not ok

if failed:
    print("Ubuntu logic stage did not pass; platform compatibility jobs stay blocked.")
    sys.exit(1)
PY
