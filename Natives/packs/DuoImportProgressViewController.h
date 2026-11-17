#import <UIKit/UIKit.h>
#import "MinecraftResourceDownloadTask.h"

// Non-blocking sheet shown as soon as an import/download starts. "Hide" only dismisses the sheet; the
// import keeps running and progress remains visible in the toolbar and the Packs screen. "Cancel"
// asks the task to stop (the importers check progress.cancelled between steps and roll back).
@interface DuoImportProgressViewController : UIViewController
- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task title:(NSString *)title;
@end
