import base64
import importlib.util
import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
