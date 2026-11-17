#import <CommonCrypto/CommonDigest.h>
#include <limits.h>
#import "JavaLauncher.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "packs/DuoPackLibrary.h"
#import "OfflineModpackImporter.h"
#import "ModpackUtils.h"
#import "OfflineVanillaSeed.h"

static const unsigned long long OfflineMaxEntries = 12000;
static const unsigned long long OfflineMaxBytes = 2ULL * 1024 * 1024 * 1024;
static const unsigned long long OfflineMaxSingleFile = 512ULL * 1024 * 1024;
static const unsigned long long OfflineMaxControlBytes = 1024ULL * 1024;
static const unsigned long long OfflineMaxChecksumBytes = 4ULL * 1024 * 1024;
static const unsigned long long OfflineMaxCompressionRatio = 100;
static const unsigned long long OfflineMaxCentralDirectoryBytes = 16ULL * 1024 * 1024;
static const unsigned long long OfflineMaxInstallerBytes = 128ULL * 1024 * 1024;
static NSString * const OfflineNeoForge211264InstallerSHA256 = @"d7c035dd5436a7c524dfbad6df191b0ef34179fd3edfee9dc99262af3b80239b";

static uint16_t OfflineLE16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t OfflineLE32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

@implementation OfflineModpackImporter

+ (BOOL)preflightZipAtPath:(NSString *)path error:(NSError **)error {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (!attributes || ![attributes[NSFileType] isEqual:NSFileTypeRegular] || size < 22) return [self fail:error description:@"The private pack is not a regular ZIP file."];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    unsigned long long tailSize = MIN(size, 22ULL + 65535ULL);
    @try { [handle seekToFileOffset:size - tailSize]; } @catch (NSException *exception) { return [self fail:error description:@"The private pack ZIP cannot be read."]; }
    NSData *tail = [handle readDataToEndOfFile]; [handle closeFile];
    const uint8_t *bytes = tail.bytes; NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)tail.length - 22; i >= 0; i--) if (OfflineLE32(bytes + i) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0 || (NSUInteger)eocd + 22 + OfflineLE16(bytes + eocd + 20) != tail.length) return [self fail:error description:@"The private pack ZIP has no valid end-of-central-directory record."];
    uint16_t disk = OfflineLE16(bytes + eocd + 4), directoryDisk = OfflineLE16(bytes + eocd + 6), entries = OfflineLE16(bytes + eocd + 10);
    uint32_t directoryBytes = OfflineLE32(bytes + eocd + 12), directoryOffset = OfflineLE32(bytes + eocd + 16);
    if (disk || directoryDisk || entries == UINT16_MAX || directoryBytes == UINT32_MAX || directoryOffset == UINT32_MAX || entries > OfflineMaxEntries || directoryBytes > OfflineMaxCentralDirectoryBytes || (unsigned long long)directoryOffset + directoryBytes > size) return [self fail:error description:@"The private pack ZIP central directory exceeds supported safety bounds or requires unsupported ZIP64 metadata."];
    return YES;
}

+ (NSString *)filesystemIdentityForPath:(NSString *)path {
    return [[path precomposedStringWithCanonicalMapping] lowercaseString];
}

+ (BOOL)validateDestinationCollisions:(NSDictionary<NSString *, NSString *> *)checksums error:(NSError **)error {
    NSMutableSet *files = [NSMutableSet set], *ancestors = [NSMutableSet set];
    for (NSString *path in checksums) {
        NSString *identity = [self filesystemIdentityForPath:path];
        if ([files containsObject:identity] || [ancestors containsObject:identity] || [identity isEqualToString:[self filesystemIdentityForPath:@"duo-offline-pack.json"]] || [identity isEqualToString:[self filesystemIdentityForPath:@"SHA256SUMS.txt"]]) return [self fail:error description:@"The private pack contains filesystem-normalized destination collisions."];
        NSArray *components = identity.pathComponents;
        NSMutableArray *prefix = [NSMutableArray array];
        for (NSUInteger i = 0; i + 1 < components.count; i++) { [prefix addObject:components[i]]; NSString *ancestor = [prefix componentsJoinedByString:@"/"]; if ([files containsObject:ancestor]) return [self fail:error description:@"The private pack contains a file/directory destination collision."]; [ancestors addObject:ancestor]; }
        [files addObject:identity];
    }
    return YES;
}

+ (NSString *)trustedInstallerHashForProfileID:(NSString *)profileID {
    return [profileID isEqualToString:@"neoforge-21.1.264"] ? OfflineNeoForge211264InstallerSHA256 : nil;
}

+ (BOOL)validateTrustedInstaller:(NSString *)installer profileID:(NSString *)profileID error:(NSError **)error {
    NSString *expected = [self trustedInstallerHashForProfileID:profileID];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:installer error:error];
    if (!expected || !attributes || [attributes[NSFileType] isEqual:NSFileTypeSymbolicLink] || ![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > OfflineMaxInstallerBytes) return [self fail:error description:@"The required NeoForge installer is unsupported, unsafe, or missing."];
    NSString *actual = [self sha256ForFile:installer error:error];
    return actual && [actual isEqualToString:expected] ? YES : [self fail:error description:@"The required NeoForge installer does not match Duo's trusted official SHA-256."];
}

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
        ![control[@"payloadBytes"] respondsToSelector:@selector(unsignedLongLongValue)] || ![control[@"minimumRamMiB"] respondsToSelector:@selector(unsignedLongLongValue)] || ![control[@"desktopRecommendedRamMiB"] respondsToSelector:@selector(unsignedLongLongValue)] ||
        [control[@"fileCount"] unsignedLongLongValue] != checksums.count || [control[@"payloadBytes"] unsignedLongLongValue] > OfflineMaxBytes || checksums.count > OfflineMaxEntries ||
        [control[@"minimumRamMiB"] unsignedLongLongValue] < 4096 || [control[@"desktopRecommendedRamMiB"] unsignedLongLongValue] < 6016 || [control[@"desktopRecommendedRamMiB"] unsignedLongLongValue] < [control[@"minimumRamMiB"] unsignedLongLongValue]) return [self fail:error description:@"This is not a valid Duo private offline-pack control manifest."];
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
        if (extractedFiles % 250 == 0 || extractedFiles == checksums.count) NSLog(@"[ModpackImport] Extracted %lu/%lu files", (unsigned long)extractedFiles, (unsigned long)checksums.count);
    }
    return valid && extractedFiles == checksums.count && (!error || !*error);
}

+ (BOOL)publishInstallerLibrariesFrom:(NSString *)sourceRoot toGameRoot:(NSString *)gameRoot created:(NSMutableArray<NSString *> *)created error:(NSError **)error {
    NSString *sourceLibraries = [sourceRoot stringByAppendingPathComponent:@"libraries"], *destinationLibraries = [gameRoot stringByAppendingPathComponent:@"libraries"];
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:sourceLibraries];
    for (NSString *relativePath in enumerator) {
        NSString *source = [sourceLibraries stringByAppendingPathComponent:relativePath];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:source error:error];
        if (!attributes || [attributes[NSFileType] isEqual:NSFileTypeSymbolicLink]) return [self fail:error description:@"The NeoForge installer produced an unsafe library path."];
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
        NSString *destination = [destinationLibraries stringByAppendingPathComponent:relativePath];
        if ([NSFileManager.defaultManager fileExistsAtPath:destination]) {
            if (![[self sha256ForFile:source error:error] isEqualToString:[self sha256ForFile:destination error:error]]) return [self fail:error description:@"NeoForge library output conflicts with an existing file."];
            continue;
        }
        if (![NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] || ![NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:error]) return NO;
        [created addObject:destination];
    }
    return YES;
}

+ (void)publishStaging:(NSString *)staging control:(NSDictionary *)control downloader:(MinecraftResourceDownloadTask *)downloader {
    NSString *profileName = control[@"profileName"], *minecraft = control[@"minecraftVersion"], *neoforge = control[@"neoforge"];
    NSString *profileID = [neoforge hasPrefix:@"neoforge-"] ? neoforge : nil, *gameDir = @(getenv("GAME_DIR"));
    NSString *destination = [gameDir stringByAppendingPathComponent:[@"custom_gamedir/" stringByAppendingString:profileName]]; NSError *error = nil;
    if (!profileID || PLProfiles.current.profiles[profileName] || [NSFileManager.defaultManager fileExistsAtPath:destination]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:@"This private pack conflicts with an existing profile or game directory."]; return; }
    NSString *installer = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"neoforge-installers/%@-installer.jar", profileID]];
    if (![self validateTrustedInstaller:installer profileID:profileID error:&error]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    NSString *installerRoot = [[gameDir stringByAppendingPathComponent:@"custom_gamedir"] stringByAppendingPathComponent:[NSString stringWithFormat:@".offline-neoforge-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager removeItemAtPath:installerRoot error:nil];
    if (![NSFileManager.defaultManager createDirectoryAtPath:installerRoot withIntermediateDirectories:YES attributes:nil error:&error]) { [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    // NeoForge ClientInstall needs vanilla prerequisites in its root: seed only verified regular files from GAME_DIR.
    char seedError[512] = {0};
    if (OfflineSeedVanillaRoot(gameDir.fileSystemRepresentation, installerRoot.fileSystemRepresentation, minecraft.UTF8String, seedError, sizeof seedError) != 0) { [NSFileManager.defaultManager removeItemAtPath:installerRoot error:nil]; [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:@(seedError)]; return; }
    [downloader reportPhase:@"Installing NeoForge (this can take several minutes)"];
    __block BOOL installed = NO; __block NSString *installError = nil;
    // Install in a disposable root: GAME_DIR is untouched until the verified output is published.
    launchNeoForgeInstaller(installer, profileID, installerRoot, ^(BOOL success, NSString *message) { installed = success; installError = message; });
    [downloader reportPhase:installed ? @"NeoForge installed; publishing transactionally" : @"NeoForge installation failed"];
    NSString *generatedVersion = [NSString stringWithFormat:@"%@/versions/%@", installerRoot, profileID];
    NSString *publishedVersion = [NSString stringWithFormat:@"%@/versions/%@", gameDir, profileID];
    if (!installed || downloader.progress.cancelled || ![NSFileManager.defaultManager fileExistsAtPath:generatedVersion] || [NSFileManager.defaultManager fileExistsAtPath:publishedVersion]) { [NSFileManager.defaultManager removeItemAtPath:installerRoot error:nil]; [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:installError ?: @"NeoForge installation failed before this private pack could be published."]; return; }
    NSMutableArray<NSString *> *createdLibraries = [NSMutableArray new];
    BOOL librariesPublished = [self publishInstallerLibrariesFrom:installerRoot toGameRoot:gameDir created:createdLibraries error:&error];
    if (!librariesPublished || ![NSFileManager.defaultManager createDirectoryAtPath:publishedVersion.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] || ![NSFileManager.defaultManager moveItemAtPath:generatedVersion toPath:publishedVersion error:&error] || ![NSFileManager.defaultManager moveItemAtPath:staging toPath:destination error:&error]) { for (NSString *library in createdLibraries) [NSFileManager.defaultManager removeItemAtPath:library error:nil]; [NSFileManager.defaultManager removeItemAtPath:publishedVersion error:nil]; [NSFileManager.defaultManager removeItemAtPath:installerRoot error:nil]; [NSFileManager.defaultManager removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"NeoForge installation could not be published atomically."]; return; }
    [NSFileManager.defaultManager removeItemAtPath:installerRoot error:nil];
    [downloader reportPhase:@"Saving profile"];
    PLProfiles *profiles = PLProfiles.current;
    NSMutableDictionary *previousProfile = profiles.profiles[profileName];
    NSString *previousSelection = profiles.selectedProfileName;
    profiles.profiles[profileName] = [@{ @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", profileName], @"name": profileName, @"lastVersionId": profileID, @"icon": @"" } mutableCopy];
    [DuoPackLibrary markProfile:profiles.profiles[profileName] source:@"offline"];
    profiles.profileDict[@"selectedProfile"] = profileName;
    if (![profiles save:&error]) {
        if (previousProfile) profiles.profiles[profileName] = previousProfile; else [profiles.profiles removeObjectForKey:profileName];
        profiles.profileDict[@"selectedProfile"] = previousSelection;
        [profiles save:nil];
        [NSFileManager.defaultManager removeItemAtPath:destination error:nil];
        [NSFileManager.defaultManager removeItemAtPath:publishedVersion error:nil];
        for (NSString *library in createdLibraries) [NSFileManager.defaultManager removeItemAtPath:library error:nil];
        [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"The profile could not be persisted; the private pack was rolled back."];
        return;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:profiles];
    [downloader finishDownloadWithSuccess];
}

+ (void)importPackAtPath:(NSString *)sourcePath downloader:(MinecraftResourceDownloadTask *)downloader {
    NSError *error = nil; NSFileManager *fm = NSFileManager.defaultManager; BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:sourcePath isDirectory:&isDirectory]) { [downloader finishDownloadWithErrorString:@"The selected private pack is no longer available."]; return; }
    NSData *controlData = nil, *sumData = nil; UZKArchive *archive = nil; NSArray<UZKFileInfo *> *entries = nil; UZKFileInfo *controlInfo = nil, *sumsInfo = nil;
    if (isDirectory) { [downloader finishDownloadWithErrorString:@"Private offline packs must be imported as bounded ZIP files; folder imports are not supported."]; return; }
    [downloader reportPhase:@"ZIP preflight (central directory bounds)"];
    if (![self preflightZipAtPath:sourcePath error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    [downloader reportPhase:@"Reading manifest and checksums"];
    archive = [[UZKArchive alloc] initWithPath:sourcePath error:&error];
    if (archive && [self validatedArchive:archive controlInfo:&controlInfo sumsInfo:&sumsInfo entries:&entries error:&error]) {
        controlData = [self readArchiveFile:archive info:controlInfo maximumBytes:OfflineMaxControlBytes error:&error];
        sumData = !error ? [self readArchiveFile:archive info:sumsInfo maximumBytes:OfflineMaxChecksumBytes error:&error] : nil;
    }
    NSDictionary *control = controlData ? [NSJSONSerialization JSONObjectWithData:controlData options:0 error:&error] : nil;
    NSDictionary *checksums = !error ? [self checksumsFromData:sumData error:&error] : nil;
    NSString *actualManifestHash = sumData ? [self sha256ForData:sumData] : nil;
    unsigned long long actualBytes = 0;
    BOOL payloadValid = [self validateArchivePayloadEntries:entries checksums:checksums actualBytes:&actualBytes error:&error];
    if (error || ![control isKindOfClass:NSDictionary.class] || !checksums || ![self validateDestinationCollisions:checksums error:&error] || ![self validateControl:control checksums:checksums error:&error] || !payloadValid || actualBytes != [control[@"payloadBytes"] unsignedLongLongValue] || ![actualManifestHash isEqualToString:control[@"sha256sumsSHA256"]]) { [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"The private pack control, checksum manifest, or payload size is invalid."]; return; }
    [downloader reportPhase:[NSString stringWithFormat:@"Checking free space for %llu MiB payload", actualBytes / (1024ULL * 1024ULL)]];
    if (![self checkFreeSpaceForBytes:actualBytes atPath:@(getenv("GAME_DIR")) error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    downloader.progress.totalUnitCount = checksums.count + 1;
    NSString *staging = [[@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"custom_gamedir"] stringByAppendingPathComponent:[NSString stringWithFormat:@".offline-installing-%@", NSUUID.UUID.UUIDString]];
    [fm removeItemAtPath:staging error:nil];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:&error]) { [downloader finishDownloadWithErrorString:error.localizedDescription]; return; }
    [downloader reportPhase:[NSString stringWithFormat:@"Extracting and verifying %lu files (%llu MiB)", (unsigned long)checksums.count, actualBytes / (1024ULL * 1024ULL)]];
    BOOL copied = [self extractArchive:archive checksums:checksums entries:entries to:staging progress:downloader.progress error:&error];
    if (!copied || downloader.progress.cancelled) { [fm removeItemAtPath:staging error:nil]; [downloader finishDownloadWithErrorString:error.localizedDescription ?: @"Private pack import was cancelled or failed integrity verification."]; return; }
    downloader.progress.completedUnitCount++; [downloader reportPhase:@"Extraction verified; preparing NeoForge"]; [self publishStaging:staging control:control downloader:downloader];
}

+ (NSDictionary<NSString *, NSNumber *> *)requirementsForOfflinePackAtPath:(NSString *)path {
    NSError *error = nil;
    if (![self preflightZipAtPath:path error:&error]) return nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:&error]; UZKFileInfo *control = nil;
    if (!archive || ![self validatedArchive:archive controlInfo:&control sumsInfo:nil entries:nil error:&error]) return nil;
    NSData *data = [self readArchiveFile:archive info:control maximumBytes:OfflineMaxControlBytes error:&error];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (error || ![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"minimumRamMiB"] respondsToSelector:@selector(unsignedLongLongValue)] || ![manifest[@"desktopRecommendedRamMiB"] respondsToSelector:@selector(unsignedLongLongValue)]) return nil;
    return @{ @"minimumRamMiB": manifest[@"minimumRamMiB"], @"desktopRecommendedRamMiB": manifest[@"desktopRecommendedRamMiB"] };
}

+ (BOOL)isOfflinePackAtPath:(NSString *)path {
    NSError *error = nil; BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]) return NO;
    if (isDirectory || ![self preflightZipAtPath:path error:&error]) return NO;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:&error]; UZKFileInfo *control = nil, *sums = nil;
    if (!archive || ![self validatedArchive:archive controlInfo:&control sumsInfo:&sums entries:nil error:&error]) return NO;
    NSData *data = [self readArchiveFile:archive info:control maximumBytes:OfflineMaxControlBytes error:&error]; NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    return !error && [manifest isKindOfClass:NSDictionary.class] && [manifest[@"format"] isEqual:@"amethyst-duo-offline-pack"] && [manifest[@"formatVersion"] integerValue] == 1;
}
@end
