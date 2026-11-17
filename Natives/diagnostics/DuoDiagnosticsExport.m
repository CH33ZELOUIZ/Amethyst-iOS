#import "DuoDiagnosticsExport.h"

#if DUO_PRIVATE_BUILD

#import "DuoLogRedaction.h"
#import "HostManagerBridge.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "RendererCrashTracker.h"
#import "UIKit+hook.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "utils.h"
#import <UIKit/UIKit.h>

const NSUInteger DuoMaxBundleBytes = 2 * 1024 * 1024;
const NSUInteger DuoMaxHsErrFiles = 3;
static const NSUInteger kLatestLogTail = 700 * 1024, kOldLogTail = 400 * 1024, kMobileGLTail = 100 * 1024, kHsErrTail = 150 * 1024;

@implementation DuoDiagnosticsExport

+ (NSString *)jitState {
    if (isJITEnabled(false)) return localize(@"duo.diag.jit.enabled", nil);
    return localize(@"duo.diag.jit.disabled", nil);
}

+ (NSString *)jitMethod {
    if (getEntitlementValue(@"dynamic-codesigning")) return @"dynamic-codesigning entitlement";
    if (isJailbroken) return @"jailbreak";
    if (getEntitlementValue(@"com.apple.private.security.no-sandbox")) return @"PT_TRACE_ME";
    if (getEntitlementValue(@"jb.pmap_cs.custom_trust")) return @"TrollStore";
    if (isJITEnabled(false)) return @"attached debugger";
    if (@available(iOS 17.4, *)) return @"StikDebug when launching";
    return @"SideStore when launching";
}

+ (NSArray<NSArray<NSString *> *> *)statusRows {
    NSMutableArray *rows = [NSMutableArray new];
    void (^add)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        [rows addObject:@[localize(key, nil), value.length ? value : @"-"]];
    };
    add(@"duo.diag.app_version", [NSString stringWithFormat:@"%@-%s", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"], CONFIG_TYPE]);
    add(@"duo.diag.commit", [NSString stringWithFormat:@"%s (%s)", CONFIG_COMMIT, CONFIG_BRANCH]);
    add(@"duo.diag.device", [HostManager GetModelName]);
    add(@"duo.diag.os", UIDevice.currentDevice.completeOSVersion);
    const char *installType = getenv("AME_DETECTEDINST");
    add(@"duo.diag.install_type", installType ? @(installType) : nil);
    add(@"duo.diag.jit", [self jitState]);
    add(@"duo.diag.jit_method", [self jitMethod]);
    const char *gameDir = getenv("GAME_DIR");
    add(@"duo.diag.game_dir", gameDir ? DuoRedactedString(@(gameDir)) : nil);
    add(@"duo.diag.renderer", [NSString stringWithFormat:@"%@ / %@", getPrefObject(@"video.renderer"), [PLProfiles resolveKeyForCurrentProfile:@"renderer"]]);
    NSString *profileRenderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    NSUInteger failures = [RendererCrashTracker consecutiveFailuresForRenderer:profileRenderer];
    add(@"duo.diag.renderer_crash_tracker", [NSString stringWithFormat:@"%@ pending failure%@", @(failures), failures == 1 ? @"" : @"s"]);
    add(@"duo.diag.java", [NSString stringWithFormat:@"%@", [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"]]);
    unsigned long long physical = NSProcessInfo.processInfo.physicalMemory / (1024ULL * 1024ULL);
    add(@"duo.diag.ram", [NSString stringWithFormat:@"%@ MiB allocated (auto: %@) of %llu MiB", getPrefObject(@"java.allocated_memory"), getPrefBool(@"java.auto_ram") ? @"yes" : @"no", physical]);
    add(@"duo.diag.curseforge", [CurseForgeAPI isConfigured] ? localize(@"duo.diag.configured", nil) : localize(@"duo.diag.not_configured", nil));
    const char *home = getenv("AME_HOME");
    if (home) {
        NSNumber *free = nil;
        [[NSURL fileURLWithPath:@(home)] getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
        if (free) add(@"duo.diag.free_space", [NSByteCountFormatter stringFromByteCount:free.longLongValue countStyle:NSByteCountFormatterCountStyleFile]);
    }
    return rows;
}

+ (NSString *)tailOfFileAtPath:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    unsigned long long size = 0;
    @try {
        size = [handle seekToEndOfFile];
        unsigned long long start = size > maxBytes ? size - maxBytes : 0;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataOfLength:maxBytes];
        [handle closeFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        return start > 0 ? [@"[... truncated to the last part of the file ...]\n" stringByAppendingString:text ?: @""] : text;
    } @catch (NSException *exception) {
        return nil;
    }
}

+ (NSString *)buildRedactedReport {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"Amethyst Duo developer diagnostics (redacted, reviewed by user before sharing)\n"];
    [report appendFormat:@"Generated: %@\n\n== Status ==\n", [NSDate date]];
    for (NSArray<NSString *> *row in [self statusRows]) [report appendFormat:@"%@: %@\n", row[0], row[1]];

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL foundDiagnosticFile = NO;
    const char *homeEnv = getenv("AME_HOME");
    if (homeEnv && *homeEnv) {
        NSString *home = @(homeEnv);
        NSArray *files = @[@[@"latestlog.txt", @(kLatestLogTail)], @[@"latestlog.old.txt", @(kOldLogTail)], @[@"mobilegl.log", @(kMobileGLTail)]];
        for (NSArray *entry in files) {
            NSString *text = [self tailOfFileAtPath:[home stringByAppendingPathComponent:entry[0]] maxBytes:[entry[1] unsignedIntegerValue]];
            if (text.length) foundDiagnosticFile = YES;
            [report appendFormat:@"\n== %@ ==\n%@\n", entry[0], text ?: @"(not present)"];
        }
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:home] includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        NSSet *skip = [NSSet setWithArray:@[@"versions", @"libraries", @"assets", @"java_runtimes", @"saves", @"mods", @"custom_gamedir"]];
        NSUInteger found = 0;
        for (NSURL *url in enumerator) {
            NSNumber *isDir = nil;
            [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
            if (isDir.boolValue && [skip containsObject:url.lastPathComponent]) { [enumerator skipDescendants]; continue; }
            if (!isDir.boolValue && [url.lastPathComponent hasPrefix:@"hs_err_pid"] && [url.pathExtension isEqualToString:@"log"]) {
                NSString *text = [self tailOfFileAtPath:url.path maxBytes:kHsErrTail];
                if (text.length) foundDiagnosticFile = YES;
                [report appendFormat:@"\n== %@ ==\n%@\n", url.lastPathComponent, text ?: @"(unreadable)"];
                if (++found >= DuoMaxHsErrFiles) break;
            }
        }
    }
    if (!foundDiagnosticFile) [report appendString:@"\n== Diagnostic files ==\n(no readable diagnostic logs were found)\n"];
    // Redact first, then cap, so a cap boundary can never cut a redaction marker in half.
    return [self redactedExportTextFromReviewedText:report];
}

+ (NSString *)redactedExportTextFromReviewedText:(NSString *)text {
    // This is also called immediately before clipboard/file export. Never trust a cached preview
    // buffer to remain safe after account, path, or configured launch values have changed.
    NSString *redacted = DuoRedactedString(text ?: @"");
    NSData *utf8 = [redacted dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length > DuoMaxBundleBytes) {
        NSData *tail = [utf8 subdataWithRange:NSMakeRange(utf8.length - DuoMaxBundleBytes, DuoMaxBundleBytes)];
        redacted = [@"[... report truncated to the last 2 MB ...]\n" stringByAppendingString:[[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding] ?: @""];
    }
    return redacted;
}

+ (NSString *)contentsSummary {
    return localize(@"duo.diag.summary", nil);
}

+ (NSURL *)writeReportText:(NSString *)text error:(NSError **)error {
    text = [self redactedExportTextFromReviewedText:text];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"duo-diagnostics-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSString *path = [dir stringByAppendingPathComponent:@"duo-diagnostics.txt"];
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}

@end

#endif
