#!/usr/bin/env python3
"""Static validation for the Duo private-developer UX: routing, packs persistence, sheet, JIT cancel, ordering."""
from pathlib import Path
import re

ROOT = Path(__file__).parents[1]


def src(path):
    return (ROOT / path).read_text()


def body(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[brace:i + 1]
    raise AssertionError("unbalanced braces")


def test_menu_routes_packs_and_gates_diagnostics():
    menu = src("Natives/LauncherMenuViewController.m")
    assert "DuoPacksViewController.class" in menu
    start = menu.index("#if DUO_PRIVATE_BUILD")
    assert start < menu.index("DuoDiagnosticsViewController.class") < menu.index("#endif", start)
    assert "Technoblade" not in menu and "login.menu.sendlogs" not in menu


def test_all_new_sources_are_in_cmake():
    cmake = src("Natives/CMakeLists.txt")
    for f in ("diagnostics/DuoLogRedactor.c", "diagnostics/DuoLogRedaction.m", "diagnostics/DuoDiagnosticsExport.m",
              "diagnostics/DuoDiagnosticsViewController.m", "packs/DuoPackLibrary.m", "packs/DuoPacksViewController.m",
              "packs/DuoImportProgressViewController.m"):
        assert f in cmake, f
        assert (ROOT / "Natives" / f).exists(), f


def test_import_sheet_after_observer_before_background_work():
    text = src("Natives/LauncherNavigationController.m")
    b = body(text, "- (void)receiveNotification:")
    assert b.index("attachProgressObserverForTask:task") < b.index("presentImportSheetForTask") < b.index("dispatch_get_global_queue")
    assert "isMainThread" in body(text, "- (void)presentImportSheetForTask:")
    sheet = src("Natives/packs/DuoImportProgressViewController.m")
    assert "actionHide" in sheet and "[self.task cancel]" in sheet and "NSTimer" in sheet and "invalidate" in sheet


def test_error_and_success_paths_dismiss_sheet_and_persist_result():
    text = src("Natives/LauncherNavigationController.m")
    handler = body(text, "- (void)receiveNotification:")
    err = handler[handler.index("task.handleError"):handler.index("task.phaseHandler")]
    assert "dismissImportSheet" in err and "recordImportResult:NO" in err
    obs = body(text, "- (void)observeValueForKeyPath:")
    assert "dismissImportSheet" in obs and "recordImportResult:YES" in obs


def test_pack_marker_written_by_all_importers_and_listed():
    for f, source in (("Natives/installer/modpack/OfflineModpackImporter.m", "offline"),
                      ("Natives/installer/modpack/CurseForgeAPI.m", "curseforge"),
                      ("Natives/installer/modpack/ModrinthAPI.m", "modrinth")):
        text = src(f)
        assert "markProfile" in text and f'source:@"{source}"' in text, f
    lib = src("Natives/packs/DuoPackLibrary.m")
    assert "duoPackSource" in lib and "./custom_gamedir/" in lib and "caseInsensitiveCompare" in lib


def test_offline_profile_mutation_is_main_thread_owned_and_extraction_checks_cancel():
    importer = src("Natives/installer/modpack/OfflineModpackImporter.m")
    publish = body(importer, "+ (void)publishStaging:")
    assert "dispatch_sync(dispatch_get_main_queue()" in publish
    assert "profileAlreadyExists" in publish and "profileSaved" in publish
    extract = body(importer, "+ (BOOL)extractArchive:")
    assert "progress.cancelled" in extract
    import_body = body(importer, "+ (void)importPackAtPath:")
    assert import_body.count("downloader.progress.cancelled") >= 3


def test_pack_removal_is_path_confined_and_io_off_main():
    lib = src("Natives/packs/DuoPackLibrary.m")
    safe = body(lib, "+ (NSString *)safeAbsoluteDirForRelative:")
    for guard in ('@"/"', '@".."', 'hasPrefix:@"."'):
        assert guard in safe, guard
    vc = src("Natives/packs/DuoPacksViewController.m")
    remove = body(vc, "- (void)confirmRemove:")
    assert remove.index("dispatch_get_global_queue") < remove.index("quarantinePackFolder") < remove.index("dispatch_get_main_queue") < remove.index("removePackProfile")
    assert "canRemovePackProfile" in remove
    assert "restoreQuarantinedPackFolder" in remove and "deleteQuarantinedPackFolder" in remove
    reload = body(vc, "- (void)reload")
    assert "dispatch_get_global_queue" in reload and "storageBytesForPack" in reload and "reloadGeneration" in reload


def test_profile_order_deterministic():
    for f in ("Natives/LauncherProfilesViewController.m", "Natives/LauncherNavigationController.m"):
        assert "profiles.allValues[" not in src(f), f
    assert "sortedProfileNames" in src("Natives/PLProfiles.m")


def test_defects_d1_d4_fixed():
    assert "controll.hardware_hide" not in src("Natives/SurfaceViewController.m")
    nav = src("Natives/LauncherNavigationController.m")
    jit = nav[nav.index("launcher.wait_jit.title"):]
    assert "waitCancelled" in jit and "UIAlertActionStyleCancel" in jit
    assert jit.count("@synchronized (self)") >= 3


def test_cancel_finalizes_once_and_keeps_ram_rejected_archive():
    task = src("Natives/MinecraftResourceDownloadTask.m")
    cancel = body(task, "- (void)cancel")
    failed = body(task, "- (void)finishDownloadWithErrorString:")
    success = body(task, "- (void)finishDownloadWithSuccess")
    assert "finishDownloadWithErrorString" in cancel
    assert "invalidateSessionCancelingTasks:YES" in failed
    assert "@synchronized (self)" in failed and "@synchronized (self)" in success
    install = body(src("Natives/installer/ModpackInstallViewController.m"), "- (void)confirmOfflineImportAtPath:")
    rejected = install[install.index("if (!requirements"):install.index("UIAlertController", install.index("if (!requirements"))]
    assert "removeItemAtPath:path" not in rejected


def test_new_strings_exist_and_english_removed_from_flows():
    view = src("Natives/installer/ModpackInstallViewController.m")
    assert "Private pack blocked" not in view
    strings = src("Natives/resources/en.lproj/Localizable.strings")
    used = set()
    for f in (ROOT / "Natives").rglob("*.m"):
        used |= set(re.findall(r'localize\(@"(duo\.[A-Za-z0-9_.]+)"', f.read_text()))
    keys = set(re.findall(r'^"([^"]+)"\s*=', strings, re.M))
    missing = sorted(k for k in used if k not in keys)
    assert not missing, missing
    assert {"Share", "Error", "Remove"} <= keys


def test_settings_exposes_accounts_files_import_and_capability_hints():
    settings = src("Natives/LauncherPreferencesViewController.m")
    for section in ("accounts", "general", "video", "control", "java", "files", "debug"):
        assert f'@"{section}"' in settings
    for controller in ("AccountListViewController.class", "AMFilesHubViewController.class",
                       "AMScreenshotsViewController.class", "ModpackInstallViewController.class"):
        assert controller in settings
    assert "CurseForgeAPI setAPIKey" in settings
    assert "UISearchController" in settings and "updateSearchResultsForSearchController" in settings
    table = src("Natives/PLPrefTableViewController.m")
    assert "disabledReason" in table and "accessibilityHint" in table


def test_menu_destinations_are_accessible_on_compact_navigation():
    menu = src("Natives/LauncherMenuViewController.m")
    for controller in ("LauncherProfilesViewController.class", "DuoPacksViewController.class",
                       "LauncherPreferencesViewController.class"):
        assert controller in menu
    assert "displayModeButtonItem" in menu
    assert "accessibilityLabel" in menu and "duo.navigation.open" in menu


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
