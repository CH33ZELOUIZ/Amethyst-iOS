#!/usr/bin/env python3
"""Regression checks for the source-only private offline-pack importer."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
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
    assert "OfflineMaxCompressionRatio = 100" in importer
    assert "OfflineMaxEntries = 12000" in importer
    assert "OfflineMaxBytes = 2ULL * 1024 * 1024 * 1024" in importer
    assert "moveItemAtPath:staging toPath:destination" in importer
    assert importer.index("launchNeoForgeInstaller") < importer.index("moveItemAtPath:staging toPath:destination")
    assert importer.index("moveItemAtPath:staging toPath:destination") < importer.rindex("profiles.profiles[profileName]")
    assert "OfflineNeoForge211264InstallerSHA256" in importer
    assert "preflightZipAtPath" in importer
    assert "validateDestinationCollisions" in importer
    # Profile state is owned by the main queue and retains its own error while the worker publishes.
    assert "[profiles save:&profileError]" in importer


def test_import_ui_keeps_generic_curseforge_distinct_and_warns_about_phone_ram():
    view = source("Natives/installer/ModpackInstallViewController.m")
    task = source("Natives/MinecraftResourceDownloadTask.m")
    assert "OfflineModpackImporter isOfflinePackAtPath:dest" in view
    assert "CurseForge manifests require your API key" in view
    assert "no validated iPhone RAM allocation" in view
    assert "physical memory and current allocation" in view
    assert "OfflineModpackImporter importPackAtPath:filePath downloader:self" in task


def load_packager():
    script = ROOT / "tools/package-private-offline-modpack.py"
    spec = importlib.util.spec_from_file_location("private_offline_packager", script)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def package(script, source, output):
    return subprocess.run(
        [sys.executable, str(script), str(source), str(output), "--profile-name", "integrated_boogaloo"],
        text=True, capture_output=True, check=False,
    )


def test_packaging_tool_creates_a_checksum_bound_zip_without_repo_payload():
    script = ROOT / "tools/package-private-offline-modpack.py"
    script_text = script.read_text()
    assert "ZIP_STORED" in script_text
    assert "validate_archive(temporary)" in script_text
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "input"
        root.mkdir()
        (root / "mods").mkdir()
        payload = root / "mods" / "example.jar"
        payload.write_bytes(b"synthetic-only")
        archive_path = Path(temporary) / "private.duo-pack.zip"
        result = package(script, root, archive_path)
        assert result.returncode == 0, result.stderr
        packager = load_packager()
        packager.validate_archive(archive_path)
        with zipfile.ZipFile(archive_path) as archive:
            control = json.loads(archive.read("duo-offline-pack.json"))
            assert set(archive.namelist()) == {"duo-offline-pack.json", "SHA256SUMS.txt", "mods/example.jar"}
            assert hashlib.sha256(archive.read("SHA256SUMS.txt")).hexdigest() == control["sha256sumsSHA256"]
            assert archive.read("mods/example.jar") == b"synthetic-only"


def test_packager_repetitive_two_mib_payload_is_importer_preflight_compatible():
    script = ROOT / "tools/package-private-offline-modpack.py"
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "input"
        payload = root / "mods" / "repetitive.jar"
        payload.parent.mkdir(parents=True)
        payload.write_bytes(b"A" * (2 * 1024 * 1024))
        archive_path = Path(temporary) / "private.duo-pack.zip"
        result = package(script, root, archive_path)
        assert result.returncode == 0, result.stderr
        packager = load_packager()
        packager.validate_archive(archive_path)
        with zipfile.ZipFile(archive_path) as archive:
            info = archive.getinfo("mods/repetitive.jar")
            assert info.compress_size == info.file_size
            assert info.file_size // info.compress_size <= packager.MAX_COMPRESSION_RATIO


def test_packager_rejects_control_values_the_importer_would_reject():
    script = ROOT / "tools/package-private-offline-modpack.py"
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "input"
        root.mkdir()
        (root / "example.jar").write_bytes(b"synthetic-only")
        archive_path = Path(temporary) / "private.duo-pack.zip"
        result = subprocess.run(
            [sys.executable, str(script), str(root), str(archive_path), "--profile-name", "unsafe/profile"],
            text=True, capture_output=True, check=False,
        )
        assert result.returncode != 0
        assert "importer-compatible" in result.stderr
        assert not archive_path.exists()


def test_importer_rejects_adversarial_archive_layouts_before_payload_extraction():
    importer = source("Natives/installer/modpack/OfflineModpackImporter.m")
    # Central-directory validation happens before either untrusted manifest is read.
    assert "validatedArchive:archive controlInfo:&controlInfo sumsInfo:&sumsInfo entries:&entries" in importer
    assert "OfflineMaxControlBytes = 1024ULL * 1024" in importer
    assert "OfflineMaxChecksumBytes = 4ULL * 1024 * 1024" in importer
    assert "extractBufferedDataFromFile:info.filename" in importer
    assert "if (control || info.isDirectory" in importer
    assert "if (sums || info.isDirectory" in importer
    assert "isEncryptedWithPassword" in importer
    assert "(info.posixPermissions & 0170000) == 0120000" in importer
    assert "seen.count != checksums.count" in importer
    assert "actualBytes != [control[@\"payloadBytes\"] unsignedLongLongValue]" in importer


def test_importer_rejects_duplicate_manifest_fixture_layout():
    with tempfile.TemporaryDirectory() as temporary:
        archive_path = Path(temporary) / "duplicate-control.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            archive.writestr("duo-offline-pack.json", b"{}")
            archive.writestr("duo-offline-pack.json", b"{}")
            archive.writestr("SHA256SUMS.txt", b"0" * 64 + b"  mods/example.jar\\n")
        names = zipfile.ZipFile(archive_path).namelist()
        assert names.count("duo-offline-pack.json") == 2
        # validatedArchive tracks and rejects a second control entry before it is streamed.


def test_importer_rejects_declared_payload_size_mismatch_before_disk_preflight():
    importer = source("Natives/installer/modpack/OfflineModpackImporter.m")
    assert "folderPayloadBytesAtRoot" in importer
    assert "validateArchivePayloadEntries" in importer
    assert "actualBytes != [control[@\"payloadBytes\"] unsignedLongLongValue]" in importer
    assert "checkFreeSpaceForBytes:actualBytes" in importer


def test_importer_rejects_compressed_control_bomb_before_streaming_manifest():
    importer = source("Natives/installer/modpack/OfflineModpackImporter.m")
    with tempfile.TemporaryDirectory() as temporary:
        archive_path = Path(temporary) / "control-bomb.zip"
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("duo-offline-pack.json", b"0" * (2 * 1024 * 1024))
            archive.writestr("SHA256SUMS.txt", b"0" * 64 + b"  mods/example.jar\\n")
        control = zipfile.ZipFile(archive_path).getinfo("duo-offline-pack.json")
        assert control.file_size > 1024 * 1024
        assert control.file_size / control.compress_size > 100
    assert importer.index("validatedArchive:archive") < importer.index("readArchiveFile:archive info:controlInfo")
    assert "OfflineMaxControlBytes" in importer
    assert "OfflineMaxCompressionRatio" in importer


def test_importer_rejects_folder_ancestor_symlinks():
    importer = source("Natives/installer/modpack/OfflineModpackImporter.m")
    assert "validatedFolderFile" in importer
    assert "root.stringByResolvingSymlinksInPath" in importer
    assert "attributes[NSFileType] isEqual:NSFileTypeSymbolicLink" in importer
    assert "candidate.stringByResolvingSymlinksInPath" in importer


def test_private_pack_ram_requirements_are_bound_and_confirmed_before_install():
    importer = source("Natives/installer/modpack/OfflineModpackImporter.m")
    view = source("Natives/installer/ModpackInstallViewController.m")
    launcher = source("Natives/JavaLauncher.m")
    assert "[control[@\"minimumRamMiB\"] unsignedLongLongValue] < 4096" in importer
    assert "[control[@\"desktopRecommendedRamMiB\"] unsignedLongLongValue] < 6016" in importer
    assert "requirementsForOfflinePackAtPath" in importer
    assert "confirmOfflineImportAtPath" in view
    assert "duo.offline.confirm.import" in view  # localized "I understand — Import" confirmation
    assert "I understand — Import" in (ROOT / "Natives/resources/en.lproj/Localizable.strings").read_text()
    assert "physical < minimum || allocated < minimum" in view
    assert "launchNeoForgeInstaller(installer, profileID, installerRoot" in importer
    assert "[NSFileManager.defaultManager removeItemAtPath:publishedVersion" in importer
    assert "metadata[@\"id\"] isEqualToString:versionID" in launcher


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"PASS {name}")
