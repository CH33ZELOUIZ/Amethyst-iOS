# Amethyst Duo — UI/feature audit and polished private developer build spec

Audited: /home/jeffrey/duo/src (branch duo-optimized, 2026-11-17). Read-only audit; no code changed.
Note: working tree has uncommitted edits (LauncherNavigationController.m, MinecraftResourceDownloadTask.[hm], OfflineModpackImporter.m). Line numbers refer to the tree as audited. Static review only: nothing was built or run on a device.

## 1. Current inventory

### Navigation shell
- LauncherSplitViewController.m:48-63: sidebar (LauncherMenuViewController) + content nav (LauncherNavigationController). `general.hidden_sidebar` defaults to YES on iPhone (PLPreferences.m:82), so on iPhone the sidebar is hidden and reachable only via the displayModeButton. Discoverability problem: every feature below sits behind it.
- Sidebar rows (LauncherMenuViewController.m:67-131), flat and unsectioned:
  1. News (LauncherNewsViewController)
  2. Profiles
  3. Settings
  4. Mods/Content search (ModrinthModsViewController, titled via content.title.*, icon magnifyingglass)
  5. Resource packs
  6. Shader packs
  7. Worlds (AMWorldsViewController)
  8. Screenshots
  9. Files hub
  10. "Modpacks": a modal action, not a screen (:78-84). It presents ModpackInstallViewController in a UINavigationController.
  11. Custom controls (non-tvOS): enterCustomControls
  12. Execute .jar (enterModInstaller)
  13. "Send your logs"
  14. Easter-egg row 06-29..07-01
- Startup selects row index 1 (hard-coded Profiles) at :150-153.
- Toolbar (bottom): version picker (PickTextField), Play/Details button, progress bar, status text (LauncherNavigationController.m:45-110). A JIT status label also lives in the sidebar toolbar (:135-143, displayProgress:).
- Account button, top right: popover AccountListViewController (350x250) at :263-289.

### Flows
- Vanilla install/launch: pick a profile in the toolbar picker, then Play. launchMinecraft (LauncherNavigationController.m:282) downloads the version via MinecraftResourceDownloadTask. Progress goes to the toolbar bar and text; tapping Details opens DownloadProgressViewController as a popover (:328-352). JIT is then handled by invokeAfterJITEnabled (:465-517).
- Profiles (LauncherProfilesViewController.m): section "Instance" has game directory (pushes LauncherPrefGameDirViewController) and a separate-preferences switch. Section "Profiles" lists every profile flat from `profiles.allValues` (:178-187). That is dictionary order, so ordering is not guaranteed stable. "+" menu: Vanilla / Fabric-Quilt / Forge / Modpack (:43-85). The OptiFine entry is `#if 0`. Tapping a row opens LauncherProfileEditorViewController. Swipe-delete exists, with a confirm that reuses the "delete runtime" string.
- Modpack import (ModpackInstallViewController.m):
  - Modrinth browse is the default. The CurseForge segment is disabled until a key is configured (:36-47,:57-60). There is no hint on the control about why it is disabled.
  - Left bar button "Import Pack" opens an action sheet with .mrpack/.zip found in Documents and Documents/modpacks, plus "Choose from Files..." (:113-170).
  - Format detection: private Duo offline ZIP (OfflineModpackImporter isOfflinePackAtPath), else packFormatForArchiveAtPath (curseforge or modrinth).
  - Offline packs get a RAM gate and an "I understand — Import" alert (:79-98). Hard-coded English; blocked packs are deleted.
  - Posts the "InstallModpack" notification. LauncherNavigationController receiveNotification (:402-444) shows phase text in the toolbar. The phase/progress plumbing is new and uncommitted.
  - The offline-pack import path never dismisses the modal. The non-offline picker path posts the notification but leaves the modal presented; only importLocalMrpackAtPath dismisses it, after 0.5 s (:~118-121). User sees import progress only after manually closing the modal, and on iPhone the toolbar is behind the modal.
- Result of an offline import: OfflineModpackImporter.publishStaging (OfflineModpackImporter.m:291-335) writes a profile into custom_gamedir/<name>, selected immediately. There is no record of "installed pack" beyond a normal profile. Imported/installed packs cannot be separated from ordinary profiles; the profile dict has no pack marker or source field.
- CurseForge key: Settings > General > curseforge_api_key (LauncherPreferencesViewController.m:56-58, editCurseForgeKey at :486+). Secure text alert, with a Remove option. Key storage is in CurseForgeAPI.m:25-55. Posts CurseForgeConfigurationDidChange. The ModrinthMods screen also has a provider toggle.
- Account: AccountListViewController popover. Demo mode switches GAME_DIR to .demo (updateAccountInfo :291-357). An "erase demo data" button is in Settings.
- Files/screenshots/worlds (tools/AMTools.m): Files hub with 12 shortcuts (:748-765): game folder, mods, config, resourcepacks, shaderpacks, saves, logs, crash-reports, screenshots, options.txt, Amethyst folder, Backups. Full file browser (copy/move/zip/extract/rename/import/share), text editor, image viewer. Worlds: backup and import zip. Screenshots: collection view with context menu.
- Custom controls: enterCustomControls (LauncherNavigationController.m:223), plus default gamepad control pane (LauncherPrefContCfgViewController).
- Execute JAR: enterModInstaller (:235-260).
- JIT: startup check with toolbar text (LauncherMenuViewController.m:155-176); AltKit on <17; invokeAfterJITEnabled on launch picks TrollStore / StikJIT / SideStore, with a polling alert.
- Renderer: Settings > Video > renderer (picker) plus per-profile renderer override in the profile editor (:113). MobileGL, MoltenVK and Zink toggles are in Settings.
- Java/RAM: Settings > Java: manage runtime (LauncherPrefManageJREViewController), java_args, env_variables, auto_ram, allocated_memory (LauncherPreferencesViewController.m ~:276-310). Profile editor also has javaArgs and a Java version override (:136-143).
- Diagnostics: see Privacy section. Only a debug_logging switch, an in-game log overlay (PLLogOutputView), and "Send your logs".

### Settings inventory (LauncherPreferencesViewController.m:44-345)
General: curseforge_api_key (button), check_sha, cosmetica, debug_logging, appicon, hidden_sidebar, reset_warnings, reset_settings, erase_demo_data.
Video: renderer, resolution, max_framerate, performance_hud, mobilegl_fast_shader_load, mobilegl_buffer_compat, mobilegl_relaxed, moltenvk_fast_math, moltenvk_argument_buffers, moltenvk_smooth_scaling, fullscreen_airplay, silence_other_audio, silence_with_switch, allow_microphone.
Control: default_gamepad_ctrl (child pane), hardware_hide, recording_hide, gesture_mouse, gesture_hotbar, disable_haptics, slideable_hotbar, press_duration, button_scale, mouse_scale, mouse_speed, virtmouse_enable, gyroscope_enable/invert/sensitivity.
Java: manage_runtime, java_args, env_variables, auto_ram, allocated_memory.
Debug: debug_always_attached_jit, debug_skip_wait_jit, debug_hide_home_indicator, debug_ipad_ui, debug_auto_correction.
Settings are a flat list in 5 sections. Many rows are greyed with no explanation (`enableCondition` returns NO: whenNotInGame, MobileGL options for non-matching renderers, max_framerate on 60Hz, performance_hud without developerHUDProperties, always_attached_jit without TXM, appicon on unsupported).

## 2. Defects: dead / no-op / missing controls (code locations)

D1. Dead pref key typo: SurfaceViewController.m:267 reads `controll.hardware_hide`; always false, so the controls are not un-hidden when a hardware mouse disconnects. Lines 284/292/842 use the correct key. Fix: one-character change.
D2. `collectDiagnosticReportItems` (LauncherMenuViewController.m:391-448) has zero callers. It builds a diagnostics bundle (logs, hs_err, device/renderer info) but is never invoked. "Send your logs" (:99-120) instead shares raw latestlog.old.txt as an NSURL with no redaction, no preview, no consent text. The in-game PLLogOutputView actionShareLatestlog (:106-111) shares raw latestlog.txt, and long-press line share shares raw lines.
D3. The "Send your logs" action silently shares a file that may not exist (latestlog.old.txt only exists after a previous session) and fails with an empty share sheet; no feedback.
D4. The JIT wait alert has no cancel/escape (LauncherNavigationController.m:~500-510 commented TODO). User is trapped waiting indefinitely if JIT never arrives; only `debug_skip_wait_jit` bypasses it.
D5. Hidden-sidebar default on iPhone hides everything; there is no bottom tab bar, no home screen, and "Modpacks" is only a modal row.
D6. The "Modpacks" row (LauncherMenuViewController.m:78-84) is an action item with no selected state, no history, and no installed list.
D7. Import progress is invisible while the import modal is up (see flows) and the offline confirm alert hard-fails (deletes the user's file) on a RAM shortfall (ModpackInstallViewController.m:~85-90); the error says "Do not import" but offers no path to raise RAM (the Settings link is absent).
D8. CurseForge segment is disabled with no explanation (ModpackInstallViewController.m:~43-47); there is no deep link to the key field. Imported CurseForge ZIPs without a key fail only after pick.
D9. Profile list order unstable (LauncherProfilesViewController.m:178 `allValues[row]`); the swipe-delete confirm uses the "runtime" wording; deleting an imported pack profile does not remove custom_gamedir/<name> (data orphaned; unverified, needs runtime test).
D10. Hard-coded, unlocalized English in the new Duo paths (ModpackInstallViewController.m: "Import Pack", "Experimental private pack", etc.; LauncherNavigationController.m phase strings; AMTools.m "Worlds", "Screenshots", "Files"). Mixed with localize() elsewhere.
D11. Settings rows that are disabled without a reason string (see above); `debug_ipad_ui` and `debug_auto_correction` are developer toggles mixed with end-user settings.
D12. Mods search row (ModrinthModsViewController) and resource/shader tabs have the same title/icon pattern; the Modrinth provider toggle can be CurseForge, but sidebar title says only "Mods".
D13. "Technoblade never dies!" seasonal row has an empty imageName; harmless but off-brand for a private build.
D14. Version text field placeholder "Specify version..." (LauncherNavigationController.m:~64) is shown when the profile is blank; it is really a profile picker.
D15. Upstream: `OptiFine` profile type is `#if 0` (LauncherProfilesViewController.m:~55): honestly absent but untracked in UI.

## 3. Proposed iPhone Duo screen architecture

Replace the hidden sidebar with a UITabBarController (5 tabs) on iPhone; keep split view on iPad.

1. Play (home): selected profile card (icon, name, MC version, loader, RAM/renderer summary), account chip, JIT status chip (tap = JIT detail sheet), big Play button, inline import/download progress card (phase, %, speed, ETA, cancel, "Details"). Replaces toolbar-only progress.
2. Packs (new, dedicated "Installed & imported modpacks" section): list of installed packs (source badge: Offline private / Modrinth / CurseForge; MC version, loader, size, RAM minimum, installed date), per-pack actions: Play/select, Open folder, Edit profile, Delete (removes custom_gamedir and profile, confirmed). Header actions: Import pack, Browse Modrinth, Browse CurseForge (disabled with "Add API key" link). Active imports pinned at top with live phase/progress. Requires a pack-marker in profile dict (`duoPack: {source, version, installedAt}`), written in OfflineModpackImporter.publishStaging and the Modrinth/CurseForge installers.
3. Library (Browse): segmented Mods / Resource packs / Shaders / Worlds / Screenshots (existing VCs reused).
4. Files: existing Files hub (moves 'Mods/Config/Logs/Crash reports' shortcuts here) plus Custom controls entry and Execute .jar under a "Tools" section.
5. Settings (grouped, searchable): Account & Profiles, Game (Java/RAM/flags), Graphics & Renderer, Controls, Content (CurseForge key with status "configured/not configured"), Launcher (sidebar, app icon, resets), Developer (hidden behind explicit "Developer mode" switch), Diagnostics. Each disabled row shows a footer reason.

Navigation rules: no modal-only primary features; every modal has Close; import is non-blocking (dismiss immediately, progress on Play and Packs); back-stack preserved per tab.

### Diagnostics screen (Settings > Diagnostics)
Status panel: app version/commit (config.h), device/OS, install type (AME_DETECTEDINST), JIT state (isJITEnabled + method: TrollStore/StikJIT/SideStore/AltKit), renderer (global + per-profile resolved), Java runtime + version, RAM (allocated vs physical, auto), CurseForge key present (boolean only), GAME_DIR, free space, last crash tracker state (RendererCrashTracker).

## 4. Privacy-safe developer log support (requirements and design)

Requirements: opt-in, manual, redacted, scoped to this private build, no auto-upload.
Design:
- Compile-gate: `#if DUO_PRIVATE_BUILD` (or runtime check of a CONFIG_TYPE flag) so the feature does not exist in a public build.
- Settings > Diagnostics > "Developer log export" row, off by default; first use shows a consent sheet explaining what is included.
- Export is a user-initiated button: builds a bundle in NSTemporaryDirectory (revive collectDiagnosticReportItems as the base), runs a redactor, shows a preview screen (text view) of exactly what will be shared, then presents UIActivityViewController. The user chooses the destination. No network code, no background upload, no scheduled export.
- Redaction pass (unit-testable pure function): strip Microsoft/Minecraft access tokens and JWT-like strings, `x-api-key`/CurseForge key values, usernames/UUIDs (hash or mask), email addresses, home-directory absolute paths (`/var/mobile/Containers/...` to `<home>`), IPs, Xbox gamertags, `--accessToken`, `--uuid`, `--username` launch args and any `java.args` env values. Cap size (e.g. 2 MB tail) and cap hs_err files at 3 (already in :426).
- Delete the temp bundle after the share sheet completes.
- Remove raw-share paths: LauncherMenuViewController.m:99-120 and PLLogOutputView.m:106-111/78-90 must route through the same redactor, or be removed/disabled in the Duo build.
- debug_logging: relabel as "Verbose logging (slower)"; session-scoped hint that logs stay on device.
- Acceptance tests: fixture log containing fake tokens/paths/emails/key must export with none of them; grep for URLSession/AFNetworking in the diagnostics module returns nothing.

## 5. Acceptance matrix (iPhone Duo)

| Area | Criterion | Pass condition |
|---|---|---|
| Navigation | All features reachable in <=2 taps from tab bar on iPhone SE-size and Pro Max | tab bar visible; no hidden sidebar dependency |
| Dead controls | Every button/row/switch performs an action or shows a reason it is unavailable | no silent no-op; footers on disabled rows |
| Vanilla | Create vanilla profile, Play, download progress visible, game launches | progress card shows %, phase, speed, ETA; Details works |
| Profiles | Edit/rename/delete profile; stable ordering | sorted deterministic list; delete confirm wording correct |
| Offline pack | Import private ZIP from Files and Documents | progress card live through preflight/checksum/extract/NeoForge install/save; failure shows reason; success appears in Packs tab |
| Packs section | Shows all installed/imported packs with source, MC, loader | delete removes pack data and profile |
| Online packs | Modrinth install works; CurseForge disabled with explanation until key set | segment tap deep-links to key entry |
| CurseForge key | Save, status shown, remove | key never displayed or logged |
| Files | Browse, import, share, edit options.txt, screenshots, worlds backup | all 12 shortcuts open |
| Custom controls | Editor opens from Files/Tools; changes persist | save/reload verified |
| JIT | Status chip reflects real state; wait alert has Cancel | cancel returns to Play without hang |
| Renderer | Global + per-profile picker; unavailable options explain why | resolved renderer shown in Diagnostics |
| Java/RAM | JRE manager, flags, auto/manual RAM with warnings | matches launched args (verify in log) |
| Account | Add/select/delete, demo mode | chip updates everywhere |
| Diagnostics | Status page accurate; export manual, redacted, previewed | redaction tests pass; no network calls |
| Localization | No hard-coded English in new strings | localize() or documented exception |
| Unsupported | Honest labels: OptiFine, TV-only features, MobileGL/Zink options on wrong renderer | "Not supported" text, not hidden |

## 6. Split: current-app UI work vs upstream/backend work

Current-app UI work (this repo, Objective-C UIKit):
- Tab bar shell, Play home, Packs tab, import progress card, Settings regroup/search/footers, Diagnostics screen, redactor, string localization, typo fix D1, JIT cancel D4, deterministic profile sort D9, deep link to CurseForge key.
- Pack metadata marker in profile dict (Duo-owned format; small backend change but within app).

Upstream/backend/needs runtime verification:
- Real NeoForge 1.21.1 playability for Integrated Boogaloo (see earlier task t_cba0004e: NO-GO to claim playable); UI should label "Experimental".
- JIT automation (StikJIT/SideStore URL schemes, iOS 26 TXM) is OS/ecosystem dependent.
- Renderer correctness/perf (MobileGL, Zink, KosmicKrisp) and memory limits on iPhone.
- CurseForge third-party download restrictions (API key + distribution flags).
- OptiFine profiles (stubbed upstream).
- Pack-delete cleanup of shared libraries/versions installed into GAME_DIR (publishInstallerLibrariesFrom writes shared files; needs ownership tracking so delete does not break other packs).

## 7. Prioritized implementation slices

S0 (small fixes, ~1 day): D1 typo; D2 stop raw log share in Duo build (disable row or route to placeholder); D3 file-missing feedback; D4 JIT Cancel; D9 sort profiles.
S1 (import visibility): dismiss import modal immediately; Play-screen progress card bound to MinecraftResourceDownloadTask (phase/progress/cancel); persist last import result. Files: ModpackInstallViewController.m, LauncherNavigationController.m, DownloadProgressViewController.m.
S2 (Packs tab): pack marker in profiles, Packs list VC, delete-with-cleanup. Files: OfflineModpackImporter.m:325-335, PLProfiles.m, new PacksViewController, LauncherMenuViewController.m.
S3 (navigation shell): UITabBarController on iPhone; Play home; reorganize sidebar rows into tabs; keep split view for iPad.
S4 (settings polish): grouped IA, search, disabled-row reasons, Developer section gate, CurseForge key status row and deep link.
S5 (diagnostics + redacted export): status page; redactor with tests; consent + preview; remove raw shares.
S6 (localization and honest labels): replace hard-coded strings; "Experimental"/"Unsupported" labelling; remove seasonal row.
S7 (device QA pass against the matrix above, on a real iPhone with JIT).

Suggested ordering: S0, S1, S5 (privacy), S2, S3, S4, S6, S7.

Confidence: high on code locations and defects D1-D8 (read directly); medium on D9 delete-orphaning and D7 UX impact (static reading, not run); nothing was executed on a device.

## 8. Implementation status (t_8f7ab1ce)

Done in source (Objective-C not compiled on this host; no iOS SDK): S0 (D1, D2, D3, D4, D9), S1 (non-blocking import sheet, persisted last result), S2 (Packs screen + pack marker + path-confined delete), S5 (pure-C redactor with tests, private-build-gated Diagnostics, preview + Share Sheet, raw shares removed), D7, D8, D13, partial S6 (new strings localized).
Not done: S3 tab bar / Play home card, S4 Settings regroup/search/Developer gate, remaining hard-coded strings in AMTools.m and phase strings, S7 device QA. Diagnostics is a sidebar row in private builds, not yet under Settings.
