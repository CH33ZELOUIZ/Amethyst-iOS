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
    assert 'object:api userInfo:@{@"localPath": dest}' in view


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


def test_local_archives_are_detected_before_provider_routing():
    view = source("Natives/installer/ModpackInstallViewController.m")
    utils = source("Natives/installer/modpack/ModpackUtils.m")
    assert 'initForOpeningContentTypes:@[UTTypeItem] asCopy:YES' in view
    assert '[f.pathExtension.lowercaseString isEqualToString:@"zip"]' in view
    assert '[ModpackUtils packFormatForArchiveAtPath:dest error:&formatError]' in view
    assert '[format isEqualToString:@"curseforge"] ? [CurseForgeAPI new] : [ModrinthAPI new]' in view
    assert 'This archive is not a supported Modrinth .mrpack or official CurseForge client modpack ZIP.' in utils
    assert 'manifest[@"manifestType"]' in utils
    assert 'index[@"formatVersion"]' in utils


def test_archives_are_bounded_and_reject_unsafe_entries():
    utils = source("Natives/installer/modpack/ModpackUtils.m")
    assert 'entryCount > 10000' in utils
    assert '1024ULL * 1024 * 1024' in utils
    assert '[name containsString:@"\\\\"]' in utils
    assert '0120000' in utils
    assert '[self validateArchive:archive error:error]' in utils


def test_neoforge_modpacks_use_the_official_headless_client_installer_before_profile_publish():
    curse = source("Natives/installer/modpack/CurseForgeAPI.m")
    launcher = source("Natives/JavaLauncher.m")
    assert '[loaderID hasPrefix:@"neoforge-"]' in curse
    assert 'maven.neoforged.net/releases/net/neoforged/neoforge' in curse
    assert 'launchNeoForgeInstaller(neoForgeInstallerPath, profileID' in curse
    assert curse.index('launchNeoForgeInstaller(neoForgeInstallerPath, profileID') < curse.index('profiles.profiles[packName]')
    assert 'standalone NeoForge installer is not wired into modpack profiles' not in curse
    assert '@[@"--installClient", installationDirectory]' in launcher
    assert 'int result = launchJVMWithJarArguments(nil, installerPath' in launcher
    assert 'result == 0 && [NSFileManager.defaultManager fileExistsAtPath:versionJSON]' in launcher


def test_curseforge_archives_use_only_official_file_metadata():
    curse = source("Natives/installer/modpack/CurseForgeAPI.m")
    assert 'extractDataFromFile:@"manifest.json"' in curse
    assert 'versionForID:CFIdentifier(candidate[@"fileID"]) projectID:CFIdentifier(candidate[@"projectID"])' in curse
    assert '[file[@"downloadUnavailable"] boolValue]' in curse
    assert 'sha:download[@"hashes"][@"sha1"]' in curse
    assert 'forceSHA:YES' in curse
    assert 'extractDirectory:@"overrides"' in curse
    assert 'dependency = @{ @"minecraft": minecraftVersion, @"neoforge": loaderID }' in curse


def test_curseforge_install_is_staged_and_published_only_after_all_downloads():
    curse = source("Natives/installer/modpack/CurseForgeAPI.m")
    assert 'stagingPath = [destPath stringByAppendingFormat:@".installing-%@"' in curse
    assert 'root:stagingPath' in curse
    assert 'dispatch_group_notify(downloadsComplete' in curse
    assert curse.index('moveItemAtPath:stagingPath toPath:destPath') < curse.index('profiles.profiles[packName]')
    assert 'removeItemAtPath:stagingPath' in curse
    assert 'Open Content Settings, add your CurseForge API key' in curse


def test_required_curseforge_hashes_ignore_global_preference_and_progress_is_not_double_counted():
    task = source("Natives/MinecraftResourceDownloadTask.m")
    curse = source("Natives/installer/modpack/CurseForgeAPI.m")
    assert 'forceSHA ? [self checkSHAIgnorePref:sha' in task
    assert 'downloader.progress.totalUnitCount = downloads.count' not in curse
    assert 'downloader.progress.completedUnitCount = 1' in curse


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
