#import "DuoPackLibrary.h"
#import "PLProfiles.h"
#import "utils.h"

static NSString *const kLastImportKey = @"duo.packs.lastImport";

@implementation DuoPackInfo
@end

@implementation DuoPackLibrary

+ (NSString *)customGameDirRoot {
    const char *gameDir = getenv("GAME_DIR");
    return gameDir ? [@(gameDir) stringByAppendingPathComponent:@"custom_gamedir"] : nil;
}

+ (void)markProfile:(NSMutableDictionary *)profile source:(NSString *)source {
    profile[@"duoPackSource"] = source;
    profile[@"duoPackInstalledAt"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
}

// Resolves "./custom_gamedir/<name>" to a path that is verified to be a direct child of custom_gamedir.
+ (NSString *)safeAbsoluteDirForRelative:(NSString *)relative {
    NSString *root = [self customGameDirRoot];
    if (!root || ![relative hasPrefix:@"./custom_gamedir/"]) return nil;
    NSString *leaf = [relative substringFromIndex:@"./custom_gamedir/".length];
    if (leaf.length == 0 || [leaf containsString:@"/"] || [leaf containsString:@".."] || [leaf hasPrefix:@"."]) return nil;
    return [root stringByAppendingPathComponent:leaf];
}

+ (NSString *)loaderForVersionId:(NSString *)versionId {
    NSString *lower = versionId.lowercaseString;
    if ([lower hasPrefix:@"neoforge"]) return @"NeoForge";
    if ([lower containsString:@"fabric"]) return @"Fabric";
    if ([lower containsString:@"quilt"]) return @"Quilt";
    if ([lower containsString:@"forge"]) return @"Forge";
    return @"Vanilla";
}

+ (NSString *)gameVersionForVersionId:(NSString *)versionId {
    // "neoforge-21.1.264" does not name the MC version; read versions/<id>/<id>.json inheritsFrom when present.
    const char *gameDir = getenv("GAME_DIR");
    if (gameDir && versionId.length) {
        NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json", gameDir, versionId, versionId];
        NSData *data = [NSData dataWithContentsOfFile:path];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:NSDictionary.class]) {
            NSString *inherits = json[@"inheritsFrom"];
            if ([inherits isKindOfClass:NSString.class] && inherits.length) return inherits;
        }
    }
    return nil;
}

+ (NSArray<DuoPackInfo *> *)installedPacks {
    PLProfiles *profiles = PLProfiles.current;
    NSMutableArray *packs = [NSMutableArray new];
    for (NSString *name in profiles.profiles.allKeys) {
        NSDictionary *profile = profiles.profiles[name];
        NSString *relative = profile[@"gameDir"];
        if (![relative isKindOfClass:NSString.class] || ![relative hasPrefix:@"./custom_gamedir/"]) continue;
        DuoPackInfo *info = [DuoPackInfo new];
        info.profileName = name;
        info.relativeGameDir = relative;
        info.absoluteGameDir = [self safeAbsoluteDirForRelative:relative];
        NSString *source = profile[@"duoPackSource"];
        info.source = source.length ? source : @"installed";
        info.installedAt = profile[@"duoPackInstalledAt"];
        NSString *versionId = profile[@"lastVersionId"];
        info.loader = [self loaderForVersionId:versionId];
        info.gameVersion = [self gameVersionForVersionId:versionId] ?: versionId;
        BOOL isDir = NO;
        info.directoryExists = info.absoluteGameDir && [NSFileManager.defaultManager fileExistsAtPath:info.absoluteGameDir isDirectory:&isDir] && isDir;
        info.isSelected = [profiles.selectedProfileName isEqualToString:name];
        [packs addObject:info];
    }
    [packs sortUsingComparator:^NSComparisonResult(DuoPackInfo *a, DuoPackInfo *b) {
        return [a.profileName caseInsensitiveCompare:b.profileName];
    }];
    return packs;
}

+ (unsigned long long)storageBytesForPack:(DuoPackInfo *)pack {
    if (!pack.absoluteGameDir) return 0;
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:pack.absoluteGameDir] includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsRegularFileKey] options:0 errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *regular = nil, *size = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (regular.boolValue) total += size.unsignedLongLongValue;
    }
    return total;
}

+ (BOOL)canRemoveAnyPack {
    return PLProfiles.current.profiles.count > 1;
}

+ (BOOL)removePackFolder:(DuoPackInfo *)pack error:(NSError **)error {
    // Safe off the main thread: touches only the filesystem, never PLProfiles.
    NSString *directory = [self safeAbsoluteDirForRelative:pack.relativeGameDir];
    if (!directory) {
        if (error) *error = [NSError errorWithDomain:@"DuoPackLibrary" code:1 userInfo:@{NSLocalizedDescriptionKey: @"This profile does not own a removable pack folder."}];
        return NO;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:directory]) return YES;
    return [NSFileManager.defaultManager removeItemAtPath:directory error:error];
}

+ (BOOL)removePackProfile:(DuoPackInfo *)pack error:(NSError **)error {
    // Main thread only (PLProfiles is not thread-safe).
    PLProfiles *profiles = PLProfiles.current;
    NSMutableDictionary *previous = profiles.profiles[pack.profileName];
    NSString *previousSelection = profiles.selectedProfileName;
    if (!previous) return YES;
    if (profiles.profiles.count <= 1) {
        if (error) *error = [NSError errorWithDomain:@"DuoPackLibrary" code:2 userInfo:@{NSLocalizedDescriptionKey: @"The last remaining profile cannot be removed."}];
        return NO;
    }
    [profiles.profiles removeObjectForKey:pack.profileName];
    if ([previousSelection isEqualToString:pack.profileName]) {
        NSArray *remaining = [profiles.profiles.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        profiles.profileDict[@"selectedProfile"] = remaining.firstObject;
    }
    if (![profiles save:error]) {
        profiles.profiles[pack.profileName] = previous;
        profiles.profileDict[@"selectedProfile"] = previousSelection;
        return NO;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:profiles];
    return YES;
}

+ (void)recordImportResult:(BOOL)success message:(NSString *)message {
    NSDictionary *entry = @{@"success": @(success), @"message": message ?: @"", @"date": NSDate.date};
    [NSUserDefaults.standardUserDefaults setObject:entry forKey:kLastImportKey];
}

+ (NSDictionary *)lastImportResult {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:kLastImportKey];
}

@end
