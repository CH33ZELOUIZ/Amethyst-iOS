#import <CommonCrypto/CommonDigest.h>
#include <limits.h>
#import "JavaLauncher.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "OfflineModpackImporter.h"
#import "ModpackUtils.h"

static const unsigned long long OfflineMaxEntries = 12000;
static const unsigned long long OfflineMaxBytes = 2ULL * 1024 * 1024 * 1024;
static const unsigned long long OfflineMaxSingleFile = 512ULL * 1024 * 1024;

@implementation OfflineModpackImporter

+ (BOOL)fail:(NSError **)error description:(NSString *)description {
    if (error) *error = [NSError errorWithDomain:@"OfflineModpack" code:1 userInfo:@{NSLocalizedDescriptionKey: description}];
    return NO;
}

+ (BOOL)isSafeRelativePath:(NSString *)path {
    if (![path isKindOfClass:NSString.class] || !path.length || path.isAbsolutePath || [path containsString:@"\\"]) return NO;
    for (NSString *part in path.pathComponents) if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}

+ (NSString *)sha256ForFile:(NSString *)path error:(NSError **)error {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    if (stream.streamStatus == NSStreamStatusError) { if (error) *error = stream.streamError; return nil; }
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t buffer[1024 * 1024];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    NSError *streamError = stream.streamError;
    [stream close];
    if (count < 0 || streamError) { if (error) *error = streamError ?: [NSError errorWithDomain:@"OfflineModpack" code:2 userInfo:nil]; return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

+ (NSDictionary<NSString *, NSString *> *)checksumsAtPath:(NSString *)path error:(NSError **)error {
    NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
    if (!contents) return nil;
    NSMutableDictionary *checksums = [NSMutableDictionary new];
    NSCharacterSet *newlines = NSCharacterSet.newlineCharacterSet;
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:newlines]) {
        if (!line.length) continue;
        if (line.length < 67 || ![[line substringWithRange:NSMakeRange(64, 2)] isEqualToString:@"  "]) return nil;
        NSRange invalidCharacters = [[line substringToIndex:64] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]];
        if (invalidCharacters.location != NSNotFound) return nil;
        NSString *relativePath = [line substringFromIndex:66];
        if (![self isSafeRelativePath:relativePath] || checksums[relativePath]) return nil;
        checksums[relativePath] = [line substringToIndex:64];
    }
    if (!checksums.count) { [self fail:error description:@"The private pack checksum manifest is empty or malformed."]; return nil; }
    return checksums;
}

+ (BOOL)validateControl:(NSDictionary *)control checksums:(NSDictionary *)checksums error:(NSError **)error {
    NSString *profileName = control[@"profileName"];
    NSString *neoForge = control[@"neoforge"];
    NSCharacterSet *safeVersionCharacters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if (![profileName isKindOfClass:NSString.class] || ![neoForge isKindOfClass:NSString.class] || profileName.pathComponents.count != 1 || ![self isSafeRelativePath:profileName] || ![neoForge hasPrefix:@"neoforge-"] || neoForge.length == @"neoforge-".length || [neoForge rangeOfCharacterFromSet:safeVersionCharacters.invertedSet].location != NSNotFound ||
        ![control[@"format"] isEqual:@"amethyst-duo-offline-pack"] || [control[@"formatVersion"] integerValue] != 1 ||
        ![control[@"minecraftVersion"] isKindOfClass:NSString.class] ||
        ![control[@"neoforge"] isKindOfClass:NSString.class] || ![control[@"sha256sumsSHA256"] isKindOfClass:NSString.class] ||
        ![control[@"payloadBytes"] respondsToSelector:@selector(unsignedLongLongValue)] || ![control[@"fileCount"] respondsToSelector:@selector(unsignedLongLongValue)] ||
        [control[@"fileCount"] unsignedLongLongValue] != checksums.count || [control[@"payloadBytes"] unsignedLongLongValue] > OfflineMaxBytes || checksums.count > OfflineMaxEntries) {
        return [self fail:error description:@"This is not a valid Duo private offline-pack control manifest."];
    }
    return YES;
}

+ (BOOL)checkFreeSpaceForBytes:(unsigned long long)bytes atPath:(NSString *)path error:(NSError **)error {
    NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:error];
    unsigned long long free = [fs[NSFileSystemFreeSize] unsignedLongLongValue];
    // Source/archive, staging and filesystem metadata coexist during import; reserve 1 GiB beyond two payload copies.
    unsigned long long required = bytes > (ULLONG_MAX - 1024ULL * 1024 * 1024) / 2 ? ULLONG_MAX : bytes * 2 + 1024ULL * 1024 * 1024;
    if (!fs || free < required) return [self fail:error description:[NSString stringWithFormat:@"Not enough free storage for this private pack. Need %@ free (two payload copies plus 1 GiB working space), but only %@ is available.", [NSByteCountFormatter stringFromByteCount:required countStyle:NSByteCountFormatterCountStyleFile], [NSByteCountFormatter stringFromByteCount:free countStyle:NSByteCountFormatterCountStyleFile]]];
    return YES;
}

+ (BOOL)copyFile:(NSString *)source to:(NSString *)destination expectedSHA:(NSString *)expected error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] || ![fm copyItemAtPath:source toPath:destination error:error]) return NO;
    NSString *actual = [self sha256ForFile:destination error:error];
    if (!actual || ![actual isEqualToString:expected]) { [fm removeItemAtPath:destination error:nil]; return [self fail:error description:[NSString stringWithFormat:@"Integrity verification failed for %@.", destination.lastPathComponent]]; }
    return YES;
}

+ (BOOL)copyFolder:(NSString *)source checksums:(NSDictionary *)checksums to:(NSString *)staging progress:(NSProgress *)progress error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *relativePath in checksums) {
        NSString *sourceFile = [source stringByAppendingPathComponent:relativePath];
        NSNumber *isDirectory = nil, *isSymlink = nil;
        NSURL *url = [NSURL fileURLWithPath:sourceFile];
        if (![url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:error] || ![url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:error] || isDirectory.boolValue || isSymlink.boolValue || ![self copyFile:sourceFile to:[staging stringByAppendingPathComponent:relativePath] expectedSHA:checksums[relativePath] error:error]) return NO;
        progress.completedUnitCount++;
    }
    return YES;
}

+ (BOOL)extractArchive:(UZKArchive *)archive checksums:(NSDictionary *)checksums to:(NSString *)staging progress:(NSProgress *)progress error:(NSError **)error {
    NSArray<UZKFileInfo *> *entries = [archive listFileInfo:error];
    unsigned long long expanded = 0, files = 0;
    for (UZKFileInfo *info in entries) {
        NSString *name = info.filename;
        if (![self isSafeRelativePath:name] || ++files > OfflineMaxEntries || info.uncompressedSize > OfflineMaxSingleFile || expanded > OfflineMaxBytes - info.uncompressedSize || (info.uncompressedSize > 0 && (info.compressedSize == 0 || info.uncompressedSize / MAX(1ULL, info.compressedSize) > 100))) return [self fail:error description:@"The private pack archive exceeds safe size or compression-ratio limits."];
        expanded += info.uncompressedSize;
        if (!info.isDirectory && ![name isEqualToString:@"duo-offline-pack.json"] && ![name isEqualToString:@"SHA256SUMS.txt"] && !checksums[name]) return [self fail:error description:@"The private pack archive contains an unexpected file."];
    }
    if (!entries || expanded > OfflineMaxBytes) return [self fail:error description:@"The private pack archive cannot be read safely."];
    __block BOOL valid = YES;
    __block NSUInteger extractedFiles = 0;
    [archive performOnFilesInArchive:^(UZKFileInfo *info, BOOL *stop) {
        NSString *name = info.filename;
        if (info.isDirectory || [name isEqualToString:@"duo-offline-pack.json"] || [name isEqualToString:@"SHA256SUMS.txt"]) return;
        NSString *expected = checksums[name];
        if (![self isSafeRelativePath:name] || !expected) { valid = [self fail:error description:@"The private pack archive contains an unexpected or unsafe file."]; *stop = YES; return; }
        NSString *destination = [staging stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) { valid = NO; *stop = YES; return; }
        [[NSFileManager defaultManager] createFileAtPath:destination contents:nil attributes:nil];
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:destination];
        __block BOOL wrote = YES;
        BOOL extracted = [archive extractBufferedDataFromFile:name error:error action:^(NSData *chunk, CGFloat ignored) { @try { [out writeData:chunk]; } @catch (NSException *exception) { wrote = NO; } }];
        [out closeFile];
        NSString *actual = extracted && wrote ? [self sha256ForFile:destination error:error] : nil;
        if (!actual || ![actual isEqualToString:expected]) { valid = [self fail:error description:[NSString stringWithFormat:@"Archive extraction or integrity verification failed for %@.", name]]; *stop = YES; return; }
        extractedFiles++;
        progress.completedUnitCount++;
    } error:error];
    if (valid && extractedFiles != checksums.count) valid = [self fail:error description:@"The private pack archive is missing files declared by its integrity manifest."];
    return valid && (!error || !*error);
}

+ (void)publishStaging:(NSString *)staging control:(NSDictionary *)control downloader:(MinecraftResourceDownloadTask *)downloader {
    NSString *profileName = control[@"profileName"];
    NSString *minecraft = control[@"minecraftVersion"];
    NSString *neoforge = control[@"neoforge"];
    NSString *profileID = [neoforge hasPrefix:@"neoforge-"] ? neoforge : nil;
    NSString *gameDir = @(getenv("GAME_DIR"));
    NSString *destination = [gameDir stringByAppendingPathComponent:[@"custom_gamedir/" stringByAppendingString:profileName]];
    NSError *error = nil;
    if (!profileID || PLProfiles.current.profiles[profileName] || [NSFileManager.defaultManager fileExistsAtPath:destination]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:@"This private pack conflicts with an existing profile or game directory."]; return; }
    NSString *installer = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"neoforge-installers/%@-installer.jar", profileID]];
    if (![NSFileManager.defaultManager fileExistsAtPath:installer]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:@"The private pack is complete, but its verified NeoForge installer is missing. Transfer it privately to GAME_DIR/neoforge-installers before retrying."]; return; }
    __block BOOL installed = NO; __block NSString *installError = nil;
    launchNeoForgeInstaller(installer, profileID, gameDir, ^(BOOL success, NSString *message) { installed = success; installError = message; });
    if (!installed || downloader.progress.cancelled || ![NSFileManager.defaultManager moveItemAtPath:staging toPath:destination error:&error]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:installError ?: error.localizedDescription ?: @"NeoForge installation failed before this private pack could be published."]; return; }
    PLProfiles.current.profiles[profileName] = [@{ @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", profileName], @"name": profileName, @"lastVersionId": profileID, @"icon": @"" } mutableCopy];
    PLProfiles.current.selectedProfileName = profileName;
    [downloader finishDownloadWithSuccess];
}

+ (void)importPackAtPath:(NSString *)sourcePath downloader:(MinecraftResourceDownloadTask *)downloader {
    NSError *error = nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:sourcePath isDirectory:&isDirectory]) { [downloader finishDownloadWithErrorString:@"The selected private pack is no longer available."]; return; }
    NSString *controlPath = isDirectory ? [sourcePath stringByAppendingPathComponent:@"duo-offline-pack.json"] : nil;
    NSString *sumPath = isDirectory ? [sourcePath stringByAppendingPathComponent:@"SHA256SUMS.txt"] : nil;
    UZKArchive *archive = nil;
    NSData *controlData = nil, *sumData = nil;
    if (isDirectory) { controlData = [NSData dataWithContentsOfFile:controlPath options:0 error:&error]; sumData = [NSData dataWithContentsOfFile:sumPath options:0 error:&error]; }
    else {
        archive = [[UZKArchive alloc] initWithPath:sourcePath error:&error];
        if (archive) { controlData = [archive extractDataFromFile:@"duo-offline-pack.json" error:&error]; sumData = [archive extractDataFromFile:@"SHA256SUMS.txt" error:&error]; }
    }
    NSDictionary *control = controlData ? [NSJSONSerialization JSONObjectWithData:controlData options:0 error:&error] : nil;
    NSString *temporarySums = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".sha256"]];
    [sumData writeToFile:temporarySums options:NSDataWritingAtomic error:&error];
    NSDictionary *checksums = !error ? [self checksumsAtPath:temporarySums error:&error] : nil;
    [fm removeItemAtPath:temporarySums error:nil];
    NSString *actualManifestHash = isDirectory ? [self sha256ForFile:sumPath error:&error] : nil;
    if (!isDirectory && sumData) { NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]; [sumData writeToFile:temp atomically:YES]; actualManifestHash = [self sha256ForFile:temp error:&error]; [fm removeItemAtPath:temp error:nil]; }
    if (error || ![control isKindOfClass:NSDictionary.class] || !checksums || ![self validateControl:control checksums:checksums error:&error] || ![actualManifestHash isEqualToString:control[@"sha256sumsSHA256"]]) { [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"The private pack control or checksum manifest is invalid."]; return; }
    unsigned long long bytes = [control[@"payloadBytes"] unsignedLongLongValue];
    if (![self checkFreeSpaceForBytes:bytes atPath:@(getenv("GAME_DIR")) error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    downloader.progress.totalUnitCount = checksums.count + 1;
    NSString *staging = [[@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"custom_gamedir"] stringByAppendingPathComponent:[NSString stringWithFormat:@".offline-installing-%@", NSUUID.UUID.UUIDString]];
    [fm removeItemAtPath:staging error:nil];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    BOOL copied = isDirectory ? [self copyFolder:sourcePath checksums:checksums to:staging progress:downloader.progress error:&error] : [self extractArchive:archive checksums:checksums to:staging progress:downloader.progress error:&error];
    if (!copied || downloader.progress.cancelled) { [fm removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"Private pack import was cancelled or failed integrity verification."]; return; }
    downloader.progress.completedUnitCount++;
    [self publishStaging:staging control:control downloader:downloader];
}

+ (BOOL)isOfflinePackAtPath:(NSString *)path {
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]) return NO;
    if (isDirectory) return [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"duo-offline-pack.json"]];
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:&error];
    if (!archive) return NO;
    NSData *controlData = [archive extractDataFromFile:@"duo-offline-pack.json" error:&error];
    NSDictionary *control = controlData ? [NSJSONSerialization JSONObjectWithData:controlData options:0 error:&error] : nil;
    return !error && [control isKindOfClass:NSDictionary.class] && [control[@"format"] isEqual:@"amethyst-duo-offline-pack"] && [control[@"formatVersion"] integerValue] == 1;
}
@end
