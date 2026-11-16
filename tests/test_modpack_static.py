#!/usr/bin/env python3
"""Static regression checks for provider routing and archive-safety contracts."""
from pathlib import Path

ROOT = Path(__file__).parents[1]


def source(path):
    return (ROOT / path).read_text()


def test_provider_switch_and_no_embedded_key():
    view = source("Natives/installer/ModpackInstallViewController.m")
    curse = source("Natives/installer/modpack/CurseForgeAPI.m")
    assert 'initWithItems:@[@"Modrinth", @"CurseForge"]' in view
    assert 'self.api = sender.selectedSegmentIndex == 1 ? [CurseForgeAPI new] : [ModrinthAPI new]' in view
    assert 'kSecAttrService: @"Amethyst.CurseForge"' in curse
    assert 'CONFIG_CURSEFORGE_API_KEY' not in curse
    assert 'object:[ModrinthAPI new] userInfo:@{@"localPath": dest}' in view


def test_modrinth_details_append_in_lockstep():
    modrinth = source("Natives/installer/modpack/ModrinthAPI.m")
    for expression in ('[names addObject:', '[mcNames addObject:', '[urls addObject:', '[hashes addObject:', '[sizes addObject:'):
        assert expression in modrinth
    assert 'mcNames[i] =' not in modrinth


def test_archive_and_download_paths_are_checked():
    utils = source("Natives/installer/modpack/ModpackUtils.m")
    modrinth = source("Natives/installer/modpack/ModrinthAPI.m")
    assert 'safeDestinationForRelativePath' in utils
    assert '[component isEqual:@".."]' in utils
    assert '[dir stringByAppendingString:@"/"]' in utils
    assert '[ModpackUtils safeDestinationForRelativePath:indexFile[@"path"] root:destPath error:&error]' in modrinth


def test_neoforge_is_not_offered_as_playable():
    curse = source("Natives/installer/modpack/CurseForgeAPI.m")
    assert '[version[@"loaders"] containsObject:@"neoforge"]' in curse
    assert 'not wired into modpack profiles' in curse


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
