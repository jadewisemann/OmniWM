import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock
import zipfile


SOURCE = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("omniwm_release", SOURCE / "Scripts/omniwm_release.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omniwm-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.version = "0.7.4"
        self.commit = "a" * 40
        self.original = "b" * 40
        self.head = self.commit
        self.remote_main = self.original
        self.remote_tag = None
        self.release = None
        self.download_error = False
        self.download_corrupt = False
        self.commands = []
        self.runner = Mock()
        self.runner.run.side_effect = self.run_command
        self.manager = RELEASE.ReleaseManager(RELEASE.Config(self.root, "OmniNull/OmniWM"), self.runner)
        self.manager.git = Mock(side_effect=self.git)
        self.manager.fetch = Mock()
        self.manager.verify_destinations = Mock()
        self.manager.verify_app_zip = Mock()
        self.manager.repo_state = Mock(return_value=RELEASE.RepoState("main", True, "", 1, 0, self.commit))
        self.manager.remote_tag_commit = Mock(side_effect=lambda tag: self.remote_tag)
        self.manager.local_tag_commit = Mock(return_value=self.commit)
        self.manager.github_release = Mock(side_effect=lambda tag: self.release)
        self.manager.latest_github_release_tag = Mock(return_value=self.manager.tag(self.version))
        scripts = self.root / "Scripts"
        scripts.mkdir()
        (scripts / "ghostty-preflight.sh").write_text("#!/bin/bash\nexit 0\n")
        self.framework = self.root / "Frameworks/GhosttyKit.xcframework"
        (self.framework / "macos-arm64/Headers").mkdir(parents=True)
        (self.framework / "Info.plist").write_text("framework metadata")
        (self.framework / "macos-arm64/Headers/ghostty.h").write_text("header")
        archive = self.framework / "macos-arm64/libghostty-internal.a"
        archive.write_bytes(b"library")
        self.paths = self.manager.asset_paths(self.version)
        self.paths["ghostty"].parent.mkdir()
        with zipfile.ZipFile(self.paths["ghostty"], "w") as zipped:
            for path in self.framework.rglob("*"):
                if path.is_file():
                    zipped.write(path, path.relative_to(self.framework.parent))
        self.zip_sha = RELEASE.sha256_file(self.paths["ghostty"])
        (scripts / "dev-tools.env").write_text(
            f"OMNIWM_GHOSTTY_DOWNLOAD_URL={self.manager.ghostty_release_url(self.version)}\n"
            f"OMNIWM_GHOSTTY_ZIP_SHA256={self.zip_sha}\n"
        )
        (scripts / "build-metadata.env").write_text(
            "OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH=Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a\n"
            f"OMNIWM_GHOSTTY_ARCHIVE_SHA256={RELEASE.sha256_file(archive)}\n"
        )
        self.paths["app"].write_bytes(b"signed app fixture")
        self.paths["notes"].write_text("release notes\n")
        self.manifest = {
            "schema": RELEASE.MANIFEST_SCHEMA,
            "version": self.version,
            "tag": self.manager.tag(self.version),
            "previous_tag": "v0.7.3",
            "previous_version": "0.7.3",
            "build": 86,
            "state": "sealed",
            "sealed": True,
            "original_main_head": self.original,
            "release_commit": self.commit,
            "embedded_git_hash": self.commit[:8],
            "signing_identity": RELEASE.SIGNING_IDENTITY,
            "notarize_profile": RELEASE.NOTARIZE_PROFILE,
            "notarization": {"status": "verified", "stapled": True},
            "destinations": {"main_remote": "https://github.com/OmniNull/OmniWM.git", "github_repo": "OmniNull/OmniWM"},
            "assets": {
                name: {"path": str(self.paths[name]), "sha256": RELEASE.sha256_file(self.paths[name])}
                for name in ("app", "ghostty")
            },
            "notes_sha256": RELEASE.sha256_file(self.paths["notes"]),
            "published": {stage: False for stage in RELEASE.PUBLIC_STAGES},
            "release_url": None,
        }
        self.manager.save_manifest(self.manifest)

    def git(self, repo, *args, **kwargs):
        if args == ("rev-parse", "HEAD"):
            return self.head
        if args == ("rev-parse", "origin/main"):
            return self.remote_main
        if args == ("rev-parse", "--short", self.commit):
            return self.commit[:8]
        if args == ("branch", "--show-current"):
            return "main"
        if args == ("status", "--porcelain=v1"):
            return ""
        raise AssertionError(args)

    def run_command(self, args, **kwargs):
        command = [str(arg) for arg in args]
        self.commands.append(command)
        code = 0
        if command[0] == "curl":
            if self.download_error:
                raise RELEASE.ReleaseError("public dependency download failed: HTTP 404")
            destination = Path(command[command.index("--output") + 1])
            if self.download_corrupt:
                destination.write_bytes(b"wrong public dependency")
            else:
                shutil.copy2(self.paths["ghostty"], destination)
        elif command[:3] == ["ditto", "-x", "-k"]:
            with zipfile.ZipFile(command[3]) as zipped:
                zipped.extractall(command[4])
        elif command[:3] == ["gh", "release", "create"]:
            self.release = {
                "tagName": self.manifest["tag"],
                "name": f"OmniWM v{self.version}",
                "body": self.paths["notes"].read_text(),
                "url": f"https://github.com/OmniNull/OmniWM/releases/tag/{self.manifest['tag']}",
                "isDraft": False,
                "isPrerelease": False,
                "assets": [{"name": self.paths[name].name} for name in ("app", "ghostty")],
            }
        elif command[:3] == ["gh", "release", "download"]:
            destination = Path(command[command.index("--dir") + 1])
            for name in ("app", "ghostty"):
                shutil.copy2(self.paths[name], destination / self.paths[name].name)
        elif command[:3] == ["git", "push", "origin"]:
            if command[3] == "main":
                self.remote_main = self.commit
            else:
                self.remote_tag = self.commit
        elif command[:3] == ["git", "merge-base", "--is-ancestor"]:
            code = 0 if command[3] == self.remote_main else 1
        return subprocess.CompletedProcess(command, code, "", "")

    def command_index(self, prefix):
        return next(index for index, command in enumerate(self.commands) if command[:len(prefix)] == prefix)

    def test_publish_downloads_pinned_asset_before_main(self):
        self.manager.publish(self.version, True)
        tag = self.command_index(["git", "push", "origin", self.manifest["tag"]])
        release = self.command_index(["gh", "release", "create"])
        download = self.command_index(["curl"])
        main = self.command_index(["git", "push", "origin", "main"])
        self.assertLess(tag, release)
        self.assertLess(release, download)
        self.assertLess(download, main)
        self.assertEqual(self.commands[download][-1], self.manager.ghostty_release_url(self.version))
        self.assertEqual(self.commands[download][1], "--disable")
        final = self.manager.load_manifest(self.version)
        self.assertEqual(final["state"], "published")
        self.assertTrue(all(final["published"].values()))

    def test_public_download_failure_is_resumable_without_main_push(self):
        self.download_error = True
        with self.assertRaisesRegex(RELEASE.ReleaseError, "HTTP 404"):
            self.manager.publish(self.version, True)
        checkpoint = self.manager.load_manifest(self.version)
        self.assertEqual(checkpoint["state"], "published-release")
        self.assertEqual(checkpoint["published"], {"tag": True, "release": True, "main": False})
        self.assertEqual(self.remote_main, self.original)
        self.download_error = False
        self.manager.publish(self.version, True)
        self.assertEqual(self.remote_main, self.commit)
        self.assertEqual(sum(command[:3] == ["gh", "release", "create"] for command in self.commands), 1)

    def test_public_download_hash_mismatch_never_pushes_main(self):
        self.download_corrupt = True
        with self.assertRaisesRegex(RELEASE.ReleaseError, "ZIP hash mismatch"):
            self.manager.publish(self.version, True)
        self.assertEqual(self.remote_main, self.original)
        self.assertFalse(self.manager.load_manifest(self.version)["published"]["main"])

    def test_resume_after_tag_revalidates_release_and_dependency(self):
        self.remote_tag = self.commit
        self.manifest["published"]["tag"] = True
        self.manifest["state"] = "published-tag"
        self.manager.save_manifest(self.manifest)
        self.manager.publish(self.version, True)
        self.assertNotIn(["git", "push", "origin", self.manifest["tag"]], self.commands)
        self.assertLess(self.command_index(["curl"]), self.command_index(["git", "push", "origin", "main"]))

    def test_package_reuses_exact_pinned_zip(self):
        self.manager.create_zip = Mock(side_effect=AssertionError("must not repack"))
        self.manager.package_ghostty(self.version)
        self.assertEqual(RELEASE.sha256_file(self.paths["ghostty"]), self.zip_sha)
        self.assertFalse(any(command[0] == "curl" for command in self.commands))

    def test_candidate_zip_hash_drift_is_rejected_before_publication(self):
        with self.paths["ghostty"].open("ab") as archive:
            archive.write(b"changed")
        with self.assertRaisesRegex(RELEASE.ReleaseError, "ZIP hash mismatch"):
            self.manager.package_ghostty(self.version)
        self.assertIsNone(self.remote_tag)
        self.assertIsNone(self.release)

    def test_complete_framework_comparison_includes_headers(self):
        (self.framework / "macos-arm64/Headers/ghostty.h").write_text("different header")
        with self.assertRaisesRegex(RELEASE.ReleaseError, "contents differ"):
            self.manager.verify_ghostty_dependency(self.version)

    def test_existing_dependency_pin_uses_public_download(self):
        pins = self.root / "Scripts/dev-tools.env"
        url = self.manager.ghostty_release_url("0.7.3")
        pins.write_text(pins.read_text().replace(self.manager.ghostty_release_url(self.version), url))
        self.assertEqual(self.manager.verify_ghostty_dependency(self.version), url)
        self.assertEqual(self.commands[self.command_index(["curl"])][-1], url)

    def test_dirty_pins_cannot_replace_frozen_metadata(self):
        self.manager.git = Mock(return_value=" M Scripts/dev-tools.env")
        with self.assertRaisesRegex(RELEASE.ReleaseError, "frozen commit"):
            self.manager.verify_manifest(self.manifest, False)

    def test_abort_refuses_observed_public_stage_with_stale_flags(self):
        self.remote_tag = self.commit
        with self.assertRaisesRegex(RELEASE.ReleaseError, "any public stage"):
            self.manager.abort(self.version)
        self.assertTrue(self.paths["ghostty"].exists())
        self.assertTrue(self.manager.manifest_path(self.version).exists())

    def test_local_abort_preserves_pinned_dependency_for_retry(self):
        self.manager.abort(self.version)
        self.assertEqual(RELEASE.sha256_file(self.paths["ghostty"]), self.zip_sha)
        self.assertFalse(self.paths["app"].exists())
        self.assertFalse(self.manager.manifest_path(self.version).exists())

    def test_schema_three_history_retains_previous_stage_order(self):
        self.manifest["schema"] = 3
        self.manifest["state"] = "published"
        self.manifest["published"] = {"main": True, "tag": True, "release": True}
        self.manifest["release_url"] = "https://github.com/OmniNull/OmniWM/releases/tag/v0.7.4"
        self.manager.manifest_path(self.version).write_text(json.dumps(self.manifest))
        self.assertEqual(RELEASE.manifest_stages(self.manifest), ("main", "tag", "release"))
        self.assertTrue(self.manager.status(self.version))
        self.manager.fetch.assert_not_called()
        with self.assertRaisesRegex(RELEASE.ReleaseError, "historical manifests are read-only"):
            self.manager.publish(self.version, True)


if __name__ == "__main__":
    unittest.main()
