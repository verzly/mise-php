#!/usr/bin/env bash
set -euo pipefail

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

git ls-remote --tags --refs origin 'refs/tags/v*' > "${tmp_dir}/tags.tsv"
gh api --paginate --slurp \
  "/repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  > "${tmp_dir}/releases.json"

python3 - "${tmp_dir}/tags.tsv" "${tmp_dir}/releases.json" > "${tmp_dir}/selected.tsv" <<'PY'
import json
import re
import sys
from pathlib import Path

tag_pattern = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)$")
remote_tags = set()
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    parts = line.split("\t", 1)
    if len(parts) == 2 and parts[1].startswith("refs/tags/"):
        remote_tags.add(parts[1][len("refs/tags/"):])

payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
pages = payload if payload and isinstance(payload[0], list) else [payload]
releases = [release for page in pages for release in page]
eligible = []
for release in releases:
    tag = release.get("tag_name", "")
    match = tag_pattern.fullmatch(tag)
    if not match or tag not in remote_tags or release.get("draft") or release.get("prerelease"):
        continue
    eligible.append((tuple(int(match.group(index)) for index in (1, 2, 3)), tag))

if not eligible:
    raise SystemExit("No published stable release with an existing version tag was found; shared manifest was not changed.")

version_key, tag = max(eligible)
print(f"{tag}\t{'.'.join(str(part) for part in version_key)}")
PY

IFS=$'\t' read -r selected_tag selected_version < "${tmp_dir}/selected.tsv"
mkdir -p "${tmp_dir}/selected"
if ! gh release download "${selected_tag}" \
  --repo "${GITHUB_REPOSITORY}" \
  --pattern manifest.json \
  --dir "${tmp_dir}/selected" \
  > "${tmp_dir}/download.log" 2>&1; then
  echo "Selected stable release ${selected_tag} has no downloadable manifest.json asset; shared manifest was not changed." >&2
  cat "${tmp_dir}/download.log" >&2
  exit 1
fi

python3 - "${tmp_dir}/selected/manifest.json" "${selected_version}" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if manifest.get("version") != sys.argv[2]:
    raise SystemExit(
        f"Selected release manifest version {manifest.get('version')!r} does not match release tag version {sys.argv[2]!r}."
    )
PY

shared_exists=false
if gh release view manifest --json isDraft > "${tmp_dir}/shared-release.json" 2> "${tmp_dir}/shared-release-error.log"; then
  python3 - "${tmp_dir}/shared-release.json" <<'PY'
import json
import sys
from pathlib import Path

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if release.get("isDraft"):
    raise SystemExit("Shared manifest release is a draft; refusing to change it.")
PY
  shared_exists=true
else
  if ! grep -qiE 'not found|HTTP 404' "${tmp_dir}/shared-release-error.log"; then
    cat "${tmp_dir}/shared-release-error.log" >&2
    exit 1
  fi
fi

if [ "${shared_exists}" = true ]; then
  gh release upload manifest "${tmp_dir}/selected/manifest.json" \
    --repo "${GITHUB_REPOSITORY}" --clobber
  gh release edit manifest --repo "${GITHUB_REPOSITORY}" --prerelease --latest=false
else
  gh release create manifest "${tmp_dir}/selected/manifest.json" \
    --repo "${GITHUB_REPOSITORY}" \
    --title "manifest" \
    --notes "Latest mise plugin manifest." \
    --prerelease \
    --latest=false
fi

gh release edit "${selected_tag}" --repo "${GITHUB_REPOSITORY}" --latest
echo "Shared manifest now uses ${selected_tag} (${selected_version})."
