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
    (directory / "latest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    assets = sorted(path for path in directory.iterdir() if path.name.startswith("ArcLink-") or path.name == "latest.json")
    (directory / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in assets
    ))
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
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.bundle, args.output, args.arch, args.version)
    else:
        assemble(args.directory, args.version, args.repository, args.notes_file)


if __name__ == "__main__":
    main()
