#!/usr/bin/env python3
"""Mirror a published ArcLink release to R2, then conditionally promote latest.json."""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

spec = importlib.util.spec_from_file_location("release_assets", Path(__file__).with_name("release-assets.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
LATEST_CACHE = "no-store, max-age=0"


class MirrorError(RuntimeError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def content_type(name):
    if name.endswith(".dmg"):
        return "application/x-apple-diskimage"
    if name.endswith(".tar.gz"):
        return "application/gzip"
    if name.endswith(".json"):
        return "application/json; charset=utf-8"
    return "text/plain; charset=utf-8"


def error_code(error):
    return getattr(error, "response", {}).get("Error", {}).get("Code")


def object_bytes(client, bucket, key):
    try:
        result = client.get_object(Bucket=bucket, Key=key)
    except Exception as error:
        if error_code(error) in ("NoSuchKey", "NotFound", "404"):
            return None
        raise
    stream = result["Body"]
    try:
        body = stream.read()
    finally:
        stream.close()
    return body, result.get("ETag")


def latest_state(client, bucket, candidate, version):
    current = object_bytes(client, bucket, "latest.json")
    if current is None:
        return None
    body, etag = current
    try:
        previous = json.loads(body)
        previous_version = release.version_parts(previous["version"])
    except (ValueError, KeyError, TypeError) as error:
        raise MirrorError("Existing latest.json is invalid; refusing to replace it") from error
    target_version = release.version_parts(version)
    if previous_version > target_version:
        raise MirrorError("Refusing to move R2 latest backwards")
    if previous_version == target_version and body != candidate:
        raise MirrorError("Same-version R2 latest differs; refusing to overwrite it")
    if not etag:
        raise MirrorError("Missing latest ETag; cannot safely promote")
    return body, etag


def put_immutable(client, bucket, key, body):
    existing = object_bytes(client, bucket, key)
    if existing is not None:
        if existing[0] != body:
            raise MirrorError("Immutable R2 object differs: " + key)
        return False
    try:
        client.put_object(Bucket=bucket, Key=key, Body=body, ContentLength=len(body),
                          ContentType=content_type(key), CacheControl=IMMUTABLE_CACHE,
                          Metadata={"sha256": digest(body)}, IfNoneMatch="*")
    except Exception as error:
        if error_code(error) in ("PreconditionFailed", "ConditionalRequestConflict", "412", "409"):
            # Another publisher may have won the create; never overwrite it.
            existing = object_bytes(client, bucket, key)
            if existing is not None and existing[0] == body:
                return False
            raise MirrorError("Concurrent immutable R2 object differs: " + key) from error
        raise
    return True


def verify_public(url, expected_digest, attempts=3, opener=urlopen, sleeper=time.sleep):
    """Fetch actual bytes through the custom hostname, not the authenticated S3 API."""
    last_error = None
    for attempt in range(attempts):
        try:
            request = Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "ArcLink-release-verifier"})
            with opener(request, timeout=30) as response:
                if response.status != 200 or urlsplit(response.geturl()).scheme != "https":
                    raise MirrorError("Public object did not return HTTPS 200")
                actual = hashlib.sha256()
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    actual.update(chunk)
                if actual.hexdigest() != expected_digest:
                    raise MirrorError("Public object checksum mismatch")
            return
        except Exception as error:
            last_error = error
            if attempt + 1 < attempts:
                sleeper(2 ** attempt)
    # Do not print response URLs, redirects, SDK errors or credentials.
    raise MirrorError("Public object verification failed after bounded retries: " + urlsplit(url).path) from last_error


def publish(client, bucket, directory, version, repository, origin, verifier=verify_public):
    origin = release.public_base_url(origin)
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
        raise ValueError("Invalid R2 bucket name")
    with tempfile.TemporaryDirectory(prefix="arclink-r2-stage-") as temporary:
        staged = Path(temporary)
        release.mirror(Path(directory), staged, version, repository, origin)
        candidate = (staged / "latest.json").read_bytes()
        # Fail on a stale or conflicting candidate before any writes.
        latest_state(client, bucket, candidate, version)
        prefix = "releases/arclink-v" + version + "/"
        names = release.asset_names() + ["latest.json", "SHA256SUMS.txt"]
        uploaded = 0
        for name in names:
            uploaded += put_immutable(client, bucket, prefix + name, (staged / name).read_bytes())
        for name in names:
            verifier(origin + "/" + prefix + name, digest((staged / name).read_bytes()))
        # Read again after slow uploads and public validation. Conditional put
        # also closes the race between this read and the promotion itself.
        current = latest_state(client, bucket, candidate, version)
        promoted = current is None or current[0] != candidate
        if promoted:
            condition = {"IfNoneMatch": "*"} if current is None else {"IfMatch": current[1]}
            try:
                client.put_object(Bucket=bucket, Key="latest.json", Body=candidate,
                                  ContentLength=len(candidate), ContentType=content_type("latest.json"),
                                  CacheControl=LATEST_CACHE, Metadata={"sha256": digest(candidate)}, **condition)
            except Exception as error:
                if error_code(error) in ("PreconditionFailed", "ConditionalRequestConflict", "412", "409"):
                    raise MirrorError("R2 latest changed concurrently; inspect the new state before retrying") from error
                raise
        verifier(origin + "/latest.json", digest(candidate))
        return {"version": version, "bucket": bucket, "public_base_url": origin,
                "version_prefix": prefix, "immutable_objects": len(names),
                "uploaded_objects": uploaded, "latest_promoted": promoted,
                "public_checksums_verified": True, "cryptographic_signature_verified": False}


def make_client(account_id):
    if not re.fullmatch(r"[a-f0-9]{32}", account_id):
        raise ValueError("R2_ACCOUNT_ID must be a 32-character account ID")
    for name in ("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"):
        if not os.environ.get(name):
            raise ValueError("Missing " + name)
    import boto3
    from botocore.config import Config
    return boto3.client("s3", endpoint_url=f"https://{account_id}.r2.cloudflarestorage.com",
                        region_name="auto", aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
                        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
                        config=Config(connect_timeout=10, read_timeout=60,
                                      request_checksum_calculation="when_required",
                                      response_checksum_validation="when_required",
                                      retries={"max_attempts": 3, "mode": "standard"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--public-base-url", default=os.environ.get("R2_PUBLIC_BASE_URL"))
    parser.add_argument("--bucket", default=os.environ.get("R2_BUCKET"))
    parser.add_argument("--account-id", default=os.environ.get("R2_ACCOUNT_ID"))
    args = parser.parse_args()
    try:
        for name in ("public_base_url", "bucket", "account_id"):
            if not getattr(args, name):
                raise ValueError("Missing R2_" + name.upper())
        result = publish(make_client(args.account_id), args.bucket, args.directory,
                         args.version, args.repository, args.public_base_url)
    except Exception as error:
        message = str(error) if isinstance(error, (MirrorError, ValueError)) else type(error).__name__
        print("R2 mirror failed: " + message, file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
