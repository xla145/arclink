import base64
import hashlib
import importlib.util
from io import BytesIO
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import urlsplit

spec = importlib.util.spec_from_file_location("r2_release", Path(__file__).with_name("r2-release.py"))
r2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2)


class S3Error(Exception):
    def __init__(self, code):
        self.response = {"Error": {"Code": code}}


class FakeS3:
    def __init__(self):
        self.objects = {}
        self.puts = []
        self.fail_key = None
        self.on_put = None

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise S3Error("NoSuchKey")
        body = self.objects[Key]
        return {"Body": BytesIO(body), "ETag": '"' + hashlib.md5(body).hexdigest() + '"'}

    def put_object(self, **arguments):
        key = arguments["Key"]
        if self.on_put:
            self.on_put(arguments)
        if key == self.fail_key:
            raise S3Error("AccessDenied")
        if arguments.get("IfNoneMatch") == "*" and key in self.objects:
            raise S3Error("PreconditionFailed")
        if "IfMatch" in arguments:
            current = self.get_object(arguments["Bucket"], key)
            if current["ETag"] != arguments["IfMatch"]:
                raise S3Error("PreconditionFailed")
        self.objects[key] = bytes(arguments["Body"])
        self.puts.append(arguments)


class MirrorPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        for arch in r2.release.ARCHITECTURES:
            (self.directory / f"build-{arch}.json").write_text(json.dumps({"version": "1.2.3", "arch": arch}))
            for suffix in (".dmg", ".app.tar.gz"):
                (self.directory / f"ArcLink-macos-{arch}{suffix}").write_bytes((arch + suffix).encode())
            (self.directory / f"ArcLink-macos-{arch}.app.tar.gz.sig").write_text(base64.b64encode(b"fixture").decode())
        notes = self.directory / "notes.md"
        notes.write_text("## 更新\n\n- 优化下载。\n", encoding="utf-8")
        r2.release.assemble(self.directory, "1.2.3", "example/repo", notes)
        self.client = FakeS3()
        self.verified = []

    def verify(self, url, expected_digest):
        key = urlsplit(url).path.lstrip("/")
        self.assertIn(key, self.client.objects)
        self.assertEqual(r2.digest(self.client.objects[key]), expected_digest)
        self.verified.append(key)

    def publish(self, verifier=None):
        return r2.publish(self.client, "oss", self.directory, "1.2.3", "example/repo", "https://download.example.com", verifier or self.verify)

    def test_complete_public_verification_precedes_latest_and_retry_is_idempotent(self):
        def verify(url, digest):
            if urlsplit(url).path != "/latest.json":
                self.assertNotIn("latest.json", self.client.objects)
            self.verify(url, digest)
        report = self.publish(verify)
        self.assertEqual(len(self.client.puts), 9)
        self.assertEqual(len(self.verified), 9)
        self.assertTrue(report["latest_promoted"])
        self.assertFalse(report["cryptographic_signature_verified"])
        self.assertEqual(self.client.puts[-1]["Key"], "latest.json")
        self.assertEqual(self.client.puts[-1]["CacheControl"], r2.LATEST_CACHE)
        for item in self.client.puts[:-1]:
            self.assertEqual(item["CacheControl"], r2.IMMUTABLE_CACHE)
            self.assertEqual(item["IfNoneMatch"], "*")
        self.assertEqual(self.client.puts[0]["ContentType"], "application/x-apple-diskimage")
        report = self.publish()
        self.assertEqual(report["uploaded_objects"], 0)
        self.assertFalse(report["latest_promoted"])
        self.assertEqual(len(self.client.puts), 9)

    def test_upload_failure_preserves_previous_latest(self):
        previous = b'{"version":"1.2.2"}'
        self.client.objects["latest.json"] = previous
        self.client.fail_key = "releases/arclink-v1.2.3/ArcLink-macos-x64.app.tar.gz"
        with self.assertRaises(S3Error):
            self.publish()
        self.assertEqual(self.client.objects["latest.json"], previous)
        self.assertFalse(self.verified)

    def test_public_verification_failure_preserves_previous_latest(self):
        previous = b'{"version":"1.2.2"}'
        self.client.objects["latest.json"] = previous
        def fail(url, digest):
            raise r2.MirrorError("Public file differs")
        with self.assertRaisesRegex(r2.MirrorError, "Public file differs"):
            self.publish(fail)
        self.assertEqual(self.client.objects["latest.json"], previous)

    def test_incomplete_upload_retries_identical_objects_and_finishes_without_rewriting(self):
        previous = b'{"version":"1.2.2"}'
        self.client.objects["latest.json"] = previous
        self.client.fail_key = "releases/arclink-v1.2.3/ArcLink-macos-x64.app.tar.gz"
        with self.assertRaises(S3Error):
            self.publish()
        completed = list(self.client.puts)
        self.client.fail_key = None
        self.publish()
        for item in completed:
            self.assertEqual(sum(p["Key"] == item["Key"] for p in self.client.puts), 1)
        self.assertEqual(json.loads(self.client.objects["latest.json"])["version"], "1.2.3")

    def test_create_precondition_refuses_a_concurrent_different_immutable_object(self):
        key = "releases/arclink-v1.2.3/ArcLink-macos-arm64.dmg"
        def race(arguments):
            if arguments["Key"] == key:
                self.client.objects[key] = b"concurrent different bytes"
        self.client.on_put = race
        with self.assertRaisesRegex(r2.MirrorError, "Concurrent immutable R2 object differs"):
            self.publish()
        self.assertEqual(self.client.objects[key], b"concurrent different bytes")
        self.assertNotIn("latest.json", self.client.objects)

    def test_existing_different_object_is_never_overwritten(self):
        key = "releases/arclink-v1.2.3/ArcLink-macos-arm64.dmg"
        self.client.objects[key] = b"different"
        with self.assertRaisesRegex(r2.MirrorError, "Immutable R2 object differs"):
            self.publish()
        self.assertEqual(self.client.objects[key], b"different")
        self.assertFalse(self.client.puts)

    def test_stale_same_version_conflict_and_invalid_latest_are_rejected_before_writes(self):
        for previous in (b'{"version":"1.2.4"}', b'{"version":"1.2.3"}', b"broken"):
            with self.subTest(previous=previous):
                self.client.objects["latest.json"] = previous
                with self.assertRaises(r2.MirrorError):
                    self.publish()
                self.assertFalse(self.client.puts)
                self.assertEqual(self.client.objects["latest.json"], previous)

    def test_latest_advancing_during_public_validation_cannot_be_downgraded(self):
        previous = b'{"version":"1.2.4"}'
        def advance(url, digest):
            self.verify(url, digest)
            self.client.objects["latest.json"] = previous
        with self.assertRaisesRegex(r2.MirrorError, "backwards"):
            self.publish(advance)
        self.assertEqual(self.client.objects["latest.json"], previous)

    def test_latest_cas_closes_race_after_final_read(self):
        self.client.objects["latest.json"] = b'{"version":"1.2.2"}'
        def race(arguments):
            if arguments["Key"] == "latest.json":
                self.client.objects["latest.json"] = b'{"version":"1.2.4"}'
        self.client.on_put = race
        with self.assertRaisesRegex(r2.MirrorError, "changed concurrently"):
            self.publish()
        self.assertEqual(self.client.objects["latest.json"], b'{"version":"1.2.4"}')

    def test_missing_source_asset_never_writes(self):
        (self.directory / "ArcLink-macos-x64.dmg").unlink()
        with self.assertRaises(ValueError):
            self.publish()
        self.assertFalse(self.client.puts)

    def test_non_not_found_s3_errors_are_not_treated_as_empty_bucket(self):
        class Denied:
            def get_object(self, **arguments):
                raise S3Error("AccessDenied")
        with self.assertRaises(S3Error):
            r2.object_bytes(Denied(), "oss", "latest.json")


class PublicVerificationTests(unittest.TestCase):
    def test_streaming_response_is_verified(self):
        class Response(BytesIO):
            status = 200
            def geturl(self):
                return "https://download.example.com/test"
        r2.verify_public("https://download.example.com/test", r2.digest(b"fixture"), opener=lambda *a, **k: Response(b"fixture"))

    def test_corrupt_public_bytes_retry_is_bounded(self):
        calls, sleeps = [], []
        class Response(BytesIO):
            status = 200
            def geturl(self):
                return "https://download.example.com/test"
        def opener(*a, **k):
            calls.append(1)
            return Response(b"corrupt")
        with self.assertRaisesRegex(r2.MirrorError, "after bounded retries"):
            r2.verify_public("https://download.example.com/test", r2.digest(b"fixture"), opener=opener, sleeper=sleeps.append)
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [1, 2])

    def test_public_redirect_to_http_is_rejected(self):
        class Response(BytesIO):
            status = 200
            def geturl(self):
                return "http://download.example.com/test"
        with self.assertRaises(r2.MirrorError):
            r2.verify_public("https://download.example.com/test", r2.digest(b"fixture"), attempts=1, opener=lambda *a, **k: Response(b"fixture"))


if __name__ == "__main__":
    unittest.main()
