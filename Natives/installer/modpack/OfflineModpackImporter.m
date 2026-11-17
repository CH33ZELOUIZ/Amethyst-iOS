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
static const unsigned long long OfflineMaxControlBytes = 1024ULL * 1024;
static const unsigned long long OfflineMaxChecksumBytes = 4ULL * 1024 * 1024;
static const unsigned long long OfflineMaxCompressionRatio = 100;

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

+ (BOOL)isSafeArchiveEntry:(UZKFileInfo *)info maximumBytes:(unsigned long long)maximumBytes error:(NSError **)error {
    if (![self isSafeRelativePath:info.filename] || (info.posixPermissions & 0170000) == 0120000 || info.isEncryptedWithPassword ||
        info.uncompressedSize > maximumBytes || (info.uncompressedSize > 0 && (info.compressedSize == 0 || info.uncompressedSize / MAX(1ULL, info.compressedSize) > OfflineMaxCompressionRatio))) {
        return [self fail:error description:@"The private pack archive contains an unsafe or excessively compressed entry."];
    }
    return YES;
}

+ (NSData *)readArchiveFile:(UZKArchive *)archive info:(UZKFileInfo *)info maximumBytes:(unsigned long long)maximumBytes error:(NSError **)error {
    if (![self isSafeArchiveEntry:info maximumBytes:maximumBytes error:error]) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)info.uncompressedSize];
    __block BOOL overflow = NO;
    BOOL extracted = [archive extractBufferedDataFromFile:info.filename error:error action:^(NSData *chunk, CGFloat ignored) {
        if (chunk.length > maximumBytes - data.length) { overflow = YES; return; }
        [data appendData:chunk];
    }];
    if (!extracted || overflow || data.length != info.uncompressedSize) {
        [self fail:error description:@"The private pack control or checksum entry exceeds its safe size."];
        return nil;
    }
    return data;
}

+ (NSData *)readBoundedRegularFile:(NSString *)path maximumBytes:(unsigned long long)maximumBytes error:(NSError **)error {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
    if (!attributes || [attributes[NSFileType] isEqual:NSFileTypeSymbolicLink] || ![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > maximumBytes) {
        [self fail:error description:@"The private pack control or checksum file is unsafe or too large."];
        return nil;
    }
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)[attributes[NSFileSize] unsignedLongLongValue]];
    uint8_t buffer[64 * 1024]; NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        if ((unsigned long long)data.length > maximumBytes - (unsigned long long)count) { [stream close]; [self fail:error description:@"The private pack control or checksum file exceeds its safe size."]; return nil; }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    NSError *streamError = stream.streamError; [stream close];
    if (count < 0 || streamError) { if (error) *error = streamError; return nil; }
    return data;
}

+ (NSString *)sha256ForFile:(NSString *)path error:(NSError **)error {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    if (stream.streamStatus == NSStreamStatusError) { if (error) *error = stream.streamError; return nil; }
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t buffer[1024 * 1024]; NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    NSError *streamError = stream.streamError; [stream close];
    if (count < 0 || streamError) { if (error) *error = streamError ?: [NSError errorWithDomain:@"OfflineModpack" code:2 userInfo:nil]; return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

+ (NSString *)sha256ForData:(NSData *)data {
    CC_SHA256_CTX context; CC_SHA256_Init(&context); CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

+ (NSDictionary<NSString *, NSString *> *)checksumsFromData:(NSData *)data error:(NSError **)error {
    NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!contents) return nil;
    NSMutableDictionary *checksums = [NSMutableDictionary new];
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length) continue;
        if (line.length < 67 || ![[line substringWithRange:NSMakeRange(64, 2)] isEqual:@"  "]) return nil;
        if ([[line substringToIndex:64] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return nil;
        NSString *relativePath = [line substringFromIndex:66];
        if (![self isSafeRelativePath:relativePath] || checksums[relativePath]) return nil;
        checksums[relativePath] = [line substringToIndex:64];
    }
    if (!checksums.count) { [self fail:error description:@"The private pack checksum manifest is empty or malformed."]; return nil; }
    return checksums;
}

+ (BOOL)validateControl:(NSDictionary *)control checksums:(NSDictionary *)checksums error:(NSError **)error {
    NSString *profileName = control[@"profileName"], *neoForge = control[@"neoforge"];
    NSCharacterSet *safeVersionCharacters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if (![profileName isKindOfClass:NSString.class] || ![neoForge isKindOfClass:NSString.class] || profileName.pathComponents.count != 1 || ![self isSafeRelativePath:profileName] || ![neoForge hasPrefix:@"neoforge-"] || neoForge.length == @"neoforge-".length || [neoForge rangeOfCharacterFromSet:safeVersionCharacters.invertedSet].location != NSNotFound ||
        ![control[@"format"] isEqual:@"amethyst-duo-offline-pack"] || [control[@"formatVersion"] integerValue] != 1 || ![control[@"minecraftVersion"] isKindOfClass:NSString.class] || ![control[@"sha256sumsSHA256"] isKindOfClass:NSString.class] ||
        ![control[@"payloadBytes"] respondsToSelector:@selector(unsignedLongLongValue)] || ![control[@"fileCount"] respondsToSelector:@selector(unsignedLongLongValue)] ||
        [control[@"fileCount"] unsignedLongLongValue] != checksums.count || [control[@"payloadBytes"] unsignedLongLongValue] > OfflineMaxBytes || checksums.count > OfflineMaxEntries) return [self fail:error description:@"This is not a valid Duo private offline-pack control manifest."];
    return YES;
}

+ (BOOL)checkFreeSpaceForBytes:(unsigned long long)bytes atPath:(NSString *)path error:(NSError **)error {
    NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:path error:error];
    unsigned long long free = [fs[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long required = bytes > (ULLONG_MAX - 1024ULL * 1024 * 1024) / 2 ? ULLONG_MAX : bytes * 2 + 1024ULL * 1024 * 1024;
    if (!fs || free < required) return [self fail:error description:[NSString stringWithFormat:@"Not enough free storage for this private pack. Need %@ free (two payload copies plus 1 GiB working space), but only %@ is available.", [NSByteCountFormatter stringFromByteCount:required countStyle:NSByteCountFormatterCountStyleFile], [NSByteCountFormatter stringFromByteCount:free countStyle:NSByteCountFormatterCountStyleFile]]];
    return YES;
}

+ (BOOL)validatedArchive:(UZKArchive *)archive controlInfo:(UZKFileInfo **)controlInfo sumsInfo:(UZKFileInfo **)sumsInfo entries:(NSArray<UZKFileInfo *> **)archiveEntries error:(NSError **)error {
    NSArray<UZKFileInfo *> *entries = [archive listFileInfo:error];
    UZKFileInfo *control = nil, *sums = nil;
    unsigned long long expanded = 0; NSUInteger count = 0;
    unsigned long long maximumArchiveBytes = OfflineMaxBytes + OfflineMaxControlBytes + OfflineMaxChecksumBytes;
    for (UZKFileInfo *info in entries) {
        if (++count > OfflineMaxEntries || ![self isSafeArchiveEntry:info maximumBytes:OfflineMaxSingleFile error:error] || expanded > maximumArchiveBytes - info.uncompressedSize) return NO;
        expanded += info.uncompressedSize;
        if ([info.filename isEqual:@"duo-offline-pack.json"]) { if (control || info.isDirectory || ![self isSafeArchiveEntry:info maximumBytes:OfflineMaxControlBytes error:error]) return [self fail:error description:@"The private pack archive must contain one safe control file."]; control = info; }
        if ([info.filename isEqual:@"SHA256SUMS.txt"]) { if (sums || info.isDirectory || ![self isSafeArchiveEntry:info maximumBytes:OfflineMaxChecksumBytes error:error]) return [self fail:error description:@"The private pack archive must contain one safe checksum file."]; sums = info; }
    }
    if (!entries || !control || !sums) return [self fail:error description:@"The private pack archive cannot be read safely."];
    if (controlInfo) *controlInfo = control; if (sumsInfo) *sumsInfo = sums; if (archiveEntries) *archiveEntries = entries;
    return YES;
}

+ (BOOL)validateArchivePayloadEntries:(NSArray<UZKFileInfo *> *)entries checksums:(NSDictionary *)checksums actualBytes:(unsigned long long *)actualBytes error:(NSError **)error {
    NSMutableSet *seen = [NSMutableSet set]; unsigned long long bytes = 0;
    for (UZKFileInfo *info in entries) {
        if (info.isDirectory || [info.filename isEqual:@"duo-offline-pack.json"] || [info.filename isEqual:@"SHA256SUMS.txt"]) continue;
        if (!checksums[info.filename] || [seen containsObject:info.filename] || info.uncompressedSize > OfflineMaxSingleFile || bytes > OfflineMaxBytes - info.uncompressedSize) return [self fail:error description:@"The private pack archive contains an unexpected or oversized payload file."];
        [seen addObject:info.filename];
        bytes += info.uncompressedSize;
    }
    if (seen.count != checksums.count) return [self fail:error description:@"The private pack archive is missing files declared by its integrity manifest."];
    if (actualBytes) *actualBytes = bytes;
    return YES;
}

+ (NSString *)validatedFolderFile:(NSString *)root relativePath:(NSString *)relativePath error:(NSError **)error {
    NSString *canonicalRoot = root.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    if (![root.stringByStandardizingPath isEqual:canonicalRoot] || ![self isSafeRelativePath:relativePath]) { [self fail:error description:@"The private pack folder contains a symbolic link or unsafe path."]; return nil; }
    NSString *candidate = canonicalRoot;
    for (NSString *component in relativePath.pathComponents) {
        candidate = [candidate stringByAppendingPathComponent:component];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:candidate error:error];
        if (!attributes || [attributes[NSFileType] isEqual:NSFileTypeSymbolicLink]) { [self fail:error description:@"The private pack folder contains a symbolic link or missing payload file."]; return nil; }
    }
    if (![candidate.stringByResolvingSymlinksInPath.stringByStandardizingPath hasPrefix:[canonicalRoot stringByAppendingString:@"/"]]) { [self fail:error description:@"The private pack folder payload escapes its root."]; return nil; }
    return candidate;
}

+ (BOOL)folderPayloadBytesAtRoot:(NSString *)root checksums:(NSDictionary *)checksums actualBytes:(unsigned long long *)actualBytes error:(NSError **)error {
    unsigned long long bytes = 0;
    for (NSString *relativePath in checksums) {
        NSString *file = [self validatedFolderFile:root relativePath:relativePath error:error];
        NSDictionary *attributes = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file error:error] : nil;
        if (!attributes || ![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > OfflineMaxSingleFile || bytes > OfflineMaxBytes - [attributes[NSFileSize] unsignedLongLongValue]) return [self fail:error description:@"The private pack folder contains an invalid or oversized payload file."];
        bytes += [attributes[NSFileSize] unsignedLongLongValue];
    }
    if (actualBytes) *actualBytes = bytes;
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
    for (NSString *relativePath in checksums) {
        NSString *sourceFile = [self validatedFolderFile:source relativePath:relativePath error:error];
        if (!sourceFile || ![self copyFile:sourceFile to:[staging stringByAppendingPathComponent:relativePath] expectedSHA:checksums[relativePath] error:error]) return NO;
        progress.completedUnitCount++;
    }
    return YES;
}

+ (BOOL)extractArchive:(UZKArchive *)archive checksums:(NSDictionary *)checksums entries:(NSArray<UZKFileInfo *> *)entries to:(NSString *)staging progress:(NSProgress *)progress error:(NSError **)error {
    __block BOOL valid = YES; __block NSUInteger extractedFiles = 0;
    for (UZKFileInfo *info in entries) {
        NSString *name = info.filename;
        if (info.isDirectory || [name isEqual:@"duo-offline-pack.json"] || [name isEqual:@"SHA256SUMS.txt"]) continue;
        NSString *destination = [staging stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        [[NSFileManager defaultManager] createFileAtPath:destination contents:nil attributes:nil];
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:destination]; __block unsigned long long written = 0; __block BOOL wrote = YES;
        BOOL extracted = [archive extractBufferedDataFromFile:name error:error action:^(NSData *chunk, CGFloat ignored) { if (chunk.length > info.uncompressedSize - written) { wrote = NO; return; } @try { [out writeData:chunk]; written += chunk.length; } @catch (NSException *exception) { wrote = NO; } }];
        [out closeFile];
        NSString *actual = extracted && wrote && written == info.uncompressedSize ? [self sha256ForFile:destination error:error] : nil;
        if (!actual || ![actual isEqualToString:checksums[name]]) { valid = [self fail:error description:[NSString stringWithFormat:@"Archive extraction or integrity verification failed for %@.", name]]; break; }
        extractedFiles++; progress.completedUnitCount++;
    }
    return valid && extractedFiles == checksums.count && (!error || !*error);
}

+ (void)publishStaging:(NSString *)staging control:(NSDictionary *)control downloader:(MinecraftResourceDownloadTask *)downloader {
    NSString *profileName = control[@"profileName"], *minecraft = control[@"minecraftVersion"], *neoforge = control[@"neoforge"];
    NSString *profileID = [neoforge hasPrefix:@"neoforge-"] ? neoforge : nil, *gameDir = @(getenv("GAME_DIR"));
    NSString *destination = [gameDir stringByAppendingPathComponent:[@"custom_gamedir/" stringByAppendingString:profileName]]; NSError *error = nil;
    if (!profileID || PLProfiles.current.profiles[profileName] || [NSFileManager.defaultManager fileExistsAtPath:destination]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:@"This private pack conflicts with an existing profile or game directory."]; return; }
    NSString *installer = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"neoforge-installers/%@-installer.jar", profileID]];
    if (![NSFileManager.defaultManager fileExistsAtPath:installer]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:@"The private pack is complete, but its verified NeoForge installer is missing. Transfer it privately to GAME_DIR/neoforge-installers before retrying."]; return; }
    __block BOOL installed = NO; __block NSString *installError = nil;
    launchNeoForgeInstaller(installer, profileID, gameDir, ^(BOOL success, NSString *message) { installed = success; installError = message; });
    if (!installed || downloader.progress.cancelled || ![NSFileManager.defaultManager moveItemAtPath:staging toPath:destination error:&error]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:installError ?: error.localizedDescription ?: @"NeoForge installation failed before this private pack could be published."]; return; }
    PLProfiles.current.profiles[profileName] = [@{ @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", profileName], @"name": profileName, @"lastVersionId": profileID, @"icon": @"" } mutableCopy];
    PLProfiles.current.selectedProfileName = profileName; [downloader finishDownloadWithSuccess];
}

+ (void)importPackAtPath:(NSString *)sourcePath downloader:(MinecraftResourceDownloadTask *)downloader {
    NSError *error = nil; NSFileManager *fm = NSFileManager.defaultManager; BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:sourcePath isDirectory:&isDirectory]) { [downloader finishDownloadWithErrorString:@"The selected private pack is no longer available."]; return; }
    NSData *controlData = nil, *sumData = nil; UZKArchive *archive = nil; NSArray<UZKFileInfo *> *entries = nil; UZKFileInfo *controlInfo = nil, *sumsInfo = nil;
    if (isDirectory) {
        NSString *controlPath = [self validatedFolderFile:sourcePath relativePath:@"duo-offline-pack.json" error:&error];
        controlData = controlPath ? [self readBoundedRegularFile:controlPath maximumBytes:OfflineMaxControlBytes error:&error] : nil;
        NSString *sumPath = !error ? [self validatedFolderFile:sourcePath relativePath:@"SHA256SUMS.txt" error:&error] : nil;
        sumData = sumPath ? [self readBoundedRegularFile:sumPath maximumBytes:OfflineMaxChecksumBytes error:&error] : nil;
    }
    else { archive = [[UZKArchive alloc] initWithPath:sourcePath error:&error]; if (archive && [self validatedArchive:archive controlInfo:&controlInfo sumsInfo:&sumsInfo entries:&entries error:&error]) { controlData = [self readArchiveFile:archive info:controlInfo maximumBytes:OfflineMaxControlBytes error:&error]; sumData = !error ? [self readArchiveFile:archive info:sumsInfo maximumBytes:OfflineMaxChecksumBytes error:&error] : nil; } }
    NSDictionary *control = controlData ? [NSJSONSerialization JSONObjectWithData:controlData options:0 error:&error] : nil;
    NSDictionary *checksums = !error ? [self checksumsFromData:sumData error:&error] : nil;
    NSString *actualManifestHash = sumData ? [self sha256ForData:sumData] : nil;
    unsigned long long actualBytes = 0;
    BOOL payloadValid = isDirectory ? [self folderPayloadBytesAtRoot:sourcePath checksums:checksums actualBytes:&actualBytes error:&error] : [self validateArchivePayloadEntries:entries checksums:checksums actualBytes:&actualBytes error:&error];
    if (error || ![control isKindOfClass:NSDictionary.class] || !checksums || ![self validateControl:control checksums:checksums error:&error] || !payloadValid || actualBytes != [control[@"payloadBytes"] unsignedLongLongValue] || ![actualManifestHash isEqualToString:control[@"sha256sumsSHA256"]]) { [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"The private pack control, checksum manifest, or payload size is invalid."]; return; }
    if (![self checkFreeSpaceForBytes:actualBytes atPath:@(getenv("GAME_DIR")) error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    downloader.progress.totalUnitCount = checksums.count + 1;
    NSString *staging = [[@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"custom_gamedir"] stringByAppendingPathComponent:[NSString stringWithFormat:@".offline-installing-%@", NSUUID.UUID.UUIDString]];
    [fm removeItemAtPath:staging error:nil];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    BOOL copied = isDirectory ? [self copyFolder:sourcePath checksums:checksums to:staging progress:downloader.progress error:&error] : [self extractArchive:archive checksums:checksums entries:entries to:staging progress:downloader.progress error:&error];
    if (!copied || downloader.progress.cancelled) { [fm removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"Private pack import was cancelled or failed integrity verification."]; return; }
    downloader.progress.completedUnitCount++; [self publishStaging:staging control:control downloader:downloader];
}

+ (BOOL)isOfflinePackAtPath:(NSString *)path {
    NSError *error = nil; BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]) return NO;
    if (isDirectory) {
        NSString *controlPath = [self validatedFolderFile:path relativePath:@"duo-offline-pack.json" error:&error];
        NSData *data = controlPath ? [self readBoundedRegularFile:controlPath maximumBytes:OfflineMaxControlBytes error:&error] : nil;
        NSDictionary *control = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        return !error && [control isKindOfClass:NSDictionary.class] && [control[@"format"] isEqual:@"amethyst-duo-offline-pack"] && [control[@"formatVersion"] integerValue] == 1;
    }
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:&error]; UZKFileInfo *control = nil, *sums = nil;
    if (!archive || ![self validatedArchive:archive controlInfo:&control sumsInfo:&sums entries:nil error:&error]) return NO;
    NSData *data = [self readArchiveFile:archive info:control maximumBytes:OfflineMaxControlBytes error:&error]; NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    return !error && [manifest isKindOfClass:NSDictionary.class] && [manifest[@"format"] isEqual:@"amethyst-duo-offline-pack"] && [manifest[@"formatVersion"] integerValue] == 1;
}
@end
