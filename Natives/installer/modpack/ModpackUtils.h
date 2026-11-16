#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSString *)safeDestinationForRelativePath:(NSString *)relativePath root:(NSString *)root error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

@end
