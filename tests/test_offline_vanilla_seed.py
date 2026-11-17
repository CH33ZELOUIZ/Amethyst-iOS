#!/usr/bin/env python3
"""Tests for seeding the isolated NeoForge install root with vanilla prerequisites."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).parents[1]
SEED_SOURCE = ROOT / "Natives/installer/modpack/OfflineVanillaSeed.c"
INSTALLER_SHA256 = "d7c035dd5436a7c524dfbad6df191b0ef34179fd3edfee9dc99262af3b80239b"


def load_seeder(tmp):
    lib = Path(tmp) / "libseed.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O1", "-Wall", "-Werror", "-o", str(lib), str(SEED_SOURCE)], check=True)
    fn = ctypes.CDLL(str(lib)).OfflineSeedVanillaRoot
    fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]

    def seed(game, root, version="1.21.1"):
        err = ctypes.create_string_buffer(512)
        rc = fn(str(game).encode(), str(root).encode(), version.encode(), err, 512)
        return rc, err.value.decode()
    return seed


def make_vanilla(game, version="1.21.1", jar=None, meta=None):
    d = Path(game) / "versions" / version
    d.mkdir(parents=True)
    (d / f"{version}.json").write_text(meta if meta is not None else json.dumps({"id": version, "downloads": {"client": {}}}))
    jar_path = d / f"{version}.jar"
    if jar is None:
        with zipfile.ZipFile(jar_path, "w") as z:
            z.writestr("net/minecraft/Main.class", b"x")
    else:
        jar_path.write_bytes(jar)
    return d


def test_seed_copies_only_required_inputs_into_isolated_root():
    with tempfile.TemporaryDirectory() as tmp:
        game = Path(tmp) / "game"
        root = game / "custom_gamedir/.offline-neoforge-x"
        root.mkdir(parents=True)
        vanilla = make_vanilla(game)
        (vanilla / "extra.txt").write_text("unrelated")
        (game / "saves").mkdir()
        assert load_seeder(tmp)(game, root) == (0, "")
        files = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
        assert files == ["launcher_profiles.json", "versions/1.21.1/1.21.1.jar", "versions/1.21.1/1.21.1.json"]
        assert (root / "versions/1.21.1/1.21.1.jar").read_bytes() == (vanilla / "1.21.1.jar").read_bytes()
        assert isinstance(json.loads((root / "launcher_profiles.json").read_text())["profiles"], dict)
        assert not os.path.islink(root / "versions/1.21.1/1.21.1.jar")
        assert not (game / "launcher_profiles.json").exists()


def test_seed_fails_early_with_actionable_message_when_missing_or_corrupt():
    with tempfile.TemporaryDirectory() as tmp:
        seed = load_seeder(tmp)
        cases = {}
        g = Path(tmp) / "none"; (g / "versions").mkdir(parents=True); cases["missing"] = g
        g = Path(tmp) / "nojar"; make_vanilla(g); (g / "versions/1.21.1/1.21.1.jar").unlink(); cases["nojar"] = g
        g = Path(tmp) / "badjar"; make_vanilla(g, jar=b"not a zip at all, definitely"); cases["badjar"] = g
        g = Path(tmp) / "truncjar"; make_vanilla(g, jar=b"PK\x03\x04" + b"\0" * 64); cases["truncjar"] = g
        g = Path(tmp) / "badjson"; make_vanilla(g, meta="{not json"); cases["badjson"] = g
        g = Path(tmp) / "wrongid"; make_vanilla(g, meta=json.dumps({"id": "1.20.1", "downloads": {}})); cases["wrongid"] = g
        g = Path(tmp) / "emptyjson"; make_vanilla(g, meta=""); cases["emptyjson"] = g
        for name, g in cases.items():
            root = Path(tmp) / f"root-{name}"; root.mkdir()
            rc, message = seed(g, root)
            assert rc != 0, name
            assert "Minecraft 1.21.1" in message and "import this pack again" in message, (name, message)
            assert list(root.iterdir()) == [] or not (root / "launcher_profiles.json").exists(), name
        for bad_version in ["../x", "", "1.21.1/../../etc", ".hidden", "a b"]:
            root = Path(tmp) / "root-badver"; root.mkdir(exist_ok=True)
            assert seed(cases["badjar"], root, bad_version)[0] != 0


def test_seed_rejects_symlinked_sources_and_directories():
    with tempfile.TemporaryDirectory() as tmp:
        seed = load_seeder(tmp)
        outside = Path(tmp) / "outside"; make_vanilla(outside)
        g1 = Path(tmp) / "g1"; d = make_vanilla(g1)
        (d / "1.21.1.jar").unlink(); (d / "1.21.1.jar").symlink_to(outside / "versions/1.21.1/1.21.1.jar")
        g2 = Path(tmp) / "g2"; d2 = make_vanilla(g2)
        (d2 / "1.21.1.json").unlink(); (d2 / "1.21.1.json").symlink_to(outside / "versions/1.21.1/1.21.1.json")
        g3 = Path(tmp) / "g3"; (g3 / "versions").mkdir(parents=True); (g3 / "versions/1.21.1").symlink_to(outside / "versions/1.21.1")
        g4 = Path(tmp) / "g4"; g4.mkdir(); (g4 / "versions").symlink_to(outside / "versions")
        for i, g in enumerate([g1, g2, g3, g4]):
            root = Path(tmp) / f"r{i}"; root.mkdir()
            rc, message = seed(g, root)
            assert rc != 0 and "Minecraft 1.21.1" in message, (i, message)
            assert list(root.iterdir()) == [], i
        real = Path(tmp) / "realroot"; real.mkdir()
        link = Path(tmp) / "linkroot"; link.symlink_to(real)
        gok = Path(tmp) / "gok"; make_vanilla(gok)
        assert seed(gok, link)[0] != 0 and list(real.iterdir()) == []


def test_importer_seeds_before_installer_and_fails_before_publication():
    importer = (ROOT / "Natives/installer/modpack/OfflineModpackImporter.m").read_text()
    seed_at, install_at = importer.index("OfflineSeedVanillaRoot("), importer.index("launchNeoForgeInstaller(installer")
    assert seed_at < install_at
    body = importer[seed_at:install_at]
    assert "removeItemAtPath:installerRoot" in body and "removeItemAtPath:staging" in body
    assert "finishDownloadWithErrorString:@(seedError)" in body
    assert "OfflineVanillaSeed.c" in (ROOT / "Natives/CMakeLists.txt").read_text()


def test_official_installer_accepts_seeded_root_when_provided():
    installer, vanilla = os.environ.get("NEOFORGE_INSTALLER"), os.environ.get("VANILLA_GAME_DIR")
    if not installer or not vanilla:
        print("SKIP official installer run (set NEOFORGE_INSTALLER and VANILLA_GAME_DIR)")
        return
    assert hashlib.sha256(Path(installer).read_bytes()).hexdigest() == INSTALLER_SHA256
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "root"; root.mkdir()
        rc, message = load_seeder(tmp)(vanilla, root)
        assert rc == 0, message
        done = subprocess.run(["java", "-jar", installer, "--installClient", str(root)], capture_output=True, text=True, timeout=900)
        assert done.returncode == 0, done.stdout[-2000:] + done.stderr[-2000:]
        meta = json.loads((root / "versions/neoforge-21.1.264/neoforge-21.1.264.json").read_text())
        assert meta["id"] == "neoforge-21.1.264" and meta["inheritsFrom"] == "1.21.1" and meta["libraries"]


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_"):
            test()
            print(f"PASS {name}")
