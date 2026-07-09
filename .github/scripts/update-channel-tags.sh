#!/usr/bin/env bash
set -euo pipefail

refs_file="$(mktemp)"
releases_file="$(mktemp)"
channels_file="$(mktemp)"
trap 'rm -f "${refs_file}" "${releases_file}" "${channels_file}"' EXIT

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch origin --tags --force
git ls-remote --tags --refs origin "refs/tags/*" > "${refs_file}"

gh api --paginate \
  "/repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  --jq '.[] | [.tag_name, (.prerelease | tostring), (.draft | tostring)] | @tsv' \
  > "${releases_file}"

python3 - "${refs_file}" "${releases_file}" > "${channels_file}" <<'PY'
import functools
import re
import sys
from pathlib import Path

release_tag_re = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?$")
channel_tag_re = re.compile(r"^v\d+(?:\.\d+)?$")


def parse_identifier(value):
    return (0, int(value)) if value.isdigit() else (1, value)


def compare_identifier(left, right):
    left_kind, left_value = parse_identifier(left)
    right_kind, right_value = parse_identifier(right)
    if left_kind != right_kind:
        return -1 if left_kind < right_kind else 1
    return (left_value > right_value) - (left_value < right_value)


def compare_version(left, right):
    if left["core"] != right["core"]:
        return (left["core"] > right["core"]) - (left["core"] < right["core"])

    left_pre = left["semver_prerelease"]
    right_pre = right["semver_prerelease"]
    if left_pre == right_pre:
        return 0
    if left_pre is None:
        return 1
    if right_pre is None:
        return -1

    left_parts = left_pre.split(".")
    right_parts = right_pre.split(".")
    for left_part, right_part in zip(left_parts, right_parts):
        result = compare_identifier(left_part, right_part)
        if result:
            return result
    return (len(left_parts) > len(right_parts)) - (len(left_parts) < len(right_parts))


def channel_sort_key(tag):
    if tag == "latest":
        return (-2, 0, 0)
    if tag == "next":
        return (-1, 0, 0)
    parts = tuple(int(part) for part in tag[1:].split("."))
    return (len(parts), *parts)


remote_tags = set()
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    parts = line.split("\t", 1)
    if len(parts) != 2:
        continue
    ref = parts[1]
    if ref.startswith("refs/tags/"):
        remote_tags.add(ref.rsplit("/", 1)[-1])

releases = []
seen_release_tags = set()
for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    tag, prerelease, draft = (line.split("\t") + ["", "", ""])[:3]
    match = release_tag_re.match(tag)
    if not match or draft == "true" or tag not in remote_tags or tag in seen_release_tags:
        continue
    seen_release_tags.add(tag)
    releases.append({
        "tag": tag,
        "core": tuple(int(match.group(index)) for index in (1, 2, 3)),
        "semver_prerelease": match.group(4),
        "github_prerelease": prerelease == "true",
    })

sort_key = functools.cmp_to_key(compare_version)
latest = max((release for release in releases if not release["github_prerelease"]), key=sort_key, default=None)
next_release = max(releases, key=sort_key, default=None)

desired = {}
if latest is not None:
    desired["latest"] = latest["tag"]
if next_release is not None:
    desired["next"] = next_release["tag"]

stable_releases = [release for release in releases if not release["github_prerelease"]]
major_targets = {}
minor_targets = {}
for release in stable_releases:
    major = f"v{release['core'][0]}"
    minor = f"v{release['core'][0]}.{release['core'][1]}"

    if major not in major_targets or compare_version(release, major_targets[major]) > 0:
        major_targets[major] = release

    if minor not in minor_targets or compare_version(release, minor_targets[minor]) > 0:
        minor_targets[minor] = release

desired.update({channel: release["tag"] for channel, release in major_targets.items()})
desired.update({channel: release["tag"] for channel, release in minor_targets.items()})

existing_channels = {
    tag for tag in remote_tags
    if tag in {"latest", "next"} or channel_tag_re.match(tag)
}

for channel in sorted(set(desired) | existing_channels, key=channel_sort_key):
    print(f"{channel}\t{desired.get(channel, '')}")
PY

remote_tag_exists() {
  local tag="$1"
  git ls-remote --exit-code --tags --refs origin "refs/tags/${tag}" >/dev/null 2>&1
}

update_channel_tag() {
  local channel="$1"
  local target="$2"

  if [ -n "${target}" ]; then
    git fetch origin "refs/tags/${target}:refs/tags/${target}" --force
    target_sha="$(git rev-list -n 1 "${target}")"
    git -c tag.gpgSign=false tag -f "${channel}" "${target_sha}"
    git push origin "refs/tags/${channel}" --force
    echo "Updated ${channel} tag to ${target} (${target_sha})."
    return
  fi

  if remote_tag_exists "${channel}"; then
    git push origin ":refs/tags/${channel}"
    git tag -d "${channel}" >/dev/null 2>&1 || true
    echo "Deleted ${channel} tag because no eligible release tag exists."
  else
    echo "${channel} tag does not exist and no eligible release tag exists."
  fi
}

while IFS=$'\t' read -r channel target; do
  [ -n "${channel}" ] || continue
  update_channel_tag "${channel}" "${target}"
done < "${channels_file}"
