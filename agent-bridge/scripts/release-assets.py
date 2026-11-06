#!/usr/bin/env python3
"""Prepare architecture artifacts and assemble a complete Tauri updater manifest."""
import argparse
import base64
import hashlib
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

ARCHITECTURES = {"arm64": "darwin-aarch64", "x64": "darwin-x86_64"}


def version_parts(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected stable semantic version")
    return tuple(map(int, version.split(".")))


def validate_repository(repository):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        raise ValueError("Expected GitHub owner/repository")


def one_file(directory, pattern):
    files = list(directory.glob(pattern))
    if len(files) != 1 or not files[0].stat().st_size:
        raise ValueError(f"Expected exactly one nonempty {pattern} in {directory}")
    return files[0]


def prepare(bundle, output, arch, version):
    version_parts(version)
    if arch not in ARCHITECTURES:
        raise ValueError("Unsupported architecture")
    dmg = one_file(bundle / "dmg", "*.dmg")
    archive = one_file(bundle / "macos", "*.app.tar.gz")
    signature = Path(str(archive) + ".sig")
    # Tauri uses base64-encoded minisign signatures. Cryptographic verification
    # is performed by the updater using the public key bundled in the app.
    if not base64.b64decode(signature.read_text().strip(), validate=True):
        raise ValueError("Empty signature")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(dmg, output / f"ArcLink-macos-{arch}.dmg")
    name = f"ArcLink-macos-{arch}.app.tar.gz"
    shutil.copy2(archive, output / name)
    shutil.copy2(signature, output / (name + ".sig"))
    (output / f"build-{arch}.json").write_text(json.dumps({"version": version, "arch": arch}))


def read_release_notes(path):
    notes = Path(path).read_text(encoding="utf-8")
    if not notes.strip():
        raise ValueError("Release notes must not be empty")
    return notes


def asset_names():
    return [f"ArcLink-macos-{arch}{suffix}" for arch in ARCHITECTURES
            for suffix in (".dmg", ".app.tar.gz", ".app.tar.gz.sig")]


def public_base_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.port is not None
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment
            or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", parsed.hostname)):
        raise ValueError("Expected an HTTPS public download origin without credentials, path, port or query")
    return f"https://{parsed.hostname}"


def write_manifest(directory, manifest):
    (directory / "latest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (directory / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256((directory / name).read_bytes()).hexdigest()}  {name}\n"
        for name in sorted(asset_names() + ["latest.json"])
    ), encoding="utf-8")


def read_checksums(directory):
    entries = {}
    for line in (directory / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9.-]+)", line)
        if not match or match.group(2) in entries:
            raise ValueError("Invalid or duplicate source checksum entry")
        entries[match.group(2)] = match.group(1)
    if set(entries) != set(asset_names() + ["latest.json"]):
        raise ValueError("Source checksums must cover exactly both architectures and the manifest")
    for name, digest in entries.items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or not path.stat().st_size:
            raise ValueError(f"Missing, empty or unsafe source asset: {name}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Source checksum mismatch: {name}")


def mirror(directory, output, version, repository, origin):
    """Stage exact published bytes with a separate, deterministic R2 manifest."""
    version_parts(version)
    validate_repository(repository)
    origin = public_base_url(origin)
    directory, output = Path(directory), Path(output)
    if directory.resolve() == output.resolve():
        raise ValueError("Mirror output must differ from the original GitHub assets directory")
    read_checksums(directory)
    manifest = json.loads((directory / "latest.json").read_text(encoding="utf-8"))
    if (manifest.get("version") != version or not isinstance(manifest.get("notes"), str)
            or not manifest["notes"].strip() or not isinstance(manifest.get("pub_date"), str)):
        raise ValueError("Invalid source version, notes or publication date")
    datetime.fromisoformat(manifest["pub_date"].replace("Z", "+00:00"))
    if set(manifest.get("platforms", {})) != set(ARCHITECTURES.values()):
        raise ValueError("Source manifest must contain both supported architectures")
    for arch, platform in ARCHITECTURES.items():
        archive = f"ArcLink-macos-{arch}.app.tar.gz"
        entry = manifest["platforms"][platform]
        signature = (directory / (archive + ".sig")).read_text(encoding="utf-8").strip()
        if not base64.b64decode(signature, validate=True) or entry.get("signature") != signature:
            raise ValueError(f"Source signature metadata mismatch: {arch}")
        expected = f"https://github.com/{repository}/releases/download/arclink-v{version}/{archive}"
        if entry.get("url") != expected:
            raise ValueError(f"Unexpected source archive URL: {arch}")
        entry["url"] = f"{origin}/releases/arclink-v{version}/{archive}"
    output.mkdir(parents=True, exist_ok=True)
    for name in asset_names():
        shutil.copy2(directory / name, output / name)
    write_manifest(output, manifest)
    return manifest


def assemble(directory, version, repository, notes_file=None):
    version_parts(version)
    validate_repository(repository)
    # Retain the legacy library default; publication through the CLI requires
    # an explicit notes file and never falls back to this generic description.
    notes = read_release_notes(notes_file) if notes_file is not None else f"ArcLink {version}"
    platforms = {}
    for arch, platform in ARCHITECTURES.items():
        build = json.loads((directory / f"build-{arch}.json").read_text())
        if build != {"version": version, "arch": arch}:
            raise ValueError(f"Mismatched build metadata for {arch}")
        archive = f"ArcLink-macos-{arch}.app.tar.gz"
        for name in (archive, archive + ".sig", f"ArcLink-macos-{arch}.dmg"):
            if not (directory / name).stat().st_size:
                raise ValueError(f"Empty asset: {name}")
        signature = (directory / (archive + ".sig")).read_text().strip()
        if not base64.b64decode(signature, validate=True):
            raise ValueError("Empty signature")
        platforms[platform] = {
            "signature": signature,
            "url": f"https://github.com/{repository}/releases/download/arclink-v{version}/{archive}",
        }
    manifest = {
        "version": version,
        "notes": notes,
        "pub_date": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "platforms": platforms,
    }
    write_manifest(directory, manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--bundle", required=True, type=Path)
    prep.add_argument("--output", required=True, type=Path)
    prep.add_argument("--arch", choices=ARCHITECTURES, required=True)
    prep.add_argument("--version", required=True)
    merge = commands.add_parser("assemble")
    merge.add_argument("--directory", required=True, type=Path)
    merge.add_argument("--version", required=True)
    merge.add_argument("--repository", required=True)
    merge.add_argument("--notes-file", required=True, type=Path)
    mirrored = commands.add_parser("mirror")
    mirrored.add_argument("--directory", required=True, type=Path)
    mirrored.add_argument("--output", required=True, type=Path)
    mirrored.add_argument("--version", required=True)
    mirrored.add_argument("--repository", required=True)
    mirrored.add_argument("--public-base-url", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.bundle, args.output, args.arch, args.version)
    elif args.command == "assemble":
        assemble(args.directory, args.version, args.repository, args.notes_file)
    else:
        mirror(args.directory, args.output, args.version, args.repository, args.public_base_url)


if __name__ == "__main__":
    main()
