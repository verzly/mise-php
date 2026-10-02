#!/usr/bin/env python3
"""Calculate and prepare canonical CalVer release versions."""

import argparse
from datetime import datetime, timezone
import re
import subprocess
import sys
from pathlib import Path


_CALVER = re.compile(r"([1-9][0-9]{3})\.([1-9]|1[0-2])\.([1-9][0-9]*)\Z")
_ASSIGNMENT_LINE = re.compile(r"(?m)^[ \t]*PLUGIN\.version[ \t]*=[^\r\n]*")
_VERSION_ASSIGNMENT = re.compile(
    r"(?P<prefix>[ \t]*PLUGIN\.version[ \t]*=[ \t]*)"
    r"(?P<quote>[\"'])(?P<value>[^\"'\\\r\n]*)(?P=quote)"
    r"(?P<suffix>[ \t]*(?:--[^\r\n]*)?)\Z"
)


def parse_calver(version):
    """Parse canonical YEAR.MONTH.COUNTER and return its numeric components."""
    match = _CALVER.fullmatch(version) if isinstance(version, str) else None
    if match is None or match.group(1) == "0000":
        raise ValueError("invalid CalVer: {!r}".format(version))
    return tuple(int(component) for component in match.groups())


def _tag_versions(tags):
    versions = []
    for tag in tags:
        if isinstance(tag, str) and tag.startswith("v"):
            try:
                versions.append(parse_calver(tag[1:]))
            except ValueError:
                pass
    return versions


def next_version(tags, current_metadata_version, date):
    """Return next CalVer for date; tags and metadata reserve published versions."""
    versions = _tag_versions(tags)
    try:
        versions.append(parse_calver(current_metadata_version))
    except ValueError:
        pass

    later_periods = [version for version in versions if version[:2] > (date.year, date.month)]
    if later_periods:
        future = max(later_periods)
        raise ValueError(
            "refusing date before existing CalVer period {}.{}".format(future[0], future[1])
        )

    counter = max(
        (version[2] for version in versions if version[:2] == (date.year, date.month)),
        default=0,
    ) + 1
    return "{:04d}.{}.{}".format(date.year, date.month, counter)


def _read_metadata(path):
    with path.open("r", encoding="utf-8", newline="") as metadata_file:
        text = metadata_file.read()
    assignments = list(_ASSIGNMENT_LINE.finditer(text))
    if len(assignments) != 1:
        raise ValueError("metadata must contain exactly one PLUGIN.version assignment")

    line = assignments[0]
    assignment = _VERSION_ASSIGNMENT.fullmatch(line.group(0))
    if assignment is None:
        raise ValueError("metadata contains invalid PLUGIN.version assignment")
    return text, line, assignment


def _prepare_metadata(path, version, tags):
    parsed = parse_calver(version)
    text, line, assignment = _read_metadata(path)
    existing = _tag_versions(tags)
    try:
        existing.append(parse_calver(assignment.group("value")))
    except ValueError:
        pass

    later_periods = [item for item in existing if item[:2] > parsed[:2]]
    if later_periods:
        future = max(later_periods)
        raise ValueError(
            "refusing version before existing CalVer period {}.{}".format(
                future[0], future[1]
            )
        )

    replacement = "{}{}{}{}".format(
        assignment.group("prefix"),
        assignment.group("quote"),
        version,
        assignment.group("quote") + assignment.group("suffix"),
    )
    updated = text[: line.start()] + replacement + text[line.end() :]
    with path.open("w", encoding="utf-8", newline="") as metadata_file:
        metadata_file.write(updated)


def _validate_metadata(path, version):
    parse_calver(version)
    _, _, assignment = _read_metadata(path)
    if assignment.group("value") != version:
        raise ValueError(
            "metadata version {!r} does not match {!r}".format(
                assignment.group("value"), version
            )
        )


def _git_tags():
    result = subprocess.run(
        ["git", "tag", "--list"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    return result.stdout.splitlines()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    next_command = commands.add_parser("next", help="calculate next release version")
    next_command.add_argument("--metadata", type=Path, default=Path("metadata.lua"))
    prepare_command = commands.add_parser("prepare", help="update metadata.lua for release")
    prepare_command.add_argument("version")
    prepare_command.add_argument("--metadata", type=Path, default=Path("metadata.lua"))
    validate_command = commands.add_parser("validate", help="check metadata release version")
    validate_command.add_argument("version")
    validate_command.add_argument("--metadata", type=Path, default=Path("metadata.lua"))
    args = parser.parse_args(argv)

    try:
        if args.command == "next":
            _, _, assignment = _read_metadata(args.metadata)
            version = next_version(
                _git_tags(),
                assignment.group("value"),
                datetime.now(timezone.utc).date(),
            )
            print(version)
        elif args.command == "prepare":
            _prepare_metadata(args.metadata, args.version, _git_tags())
        else:
            _validate_metadata(args.metadata, args.version)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print("release-version: {}".format(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
