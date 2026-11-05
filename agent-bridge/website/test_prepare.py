#!/usr/bin/env python3
"""Behavior checks for local and mirrored release download page generation."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("website_prepare", Path(__file__).with_name("prepare.py"))
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class DownloadPageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.joinpath("index.template.html").write_text(
            '<a href="{{MAC_PRIMARY_URL}}">下载</a><p>{{MAC_MIN_OS}} {{MAC_ARCH}} v{{MAC_VERSION}}</p>{{MAC_DOWNLOADS}}',
            encoding="utf-8",
        )
        self.config = {
            "mac": {
                "version": "0.1.3", "minimumOS": "macOS 13+",
                "packages": {arch: {"url": prepare.release_url("0.1.3", arch), "sizeBytes": 1000} for arch in prepare.ARCHITECTURES},
            },
            "ios": {"url": None},
        }

    def run_prepare(self, config=None, manifest=None):
        self.root.joinpath("downloads.json").write_text(json.dumps(config or self.config), encoding="utf-8")
        return prepare.prepare(self.root, manifest=manifest)

    def manifest(self, version="0.2.0"):
        return {
            "version": version, "notes": "新增下载加速\n修复日志问题",
            "platforms": {
                platform: {"url": prepare.release_url(version, arch, "app.tar.gz"), "signature": "fixture-signature"}
                for arch, platform in prepare.PLATFORMS.items()
            },
        }

    def test_external_dual_arch_links_work_without_js_or_local_binaries(self):
        page = self.run_prepare()
        for arch in prepare.ARCHITECTURES:
            self.assertIn('href="' + prepare.release_url("0.1.3", arch) + '"', page)
        self.assertIn('href="#download"', page)
        self.assertIn("下载 Apple 芯片版", page)
        self.assertIn("下载 Intel 版", page)
        self.assertIn("v0.1.3", page)
        self.assertNotIn("{{", page)
        self.assertFalse(self.root.joinpath("downloads").exists())

    def test_manifest_synchronizes_version_and_both_urls_without_stale_sizes(self):
        page = self.run_prepare(manifest=self.manifest())
        self.assertIn("v0.2.0", page)
        self.assertNotIn("0.1.3", page)
        self.assertNotIn(" MB", page)
        for arch in prepare.ARCHITECTURES:
            self.assertIn(prepare.release_url("0.2.0", arch), page)

    def test_manifest_preview_preserves_config_and_write_config_survives_next_default_build(self):
        self.run_prepare()
        original = self.root.joinpath("downloads.json").read_text()
        preview = prepare.prepare(self.root, manifest=self.manifest())
        self.assertEqual(self.root.joinpath("downloads.json").read_text(), original)
        saved_page = prepare.prepare(self.root, manifest=self.manifest(), write_config=True)
        self.assertEqual(saved_page, preview)
        self.assertEqual(json.loads(self.root.joinpath("downloads.json").read_text())["mac"]["version"], "0.2.0")
        self.assertEqual(prepare.prepare(self.root), saved_page)
        self.assertEqual(list(self.root.glob(".downloads.json.*")), [])
        self.assertEqual(self.root.joinpath("index.html").stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.root.joinpath("downloads.json").stat().st_mode & 0o777, 0o644)
        with self.assertRaisesRegex(ValueError, "requires --release-manifest"):
            prepare.prepare(self.root, write_config=True)

    def test_manifest_rejects_missing_platform_wrong_origin_version_or_signature(self):
        mutations = [
            lambda m: m["platforms"].pop("darwin-x86_64"),
            lambda m: m["platforms"]["darwin-aarch64"].update(url="https://github.com/installer.app.tar.gz"),
            lambda m: m.update(version="0.3.0"),
            lambda m: m["platforms"]["darwin-aarch64"].update(signature=""),
            lambda m: m.update(notes=" \n"),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                manifest = self.manifest()
                mutate(manifest)
                with self.assertRaises(ValueError):
                    self.run_prepare(manifest=manifest)
                self.assertFalse(self.root.joinpath("index.html").exists())

    def test_external_links_reject_wrong_arch_version_protocol_credentials_and_queries(self):
        original = prepare.release_url("0.1.3", "arm64")
        urls = [
            original.replace("https:", "http:"), original.replace("https://", "//"),
            original.replace("download.", "user:pass@download."), original + "?foo=1", original + "#fragment",
            original.replace("arm64", "x64"), original.replace("0.1.3", "0.1.2"),
            original.replace("download.classktv.com", "evil.example"), "javascript:alert(1)",
        ]
        for url in urls:
            with self.subTest(url=url):
                config = copy.deepcopy(self.config)
                config["mac"]["packages"]["arm64"]["url"] = url
                with self.assertRaises(ValueError):
                    self.run_prepare(config)

    def test_local_legacy_copies_real_package_and_verifies_checksum(self):
        data = b"real local package fixture"
        self.root.joinpath("package.dmg").write_bytes(data)
        config = {"mac": {"version": "0.1.3", "minimumOS": "macOS 13+", "architecture": "Apple Silicon", "source": "package.dmg", "url": "downloads/local.dmg"}, "ios": {"url": None}}
        page = self.run_prepare(config)
        self.assertEqual(self.root.joinpath("downloads/local.dmg").read_bytes(), data)
        self.assertIn('href="downloads/local.dmg" download', page)
        self.assertIn("Apple Silicon", page)
        config["mac"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.run_prepare(config)

    def test_local_path_traversal_encoded_path_and_symlink_are_rejected(self):
        self.root.joinpath("package.dmg").write_bytes(b"fixture")
        config = {"mac": {"version": "0.1.3", "minimumOS": "macOS 13+", "source": "package.dmg", "url": "downloads/local.dmg"}, "ios": {"url": None}}
        for url in ["../outside.dmg", "downloads/../../outside.dmg", "downloads/%2e%2e/outside.dmg", "downloads/../outside.dmg", "downloads/file.html", "downloads/file.dmg?x=1", "downloads/..\\outside.dmg"]:
            config["mac"]["url"] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.run_prepare(config)
        self.root.joinpath("downloads").symlink_to(self.root.parent, target_is_directory=True)
        config["mac"]["url"] = "downloads/local.dmg"
        with self.assertRaises(ValueError):
            self.run_prepare(config)

    def test_missing_source_ios_distribution_and_missing_arch_fail(self):
        configs = []
        config = copy.deepcopy(self.config)
        config["ios"]["url"] = "https://example.org/ios"
        configs.append(config)
        config = copy.deepcopy(self.config)
        config["mac"]["packages"].pop("x64")
        configs.append(config)
        configs.append({"mac": {"version": "0.1.3", "minimumOS": "macOS 13+", "url": "downloads/a.dmg", "source": "missing.dmg"}, "ios": {"url": None}})
        for config in configs:
            with self.assertRaises(ValueError):
                self.run_prepare(config)

    def test_unresolved_template_fails_before_copy_or_output(self):
        self.root.joinpath("index.template.html").write_text("{{UNKNOWN}}")
        self.root.joinpath("package.dmg").write_bytes(b"fixture")
        config = {"mac": {"version": "0.1.3", "minimumOS": "macOS 13+", "url": "downloads/a.dmg", "source": "package.dmg"}, "ios": {"url": None}}
        with self.assertRaisesRegex(ValueError, "Unresolved"):
            self.run_prepare(config)
        self.assertFalse(self.root.joinpath("downloads").exists())
        self.assertFalse(self.root.joinpath("index.html").exists())


if __name__ == "__main__":
    unittest.main()
