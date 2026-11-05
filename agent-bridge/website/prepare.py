#!/usr/bin/env python3
"""Prepare the static page and its real, ignored download from downloads.json."""
import hashlib
import html
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parent


def main():
    config = json.loads((ROOT / "downloads.json").read_text())
    mac = config["mac"]
    source = (ROOT / mac["source"]).resolve()
    destination = (ROOT / mac["url"]).resolve()
    if not destination.is_relative_to(ROOT / "downloads"):
        raise SystemExit("Mac URL must be a file under downloads/.")
    if not source.is_file():
        raise SystemExit(f"Missing Mac package: {source}. Update downloads.json or build the client first.")
    if config["ios"]["url"] is not None:
        raise SystemExit("iOS distribution is not available yet; update the page before configuring its URL.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        raise SystemExit("Copied package checksum does not match source.")
    values = {
        "MAC_URL": mac["url"],
        "MAC_VERSION": mac["version"],
        "MAC_MIN_OS": mac["minimumOS"],
        "MAC_ARCH": mac["architecture"],
        "MAC_SIZE": f"{source.stat().st_size / 1024 / 1024:.1f} MB",
    }
    page = (ROOT / "index.template.html").read_text()
    for key, value in values.items():
        page = page.replace("{{" + key + "}}", html.escape(value, quote=True))
    if "{{" in page:
        raise SystemExit("Unresolved page template token.")
    (ROOT / "index.html").write_text(page)
    print(f"Prepared {destination.name} ({source.stat().st_size} bytes)")
    print(f"SHA-256: {digest}")
    print("Page generated: index.html")


if __name__ == "__main__":
    main()
