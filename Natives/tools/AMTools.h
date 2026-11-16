#import <UIKit/UIKit.h>

// Amethyst Duo: file manager, text editor, image viewer, worlds manager, screenshots gallery.

NSString *AMHomeDir(void);
NSString *AMGameDir(void);

@interface AMFileBrowserViewController : UITableViewController
@property(nonatomic, copy) NSString *path;
- (instancetype)initWithPath:(NSString *)path;
@end

@interface AMTextEditorViewController : UIViewController
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL readOnly;
- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly;
@end

@interface AMImageViewerViewController : UIViewController
@property(nonatomic, copy) NSString *path;
- (instancetype)initWithPath:(NSString *)path;
@end

// Sidebar entries (title + imageName are read by LauncherMenuCustomItem vcClass:)
@interface AMFilesHubViewController : UITableViewController
- (NSString *)imageName;
@end

@interface AMWorldsViewController : UITableViewController
- (NSString *)imageName;
@end

@interface AMScreenshotsViewController : UICollectionViewController
- (NSString *)imageName;
@end
