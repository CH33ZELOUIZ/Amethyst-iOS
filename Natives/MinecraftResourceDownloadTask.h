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
// Short failure reason from the last finishDownloadWithErrorString (main queue); shown on the Packs screen.
@property(nonatomic, copy) NSString *lastErrorSummary;

// Creates the NSProgress objects so the UI can observe them BEFORE background work starts.
// The next prepareForDownload call (from the worker) reuses them instead of replacing them.
- (void)prepareProgressForObservation;
- (void)reportPhase:(NSString *)phase;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path forceSHA:(BOOL)forceSHA success:(void (^)(void))success failure:(void (^)(NSError *error))failure;
// Terminal operations are idempotent. Use cancel rather than cancelling progress directly so
// networking, UI cleanup, and the persisted outcome always converge through one path.
- (void)cancel;
- (void)finishDownloadWithErrorString:(NSString *)error;
- (void)finishDownloadWithSuccess;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)installModpackFromLocalFile:(NSString *)filePath api:(ModpackAPI *)api;

@end
