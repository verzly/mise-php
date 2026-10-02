#!/usr/bin/env python3
"""Generate the plugin manifest from literal metadata.lua fields."""

import argparse
import json
import re
from pathlib import Path

LEGACY_TAG_VERSION = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?)$")


def lua_string(value: str) -> str:
    result = []
    index = 0
    escapes = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
    while index < len(value):
        char = value[index]
        if char != "\\":
            result.append(char)
            index += 1
            continue
        index += 1
        if index == len(value):
            raise ValueError("metadata.lua contains an incomplete string escape")
        escaped = value[index]
        result.append(escapes.get(escaped, escaped))
        index += 1
    return "".join(result)


def assignment(text: str, field: str) -> str:
    match = re.search(
        rf'^\s*PLUGIN\.{re.escape(field)}\s*=\s*"((?:\\.|[^"\\])*)"',
        text,
        re.MULTILINE,
    )
    if not match:
        raise ValueError(f"Could not find PLUGIN.{field} in metadata.lua")
    return lua_string(match.group(1))


def notes(text: str) -> list[str]:
    match = re.search(r"^\s*PLUGIN\.notes\s*=\s*\{(.*?)^\s*\}", text, re.MULTILINE | re.DOTALL)
    if not match:
        return []
    strings = re.findall(r'"((?:\\.|[^"\\])*)"', match.group(1))
    return [lua_string(value) for value in strings]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=Path("metadata.lua"))
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", type=Path, default=Path("manifest.json"))
    parser.add_argument("--allow-legacy-version-mismatch", action="store_true")
    args = parser.parse_args()

    text = args.metadata.read_text(encoding="utf-8")
    metadata_version = assignment(text, "version")
    if metadata_version != args.version:
        tag_match = LEGACY_TAG_VERSION.fullmatch(args.tag)
        legacy_tag_matches_version = tag_match is not None and tag_match.group(1) == args.version
        is_legacy_version = legacy_tag_matches_version and int(args.version.split(".", 1)[0]) < 1000
        if not (args.allow_legacy_version_mismatch and is_legacy_version):
            raise SystemExit(
                f"Tagged metadata version {metadata_version!r} does not match requested version {args.version!r}."
            )

    manifest = {
        "name": assignment(text, "name"),
        "version": args.version,
        "homepage": assignment(text, "homepage"),
        "license": assignment(text, "license"),
        "description": assignment(text, "description"),
        "minRuntimeVersion": assignment(text, "minRuntimeVersion"),
        "manifestUrl": assignment(text, "manifestUrl"),
        "downloadUrl": f"https://github.com/{args.repository}/archive/refs/tags/{args.tag}.zip",
        "notes": notes(text),
    }
    args.output.write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
