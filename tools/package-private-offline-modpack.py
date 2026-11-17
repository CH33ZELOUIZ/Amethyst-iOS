#!/usr/bin/env python3
"""Create a private Duo offline-pack ZIP without copying it into this repository.

The caller supplies a local full client-instance folder.  Output is intentionally
outside the repository (for example, an encrypted removable drive or private
local IPA staging area).  The ZIP contains no launcher API credentials.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import zipfile

CHUNK = 1024 * 1024
EXCLUDE = {"SHA256SUMS.txt", "SOURCE-SHA256SUMS.txt", "INVENTORY.json", "INVENTORY.md", "duo-offline-pack.json"}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def files(root: Path):
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"symlink not allowed: {path}")
        if path.is_file() and path.name not in EXCLUDE:
            relative = path.relative_to(root).as_posix()
            if ".." in PurePosixPath(relative).parts:
                raise ValueError(f"unsafe input path: {relative}")
            yield path, relative


def main():
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--profile-name", required=True)
    p.add_argument("--minecraft", default="1.21.1")
    p.add_argument("--neoforge", default="neoforge-21.1.264")
    p.add_argument("--minimum-ram-mib", type=int, default=4096)
    p.add_argument("--desktop-recommended-ram-mib", type=int, default=6016)
    args = p.parse_args()
    source = args.source.resolve()
    if not source.is_dir() or args.output.resolve().is_relative_to(source):
        raise ValueError("source must be a directory and output must be outside it")
    records = [(digest(path), relative, path.stat().st_size, path) for path, relative in files(source)]
    sums = "".join(f"{sha}  {relative}\n" for sha, relative, _, _ in records).encode()
    control = {
        "format": "amethyst-duo-offline-pack", "formatVersion": 1,
        "profileName": args.profile_name, "minecraftVersion": args.minecraft,
        "neoforge": args.neoforge, "fileCount": len(records),
        "payloadBytes": sum(size for _, _, size, _ in records),
        "sha256sumsSHA256": hashlib.sha256(sums).hexdigest(),
        "minimumRamMiB": args.minimum_ram_mib,
        "desktopRecommendedRamMiB": args.desktop_recommended_ram_mib,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        archive.writestr("duo-offline-pack.json", json.dumps(control, sort_keys=True, separators=(",", ":")))
        archive.writestr("SHA256SUMS.txt", sums)
        for _, relative, _, path in records:
            archive.write(path, relative)
    print(f"Created private offline pack: {args.output}")
    print(f"Payload: {control['fileCount']} files, {control['payloadBytes']} bytes")


if __name__ == "__main__":
    main()
