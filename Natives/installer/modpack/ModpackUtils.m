#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

+ (BOOL)fail:(NSError **)error description:(NSString *)description {
    if (error) *error = [NSError errorWithDomain:@"Modpack" code:1 userInfo:@{NSLocalizedDescriptionKey: description}];
    return NO;
}

+ (BOOL)validateArchive:(UZKArchive *)archive error:(NSError **)error {
    __block NSUInteger entryCount = 0;
    __block unsigned long long expandedSize = 0;
    __block BOOL valid = YES;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        entryCount++;
        // This permits the 9,234-entry Integrated Boogaloo archive while bounding extraction.
        if (entryCount > 10000 || fileInfo.uncompressedSize > 256ULL * 1024 * 1024 || expandedSize > 1024ULL * 1024 * 1024 - fileInfo.uncompressedSize) {
            valid = [self fail:error description:@"The modpack archive is too large to import safely."];
            *stop = YES;
            return;
        }
        expandedSize += fileInfo.uncompressedSize;
        NSString *name = fileInfo.filename;
        if (![name isKindOfClass:NSString.class] || !name.length || name.isAbsolutePath || [name containsString:@"\\"] || (fileInfo.posixPermissions & 0170000) == 0120000) {
            valid = [self fail:error description:@"The modpack archive contains an unsafe path or symbolic link."];
            *stop = YES;
            return;
        }
        for (NSString *component in name.pathComponents) {
            if ([component isEqual:@"."] || [component isEqual:@".."] || !component.length) {
                valid = [self fail:error description:@"The modpack archive contains an unsafe file path."];
                *stop = YES;
                return;
            }
        }
    } error:error];
    return valid && (!error || !*error);
}

+ (NSString *)packFormatForArchiveAtPath:(NSString *)path error:(NSError **)error {
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:error];
    if (!archive || ![self validateArchive:archive error:error]) return nil;
    NSError *manifestError = nil, *modrinthError = nil;
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&manifestError];
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&modrinthError];
    NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&manifestError] : nil;
    NSDictionary *index = indexData ? [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&modrinthError] : nil;
    BOOL curseForge = [manifest isKindOfClass:NSDictionary.class] && [[manifest[@"manifestType"] lowercaseString] isEqualToString:@"minecraftmodpack"] && [manifest[@"minecraft"] isKindOfClass:NSDictionary.class] && [manifest[@"files"] isKindOfClass:NSArray.class];
    BOOL modrinth = [index isKindOfClass:NSDictionary.class] && [index[@"formatVersion"] respondsToSelector:@selector(integerValue)] && [index[@"files"] isKindOfClass:NSArray.class] && [index[@"dependencies"] isKindOfClass:NSDictionary.class];
    if (curseForge == modrinth) {
        [self fail:error description:curseForge ? @"The archive contains conflicting modpack manifests." : @"This archive is not a supported Modrinth .mrpack or official CurseForge client modpack ZIP."];
        return nil;
    }
    return curseForge ? @"curseforge" : @"modrinth";
}

+ (NSString *)safeDestinationForRelativePath:(NSString *)relativePath root:(NSString *)root error:(NSError **)error {
    if (![relativePath isKindOfClass:NSString.class] || !relativePath.length || relativePath.isAbsolutePath) {
        if (error) *error = [NSError errorWithDomain:@"Modpack" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The modpack contains an invalid file path."}];
        return nil;
    }
    for (NSString *component in relativePath.pathComponents) {
        if ([component isEqual:@"."] || [component isEqual:@".."] || !component.length) {
            if (error) *error = [NSError errorWithDomain:@"Modpack" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The modpack contains an unsafe file path."}];
            return nil;
        }
    }
    NSString *destination = [root stringByAppendingPathComponent:relativePath];
    NSString *standardRoot = root.stringByStandardizingPath;
    if (![destination.stringByStandardizingPath hasPrefix:[standardRoot stringByAppendingString:@"/"]]) {
        if (error) *error = [NSError errorWithDomain:@"Modpack" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The modpack file path escapes its instance."}];
        return nil;
    }
    return destination;
}

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    if (![self validateArchive:archive error:error]) return;
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *prefix = [dir stringByAppendingString:@"/"];
        if (![fileInfo.filename hasPrefix:prefix] || fileInfo.filename.length <= prefix.length) {
            return;
        }
        NSString *fileName = [fileInfo.filename substringFromIndex:prefix.length];
        NSString *destItemPath = [self safeDestinationForRelativePath:fileName root:path error:error];
        if (!destItemPath) { *stop = YES; return; }
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSData *data = [archive extractData:fileInfo error:error];
        BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, dependency[@"quilt-loader"]];
    }
    return info;
}

@end
