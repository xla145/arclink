#!/usr/bin/env python3
"""Ensure the public release manifest can be read by the ArcLink website."""
import os
import re

ORIGIN = "https://arclink.classktv.com"


def ensure_cors(client, bucket, origin=ORIGIN):
    try:
        current = client.get_bucket_cors(Bucket=bucket).get("CORSRules", [])
    except Exception as error:
        code = getattr(error, "response", {}).get("Error", {}).get("Code")
        if code not in ("NoSuchCORSConfiguration", "404", "NotFound"):
            raise
        current = []
    rules = [dict(rule) for rule in current]
    for rule in rules:
        if origin in rule.get("AllowedOrigins", []) and set(("GET", "HEAD")) <= set(rule.get("AllowedMethods", [])):
            return False
    rules.append({"AllowedOrigins": [origin], "AllowedMethods": ["GET", "HEAD"], "AllowedHeaders": ["*"], "ExposeHeaders": ["ETag", "Content-Length"], "MaxAgeSeconds": 300})
    client.put_bucket_cors(Bucket=bucket, CORSConfiguration={"CORSRules": rules})
    return True


def main():
    account = os.environ["R2_ACCOUNT_ID"]
    bucket = os.environ["R2_BUCKET"]
    if not re.fullmatch(r"[a-f0-9]{32}", account) or not bucket:
        raise SystemExit("Invalid R2 configuration")
    import boto3
    from botocore.config import Config
    client = boto3.client("s3", endpoint_url=f"https://{account}.r2.cloudflarestorage.com", region_name="auto", aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"], aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"], config=Config(connect_timeout=10, read_timeout=30))
    print("R2 CORS " + ("updated" if ensure_cors(client, bucket) else "already configured"))


if __name__ == "__main__":
    main()
