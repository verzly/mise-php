import datetime
import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release-version.py")
SPEC = importlib.util.spec_from_file_location("release_version", SCRIPT)
release_version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_version)


class ParseCalverTests(unittest.TestCase):
    def test_parses_canonical_version(self):
        self.assertEqual(release_version.parse_calver("2026.10.12"), (2026, 10, 12))

    def test_rejects_invalid_versions(self):
        for version in (
            "0200.1.1",
            "0000.1.1",
            "v2026.1.1",
            "2026.0.1",
            "2026.13.1",
            "2026.1.0",
            "2026.1.01",
            "2026.01.1",
            "2026.1.1-rc1",
            "2026.1.1-beta",
        ):
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    release_version.parse_calver(version)


class NextVersionTests(unittest.TestCase):
    def test_first_version_ignores_legacy_tags(self):
        self.assertEqual(
            release_version.next_version(
                ["v0.10.2", "0.11.0", "v2025.12.3"],
                "0.10.2",
                datetime.date(2026, 1, 2),
            ),
            "2026.1.1",
        )

    def test_uses_numeric_maximum_in_same_month(self):
        self.assertEqual(
            release_version.next_version(
                ["v2026.4.9", "v2026.4.10"], "0.10.2", datetime.date(2026, 4, 1)
            ),
            "2026.4.11",
        )

    def test_month_and_year_rollover_start_at_one(self):
        self.assertEqual(
            release_version.next_version(
                ["v2026.3.8"], "2026.3.9", datetime.date(2026, 4, 1)
            ),
            "2026.4.1",
        )
        self.assertEqual(
            release_version.next_version(
                ["v2026.12.8"], "2026.12.9", datetime.date(2027, 1, 1)
            ),
            "2027.1.1",
        )

    def test_metadata_reserves_same_month_version(self):
        self.assertEqual(
            release_version.next_version(
                [], "2026.4.3", datetime.date(2026, 4, 20)
            ),
            "2026.4.4",
        )

    def test_ignores_prerelease_and_channel_tags(self):
        self.assertEqual(
            release_version.next_version(
                [
                    "v2026.4.2-rc1",
                    "v2026.4.8-beta",
                    "latest",
                    "stable",
                    "v2026.4",
                    "v2026.4.0",
                ],
                "0.10.2",
                datetime.date(2026, 4, 1),
            ),
            "2026.4.1",
        )

    def test_rejects_calendar_rollback_before_future_calver(self):
        with self.assertRaisesRegex(ValueError, "2026.7"):
            release_version.next_version(
                ["v2026.7.1"], "0.10.2", datetime.date(2026, 6, 30)
            )
        with self.assertRaisesRegex(ValueError, "2026.7"):
            release_version.next_version(
                [], "2026.7.1", datetime.date(2026, 6, 30)
            )


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.metadata = Path(self.directory.name) / "metadata.lua"

    def tearDown(self):
        self.directory.cleanup()

    def write_metadata(self, content):
        self.metadata.write_text(content, encoding="utf-8")

    def test_missing_and_duplicate_assignments_fail(self):
        self.write_metadata('PLUGIN.name = "php"\n')
        with self.assertRaisesRegex(ValueError, "exactly one"):
            release_version._prepare_metadata(self.metadata, "2026.4.1", [])

        self.write_metadata(
            'PLUGIN.version = "0.10.2"\nPLUGIN.version = "0.10.3"\n'
        )
        with self.assertRaisesRegex(ValueError, "exactly one"):
            release_version._validate_metadata(self.metadata, "2026.4.1")

    def test_prepare_updates_only_version_assignment(self):
        original = (
            'PLUGIN.name = "php"\n'
            'PLUGIN.version = "0.10.2"\n'
            'PLUGIN.description = "0.10.2"\n'
        )
        self.write_metadata(original)
        release_version._prepare_metadata(
            self.metadata, "2026.4.1", ["v2026.3.2"]
        )
        self.assertEqual(
            self.metadata.read_text(encoding="utf-8"),
            original.replace('PLUGIN.version = "0.10.2"', 'PLUGIN.version = "2026.4.1"'),
        )
        release_version._validate_metadata(self.metadata, "2026.4.1")
        with self.assertRaisesRegex(ValueError, "does not match"):
            release_version._validate_metadata(self.metadata, "2026.4.2")

    def test_prepare_rejects_earlier_calendar_period(self):
        self.write_metadata('PLUGIN.version = "0.10.2"\n')
        with self.assertRaisesRegex(ValueError, "2026.7"):
            release_version._prepare_metadata(
                self.metadata, "2026.6.3", ["v2026.7.1"]
            )
        self.assertEqual(
            self.metadata.read_text(encoding="utf-8"), 'PLUGIN.version = "0.10.2"\n'
        )


if __name__ == "__main__":
    unittest.main()
