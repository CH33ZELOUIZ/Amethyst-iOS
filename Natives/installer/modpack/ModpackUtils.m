#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

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
