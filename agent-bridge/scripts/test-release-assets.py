import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_assets", Path(__file__).with_name("release-assets.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        for arch in release.ARCHITECTURES:
            (self.directory / f"build-{arch}.json").write_text(json.dumps({"version": "1.2.3", "arch": arch}))
            for suffix in (".dmg", ".app.tar.gz"):
                (self.directory / f"ArcLink-macos-{arch}{suffix}").write_bytes(b"fixture")
            (self.directory / f"ArcLink-macos-{arch}.app.tar.gz.sig").write_text(base64.b64encode(b"signature fixture").decode())

    def test_complete_manifest_has_versioned_architecture_urls_and_checksums(self):
        manifest = release.assemble(self.directory, "1.2.3", "example/releases")
        self.assertEqual(set(manifest["platforms"]), {"darwin-aarch64", "darwin-x86_64"})
        self.assertEqual(manifest["platforms"]["darwin-aarch64"]["url"], "https://github.com/example/releases/releases/download/arclink-v1.2.3/ArcLink-macos-arm64.app.tar.gz")
        self.assertEqual(len((self.directory / "SHA256SUMS.txt").read_text().splitlines()), 7)
        self.assertNotIn("build-", (self.directory / "SHA256SUMS.txt").read_text())

    def test_missing_architecture_cannot_publish_manifest(self):
        (self.directory / "ArcLink-macos-x64.app.tar.gz").unlink()
        with self.assertRaises(FileNotFoundError):
            release.assemble(self.directory, "1.2.3", "example/releases")
        self.assertFalse((self.directory / "latest.json").exists())

    def test_mixed_versions_are_rejected(self):
        (self.directory / "build-x64.json").write_text('{"version":"1.2.2","arch":"x64"}')
        with self.assertRaises(ValueError):
            release.assemble(self.directory, "1.2.3", "example/releases")

    def test_invalid_signature_is_rejected(self):
        (self.directory / "ArcLink-macos-arm64.app.tar.gz.sig").write_text("invalid signature!")
        with self.assertRaises(ValueError):
            release.assemble(self.directory, "1.2.3", "example/releases")

    def test_repository_and_version_injection_are_rejected(self):
        for repository in ("https://github.com/o/r", "o/r?token=secret", "../r", "o/r/extra"):
            with self.assertRaises(ValueError):
                release.assemble(self.directory, "1.2.3", repository)
        with self.assertRaises(ValueError):
            release.assemble(self.directory, "1.2.3/../bad", "o/r")

    def test_manifest_preserves_exact_multiline_chinese_release_notes(self):
        notes = "## 本次更新\n\n- 新增保持电脑活跃开关，允许正常熄屏和锁屏。\n- 支持日志查看、复制与导出。\n"
        notes_file = self.directory / "notes.md"
        notes_file.write_text(notes, encoding="utf-8")
        manifest = release.assemble(self.directory, "1.2.3", "example/releases", notes_file)
        self.assertEqual(manifest["notes"], notes)
        self.assertEqual(json.loads((self.directory / "latest.json").read_text(encoding="utf-8"))["notes"], notes)

    def test_explicit_missing_or_blank_notes_fail_before_manifest_is_written(self):
        notes_file = self.directory / "missing.md"
        with self.assertRaises(FileNotFoundError):
            release.assemble(self.directory, "1.2.3", "example/releases", notes_file)
        for text in ("", " \n\t\n"):
            with self.subTest(text=text):
                notes_file.write_text(text, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "Release notes must not be empty"):
                    release.assemble(self.directory, "1.2.3", "example/releases", notes_file)
                self.assertFalse((self.directory / "latest.json").exists())
                self.assertFalse((self.directory / "SHA256SUMS.txt").exists())

    def run_assemble_cli(self, *notes_args):
        return subprocess.run([
            sys.executable, str(Path(release.__file__)), "assemble",
            "--directory", str(self.directory), "--version", "1.2.3",
            "--repository", "example/releases", *notes_args,
        ], capture_output=True, text=True)

    def test_cli_requires_a_nonempty_notes_file(self):
        missing_argument = self.run_assemble_cli()
        self.assertNotEqual(missing_argument.returncode, 0)
        self.assertIn("--notes-file", missing_argument.stderr)
        missing_file = self.run_assemble_cli("--notes-file", str(self.directory / "missing.md"))
        self.assertNotEqual(missing_file.returncode, 0)
        notes_file = self.directory / "empty.md"
        for text in ("", " \n\t\n"):
            with self.subTest(text=text):
                notes_file.write_text(text, encoding="utf-8")
                empty_file = self.run_assemble_cli("--notes-file", str(notes_file))
                self.assertNotEqual(empty_file.returncode, 0)
                self.assertIn("Release notes must not be empty", empty_file.stderr)
        self.assertFalse((self.directory / "latest.json").exists())
        self.assertFalse((self.directory / "SHA256SUMS.txt").exists())

    def test_cli_embeds_supplied_notes_in_the_published_manifest(self):
        notes = "## 功能更新\n\n保持电脑活跃；优化日志获取。\n\n允许熄屏和锁屏。\n"
        notes_file = self.directory / "notes.md"
        notes_file.write_text(notes, encoding="utf-8")
        result = self.run_assemble_cli("--notes-file", str(notes_file))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.directory / "latest.json").read_text(encoding="utf-8"))["notes"], notes)


class PrepareAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.output = self.root / "output"
        (self.bundle / "macos").mkdir(parents=True)
        (self.bundle / "dmg").mkdir()
        (self.bundle / "dmg/ArcLink_1.2.3_aarch64.dmg").write_bytes(b"installer")
        (self.bundle / "macos/ArcLink.app.tar.gz").write_bytes(b"archive")
        self.signature = self.bundle / "macos/ArcLink.app.tar.gz.sig"
        self.signature.write_text(base64.b64encode(b"signature fixture").decode())

    def test_prepare_renames_signed_archive_and_keeps_matching_metadata(self):
        release.prepare(self.bundle, self.output, "arm64", "1.2.3")
        self.assertEqual((self.output / "ArcLink-macos-arm64.app.tar.gz").read_bytes(), b"archive")
        self.assertEqual((self.output / "ArcLink-macos-arm64.app.tar.gz.sig").read_text(), self.signature.read_text())
        self.assertEqual(json.loads((self.output / "build-arm64.json").read_text()), {"version": "1.2.3", "arch": "arm64"})

    def test_prepare_rejects_empty_signature_before_staging_any_artifacts(self):
        self.signature.write_text("\n")
        with self.assertRaisesRegex(ValueError, "Empty signature"):
            release.prepare(self.bundle, self.output, "arm64", "1.2.3")
        self.assertFalse(self.output.exists())

    def test_prepare_rejects_ambiguous_build_output(self):
        (self.bundle / "macos/Old.app.tar.gz").write_bytes(b"old archive")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            release.prepare(self.bundle, self.output, "arm64", "1.2.3")
        self.assertFalse(self.output.exists())


class MirrorAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        for arch in release.ARCHITECTURES:
            (self.directory / f"build-{arch}.json").write_text(json.dumps({"version": "1.2.3", "arch": arch}))
            for suffix in (".dmg", ".app.tar.gz"):
                (self.directory / f"ArcLink-macos-{arch}{suffix}").write_bytes(b"fixture")
            (self.directory / f"ArcLink-macos-{arch}.app.tar.gz.sig").write_text(base64.b64encode(b"signature fixture").decode())
        notes = self.directory / "notes.md"
        notes.write_text("## 更新\n\n- 优化日志。\n", encoding="utf-8")
        self.original = release.assemble(self.directory, "1.2.3", "example/releases", notes)
        self.output = self.directory / "mirror"

    def test_mirror_is_deterministic_and_preserves_original_bytes_and_metadata(self):
        before = {name: (self.directory / name).read_bytes() for name in release.asset_names() + ["latest.json", "SHA256SUMS.txt"]}
        manifest = release.mirror(self.directory, self.output, "1.2.3", "example/releases", "https://download.example.com")
        self.assertEqual(manifest["pub_date"], self.original["pub_date"])
        self.assertEqual(manifest["notes"], self.original["notes"])
        for arch, platform in release.ARCHITECTURES.items():
            self.assertEqual(manifest["platforms"][platform]["signature"], self.original["platforms"][platform]["signature"])
            self.assertEqual(manifest["platforms"][platform]["url"], f"https://download.example.com/releases/arclink-v1.2.3/ArcLink-macos-{arch}.app.tar.gz")
        for name, value in before.items():
            self.assertEqual((self.directory / name).read_bytes(), value)
            if name.startswith("ArcLink-"):
                self.assertEqual((self.output / name).read_bytes(), value)
        first = (self.output / "latest.json").read_bytes()
        release.mirror(self.directory, self.output, "1.2.3", "example/releases", "https://download.example.com/")
        self.assertEqual((self.output / "latest.json").read_bytes(), first)
        release.read_checksums(self.output)

    def test_corrupt_missing_or_incomplete_source_is_rejected_before_staging(self):
        (self.directory / "ArcLink-macos-x64.dmg").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            release.mirror(self.directory, self.output, "1.2.3", "example/releases", "https://download.example.com")
        self.assertFalse(self.output.exists())

    def test_source_url_signature_and_version_are_validated(self):
        for mutate in [lambda m: m.update(version="1.2.2"),
                       lambda m: m["platforms"]["darwin-aarch64"].update(url="https://evil.example/file"),
                       lambda m: m["platforms"]["darwin-aarch64"].update(signature="Zm9v")]:
            manifest = json.loads(json.dumps(self.original))
            mutate(manifest)
            release.write_manifest(self.directory, manifest)
            with self.assertRaises(ValueError):
                release.mirror(self.directory, self.output, "1.2.3", "example/releases", "https://download.example.com")
            self.assertFalse(self.output.exists())

    def test_unsafe_public_origin_and_output_are_rejected(self):
        for origin in ("http://download.example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?key=bad", "https://example.com#bad", "https://example.com:443"):
            with self.assertRaises(ValueError):
                release.mirror(self.directory, self.output, "1.2.3", "example/releases", origin)
        with self.assertRaisesRegex(ValueError, "must differ"):
            release.mirror(self.directory, self.directory, "1.2.3", "example/releases", "https://download.example.com")


if __name__ == "__main__":
    unittest.main()
