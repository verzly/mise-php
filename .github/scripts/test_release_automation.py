"""Offline regressions for release scripts and workflow Bash steps."""

import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "fixture/mise-php"
METADATA = '''PLUGIN = {}
PLUGIN.name = "php"
PLUGIN.version = "0.10.2"
PLUGIN.homepage = "https://github.com/fixture/mise-php"
PLUGIN.license = "AGPL-3.0"
PLUGIN.description = "PHP version manager"
PLUGIN.minRuntimeVersion = "0.3.2"
PLUGIN.manifestUrl = "https://github.com/fixture/mise-php/releases/download/manifest/manifest.json"
PLUGIN.notes = {
    "Builds PHP from source.",
    "Use \\"quoted\\" options.",
}
'''

# Only modeled API calls are accepted; an unexpected call cannot reach GitHub.
FAKE_GH = '''import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ["GH_CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\\n")
path = Path(os.environ["GH_STATE"])
state = json.loads(path.read_text(encoding="utf-8"))

def option(name):
    return args[args.index(name) + 1]

if args[:1] == ["api"] and "/pulls?" in args[-1]:
    print(json.dumps(state.get("pulls", [[]])))
elif args[:1] == ["api"] and "/releases?" in args[-1]:
    print(json.dumps(state.get("releases", [[]])))
elif args[:2] == ["pr", "create"]:
    state["created_pr"] = {key: option(key) for key in ("--base", "--head", "--title", "--body")}
    print("https://github.com/fixture/mise-php/pull/42")
elif args[:2] == ["release", "view"]:
    view = state.get("views", {}).get(args[2])
    if view is None:
        print("HTTP 404: Not Found", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(view))
elif args[:2] == ["release", "download"]:
    asset = state.get("assets", {}).get(args[2])
    if asset is None:
        print("manifest.json not found", file=sys.stderr)
        sys.exit(1)
    directory = Path(option("--dir"))
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "manifest.json").write_text(json.dumps(asset), encoding="utf-8")
elif args[:2] == ["release", "upload"]:
    state.setdefault("assets", {})[args[2]] = json.loads(Path(args[3]).read_text(encoding="utf-8"))
elif args[:2] == ["release", "edit"]:
    pass
elif args[:3] == ["release", "create", "manifest"]:
    state.setdefault("assets", {})["manifest"] = json.loads(Path(args[3]).read_text(encoding="utf-8"))
    state.setdefault("views", {})["manifest"] = {"isDraft": False, "assets": [{"name": "manifest.json"}]}
else:
    raise SystemExit("Unexpected gh fixture call: " + repr(args))
path.write_text(json.dumps(state), encoding="utf-8")
'''

LOG_GIT = '''import json
import os
import sys

with open(os.environ["GIT_CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
os.execv(os.environ["REAL_GIT"], [os.environ["REAL_GIT"]] + sys.argv[1:])
'''


def workflow_step(filename, name):
    """Extract one known step without interpreting unrelated YAML."""
    lines = (ROOT / ".github/workflows" / filename).read_text(encoding="utf-8").splitlines()
    marker = "      - name: " + name
    if lines.count(marker) != 1:
        raise AssertionError("Expected exactly one workflow step: " + name)
    start = lines.index(marker) + 1
    end = next((index for index in range(start, len(lines))
                if lines[index].startswith("      - ")), len(lines))
    for index in range(start, end):
        if lines[index] == "        run: |":
            body = []
            for line in lines[index + 1:end]:
                if line and not line.startswith("          "):
                    break
                body.append(line)
            script = textwrap.dedent("\n".join(body)) + "\n"
            if not script.strip() or "${{" in script:
                raise AssertionError("Missing script or unresolved GitHub expression: " + name)
            return script
    raise AssertionError("No Bash run block found: " + name)


class ReleaseAutomationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="release-tests-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.repo = self.directory / "checkout"
        self.origin = self.directory / "origin.git"
        self.repo.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.state_path = self.directory / "gh-state.json"
        self.state_path.write_text("{}", encoding="utf-8")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "GH_"))}
        self.env.update({
            "HOME": str(self.directory),
            "XDG_CONFIG_HOME": str(self.directory / "config"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "REAL_GIT": shutil.which("git") or "",
            "GIT_CALLS": str(self.directory / "git-calls.jsonl"),
            "GH_CALLS": str(self.directory / "gh-calls.jsonl"),
            "GH_STATE": str(self.state_path),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "GITHUB_REPOSITORY": REPOSITORY,
            "GITHUB_REF": "refs/heads/main",
            "DEFAULT_BRANCH": "main",
            "GITHUB_OUTPUT": str(self.directory / "output"),
            "RUNNER_TEMP": str(self.directory),
            "TMPDIR": str(self.directory),
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        self.assertTrue(self.env["REAL_GIT"], "git is required for offline release tests")
        for name, code in (("gh", FAKE_GH), ("git", LOG_GIT)):
            executable = self.bin / name
            executable.write_text("#!" + sys.executable + "\n" + code, encoding="utf-8")
            executable.chmod(0o755)
        scripts = self.repo / ".github/scripts"
        scripts.mkdir(parents=True)
        for name in ("release-version.py", "generate-manifest.py"):
            shutil.copyfile(ROOT / ".github/scripts" / name, scripts / name)
        (self.repo / "metadata.lua").write_text(METADATA, encoding="utf-8")
        self.git("init", "--bare", "--quiet", str(self.origin))
        self.git("init", "--quiet")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        # Workflow steps must configure their own author identity.
        self.git("config", "user.useConfigOnly", "true")
        self.base_sha = self.commit("Initial fixture")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/main")
        self.clear_calls()

    def run_command(self, command, extra_env=None, success=True):
        result = subprocess.run(command, cwd=str(self.repo), env=dict(self.env, **(extra_env or {})),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args):
        return self.run_command([self.env["REAL_GIT"], *args]).stdout.strip()

    def commit(self, message):
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgSign=false", "commit", "--quiet", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_step(self, filename, name, extra_env=None, success=True):
        return self.run_command(["bash", "-c", workflow_step(filename, name)], extra_env, success)

    def state(self, value=None):
        if value is not None:
            self.state_path.write_text(json.dumps(value), encoding="utf-8")
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def calls(self, tool):
        path = self.directory / (tool + "-calls.jsonl")
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

    def clear_calls(self):
        for tool in ("git", "gh"):
            (self.directory / (tool + "-calls.jsonl")).write_text("", encoding="utf-8")

    def output(self):
        return dict(line.split("=", 1) for line in Path(self.env["GITHUB_OUTPUT"]).read_text(encoding="utf-8").splitlines())

    def assert_no_mutations(self):
        self.assertFalse([call for call in self.calls("git") if "push" in call])
        self.assertFalse([call for call in self.calls("gh")
                          if call[:2] in (["pr", "create"], ["pr", "edit"], ["release", "create"],
                                          ["release", "upload"], ["release", "edit"])])

    def release_branch(self, version, metadata_version=None, number=7):
        branch = "chore/release-v" + version
        self.git("switch", "--quiet", "-c", branch)
        (self.repo / "metadata.lua").write_text(METADATA.replace("0.10.2", metadata_version or version), encoding="utf-8")
        (self.repo / "manual-release-notes.txt").write_text("Maintainer edits must survive preparation.\n", encoding="utf-8")
        sha = self.commit("Manual release edits")
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/" + branch)
        self.git("switch", "--quiet", "main")
        return {"number": number, "html_url": "https://github.com/fixture/mise-php/pull/" + str(number),
                "body": "Manually revised release body.", "title": "Maintainer title",
                "head": {"ref": branch, "sha": sha, "repo": {"full_name": REPOSITORY}}}

    def remote_ref(self, ref):
        return self.git("ls-remote", "origin", ref)

    def publish_tag(self, tag, sha=None):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "tag.gpgSign=false", "tag", "-a", tag, sha or self.base_sha, "-m", tag)
        self.git("push", "--quiet", "origin", "refs/tags/" + tag)

    def test_manifest_schema_and_download_url(self):
        self.run_command([sys.executable, str(ROOT / ".github/scripts/generate-manifest.py"),
                          "--version", "0.10.2", "--tag", "v0.10.2", "--repository", REPOSITORY])
        manifest = json.loads((self.repo / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest, {
            "name": "php", "version": "0.10.2", "homepage": "https://github.com/fixture/mise-php",
            "license": "AGPL-3.0", "description": "PHP version manager", "minRuntimeVersion": "0.3.2",
            "manifestUrl": "https://github.com/fixture/mise-php/releases/download/manifest/manifest.json",
            "downloadUrl": "https://github.com/fixture/mise-php/archive/refs/tags/v0.10.2.zip",
            "notes": ["Builds PHP from source.", 'Use "quoted" options.'],
        })

    def test_manifest_metadata_mismatch_fails_without_output(self):
        result = self.run_command([sys.executable, str(ROOT / ".github/scripts/generate-manifest.py"),
                                   "--version", "2026.10.1", "--tag", "v2026.10.1", "--repository", REPOSITORY], success=False)
        self.assertIn("does not match requested version", result.stderr)
        self.assertFalse((self.repo / "manifest.json").exists())

    def test_manifest_legacy_override_does_not_allow_calver_mismatch(self):
        result = self.run_command([sys.executable, str(ROOT / ".github/scripts/generate-manifest.py"),
                                   "--version", "2026.10.1", "--tag", "v2026.10.1", "--repository", REPOSITORY,
                                   "--allow-legacy-version-mismatch"], success=False)
        self.assertIn("does not match requested version", result.stderr)
        self.assertFalse((self.repo / "manifest.json").exists())

    def test_prepare_creates_metadata_only_pr_without_default_branch_push(self):
        self.run_step("prepare-release.yml", "Find existing release PR or prepare new one")
        version = self.output()["version"]
        self.assertRegex(version, r"^[1-9][0-9]{3}\.(?:[1-9]|1[0-2])\.[1-9][0-9]*$")
        branch = "chore/release-v" + version
        self.assertEqual(self.remote_ref("refs/heads/main").split()[0], self.base_sha)
        head_sha = self.remote_ref("refs/heads/" + branch).split()[0]
        self.assertEqual(self.git("diff", "--name-only", self.base_sha, head_sha), "metadata.lua")
        self.assertEqual(self.git("show", head_sha + ":metadata.lua"), METADATA.replace("0.10.2", version).strip())
        self.assertEqual([call for call in self.calls("git") if "push" in call],
                         [["push", "origin", "HEAD:refs/heads/" + branch]])
        created = self.state()["created_pr"]
        self.assertEqual(created["--base"], "main")
        self.assertEqual(created["--head"], branch)
        self.assertEqual(self.output()["url"], "https://github.com/fixture/mise-php/pull/42")

    def test_prepare_reuses_prior_month_pr_without_changing_files_or_body(self):
        today = datetime.datetime.now(datetime.timezone.utc).date()
        prior_month = today.replace(day=1) - datetime.timedelta(days=1)
        version = "{}.{}.7".format(prior_month.year, prior_month.month)
        pull = self.release_branch(version)
        state = {"pulls": [[pull]]}
        self.state(state)
        before = self.remote_ref("refs/heads/" + pull["head"]["ref"])
        self.clear_calls()
        self.run_step("prepare-release.yml", "Find existing release PR or prepare new one")
        self.assertEqual(self.state(), state)
        self.assertEqual(self.remote_ref("refs/heads/" + pull["head"]["ref"]), before)
        self.assertEqual(self.git("show", pull["head"]["sha"] + ":manual-release-notes.txt"),
                         "Maintainer edits must survive preparation.")
        self.assertEqual(self.output(), {"url": pull["html_url"], "version": version})
        self.assert_no_mutations()

    def test_prepare_rejects_branch_metadata_mismatch(self):
        pull = self.release_branch("2026.10.1", metadata_version="2026.10.2")
        self.state({"pulls": [[pull]]})
        self.clear_calls()
        result = self.run_step("prepare-release.yml", "Find existing release PR or prepare new one", success=False)
        self.assertIn("does not match", result.stderr)
        self.assert_no_mutations()

    def test_prepare_rejects_multiple_release_prs(self):
        pulls = [self.release_branch("2026.10.1"), self.release_branch("2026.10.2", number=8)]
        self.state({"pulls": [[pulls[0]], [pulls[1]]]})
        self.clear_calls()
        result = self.run_step("prepare-release.yml", "Find existing release PR or prepare new one", success=False)
        self.assertIn("More than one", result.stderr)
        self.assert_no_mutations()

    def test_release_tag_rerun_accepts_same_sha_without_replacing_tag(self):
        tag = "v2026.10.1"
        self.publish_tag(tag)
        before = self.remote_ref("refs/tags/" + tag)
        self.clear_calls()
        for _ in range(2):
            self.run_step("release.yml", "Ensure immutable release tag points to merge commit",
                          {"TAG": tag, "MERGE_SHA": self.base_sha})
        self.assertEqual(self.remote_ref("refs/tags/" + tag), before)
        self.assert_no_mutations()

    def test_release_tag_creation_uses_local_bot_identity(self):
        tag = "v2026.10.1"
        self.run_step("release.yml", "Ensure immutable release tag points to merge commit",
                      {"TAG": tag, "MERGE_SHA": self.base_sha})

        self.assertEqual(self.git("rev-parse", tag + "^{}"), self.base_sha)
        self.assertEqual(self.git("cat-file", "-t", tag), "tag")
        calls = self.calls("git")
        self.assertIn(["config", "user.name", "github-actions[bot]"], calls)
        self.assertIn(["config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], calls)
        self.assertEqual([call for call in calls if "push" in call], [["push", "origin", "refs/tags/" + tag]])

    def test_release_tag_rejects_different_sha_without_overwrite(self):
        tag = "v2026.10.1"
        self.publish_tag(tag)
        before = self.remote_ref("refs/tags/" + tag)
        (self.repo / "later.txt").write_text("Different commit\n", encoding="utf-8")
        different_sha = self.commit("Later commit")
        self.clear_calls()
        result = self.run_step("release.yml", "Ensure immutable release tag points to merge commit",
                               {"TAG": tag, "MERGE_SHA": different_sha}, success=False)
        self.assertIn("not merged release commit", result.stderr)
        self.assertEqual(self.remote_ref("refs/tags/" + tag), before)
        self.assert_no_mutations()

    def test_cleanup_deletes_only_expected_head_and_accepts_absent_branch(self):
        pull = self.release_branch("2026.10.1")
        branch, sha = pull["head"]["ref"], pull["head"]["sha"]
        self.clear_calls()
        for _ in range(2):
            self.run_step("release.yml", "Delete merged release branch", {"BRANCH": branch, "EXPECTED_HEAD_SHA": sha})
        self.assertEqual(self.remote_ref("refs/heads/" + branch), "")
        self.assertEqual(self.remote_ref("refs/heads/main").split()[0], self.base_sha)
        self.assertEqual([call for call in self.calls("git") if "push" in call],
                         [["push", "--force-with-lease=refs/heads/{}:{}".format(branch, sha), "origin", ":refs/heads/" + branch]])

    def test_cleanup_retains_moved_head(self):
        pull = self.release_branch("2026.10.1")
        branch, sha = pull["head"]["ref"], pull["head"]["sha"]
        self.git("switch", "--quiet", branch)
        (self.repo / "later.txt").write_text("New maintainer edits\n", encoding="utf-8")
        moved_sha = self.commit("Moved release branch")
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/" + branch)
        self.clear_calls()
        self.run_step("release.yml", "Delete merged release branch", {"BRANCH": branch, "EXPECTED_HEAD_SHA": sha})
        self.assertEqual(self.remote_ref("refs/heads/" + branch).split()[0], moved_sha)
        self.assert_no_mutations()

    def shared_manifest_fixture(self):
        tags = ["v2026.9.9", "v2026.10.2", "v2026.10.10", "v2026.11.1", "v2026.12.1", "v2027.1.1", "v2027.2.1-rc.1"]
        for tag in tags:
            self.publish_tag(tag)
        releases = [{"tag_name": tag, "draft": tag == "v2026.11.1", "prerelease": tag == "v2026.12.1"}
                    for tag in tags if tag != "v2027.1.1"]
        releases.append({"tag_name": "v2028.1.1", "draft": False, "prerelease": False})
        self.state({"releases": [releases[:3], releases[3:]],
                    "views": {"manifest": {"isDraft": False, "assets": [{"name": "manifest.json"}]}},
                    "assets": {"v2026.10.2": {"version": "2026.10.2"},
                               "v2026.10.10": {"version": "2026.10.10", "name": "php"},
                               "manifest": {"version": "2026.10.2"}}})
        self.clear_calls()

    def test_shared_manifest_selects_numeric_newest_published_stable(self):
        self.shared_manifest_fixture()
        self.run_command(["bash", str(ROOT / ".github/scripts/reconcile-shared-manifest.sh")])
        self.assertEqual(self.state()["assets"]["manifest"], {"version": "2026.10.10", "name": "php"})
        self.assertEqual([call[2] for call in self.calls("gh") if call[:2] == ["release", "download"] and call[2] != "manifest"],
                         ["v2026.10.10"])
        self.assertIn(["release", "edit", "v2026.10.10", "--repo", REPOSITORY, "--latest"], self.calls("gh"))

    def test_shared_manifest_older_rerun_cannot_lower_shared_asset(self):
        self.shared_manifest_fixture()
        script = ["bash", str(ROOT / ".github/scripts/reconcile-shared-manifest.sh")]
        self.run_command(script, {"TAG": "v2026.10.10"})
        latest = self.state()["assets"]["manifest"]
        self.clear_calls()
        self.run_command(script, {"TAG": "v2026.10.2", "VERSION_INPUT": "2026.10.2"})
        self.assertEqual(self.state()["assets"]["manifest"], latest)
        self.assertEqual([call[2] for call in self.calls("gh") if call[:2] == ["release", "download"] and call[2] != "manifest"],
                         ["v2026.10.10"])

    def test_shared_manifest_rejects_mismatched_selected_asset(self):
        self.shared_manifest_fixture()
        state = self.state()
        state["assets"]["v2026.10.10"]["version"] = "2026.10.2"
        self.state(state)
        result = self.run_command(["bash", str(ROOT / ".github/scripts/reconcile-shared-manifest.sh")], success=False)
        self.assertIn("does not match release tag version", result.stderr)
        self.assert_no_mutations()

    def test_repair_cannot_create_missing_release_or_tag(self):
        for tag_exists in (False, True):
            with self.subTest(tag_exists=tag_exists):
                if tag_exists:
                    self.publish_tag("v0.10.2")
                self.clear_calls()
                result = self.run_step("publish.yaml", "Validate existing tag and release",
                                       {"VERSION_INPUT": "0.10.2", "UPDATE_MANIFEST_RELEASE_INPUT": "false"}, success=False)
                self.assertIn("recovery cannot create releases", result.stderr)
                self.assert_no_mutations()
                self.assertFalse(Path(self.env["GITHUB_OUTPUT"]).exists())

    def test_recovery_accepts_legacy_tag_with_historical_metadata_version(self):
        tag = "v0.10.0"
        (self.repo / "metadata.lua").write_text(METADATA.replace("0.10.2", "0.0.1"), encoding="utf-8")
        historical_sha = self.commit("Historical metadata version")
        self.publish_tag(tag, historical_sha)
        self.state({"views": {tag: {"isDraft": False, "isPrerelease": False}}})
        self.clear_calls()

        self.run_step("publish.yaml", "Validate existing tag and release",
                      {"VERSION_INPUT": "0.10.0", "UPDATE_MANIFEST_RELEASE_INPUT": "false"})

        manifest = json.loads((self.repo / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["version"], "0.10.0")
        self.assertEqual(manifest["downloadUrl"],
                         "https://github.com/fixture/mise-php/archive/refs/tags/v0.10.0.zip")
        self.assertEqual(self.output()["tag"], tag)
        self.assertIn(["release", "view", tag], self.calls("gh"))
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls("gh")))


if __name__ == "__main__":
    unittest.main()
