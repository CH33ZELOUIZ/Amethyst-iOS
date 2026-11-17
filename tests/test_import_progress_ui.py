#!/usr/bin/env python3
"""Static behavioral checks: progress observer ordering and main-queue UI delivery for imports."""
from pathlib import Path
import re

ROOT = Path(__file__).parents[1]


def source(path):
    return (ROOT / path).read_text()


def method_body(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for i in range(brace, len(text)):
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        if depth == 0:
            return text[brace:i + 1]
    raise AssertionError("unbalanced braces")


def test_observer_attached_before_background_import_starts():
    body = method_body(source("Natives/LauncherNavigationController.m"), "- (void)receiveNotification:")
    prepare = body.index("prepareProgressForObservation")
    attach = body.index("attachProgressObserverForTask:task")
    background = body.index("dispatch_get_global_queue")
    install = body.index("installModpackFromLocalFile")
    assert prepare < attach < background < install
    assert "NSThread.isMainThread" in body  # entry hops to main before touching UIKit


def test_old_post_import_observer_is_gone():
    body = method_body(source("Natives/LauncherNavigationController.m"), "- (void)receiveNotification:")
    assert body.count("addObserver:") == 0  # only attachProgressObserverForTask adds it
    attach = method_body(source("Natives/LauncherNavigationController.m"), "- (void)attachProgressObserverForTask:")
    assert "addObserver:self" in attach and "isMainThread" in attach


def test_prepare_does_not_replace_observed_progress():
    task = source("Natives/MinecraftResourceDownloadTask.m")
    body = method_body(task, "- (void)prepareForDownload")
    assert body.index("progressPrepared") < body.index("self.progress = [NSProgress new]")
    assert "return;" in body[:body.index("self.progress = [NSProgress new]")]


def test_errors_and_dialogs_delivered_on_main_queue():
    body = method_body(source("Natives/MinecraftResourceDownloadTask.m"), "- (void)finishDownloadWithErrorString:")
    main = body.index("dispatch_async(dispatch_get_main_queue()")
    assert body.index("showDialog") > main
    assert body.index("handler()") > main
    assert "self.handleError()" not in body
    assert "[self.progress cancel]" in body  # cancellation still stops the worker


def test_error_handler_resets_ui_and_observer():
    body = method_body(source("Natives/LauncherNavigationController.m"), "- (void)receiveNotification:")
    handler = body[body.index("task.handleError"):body.index("task.phaseHandler")]
    for needle in ("detachProgressObserver", "observedProgress = nil", "setInteractionEnabled:YES", "self.task = nil", "progressVC = nil"):
        assert needle.replace("self.", "strongSelf.") in handler or needle in handler, needle


def test_success_path_detaches_observer():
    text = source("Natives/LauncherNavigationController.m")
    body = method_body(text, "- (void)observeValueForKeyPath:")
    assert body.index("detachProgressObserver") > body.index("if (!progress.finished) return;")


def test_phase_reports_cover_all_stages_in_order():
    imp = source("Natives/installer/modpack/OfflineModpackImporter.m")
    imp_body = method_body(imp, "+ (void)importPackAtPath:")
    publish_body = method_body(imp, "+ (void)publishStaging:")
    for body, markers in ((imp_body, ["ZIP preflight", "Reading manifest and checksums", "Checking free space", "Extracting and verifying", "preparing NeoForge"]),
                          (publish_body, ["Installing NeoForge", "publishing transactionally", "Saving profile"])):
        positions = [body.index(m) for m in markers]
        assert positions == sorted(positions)
    view = source("Natives/installer/ModpackInstallViewController.m")
    assert "Copying selected pack from Files/iCloud" in view


def test_profile_visible_only_after_publish_and_save():
    imp = source("Natives/installer/modpack/OfflineModpackImporter.m")
    body = method_body(imp, "+ (void)publishStaging:")
    assert body.index("Saving profile") < body.index("profiles.profiles[profileName] =")
    assert body.index("moveItemAtPath:staging") < body.index("profiles.profiles[profileName] =")
    assert re.search(r"\[downloader finishDownloadWithSuccess\]", body)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
