#import <Foundation/Foundation.h>

@class MinecraftResourceDownloadTask;

@interface OfflineModpackImporter : NSObject

// Imports a private Duo offline pack from an extracted folder or a ZIP. The pack
// must contain duo-offline-pack.json and SHA256SUMS.txt at its root.
+ (void)importPackAtPath:(NSString *)sourcePath downloader:(MinecraftResourceDownloadTask *)downloader;
+ (BOOL)isOfflinePackAtPath:(NSString *)path;

@end
