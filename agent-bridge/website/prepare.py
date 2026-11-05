#!/usr/bin/env python3
"""Generate the static download page from local packages or a versioned R2 release."""
import argparse
import copy
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
PUBLIC_BASE = "https://download.classktv.com"
ARCHITECTURES = {"arm64": "Apple 芯片版", "x64": "Intel 版"}
PLATFORMS = {"arm64": "darwin-aarch64", "x64": "darwin-x86_64"}


def stable_version(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", value):
        raise ValueError("Mac version must be a stable X.Y.Z version.")
    return value


def release_url(version, arch, extension="dmg"):
    return f"{PUBLIC_BASE}/releases/arclink-v{version}/ArcLink-macos-{arch}.{extension}"


def apply_release_manifest(config, manifest):
    """Take version and both architecture URLs from a verified local R2 manifest.

    This does not check public availability or cryptographic signatures; publication
    must verify those before deploying the generated page.
    """
    version = stable_version(manifest.get("version"))
    if not isinstance(manifest.get("notes"), str) or not manifest["notes"].strip():
        raise ValueError("Release manifest must contain human release notes.")
    platforms = manifest.get("platforms")
    if not isinstance(platforms, dict) or set(platforms) != set(PLATFORMS.values()):
        raise ValueError("Release manifest must contain both macOS architectures.")
    packages = {}
    for arch, platform in PLATFORMS.items():
        item = platforms[platform]
        if not isinstance(item, dict) or item.get("url") != release_url(version, arch, "app.tar.gz"):
            raise ValueError(f"Unexpected R2 release archive URL for {arch}.")
        if not isinstance(item.get("signature"), str) or not item["signature"].strip():
            raise ValueError(f"Missing release signature for {arch}.")
        packages[arch] = {"url": release_url(version, arch)}
    config = copy.deepcopy(config)
    config["mac"]["version"] = version
    config["mac"]["packages"] = packages
    # Legacy package data and previous-version sizes must not leak into this release.
    for key in ("source", "url", "architecture", "sizeBytes"):
        config["mac"].pop(key, None)
    return config


def write_text_atomic(path, content):
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix="." + path.name + ".", delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def prepare(root=ROOT, manifest=None, write_config=False):
    if write_config and manifest is None:
        raise ValueError("--write-config requires --release-manifest.")
    root = Path(root).resolve()
    config = json.loads((root / "downloads.json").read_text(encoding="utf-8"))
    if config["ios"]["url"] is not None:
        raise ValueError("iOS distribution is not available yet; update the page before configuring its URL.")
    if manifest is not None:
        config = apply_release_manifest(config, manifest)
    mac = config["mac"]
    version = stable_version(mac["version"])
    if not isinstance(mac.get("minimumOS"), str) or not mac["minimumOS"].strip():
        raise ValueError("Mac minimum OS must not be empty.")
    packages = mac.get("packages")
    legacy = packages is None
    if legacy:
        packages = {"arm64": mac}
    elif not isinstance(packages, dict) or set(packages) != set(ARCHITECTURES):
        raise ValueError("Mac packages must contain arm64 and x64.")

    copies, prepared, buttons = [], [], []
    for arch in (["arm64"] if legacy else ARCHITECTURES):
        package = packages[arch]
        url = package["url"]
        if not isinstance(url, str):
            raise ValueError("Mac package URL must be a string.")
        parsed = urlsplit(url)
        external = bool(parsed.scheme or parsed.netloc)
        if external:
            # Exact versioned paths also reject credentials, query strings,
            # fragments, protocol-relative URLs and accidental architecture swaps.
            if url != release_url(version, arch):
                raise ValueError(f"External Mac URL must be the versioned R2 {arch} DMG URL.")
            if "source" in package:
                raise ValueError("External packages must not declare a local source.")
            size = package.get("sizeBytes")
            if size is not None and (type(size) is not int or size <= 0):
                raise ValueError("Package sizeBytes must be a positive integer.")
        else:
            destination = (root / url).resolve()
            if parsed.query or parsed.fragment or any(character in url for character in ("%", "\\", ":")) or not url.startswith("downloads/") or not destination.is_relative_to(root / "downloads") or destination.suffix != ".dmg":
                raise ValueError("Local Mac URL must be a file under downloads/.")
            source = (root / package["source"]).resolve()
            if not source.is_file():
                raise ValueError(f"Missing Mac package: {source}. Update downloads.json or build the client first.")
            size = source.stat().st_size
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            if "sha256" in package and package["sha256"] != digest:
                raise ValueError("Local package checksum does not match configuration.")
            copies.append((source, destination, digest))
        label = "下载 Mac 客户端" if legacy else "下载 " + ARCHITECTURES[arch]
        size_label = f" · {size / 1024 / 1024:.1f} MB" if size is not None else ""
        download = "" if external else " download"
        buttons.append(
            '<a\n                class="button primary download-button"\n                href="'
            + html.escape(url, quote=True) + '"' + download + "\n                >"
            + html.escape(label + size_label) + ' <span aria-hidden="true">↓</span></a\n              >'
        )
        prepared.append({"arch": arch, "url": url, "size": size})

    arch_label = mac.get("architecture", "Apple Silicon") if legacy else "Apple Silicon / Intel"
    values = {
        "MAC_PRIMARY_URL": prepared[0]["url"] if len(prepared) == 1 else "#download",
        "MAC_VERSION": version,
        "MAC_MIN_OS": mac["minimumOS"],
        "MAC_ARCH": arch_label,
    }
    page = (root / "index.template.html").read_text(encoding="utf-8")
    for key, value in values.items():
        page = page.replace("{{" + key + "}}", html.escape(value, quote=True))
    page = page.replace("{{MAC_DOWNLOADS}}", "\n              " + "\n              ".join(buttons) + "\n            ")
    if "{{" in page:
        raise ValueError("Unresolved page template token.")
    for source, destination, digest in copies:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source != destination:
            shutil.copyfile(source, destination)
        if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise ValueError("Copied package checksum does not match source.")
        print(f"Prepared {destination.name} ({source.stat().st_size} bytes); SHA-256: {digest}")
    if write_config:
        write_text_atomic(root / "downloads.json", json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    write_text_atomic(root / "index.html", page)
    print(f"Page generated: v{version}, " + ", ".join(package["url"] for package in prepared))
    return page


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-manifest", type=Path, help="Validated local R2 latest.json; synchronizes version and both DMG links without network access")
    parser.add_argument("--write-config", action="store_true", help="Atomically persist manifest-derived downloads.json so later default builds keep the same release")
    args = parser.parse_args()
    if args.write_config and args.release_manifest is None:
        parser.error("--write-config requires --release-manifest")
    try:
        manifest = json.loads(args.release_manifest.read_text(encoding="utf-8")) if args.release_manifest else None
        prepare(manifest=manifest, write_config=args.write_config)
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
