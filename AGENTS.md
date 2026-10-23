# Agent guidelines

These instructions apply repository-wide; follow more specific nested guidance.

## Development
Start development on a new branch; merge through a PR. Use Conventional Commits. Obtain explicit authorization before committing, pushing, creating or merging PRs, or releasing.
Write only the code needed to preserve or improve functionality. Reuse helpers; avoid speculative abstractions, dependencies, and unrelated refactors. Match existing style. Keep comments brief, explaining non-obvious intent or constraints. Preserve unrelated changes.
This Lua jdx/mise plugin uses `hooks/` for entry points, `lib/` for implementation, and `bin/install-dependencies.sh` for system dependencies.
Preserve supported PHP versions, mise hook contracts/options, Linux/macOS/Windows, source/static install paths, and Composer/PECL/PIE version/platform restrictions. Update `README.md` when user-facing behavior or options change.

## Validation
Follow `README.md` Contributing: `mise plugin link php-dev /path/to/verzly/mise-php`, `mise config set env._.php-dev.verbose true`, then `mise install php-dev@latest`.
Choose relevant checks from `.github/workflows/test.yml`; CI smoke tests require a standalone `/approve` PR comment by a current repository write/maintain/admin collaborator, or manual dispatch. Approval covers future commits while a valid comment remains; editing/deleting the last valid comment revokes approval. Activation/rerun commands also require the triggering actor's current write/maintain/admin permission. Comment updates rerun the current-head PR workflow natively; trusted completion reconciliation enforces revocation during long runs without repeating failed approval checks. Missing or revoked approval fails the `Approval gate` job so tests are skipped with a clear message, and a separate `Required approval` check run stays non-successful. The failed job can trigger a GitHub failure notification; the check run alone does not. Missing/ambiguous runs or originals older than 30 days require a new commit. Deploy both workflows and trusted helpers to the default branch first, and keep `Required approval` configured as a required status check. See README Contributing for active-run retries and reconciliation details. Install checks need configured mise, dependencies, network access, and installed PHP. `.github/scripts/check-php-install.sh` checks source/static installs; `source 1` additionally requires PECL where supported. No single smoke test proves full compatibility. Report checks run and gaps.

## Collaboration and releases
Use professional English for code, comments, documentation, commit messages, issues, and PRs. Keep issue/PR descriptions brief: problem/change, rationale, validation; no templated filler.
Dispatch `.github/workflows/release.yml` from the default branch and choose patch, minor, major, or current recovery. Releases must not run automatically after PRs. Each release updates full `vX.Y.Z` tag and active `vX`/`vX.Y` aliases. `latest` points to latest stable GitHub release; `next` points to latest GitHub release, including prereleases. Existing historical aliases remain unchanged. Release workflow uses `GITHUB_TOKEN` by default.
