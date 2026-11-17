#!/usr/bin/env python3
"""Create a private Duo offline-pack ZIP without copying it into this repository.

The caller supplies a local full client-instance folder. Output is intentionally
outside the repository (for example, an encrypted removable drive or private
local IPA staging area). The ZIP contains no launcher API credentials.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile
from typing import NoReturn
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CHUNK = 1024 * 1024
EXCLUDE = {"SHA256SUMS.txt", "SOURCE-SHA256SUMS.txt", "INVENTORY.json", "INVENTORY.md", "duo-offline-pack.json"}
MAX_ENTRIES = 12000
MAX_PAYLOAD_BYTES = 2 * 1024 * 1024 * 1024
MAX_SINGLE_FILE_BYTES = 512 * 1024 * 1024
MAX_CONTROL_BYTES = 1024 * 1024
MAX_CHECKSUM_BYTES = 4 * 1024 * 1024
MAX_COMPRESSION_RATIO = 100
CONTROL_NAME = "duo-offline-pack.json"
CHECKSUM_NAME = "SHA256SUMS.txt"


def fail(message: str) -> NoReturn:
    raise ValueError(f"Cannot create importer-compatible private offline pack: {message}")


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def is_safe_relative_path(path: str) -> bool:
    relative = PurePosixPath(path)
    return bool(path) and not relative.is_absolute() and "\\" not in path and all(part not in {"", ".", ".."} for part in relative.parts)


def files(root: Path):
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail(f"source contains a symlink: {path}")
        if path.is_file() and path.name not in EXCLUDE:
            relative = path.relative_to(root).as_posix()
            if not is_safe_relative_path(relative):
                fail(f"source contains an unsafe input path: {relative}")
            size = path.stat().st_size
            if size > MAX_SINGLE_FILE_BYTES:
                fail(f"source file exceeds the {MAX_SINGLE_FILE_BYTES} byte per-file limit: {relative}")
            yield path, relative


def safe_zip_entry(info: zipfile.ZipInfo, maximum_bytes: int) -> bool:
    ratio_excessive = info.file_size > 0 and (info.compress_size == 0 or info.file_size // max(1, info.compress_size) > MAX_COMPRESSION_RATIO)
    return (is_safe_relative_path(info.filename) and not stat.S_ISLNK(info.external_attr >> 16) and not (info.flag_bits & 0x1)
            and info.file_size <= maximum_bytes and not ratio_excessive)


def validate_control(control: object, checksums: dict[str, str], payload_bytes: int, sums: bytes) -> None:
    if not isinstance(control, dict):
        fail("control manifest is not an object")
    profile_name = control.get("profileName")
    neoforge = control.get("neoforge")
    minimum_ram = control.get("minimumRamMiB")
    desktop_recommended_ram = control.get("desktopRecommendedRamMiB")
    safe_version_characters = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    if (not isinstance(profile_name, str) or len(PurePosixPath(profile_name).parts) != 1 or not is_safe_relative_path(profile_name)
            or not isinstance(neoforge, str) or not neoforge.startswith("neoforge-") or len(neoforge) == len("neoforge-")
            or any(character not in safe_version_characters for character in neoforge)
            or control.get("format") != "amethyst-duo-offline-pack" or control.get("formatVersion") != 1
            or not isinstance(control.get("minecraftVersion"), str) or not isinstance(control.get("sha256sumsSHA256"), str)
            or not isinstance(minimum_ram, int) or not isinstance(desktop_recommended_ram, int)
            or minimum_ram < 4096 or desktop_recommended_ram < 6016
            or desktop_recommended_ram < minimum_ram
            or control.get("fileCount") != len(checksums) or control.get("payloadBytes") != payload_bytes
            or control.get("payloadBytes", 0) > MAX_PAYLOAD_BYTES
            or control.get("sha256sumsSHA256") != hashlib.sha256(sums).hexdigest()):
        fail("control manifest does not satisfy importer requirements")


def validate_archive(path: Path) -> None:
    """Mirror the importer's ZIP central-directory and payload preflight checks."""
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ENTRIES:
                fail(f"archive has more than {MAX_ENTRIES} central-directory entries")
            control_infos = [info for info in entries if info.filename == CONTROL_NAME]
            checksum_infos = [info for info in entries if info.filename == CHECKSUM_NAME]
            if len(control_infos) != 1 or control_infos[0].is_dir() or not safe_zip_entry(control_infos[0], MAX_CONTROL_BYTES):
                fail("archive must have exactly one safe, bounded control file")
            if len(checksum_infos) != 1 or checksum_infos[0].is_dir() or not safe_zip_entry(checksum_infos[0], MAX_CHECKSUM_BYTES):
                fail("archive must have exactly one safe, bounded checksum file")
            expanded = 0
            maximum_archive_bytes = MAX_PAYLOAD_BYTES + MAX_CONTROL_BYTES + MAX_CHECKSUM_BYTES
            for info in entries:
                if not safe_zip_entry(info, MAX_SINGLE_FILE_BYTES) or expanded > maximum_archive_bytes - info.file_size:
                    fail("archive has an unsafe, oversized, or excessively compressed central-directory entry")
                expanded += info.file_size
            try:
                control = json.loads(archive.read(control_infos[0]).decode("utf-8"))
                sums = archive.read(checksum_infos[0])
                checksum_lines = sums.decode("utf-8").splitlines()
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                fail(f"archive control files cannot be read: {error}")
            checksums = {}
            for line in checksum_lines:
                if len(line) < 67 or line[64:66] != "  " or any(char not in "0123456789abcdef" for char in line[:64]):
                    fail("checksum manifest is malformed")
                name = line[66:]
                if not is_safe_relative_path(name) or name in checksums:
                    fail("checksum manifest has an unsafe or duplicate path")
                checksums[name] = line[:64]
            if not checksums:
                fail("checksum manifest is empty")
            payload = [info for info in entries if not info.is_dir() and info.filename not in {CONTROL_NAME, CHECKSUM_NAME}]
            names = {info.filename for info in payload}
            if len(names) != len(payload) or names != set(checksums):
                fail("archive payload does not exactly match the checksum manifest")
            payload_bytes = sum(info.file_size for info in payload)
            if payload_bytes > MAX_PAYLOAD_BYTES or any(info.file_size > MAX_SINGLE_FILE_BYTES for info in payload):
                fail("archive payload exceeds importer size limits")
            validate_control(control, checksums, payload_bytes, sums)
            for info in payload:
                h = hashlib.sha256()
                with archive.open(info) as stream:
                    for chunk in iter(lambda: stream.read(CHUNK), b""):
                        h.update(chunk)
                if h.hexdigest() != checksums[info.filename]:
                    fail(f"payload checksum does not match its manifest: {info.filename}")
    except zipfile.BadZipFile as error:
        fail(f"archive is not a valid ZIP: {error}")


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
    output = args.output.resolve()
    if not source.is_dir() or output.is_relative_to(source):
        fail("source must be a directory and output must be outside it")
    if output.is_relative_to(ROOT):
        fail("private pack output must be outside the repository top-level")
    records = [(digest(path), relative, path.stat().st_size, path) for path, relative in files(source)]
    if not records:
        fail("source has no payload files")
    if len(records) + 2 > MAX_ENTRIES:
        fail(f"source has too many files for the {MAX_ENTRIES} archive-entry limit")
    payload_bytes = sum(size for _, _, size, _ in records)
    if payload_bytes > MAX_PAYLOAD_BYTES:
        fail(f"source payload exceeds the {MAX_PAYLOAD_BYTES} byte total limit")
    sums = "".join(f"{sha}  {relative}\n" for sha, relative, _, _ in records).encode()
    if len(sums) > MAX_CHECKSUM_BYTES:
        fail(f"checksum manifest exceeds the {MAX_CHECKSUM_BYTES} byte limit")
    control = {
        "format": "amethyst-duo-offline-pack", "formatVersion": 1,
        "profileName": args.profile_name, "minecraftVersion": args.minecraft,
        "neoforge": args.neoforge, "fileCount": len(records),
        "payloadBytes": payload_bytes,
        "sha256sumsSHA256": hashlib.sha256(sums).hexdigest(),
        "minimumRamMiB": args.minimum_ram_mib,
        "desktopRecommendedRamMiB": args.desktop_recommended_ram_mib,
    }
    control_data = json.dumps(control, sort_keys=True, separators=(",", ":")).encode()
    if len(control_data) > MAX_CONTROL_BYTES:
        fail(f"control manifest exceeds the {MAX_CONTROL_BYTES} byte limit")
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".tmp", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        # Stored members deliberately avoid generating ZIP entries above Duo's 100:1 ratio cap.
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
            archive.writestr(CONTROL_NAME, control_data)
            archive.writestr(CHECKSUM_NAME, sums)
            for _, relative, _, path in records:
                archive.write(path, relative)
        validate_archive(temporary)
        temporary.replace(output)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    print(f"Created importer-compatible private offline pack: {output}")
    print(f"Payload: {control['fileCount']} files, {control['payloadBytes']} bytes")


if __name__ == "__main__":
    main()
