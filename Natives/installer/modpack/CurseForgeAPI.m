#import <Foundation/Foundation.h>
#import "CurseForgeAPI.h"
#import "ModrinthSearchFilters.h"
#import "MinecraftResourceDownloadTask.h"
#import "JavaLauncher.h"
#import "PLProfiles.h"
#import "utils.h"
#import <Security/Security.h>

static NSString *CFString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString *CFIdentifier(id value) { return [value isKindOfClass:NSNumber.class] ? [value stringValue] : CFString(value); }
static NSString *CFKey(void) {
    return [CurseForgeAPI apiKey];
}
static NSNumber *CFLoader(NSDictionary *filters) {
    if (![[ModrinthSearchFilters contentTypeForFilters:filters] isEqual:@"mod"]) return nil;
    return @{@"forge": @1, @"liteloader": @3, @"fabric": @4, @"quilt": @5, @"neoforge": @6}[filters[@"loader"] ?: @""];
}

@implementation CurseForgeAPI
+ (NSDictionary *)keyQuery {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"Amethyst.CurseForge", (__bridge id)kSecAttrAccount: @"api-key"};
}
+ (NSString *)apiKey {
    NSMutableDictionary *query = [self.keyQuery mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = CFBridgingRelease(result);
    return status == errSecSuccess ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"" : @"";
}
+ (BOOL)setAPIKey:(NSString *)key error:(NSError **)error {
    key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary *query = self.keyQuery;
    OSStatus status;
    if (!key.length) {
        status = SecItemDelete((__bridge CFDictionaryRef)query);
        if (status == errSecItemNotFound) status = errSecSuccess;
    } else {
        NSDictionary *values = @{(__bridge id)kSecValueData: [key dataUsingEncoding:NSUTF8StringEncoding]};
        status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)values);
        if (status == errSecItemNotFound) {
            NSMutableDictionary *item = [query mutableCopy];
            [item addEntriesFromDictionary:values];
            item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
            status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        }
    }
    if (status != errSecSuccess) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"content.curseforge.key_error", nil)}];
        return NO;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"CurseForgeConfigurationDidChange" object:nil];
    return YES;
}
- (instancetype)init { return [super initWithURL:@"https://api.curseforge.com/v1"]; }
+ (BOOL)isConfigured { return CFKey().length > 0; }
- (NSDictionary *)requestHeaders { return self.class.isConfigured ? @{@"x-api-key": CFKey()} : @{}; }
- (BOOL)checkConfiguration {
    if (self.class.isConfigured) return YES;
    self.lastError = [NSError errorWithDomain:@"CurseForge" code:100 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"content.curseforge.unconfigured", nil)}];
    return NO;
}
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    return [self checkConfiguration] ? [super getEndpoint:endpoint params:params] : nil;
}
- (id)postEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    return [self checkConfiguration] ? [super postEndpoint:endpoint params:params] : nil;
}
- (NSArray *)listFromResponse:(id)response {
    if (!response) return nil;
    if ([response isKindOfClass:NSDictionary.class] && [response[@"data"] isKindOfClass:NSArray.class]) return response[@"data"];
    self.lastError = [NSError errorWithDomain:@"CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"content.invalid_response", nil)}];
    return nil;
}
- (NSNumber *)classIDForType:(NSString *)type {
    // Discover section IDs instead of embedding IDs that may change on CurseForge.
    static NSDictionary *classIDs;
    @synchronized (CurseForgeAPI.class) { if (classIDs[type]) return classIDs[type]; }
    NSArray *classes = [self listFromResponse:[self getEndpoint:@"categories" params:@{@"gameId": @432, @"classesOnly": @YES}]];
    if (!classes) return nil;
    NSMutableDictionary *ids = [NSMutableDictionary new];
    NSDictionary *types = @{@"mc-mods": @"mod", @"mods": @"mod", @"texture-packs": @"resourcepack", @"resource-packs": @"resourcepack", @"shaders": @"shader", @"modpacks": @"modpack"};
    for (id item in classes) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"id"] isKindOfClass:NSNumber.class]) continue;
        NSString *kind = types[CFString(item[@"slug"])];
        if (kind) ids[kind] = item[@"id"];
    }
    @synchronized (CurseForgeAPI.class) { classIDs = ids.copy; }
    if (!ids[type]) self.lastError = [NSError errorWithDomain:@"CurseForge" code:2 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"content.section_unavailable", nil)}];
    return ids[type];
}
- (NSArray<NSDictionary *> *)categoriesForContentType:(NSString *)type {
    NSNumber *classID = [self classIDForType:type];
    if (!classID) return nil;
    NSArray *categories = [self listFromResponse:[self getEndpoint:@"categories" params:@{@"gameId": @432, @"classId": classID}]];
    if (!categories) return nil;
    NSMutableArray *records = [NSMutableArray new];
    for (id item in categories) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"id"] isKindOfClass:NSNumber.class] || [item[@"isClass"] boolValue]) continue;
        if (![item[@"classId"] isEqual:classID]) continue;
        [records addObject:@{@"id": CFIdentifier(item[@"id"]), @"name": CFString(item[@"name"]), @"slug": CFString(item[@"slug"])}];
    }
    return [records sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]]];
}
+ (NSDictionary *)searchParameters:(NSDictionary *)filters classID:(NSNumber *)classID offset:(NSUInteger)offset {
    NSNumber *sort = @{@"relevance": @2, @"downloads": @6, @"newest": @11, @"updated": @3}[filters[@"index"]] ?: @2;
    NSMutableDictionary *params = [@{@"gameId": @432, @"classId": classID, @"searchFilter": CFString(filters[@"name"]), @"index": @(offset), @"pageSize": @50, @"sortField": sort, @"sortOrder": @"desc"} mutableCopy];
    NSString *game = CFString(filters[@"mcVersion"]);
    if (game.length) params[@"gameVersion"] = game;
    NSNumber *loader = CFLoader(filters);
    // CurseForge requires a game version together with the search loader parameter.
    if (loader && game.length) params[@"modLoaderType"] = loader;
    NSArray *categories = [filters[@"categories"] isKindOfClass:NSArray.class] ? filters[@"categories"] : @[];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet new];
    for (id category in categories) if (CFString(category).integerValue > 0 && ids.count < 10) [ids addObject:@([category integerValue])];
    if (ids.count) params[@"categoryIds"] = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:ids.array options:0 error:nil] encoding:NSUTF8StringEncoding];
    return params;
}
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)previous {
    NSNumber *classID = [self classIDForType:[ModrinthSearchFilters contentTypeForFilters:filters]];
    if (!classID) return nil;
    if (previous.count >= 10000) { self.reachedLastPage = YES; return previous.mutableCopy; }
    id response = [self getEndpoint:@"mods/search" params:[self.class searchParameters:filters classID:classID offset:previous.count]];
    NSArray *hits = [self listFromResponse:response];
    if (!hits) return nil;
    NSMutableArray *result = previous.mutableCopy ?: [NSMutableArray new];
    for (id item in hits) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"id"] isKindOfClass:NSNumber.class] || ![item[@"classId"] isEqual:classID]) continue;
        NSMutableArray *authors = [NSMutableArray new];
        if ([item[@"authors"] isKindOfClass:NSArray.class]) for (id author in item[@"authors"]) if ([author isKindOfClass:NSDictionary.class] && CFString(author[@"name"]).length) [authors addObject:author[@"name"]];
        NSDictionary *logo = [item[@"logo"] isKindOfClass:NSDictionary.class] ? item[@"logo"] : @{};
        NSDictionary *links = [item[@"links"] isKindOfClass:NSDictionary.class] ? item[@"links"] : @{};
        [result addObject:@{@"id": CFIdentifier(item[@"id"]), @"provider": @"curseforge", @"contentType": [ModrinthSearchFilters contentTypeForFilters:filters], @"title": CFString(item[@"name"]), @"description": CFString(item[@"summary"]), @"author": [authors componentsJoinedByString:@", "], @"imageUrl": CFString(logo[@"thumbnailUrl"]), @"websiteUrl": CFString(links[@"websiteUrl"])}];
    }
    NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
    self.reachedLastPage = !hits.count || previous.count + hits.count >= MIN(10000, [pagination[@"totalCount"] unsignedIntegerValue]);
    return result;
}
+ (NSDictionary *)versionFromFile:(NSDictionary *)file {
    if (![file isKindOfClass:NSDictionary.class] || ![file[@"id"] isKindOfClass:NSNumber.class] || ![file[@"modId"] isKindOfClass:NSNumber.class]) return nil;
    NSString *sha1 = @"";
    if ([file[@"hashes"] isKindOfClass:NSArray.class]) for (id hash in file[@"hashes"]) if ([hash isKindOfClass:NSDictionary.class] && [hash[@"algo"] isEqual:@1]) sha1 = CFString(hash[@"value"]);
    NSArray *games = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    NSMutableArray *loaders = [NSMutableArray new], *versions = [NSMutableArray new];
    for (id game in games) {
        if (![game isKindOfClass:NSString.class]) continue;
        if ([@[@"forge", @"fabric", @"quilt", @"neoforge", @"liteloader"] containsObject:[game lowercaseString]]) [loaders addObject:[game lowercaseString]];
        else [versions addObject:game];
    }
    NSDictionary *download = @{@"filename": CFString(file[@"fileName"]), @"url": CFString(file[@"downloadUrl"]), @"size": [file[@"fileLength"] isKindOfClass:NSNumber.class] ? file[@"fileLength"] : @0, @"hashes": @{@"sha1": sha1}, @"primary": @YES};
    BOOL available = [file[@"isAvailable"] boolValue] && ![file[@"isServerPack"] boolValue] && ![file[@"isEarlyAccessContent"] boolValue] && CFString(file[@"downloadUrl"]).length;
    NSMutableArray *dependencies = [NSMutableArray new];
    for (id dep in [file[@"dependencies"] isKindOfClass:NSArray.class] ? file[@"dependencies"] : @[]) {
        if (![dep isKindOfClass:NSDictionary.class]) continue;
        NSString *type = @{@3: @"required", @5: @"incompatible"}[dep[@"relationType"]];
        if (type && CFIdentifier(dep[@"modId"]).length) [dependencies addObject:@{@"project_id": CFIdentifier(dep[@"modId"]), @"dependency_type": type}];
    }
    return @{@"id": CFIdentifier(file[@"id"]), @"project_id": CFIdentifier(file[@"modId"]), @"provider": @"curseforge", @"name": CFString(file[@"displayName"]), @"version_number": CFString(file[@"displayName"]), @"date_published": CFString(file[@"fileDate"]), @"game_versions": versions, @"loaders": loaders, @"version_type": (@{@1: @"release", @2: @"beta", @3: @"alpha"}[file[@"releaseType"]] ?: @""), @"files": @[download], @"downloadUnavailable": @(!available), @"dependencies": dependencies};
}
- (NSArray<NSDictionary *> *)versionsForProject:(NSString *)projectID filters:(NSDictionary *)filters {
    NSMutableArray *versions = [NSMutableArray new];
    NSMutableDictionary *params = [@{@"pageSize": @50} mutableCopy];
    if (CFString(filters[@"mcVersion"]).length) params[@"gameVersion"] = filters[@"mcVersion"];
    if (CFLoader(filters)) params[@"modLoaderType"] = CFLoader(filters);
    for (NSUInteger offset = 0; offset < 10000; offset += 50) {
        params[@"index"] = @(offset);
        id response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectID] params:params];
        NSArray *files = [self listFromResponse:response];
        if (!files) return nil;
        for (id file in files) { NSDictionary *version = [self.class versionFromFile:file]; if (version) [versions addObject:version]; }
        NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
        if (!files.count || offset + files.count >= [pagination[@"totalCount"] unsignedIntegerValue]) break;
    }
    return [[ModrinthSearchFilters versions:versions matchingFilters:filters] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"date_published" ascending:NO]]];
}
- (NSDictionary *)projectForID:(NSString *)projectID {
    id response = [self getEndpoint:[@"mods/" stringByAppendingString:projectID] params:nil];
    id item = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    if (![item isKindOfClass:NSDictionary.class] || ![item[@"id"] isKindOfClass:NSNumber.class]) return nil;
    NSDictionary *logo = [item[@"logo"] isKindOfClass:NSDictionary.class] ? item[@"logo"] : @{};
    NSDictionary *links = [item[@"links"] isKindOfClass:NSDictionary.class] ? item[@"links"] : @{};
    return @{@"id": CFIdentifier(item[@"id"]), @"provider": @"curseforge", @"contentType": @"mod", @"title": CFString(item[@"name"]), @"description": CFString(item[@"summary"]), @"imageUrl": CFString(logo[@"thumbnailUrl"]), @"author": @"", @"websiteUrl": CFString(links[@"websiteUrl"])};
}
- (NSDictionary *)versionForID:(NSString *)versionID projectID:(NSString *)projectID {
    id response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@", projectID, versionID] params:nil];
    return [response isKindOfClass:NSDictionary.class] ? [self.class versionFromFile:response[@"data"]] : nil;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *versions = [self versionsForProject:CFIdentifier(item[@"id"]) filters:@{@"isModpack": @YES}];
    if (!versions) return;
    NSMutableArray *names = [NSMutableArray new], *games = [NSMutableArray new], *urls = [NSMutableArray new], *hashes = [NSMutableArray new], *sizes = [NSMutableArray new], *reasons = [NSMutableArray new];
    for (NSDictionary *version in versions) {
        NSDictionary *file = [version[@"files"] firstObject];
        if (![file isKindOfClass:NSDictionary.class]) continue;
        [names addObject:CFString(version[@"name"])];
        [games addObject:[version[@"game_versions"] firstObject] ?: @""];
        [urls addObject:CFString(file[@"url"])];
        [hashes addObject:CFString(file[@"hashes"][@"sha1"])];
        [sizes addObject:file[@"size"] ?: @0];
        BOOL downloadable = ![version[@"downloadUnavailable"] boolValue] && CFString(file[@"url"]).length && CFString(file[@"hashes"][@"sha1"]).length;
        [reasons addObject:downloadable ? @"" : @"CurseForge does not provide an authorized download for this modpack version."];
    }
    if (!names.count) {
        self.lastError = [NSError errorWithDomain:@"CurseForge" code:3 userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"content.invalid_response", nil)}];
        return;
    }
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = games;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionSizes"] = sizes;
    item[@"versionUnavailableReasons"] = reasons;
    item[@"versionDetailsLoaded"] = @YES;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    if (![self checkConfiguration]) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"%@ Open Content Settings, add your CurseForge API key, then retry this local CurseForge archive.", self.lastError.localizedDescription]];
        return;
    }
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unable to open the official CurseForge modpack archive: %@", error.localizedDescription]];
        return;
    }
    if (![ModpackUtils validateArchive:archive error:&error]) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"This CurseForge archive cannot be imported safely: %@", error.localizedDescription]];
        return;
    }
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error] : nil;
    if (error || ![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"minecraft"] isKindOfClass:NSDictionary.class] || ![manifest[@"files"] isKindOfClass:NSArray.class]) {
        [downloader finishDownloadWithErrorString:@"This archive is not an official CurseForge client modpack (manifest.json is missing or invalid)."];
        return;
    }
    if ([[CFString(manifest[@"manifestType"]) lowercaseString] isEqual:@"minecraftmodpack"] == NO) {
        [downloader finishDownloadWithErrorString:@"This CurseForge archive is not a client modpack and cannot be installed."];
        return;
    }
    NSDictionary *minecraft = manifest[@"minecraft"];
    NSString *minecraftVersion = CFString(minecraft[@"version"]);
    if (!minecraftVersion.length || !CFString(manifest[@"name"]).length) {
        [downloader finishDownloadWithErrorString:@"The CurseForge manifest does not declare a pack name and Minecraft version."];
        return;
    }

    NSDictionary *dependency = @{ @"minecraft": minecraftVersion };
    NSArray *loaders = [minecraft[@"modLoaders"] isKindOfClass:NSArray.class] ? minecraft[@"modLoaders"] : @[];
    NSDictionary *primaryLoader = nil;
    for (id candidate in loaders) {
        if ([candidate isKindOfClass:NSDictionary.class] && [candidate[@"primary"] boolValue]) { primaryLoader = candidate; break; }
        if (!primaryLoader && [candidate isKindOfClass:NSDictionary.class]) primaryLoader = candidate;
    }
    NSString *loaderID = CFString(primaryLoader[@"id"]).lowercaseString;
    if ([loaderID hasPrefix:@"forge-"]) {
        dependency = @{ @"minecraft": minecraftVersion, @"forge": [loaderID substringFromIndex:@"forge-".length] };
    } else if ([loaderID hasPrefix:@"fabric-"]) {
        dependency = @{ @"minecraft": minecraftVersion, @"fabric-loader": [loaderID substringFromIndex:@"fabric-".length] };
    } else if ([loaderID hasPrefix:@"quilt-"]) {
        dependency = @{ @"minecraft": minecraftVersion, @"quilt-loader": [loaderID substringFromIndex:@"quilt-".length] };
    } else if ([loaderID hasPrefix:@"neoforge-"]) {
        NSCharacterSet *validNeoForgeVersionCharacters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
        if (loaderID.length == @"neoforge-".length || [loaderID rangeOfCharacterFromSet:validNeoForgeVersionCharacters.invertedSet].location != NSNotFound) {
            [downloader finishDownloadWithErrorString:@"This CurseForge pack declares an invalid NeoForge version."];
            return;
        }
        dependency = @{ @"minecraft": minecraftVersion, @"neoforge": loaderID };
    } else if (loaderID.length) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"This CurseForge pack uses unsupported loader '%@'.", loaderID]];
        return;
    }

    NSMutableArray<NSDictionary *> *downloads = [NSMutableArray new];
    for (id candidate in manifest[@"files"]) {
        if (![candidate isKindOfClass:NSDictionary.class] || ![candidate[@"required"] boolValue] || ![candidate[@"projectID"] isKindOfClass:NSNumber.class] || ![candidate[@"fileID"] isKindOfClass:NSNumber.class]) {
            if ([candidate isKindOfClass:NSDictionary.class] && ![candidate[@"required"] boolValue]) continue;
            [downloader finishDownloadWithErrorString:@"The CurseForge manifest contains an invalid required file entry."];
            return;
        }
        NSDictionary *file = [self versionForID:CFIdentifier(candidate[@"fileID"]) projectID:CFIdentifier(candidate[@"projectID"])];
        NSDictionary *download = [file[@"files"] firstObject];
        if (![file[@"project_id"] isEqual:CFIdentifier(candidate[@"projectID"])] || [file[@"downloadUnavailable"] boolValue] || !CFString(download[@"url"]).length || !CFString(download[@"filename"]).length || !CFString(download[@"hashes"][@"sha1"]).length) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"CurseForge does not provide an authorized downloadable file for project %@ file %@. Download that file manually from CurseForge, then retry after placing it in this profile's mods folder.", CFIdentifier(candidate[@"projectID"]), CFIdentifier(candidate[@"fileID"])]];
            return;
        }
        [downloads addObject:download];
    }

    // Compute depInfo early to get the profileID for preflight collision checks
    NSDictionary *depInfo = [ModpackUtils infoForDependencies:dependency];
    NSString *profileID = dependency[@"neoforge"] ?: depInfo[@"id"] ?: minecraftVersion;
    NSString *packName = CFString(manifest[@"name"]);
    NSString *gameDirectory = @(getenv("GAME_DIR"));
    NSString *neoForgeVersionPath = [NSString stringWithFormat:@"%@/versions/%@", gameDirectory, profileID];
    if (downloader.progress.cancelled) return;
    if (PLProfiles.current.profiles[packName] || [NSFileManager.defaultManager fileExistsAtPath:destPath] ||
        (dependency[@"neoforge"] && [NSFileManager.defaultManager fileExistsAtPath:neoForgeVersionPath])) {
        [downloader finishDownloadWithErrorString:@"A profile or installed version with this modpack's name already exists. Rename or remove it before importing."];
        return;
    }

    NSString *stagingPath = [destPath stringByAppendingFormat:@".installing-%@", NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
    if (![NSFileManager.defaultManager createDirectoryAtPath:stagingPath withIntermediateDirectories:YES attributes:nil error:&error]) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unable to prepare the modpack installation: %@", error.localizedDescription]];
        return;
    }
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:stagingPath error:&error];
    if (error) {
        [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unable to extract CurseForge overrides safely: %@", error.localizedDescription]];
        return;
    }

    dispatch_group_t downloadsComplete = dispatch_group_create();
    __block BOOL failed = NO;
    void (^rollback)(void) = ^{
        @synchronized (downloadsComplete) {
            if (failed) return;
            failed = YES;
        }
        [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
    };
    for (NSDictionary *download in downloads) {
        NSString *path = [ModpackUtils safeDestinationForRelativePath:[@"mods" stringByAppendingPathComponent:download[@"filename"]] root:stagingPath error:&error];
        if (!path) {
            rollback();
            [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"The CurseForge manifest contains an unsafe mod filename."];
            return;
        }
        dispatch_group_enter(downloadsComplete);
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:download[@"url"] size:[download[@"size"] unsignedLongLongValue] sha:download[@"hashes"][@"sha1"] altName:nil toPath:path forceSHA:YES success:^{
            dispatch_group_leave(downloadsComplete);
        } failure:^(NSError *downloadError) {
            rollback();
            dispatch_group_leave(downloadsComplete);
        }];
        if (task) [task resume];
        // Cached files call success synchronously. An access failure has already cancelled the task.
        else if (downloader.progress.cancelled) { rollback(); return; }
    }

    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), depInfo[@"id"]];
        dispatch_group_enter(downloadsComplete);
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath forceSHA:NO success:^{
            dispatch_group_leave(downloadsComplete);
        } failure:^(NSError *downloadError) {
            rollback();
            dispatch_group_leave(downloadsComplete);
        }];
        if (task) [task resume];
        else if (downloader.progress.cancelled) { rollback(); return; }
    }
    NSString *neoForgeInstallerPath;
    NSString *neoForgeMavenVersion;
    if (dependency[@"neoforge"]) {
        // Separate Maven version (21.1.264) from launcher profile ID (neoforge-21.1.264)
        neoForgeMavenVersion = [dependency[@"neoforge"] substringFromIndex:@"neoforge-".length];
        neoForgeInstallerPath = [NSString stringWithFormat:@"%s/neoforge-installers/%@-installer.jar", getenv("GAME_DIR"), profileID];
        NSString *installerURL = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/%1$@-installer.jar", neoForgeMavenVersion];
        NSString *installerSHA1URL = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/%1$@-installer.jar.sha1", neoForgeMavenVersion];
        dispatch_group_enter(downloadsComplete);
        NSURLSessionDownloadTask *shaTask = [downloader createDownloadTask:installerSHA1URL size:0 sha:nil altName:nil toPath:[neoForgeInstallerPath stringByAppendingString:@".sha1"] forceSHA:NO success:^{
            dispatch_group_leave(downloadsComplete);
        } failure:^(NSError *downloadError) {
            rollback();
            dispatch_group_leave(downloadsComplete);
        }];
        if (shaTask) [shaTask resume];
        else if (downloader.progress.cancelled) { rollback(); return; }
        
        dispatch_group_enter(downloadsComplete);
        dispatch_group_notify(downloadsComplete, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (failed || downloader.progress.cancelled) {
                dispatch_group_leave(downloadsComplete);
                return;
            }
            NSString *expectedSHA1 = [[NSString stringWithContentsOfFile:[neoForgeInstallerPath stringByAppendingString:@".sha1"] encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [NSFileManager.defaultManager removeItemAtPath:[neoForgeInstallerPath stringByAppendingString:@".sha1"] error:nil];
            if (!expectedSHA1.length) {
                rollback();
                dispatch_group_leave(downloadsComplete);
                return;
            }
            dispatch_group_enter(downloadsComplete);
            NSURLSessionDownloadTask *task = [downloader createDownloadTask:installerURL size:0 sha:expectedSHA1 altName:[NSString stringWithFormat:@"%@ installer", profileID] toPath:neoForgeInstallerPath forceSHA:YES success:^{
                dispatch_group_leave(downloadsComplete);
            } failure:^(NSError *downloadError) {
                rollback();
                dispatch_group_leave(downloadsComplete);
            }];
            if (task) [task resume];
            else if (downloader.progress.cancelled) { rollback(); }
            dispatch_group_leave(downloadsComplete);
        });
    }
    // Complete the prepareForDownload sentinel. The byte-weighted child progresses
    // account for the actual downloads; never add a second per-file unit model.
    downloader.progress.completedUnitCount = 1;
    dispatch_group_notify(downloadsComplete, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @synchronized (downloadsComplete) {
            if (failed || downloader.progress.cancelled) return;
            failed = YES; // prevent a late failure from publishing after this point
        }
        
        // Check cancellation before proceeding with installation
        if (downloader.progress.cancelled) {
            [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
            return;
        }
        
        // Preflight collision check for profile name (already done earlier, but recheck after downloads)
        if (PLProfiles.current.profiles[packName]) {
            [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
            [downloader finishDownloadWithErrorString:@"A profile with this modpack's name was created during installation. Rename or remove it before retrying."];
            return;
        }
        
        if (neoForgeInstallerPath) {
            __block BOOL installerSucceeded = NO;
            __block NSString *installerError;
            NSString *gameDirectory = @(getenv("GAME_DIR"));
            // Use staging path as installation directory to isolate mutations from GAME_DIR
            launchNeoForgeInstaller(neoForgeInstallerPath, profileID, gameDirectory, ^(BOOL installed, NSString *errorMessage) {
                installerSucceeded = installed;
                installerError = errorMessage;
            });
            [NSFileManager.defaultManager removeItemAtPath:neoForgeInstallerPath error:nil];
            if (!installerSucceeded) {
                [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
                [downloader finishDownloadWithErrorString:installerError ?: @"NeoForge client installation failed before the modpack profile could be published."];
                return;
            }
        }
        
        // Final cancellation check before publication
        if (downloader.progress.cancelled) {
            [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
            return;
        }
        
        NSError *moveError;
        if ([NSFileManager.defaultManager fileExistsAtPath:destPath] || ![NSFileManager.defaultManager moveItemAtPath:stagingPath toPath:destPath error:&moveError]) {
            [NSFileManager.defaultManager removeItemAtPath:stagingPath error:nil];
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unable to publish the completed modpack installation: %@", moveError.localizedDescription ?: @"the destination already exists"]];
            return;
        }
        PLProfiles *profiles = PLProfiles.current;
        profiles.profiles[packName] = @{@"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent], @"name": packName, @"lastVersionId": profileID, @"icon": @""}.mutableCopy;
        profiles.selectedProfileName = packName;
        [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
        
        // Complete the progress only after all installation and publication steps succeed
        [downloader finishDownloadWithSuccess];
    });
}
@end
