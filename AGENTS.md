# Agent guidelines

These instructions apply repository-wide; follow more specific nested guidance.

## Development
Start development on a new branch; merge through a PR. Use Conventional Commits. Obtain explicit authorization before committing, pushing, creating or merging PRs, or releasing.
Write only the code needed to preserve or improve functionality. Reuse helpers; avoid speculative abstractions, dependencies, and unrelated refactors. Match existing style. Keep comments brief, explaining non-obvious intent or constraints. Preserve unrelated changes.
This Lua jdx/mise plugin uses `hooks/` for entry points, `lib/` for implementation, and `bin/install-dependencies.sh` for system dependencies.
Preserve supported PHP versions, mise hook contracts/options, Linux/macOS/Windows, source/static install paths, and Composer/PECL/PIE version/platform restrictions. Update `README.md` when user-facing behavior or options change.

## Validation
Follow `README.md` Contributing: `mise plugin link php-dev /path/to/verzly/mise-php`, `mise config set env._.php-dev.verbose true`, then `mise install php-dev@latest`.
Choose relevant checks from `.github/workflows/test.yml`; CI smoke tests require the PR's `needs-ci` label or manual dispatch. Install checks need configured mise, dependencies, network access, and installed PHP. `.github/scripts/check-php-install.sh` checks source/static installs; `source 1` additionally requires PECL where supported. No single smoke test proves full compatibility. Report checks run and gaps.

## Collaboration and releases
Use professional English for code, comments, documentation, commit messages, issues, and PRs. Keep issue/PR descriptions brief: problem/change, rationale, validation; no templated filler.
Dispatch Prepare Release (`.github/workflows/prepare-release.yml`) on the default branch with no version input. It prepares UTC CalVer `vYEAR.MONTH.COUNTER` through a release PR, or reuses an existing PR unchanged. Follow `README.md` Release for counter, token, CI, and recovery rules. Do not bump metadata during development; metadata stores the release version without `v` and must match the release branch's version suffix.
Merging a same-repository release PR into the default branch triggers `.github/workflows/release.yml` at the exact merge SHA. Ordinary development PRs do not release. Publication updates manifests and channels directly; delete the release branch only after success if it has not changed since merge.
Use `.github/workflows/publish.yaml` only for manual repair of an existing tag and release; preserve legacy release recovery and deletion. Rerun failed or cancelled merged-release workflows. Publication and maintenance share a lock; rerun any displaced pending run that is still needed.
