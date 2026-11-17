#!/usr/bin/env python3
"""Portable regression fixtures for the archive-format safety contract.

The iOS implementation enforces the same format and path rules in ModpackUtils.
These fixtures intentionally use only synthetic metadata; no user modpack is stored
in the repository.
"""
import stat


def validate_entries(entries):
    """Model the accepted root-manifest contract used by the Objective-C importer."""
    if len(entries) > 10_000:
        raise ValueError("too many archive entries")
    total = 0
    for name, size, mode in entries:
        if (
            not name
            or name.startswith("/")
            or "\\" in name
            or any(part in ("", ".", "..") for part in name.split("/"))
            or stat.S_IFMT(mode) == stat.S_IFLNK
            or size > 256 * 1024 * 1024
        ):
            raise ValueError("unsafe archive entry")
        total += size
        if total > 1024 * 1024 * 1024:
            raise ValueError("expanded archive too large")
def classify(manifest, index):
    """Model root-manifest selection after structural validation."""
    curseforge = isinstance(manifest, dict) and manifest.get("manifestType", "").lower() == "minecraftmodpack" and isinstance(manifest.get("minecraft"), dict) and isinstance(manifest.get("files"), list)
    modrinth = isinstance(index, dict) and isinstance(index.get("formatVersion"), int) and isinstance(index.get("dependencies"), dict) and isinstance(index.get("files"), list)
    if curseforge == modrinth:
        raise ValueError("unsupported or ambiguous modpack archive")
    return "curseforge" if curseforge else "modrinth"


def test_official_curseforge_manifest_is_detected():
    validate_entries([("manifest.json", 100, stat.S_IFREG)])
    assert classify({"manifestType": "minecraftModpack", "minecraft": {"version": "1.21.1"}, "files": []}, None) == "curseforge"


def test_modrinth_index_is_detected():
    validate_entries([("modrinth.index.json", 100, stat.S_IFREG)])
    assert classify(None, {"formatVersion": 1, "dependencies": {"minecraft": "1.21.1"}, "files": []}) == "modrinth"


def test_generic_and_ambiguous_archives_are_rejected():
    for manifest, index in ((None, None), ({"manifestType": "minecraftModpack", "minecraft": {}, "files": []}, {"formatVersion": 1, "dependencies": {}, "files": []})):
        try:
            classify(manifest, index)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid archive was accepted")


def test_malicious_paths_are_rejected():
    for name in ("../escape", "/absolute", "overrides\\escape", "overrides/../escape"):
        try:
            validate_entries([(name, 1, stat.S_IFREG)])
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe path accepted: {name}")


def test_symlinks_and_expansion_limits_are_rejected():
    for entries in (
        [("overrides/link", 0, stat.S_IFLNK)],
        [("overrides/large", 256 * 1024 * 1024 + 1, stat.S_IFREG)],
        [("overrides/a", 600 * 1024 * 1024, stat.S_IFREG), ("overrides/b", 600 * 1024 * 1024, stat.S_IFREG)],
    ):
        try:
            validate_entries(entries)
        except ValueError:
            pass
        else:
            raise AssertionError("unsafe archive was accepted")


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
