#!/usr/bin/env python3
"""Regression checks for the source-only private offline-pack importer."""
import hashlib
import json
from pathlib import Path
import tempfile
import zipfile

ROOT = Path(__file__).parents[1]


def source(path):
    return (ROOT / path).read_text()


def test_offline_importer_is_private_integrity_checked_and_atomic():
    importer = source("Natives/installer/modpack/OfflineModpackImporter.m")
    assert "amethyst-duo-offline-pack" in importer
    assert "SHA256SUMS.txt" in importer
    assert "sha256ForFile" in importer
    assert "profileName.pathComponents.count != 1" in importer
    assert "safeVersionCharacters" in importer
    assert "extractBufferedDataFromFile" in importer
    assert "compression-ratio limits" in importer
    assert "OfflineMaxEntries = 12000" in importer
    assert "OfflineMaxBytes = 2ULL * 1024 * 1024 * 1024" in importer
    assert "moveItemAtPath:staging toPath:destination" in importer
    assert importer.index("launchNeoForgeInstaller") < importer.index("moveItemAtPath:staging toPath:destination")
    assert importer.index("moveItemAtPath:staging toPath:destination") < importer.rindex("PLProfiles.current.profiles[profileName]")


def test_import_ui_keeps_generic_curseforge_distinct_and_warns_about_phone_ram():
    view = source("Natives/installer/ModpackInstallViewController.m")
    task = source("Natives/MinecraftResourceDownloadTask.m")
    assert "OfflineModpackImporter isOfflinePackAtPath:dest" in view
    assert "CurseForge manifests require your API key" in view
    assert "6016 MiB desktop recommendation is not an iPhone claim" in view
    assert "start at 4096 MiB manually" in view
    assert "OfflineModpackImporter importPackAtPath:filePath downloader:self" in task


def test_packaging_tool_creates_a_checksum_bound_zip_without_repo_payload():
    script = ROOT / "tools/package-private-offline-modpack.py"
    script_text = script.read_text()
    assert "zipfile.ZipFile" in script_text
    assert "SHA256SUMS.txt" in script_text
    assert "duo-offline-pack.json" in script_text
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "input"
        root.mkdir()
        (root / "mods").mkdir()
        payload = root / "mods" / "example.jar"
        payload.write_bytes(b"synthetic-only")
        records = [(hashlib.sha256(payload.read_bytes()).hexdigest(), "mods/example.jar", payload.stat().st_size, payload)]
        sums = "".join(f"{sha}  {relative}\n" for sha, relative, _, _ in records).encode()
        control = {"format": "amethyst-duo-offline-pack", "formatVersion": 1, "fileCount": 1, "payloadBytes": len(b"synthetic-only"), "sha256sumsSHA256": hashlib.sha256(sums).hexdigest()}
        archive_path = Path(temporary) / "private.duo-pack.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("duo-offline-pack.json", json.dumps(control))
            archive.writestr("SHA256SUMS.txt", sums)
            archive.write(payload, "mods/example.jar")
        with zipfile.ZipFile(archive_path) as archive:
            assert set(archive.namelist()) == {"duo-offline-pack.json", "SHA256SUMS.txt", "mods/example.jar"}
            assert hashlib.sha256(archive.read("SHA256SUMS.txt")).hexdigest() == control["sha256sumsSHA256"]
            assert archive.read("mods/example.jar") == b"synthetic-only"


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"PASS {name}")
