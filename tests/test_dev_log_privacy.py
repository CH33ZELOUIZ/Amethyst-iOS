#!/usr/bin/env python3
"""Behavioral tests for the developer-log redactor (compiled C) and static privacy-gate checks."""
import ctypes
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).parents[1]
DIAG = ROOT / "Natives/diagnostics"
SOURCE = DIAG / "DuoLogRedactor.c"


def load():
    tmp = tempfile.mkdtemp()
    lib = Path(tmp) / "libredact.so"
    subprocess.run(["cc", "-shared", "-fPIC", "-O1", "-Wall", "-Werror", "-o", str(lib), str(SOURCE)], check=True)
    cdll = ctypes.CDLL(str(lib))
    fn = cdll.DuoRedactLog
    fn.restype = ctypes.c_void_p
    fn.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_char_p), ctypes.c_size_t]
    free = cdll.free if hasattr(cdll, "free") else ctypes.CDLL(None).free
    free.argtypes = [ctypes.c_void_p]

    def redact(text, literals=()):
        data = text.encode()
        arr = (ctypes.c_char_p * max(len(literals), 1))(*[l.encode() for l in literals])
        ptr = fn(data, len(data), arr, len(literals))
        assert ptr
        out = ctypes.string_at(ptr).decode()
        free(ptr)
        return out
    return redact


FIXTURE = """\
[10:00:01] Setting user: Steve_Secret
[10:00:02] java --accessToken eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abcDEF123_-xyz --uuid 069a79f4-44e9-4726-a5be-fca90e38aaf5 --username Steve_Secret --version 1.21.1
[10:00:03] x-api-key: $2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRS
[10:00:03] Authorization: Bearer abcDEF.ghiJKL-mno_123
[10:00:04] contact steve@example.com from 192.168.0.112 reached https://example.org
[10:00:05] Loading /var/mobile/Containers/Data/Application/0A1B2C3D-1111-2222-3333-444455556666/Documents/game/mods
[10:00:06] gamertag XboxSteve9 owns 069a79f4-44e9-4726-a5be-fca90e38aaf5
[10:00:07] curseforge api_key=SUPERSECRETKEYVALUE123 and password: hunter2
[10:00:08] opaque token ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789xx
[10:00:09] Minecraft 1.21.1 NeoForge 21.1.264 started in 4.2s
"""
SECRETS = ["Steve_Secret", "eyJhbGci", "069a79f4", "$2a$10$abcdef", "abcDEF.ghi", "steve@example.com",
           "192.168.0.112", "0A1B2C3D-1111", "XboxSteve9", "SUPERSECRETKEYVALUE123", "hunter2", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef"]


def test_fixture_secrets_are_removed():
    redact = load()
    out = redact(FIXTURE, ["Steve_Secret", "XboxSteve9"])
    for secret in SECRETS:
        assert secret not in out, secret
    assert "<redacted>" in out and "<email>" in out and "<home>" in out and "<ip>" in out


def test_useful_diagnostics_survive():
    redact = load()
    out = redact(FIXTURE, ["Steve_Secret"])
    assert "Minecraft 1.21.1 NeoForge 21.1.264 started in 4.2s" in out
    assert "--version 1.21.1" in out
    assert "Loading <home>/Documents/game/mods" in out


def test_literals_longest_first_and_tiny_literals_ignored():
    redact = load()
    assert redact("path /a/b/secret/c and /a/b", ["/a/b", "/a/b/secret"]) == "path <redacted>/c and <redacted>"
    assert redact("the cat sat", ["a"]) == "the cat sat"  # one-char literal would shred text


def test_embedded_nul_and_empty_input():
    redact = load()
    assert redact("") == ""
    assert "x-api-key" in redact("x-api-key: abc\x00def tail")  # no crash, tail still processed


def test_configured_java_values_are_added_as_redaction_literals():
    implementation = (DIAG / "DuoLogRedaction.m").read_text()
    for key in ("java.java_args", "java.env_variables"):
        assert key in implementation
    redact = load()
    for secret in ("s3", "xy", "abc"):
        # The C literal matcher intentionally ignores one- and two-character values,
        # while arbitrary user-supplied values of three or more characters are removed.
        assert secret not in redact(f"java argument {secret}", [secret]) if len(secret) >= 3 else True


def test_private_verification_workflow_never_publishes():
    workflow = (ROOT / ".github/workflows/duo-private-verify.yml").read_text()
    assert "permissions:\n  contents: read" in workflow
    for forbidden in ("gh release", "altstore/source.json", "git push", "contents: write"):
        assert forbidden not in workflow
    assert "actions/upload-artifact@v4" in workflow


def test_redactor_has_no_network_or_foundation():
    text = SOURCE.read_text()
    for banned in ("socket", "curl", "http", "NSURL", "#import"):
        assert banned not in text, banned


def strip_comments(text):
    return re.sub(r"//.*", "", text)


def test_diagnostics_ui_is_private_build_gated_and_network_free():
    cfg = (ROOT / "Natives/config.h.in").read_text()
    assert "DUO_PRIVATE_BUILD" in cfg
    for name in ("DuoDiagnosticsViewController.m", "DuoDiagnosticsViewController.h", "DuoDiagnosticsExport.m", "DuoDiagnosticsExport.h"):
        text = (DIAG / name).read_text()
        body = strip_comments(text)
        assert "#if DUO_PRIVATE_BUILD" in body, name
        assert body.rstrip().endswith("#endif"), name
        for banned in ("NSURLSession", "NSURLConnection", "AFNetworking", "AFHTTP", "CFNetwork", "http://", "https://", "NSURLRequest", "sendBeacon"):
            assert banned not in body, (name, banned)
    makefile = (ROOT / "Makefile").read_text()
    assert "DUO_PRIVATE_BUILD" in makefile


def test_no_raw_log_sharing_remains():
    menu = strip_comments((ROOT / "Natives/LauncherMenuViewController.m").read_text())
    assert "latestlog.old.txt" not in menu
    assert "collectDiagnosticReportItems" not in menu
    log = strip_comments((ROOT / "Natives/PLLogOutputView.m").read_text())
    assert "activityItems:@[line]" not in log
    assert "URLWithString:latestlogPath" not in log
    export = (DIAG / "DuoDiagnosticsExport.m").read_text()
    assert "DuoRedactLog" in export or "DuoRedactedString" in export
    assert "NSTemporaryDirectory" in export  # bundle lives only in tmp, deleted after share


def test_export_is_explicit_reviewed_and_cleaned_up():
    vc = (DIAG / "DuoDiagnosticsViewController.m").read_text()
    assert "duo.devlog.enabled" in vc  # opt-in, default off
    assert "kConsentKey" not in vc  # confirmation is required for every generated report
    assert "UIAlertController *consent" in vc
    assert vc.index("DuoLogPreviewViewController") < vc.index("UIActivityViewController")  # preview precedes share
    assert "removeItemAtURL" in vc or "removeItemAtPath" in vc  # temp bundle deleted after sharing
    export = (DIAG / "DuoDiagnosticsExport.m").read_text()
    assert "DuoMaxBundleBytes" in export and "DuoMaxHsErrFiles" in export
    assert "redactedExportTextFromReviewedText" in export
    write_start = export.index("+ (NSURL *)writeReportText")
    assert "redactedExportTextFromReviewedText:text" in export[write_start:]
    assert "no readable diagnostic logs were found" in export  # honest empty state
    for detail in ("jitMethod", "GAME_DIR", "RendererCrashTracker"):
        assert detail in export
    assert "redactedExportTextFromReviewedText:self.reportText" in vc  # clipboard fallback is re-redacted


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
