#import <UIKit/UIKit.h>

@class ModpackAPI;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
// Human-readable import phase; always delivered on the main queue.
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) void(^phaseHandler)(NSString *phase);
@property(nonatomic) BOOL progressPrepared;

// Creates the NSProgress objects so the UI can observe them BEFORE background work starts.
// The next prepareForDownload call (from the worker) reuses them instead of replacing them.
- (void)prepareProgressForObservation;
- (void)reportPhase:(NSString *)phase;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path forceSHA:(BOOL)forceSHA success:(void (^)(void))success failure:(void (^)(NSError *error))failure;
- (void)finishDownloadWithErrorString:(NSString *)error;
- (void)finishDownloadWithSuccess;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)installModpackFromLocalFile:(NSString *)filePath api:(ModpackAPI *)api;

@end
