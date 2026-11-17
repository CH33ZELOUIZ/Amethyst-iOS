#import <Foundation/Foundation.h>

@class MinecraftResourceDownloadTask;

@interface OfflineModpackImporter : NSObject

// Imports a private Duo offline ZIP containing the control and checksum manifests.
+ (void)importPackAtPath:(NSString *)sourcePath downloader:(MinecraftResourceDownloadTask *)downloader;
+ (BOOL)isOfflinePackAtPath:(NSString *)path;
+ (NSDictionary<NSString *, NSNumber *> *)requirementsForOfflinePackAtPath:(NSString *)path;

@end
