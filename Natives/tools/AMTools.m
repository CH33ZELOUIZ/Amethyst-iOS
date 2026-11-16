#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#import "AMTools.h"
#import "UnzipKit.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"

#pragma mark - Helpers

NSString *AMHomeDir(void) {
    const char *h = getenv("AME_HOME");
    return h ? @(h) : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

NSString *AMGameDir(void) {
    NSString *instance = getPrefObject(@"general.game_directory");
    if (![instance isKindOfClass:NSString.class] || !instance.length) instance = @"default";
    NSString *sub = nil;
    @try { sub = [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]; } @catch (NSException *e) { sub = nil; }
    if (!sub.length) sub = @".";
    NSString *dir = [[[AMHomeDir() stringByAppendingPathComponent:@"instances"] stringByAppendingPathComponent:instance] stringByAppendingPathComponent:sub];
    return dir.stringByStandardizingPath;
}

static void AMAlert(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void AMPrompt(UIViewController *vc, NSString *title, NSString *message, NSString *initial, NSString *action, void (^done)(NSString *text)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = initial;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *t = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (t.length) done(t);
    }]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void AMConfirm(UIViewController *vc, NSString *title, NSString *message, NSString *action, BOOL destructive, void (^done)(void)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:action style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *x) { done(); }]];
    [vc presentViewController:a animated:YES completion:nil];
}

static void AMShare(UIViewController *vc, NSArray *items, id anchor) {
    UIActivityViewController *s = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    if ([anchor isKindOfClass:UIBarButtonItem.class]) s.popoverPresentationController.barButtonItem = anchor;
    else if ([anchor isKindOfClass:UIView.class]) { s.popoverPresentationController.sourceView = anchor; s.popoverPresentationController.sourceRect = [anchor bounds]; }
    else { s.popoverPresentationController.sourceView = vc.view; s.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1); }
    [vc presentViewController:s animated:YES completion:nil];
}

static NSString *AMUniquePath(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) return path;
    NSString *dir = path.stringByDeletingLastPathComponent, *ext = path.pathExtension, *base = path.lastPathComponent.stringByDeletingPathExtension;
    for (int i = 2; i < 10000; i++) {
        NSString *name = ext.length ? [NSString stringWithFormat:@"%@ %d.%@", base, i, ext] : [NSString stringWithFormat:@"%@ %d", base, i];
        NSString *p = [dir stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:p]) return p;
    }
    return path;
}

static unsigned long long AMSizeOf(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
    if (!isDir) return [[fm attributesOfItemAtPath:path error:nil] fileSize];
    unsigned long long total = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
    for (NSString *f in en) {
        NSDictionary *at = en.fileAttributes;
        if ([at.fileType isEqualToString:NSFileTypeRegular]) total += at.fileSize;
    }
    return total;
}

static NSString *AMSizeString(unsigned long long bytes) {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

// Zips a file or folder with the system coordinator; the result is a temp zip that the caller must move or copy.
static void AMZip(NSString *path, void (^done)(NSString *zipPath, NSError *error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordErr = nil;
        __block NSString *out = nil;
        __block NSError *copyErr = nil;
        [c coordinateReadingItemAtURL:[NSURL fileURLWithPath:path] options:NSFileCoordinatorReadingForUploading error:&coordErr byAccessor:^(NSURL *zipURL) {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"am-%u-%@.zip", arc4random(), path.lastPathComponent.stringByDeletingPathExtension]];
            [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
            NSError *e = nil;
            if ([NSFileManager.defaultManager copyItemAtURL:zipURL toURL:[NSURL fileURLWithPath:tmp] error:&e]) out = tmp; else copyErr = e;
        }];
        NSError *err = coordErr ?: copyErr;
        dispatch_async(dispatch_get_main_queue(), ^{ done(err ? nil : out, err); });
    });
}

static BOOL AMIsTextExt(NSString *ext) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"txt", @"json", @"json5", @"properties", @"cfg", @"conf", @"config", @"toml", @"yml", @"yaml", @"log", @"xml", @"md", @"mcmeta", @"ini", @"snbt", @"js", @"csv", @"sh", @"lang", @"mcfunction", @"html", @"css", @"vsh", @"fsh", @"glsl", @"vert", @"frag", @"info", @"cfg", @"options", @"nbt_json", @"bak", @"old", @"list", @"lock"]];
    });
    return [set containsObject:ext.lowercaseString];
}
static BOOL AMIsImageExt(NSString *ext) {
    return [@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"bmp", @"tiff"] containsObject:ext.lowercaseString];
}
static BOOL AMIsArchiveExt(NSString *ext) {
    return [@[@"zip", @"jar", @"mrpack", @"mcpack", @"mcworld", @"mcaddon"] containsObject:ext.lowercaseString];
}

// extracts a zip into destination; returns error text or nil
static NSString *AMExtract(NSString *zipPath, NSString *dest) {
    NSError *err = nil;
    UZKArchive *arc = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!arc) return err.localizedDescription ?: @"Could not open archive";
    [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    if (![arc extractFilesTo:dest overwrite:YES error:&err]) return err.localizedDescription ?: @"Extraction failed";
    return nil;
}

#pragma mark - Clipboard shared by the file browsers

static NSArray<NSString *> *gClipPaths;
static BOOL gClipMove;

#pragma mark - Text editor

@interface AMTextEditorViewController () <UITextViewDelegate>
@property(nonatomic) UITextView *textView;
@property(nonatomic) BOOL dirty;
@property(nonatomic) CGFloat fontSize;
@end

@implementation AMTextEditorViewController

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly {
    self = [super init];
    self.path = path;
    self.readOnly = readOnly;
    self.fontSize = 13;
    self.title = path.lastPathComponent;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.delegate = self;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.smartQuotesType = UITextSmartQuotesTypeNo;
    self.textView.smartDashesType = UITextSmartDashesTypeNo;
    self.textView.spellCheckingType = UITextSpellCheckingTypeNo;
    self.textView.alwaysBounceVertical = YES;
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.textView.editable = !self.readOnly;
    self.textView.findInteractionEnabled = YES;
    [self applyFont];
    [self.view addSubview:self.textView];
    UILayoutGuide *kb = self.view.keyboardLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:kb.topAnchor],
    ]];

    NSError *err = nil;
    unsigned long long size = AMSizeOf(self.path);
    if (size > 4 * 1024 * 1024) {
        self.textView.text = [NSString stringWithFormat:@"This file is %@, which is too large to edit here.", AMSizeString(size)];
        self.textView.editable = NO;
        self.readOnly = YES;
    } else {
        NSString *text = [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:&err];
        if (!text) {
            text = [NSString stringWithContentsOfFile:self.path encoding:NSISOLatin1StringEncoding error:nil];
            if (!text) {
                text = @"This file is not text.";
                self.textView.editable = NO;
                self.readOnly = YES;
            }
        }
        self.textView.text = text;
    }
    [self buildBar];
}

- (void)applyFont {
    self.textView.font = [UIFont monospacedSystemFontOfSize:self.fontSize weight:UIFontWeightRegular];
}

- (void)buildBar {
    __weak typeof(self) w = self;
    NSMutableArray *menu = [NSMutableArray new];
    [menu addObject:[UIAction actionWithTitle:@"Find" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *a) {
        [w.textView.findInteraction presentFindNavigatorShowingReplace:!w.readOnly];
    }]];
    if (!self.readOnly) {
        [menu addObject:[UIAction actionWithTitle:@"Undo" image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *a) { [w.textView.undoManager undo]; }]];
        [menu addObject:[UIAction actionWithTitle:@"Redo" image:[UIImage systemImageNamed:@"arrow.uturn.forward"] identifier:nil handler:^(UIAction *a) { [w.textView.undoManager redo]; }]];
    }
    [menu addObject:[UIAction actionWithTitle:@"Bigger text" image:[UIImage systemImageNamed:@"textformat.size.larger"] identifier:nil handler:^(UIAction *a) { w.fontSize = MIN(30, w.fontSize + 1); [w applyFont]; }]];
    [menu addObject:[UIAction actionWithTitle:@"Smaller text" image:[UIImage systemImageNamed:@"textformat.size.smaller"] identifier:nil handler:^(UIAction *a) { w.fontSize = MAX(8, w.fontSize - 1); [w applyFont]; }]];
    [menu addObject:[UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { AMShare(w, @[[NSURL fileURLWithPath:w.path]], nil); }]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:menu]];
    NSMutableArray *items = [NSMutableArray arrayWithObject:more];
    if (!self.readOnly) {
        [items insertObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)] atIndex:0];
    }
    self.navigationItem.rightBarButtonItems = items;
}

- (void)textViewDidChange:(UITextView *)textView {
    self.dirty = YES;
    self.title = [self.path.lastPathComponent stringByAppendingString:@" •"];
}

- (BOOL)writeText:(NSString **)problem {
    NSString *text = self.textView.text ?: @"";
    NSString *ext = self.path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"json"] || [ext isEqualToString:@"mcmeta"]) {
        NSError *je = nil;
        [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:&je];
        if (je && problem) *problem = je.localizedDescription;
    }
    NSError *err = nil;
    if (![text writeToFile:self.path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        if (problem) *problem = err.localizedDescription;
        return NO;
    }
    self.dirty = NO;
    self.title = self.path.lastPathComponent;
    return YES;
}

- (void)save {
    NSString *problem = nil;
    BOOL ok = [self writeText:&problem];
    [self.textView resignFirstResponder];
    if (!ok) AMAlert(self, @"Could not save", problem);
    else if (problem) AMAlert(self, @"Saved, but this JSON looks invalid", problem);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.dirty && !self.readOnly && (self.isMovingFromParentViewController || self.navigationController == nil)) {
        NSString *problem = nil;
        [self writeText:&problem];
        if (problem) showDialog(@"Saved, but check this file", [NSString stringWithFormat:@"%@: %@", self.path.lastPathComponent, problem]);
    }
}

@end

#pragma mark - Image viewer

@interface AMImageViewerViewController () <UIScrollViewDelegate>
@property(nonatomic) UIScrollView *scroll;
@property(nonatomic) UIImageView *imageView;
@end

@implementation AMImageViewerViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    self.path = path;
    self.title = path.lastPathComponent;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.delegate = self;
    self.scroll.minimumZoomScale = 1;
    self.scroll.maximumZoomScale = 8;
    self.scroll.showsHorizontalScrollIndicator = NO;
    self.scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scroll];
    UIImage *img = [UIImage imageWithContentsOfFile:self.path];
    self.imageView = [[UIImageView alloc] initWithImage:img];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.layer.magnificationFilter = kCAFilterNearest;
    self.imageView.frame = self.scroll.bounds;
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.scroll addSubview:self.imageView];
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
    dt.numberOfTapsRequired = 2;
    [self.scroll addGestureRecognizer:dt];

    __weak typeof(self) w = self;
    NSArray *menu = @[
        [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { AMShare(w, @[[NSURL fileURLWithPath:w.path]], nil); }],
        [UIAction actionWithTitle:@"Save to Photos" image:[UIImage systemImageNamed:@"photo"] identifier:nil handler:^(UIAction *a) {
            UIImage *i = [UIImage imageWithContentsOfFile:w.path];
            if (i) UIImageWriteToSavedPhotosAlbum(i, w, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
        }],
        [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
            AMConfirm(w, @"Delete this image?", w.path.lastPathComponent, @"Delete", YES, ^{
                [NSFileManager.defaultManager removeItemAtPath:w.path error:nil];
                [w.navigationController popViewControllerAnimated:YES];
            });
        }],
    ];
    UIAction *del = menu.lastObject; del.attributes = UIMenuElementAttributesDestructive;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:menu]];
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)ctx {
    AMAlert(self, error ? @"Could not save" : @"Saved to Photos", error.localizedDescription);
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)s { return self.imageView; }

- (void)doubleTap:(UITapGestureRecognizer *)g {
    if (self.scroll.zoomScale > 1.01) { [self.scroll setZoomScale:1 animated:YES]; return; }
    CGPoint p = [g locationInView:self.imageView];
    CGFloat z = 3;
    CGSize s = self.scroll.bounds.size;
    [self.scroll zoomToRect:CGRectMake(p.x - s.width / z / 2, p.y - s.height / z / 2, s.width / z, s.height / z) animated:YES];
}

@end

#pragma mark - File browser

@interface AMFileBrowserViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSArray<NSString *> *names;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *dirFlags;
@property(nonatomic) NSString *query;
@property(nonatomic) UISearchController *search;
@property(nonatomic) NSInteger sortMode; // 0 name, 1 date, 2 size
@end

@implementation AMFileBrowserViewController

- (instancetype)initWithPath:(NSString *)path {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.path = path;
    self.title = path.lastPathComponent.length ? path.lastPathComponent : @"Files";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchResultsUpdater = (id)self;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    [self rebuildBar];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
    [self.navigationController setToolbarHidden:!self.isEditing animated:animated];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.query = sc.searchBar.text;
    [self reload];
}

- (void)rebuildBar {
    __weak typeof(self) w = self;
    NSMutableArray *plus = [NSMutableArray new];
    [plus addObject:[UIAction actionWithTitle:@"New File" image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil handler:^(UIAction *a) { [w newItem:NO]; }]];
    [plus addObject:[UIAction actionWithTitle:@"New Folder" image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(UIAction *a) { [w newItem:YES]; }]];
    [plus addObject:[UIAction actionWithTitle:@"Import from Files…" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) { [w importFiles]; }]];
    if (gClipPaths.count) {
        [plus addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Paste %lu item%@", (unsigned long)gClipPaths.count, gClipPaths.count == 1 ? @"" : @"s"] image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *a) { [w paste]; }]];
    }
    UIMenu *sort = [UIMenu menuWithTitle:@"Sort by" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:@"Name" image:nil identifier:nil handler:^(UIAction *a) { w.sortMode = 0; [w reload]; [w rebuildBar]; }],
        [UIAction actionWithTitle:@"Date modified" image:nil identifier:nil handler:^(UIAction *a) { w.sortMode = 1; [w reload]; [w rebuildBar]; }],
        [UIAction actionWithTitle:@"Size" image:nil identifier:nil handler:^(UIAction *a) { w.sortMode = 2; [w reload]; [w rebuildBar]; }],
    ]];
    for (UIAction *s in sort.children) s.state = ([sort.children indexOfObject:s] == (NSUInteger)self.sortMode) ? UIMenuElementStateOn : UIMenuElementStateOff;
    [plus addObject:sort];
    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle"] menu:[UIMenu menuWithChildren:plus]];
    UIBarButtonItem *sel = [[UIBarButtonItem alloc] initWithTitle:self.isEditing ? @"Done" : @"Select" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelect)];
    self.navigationItem.rightBarButtonItems = @[sel, add];

    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain target:self action:@selector(selCopy)];
    UIBarButtonItem *move = [[UIBarButtonItem alloc] initWithTitle:@"Move" style:UIBarButtonItemStylePlain target:self action:@selector(selMove)];
    UIBarButtonItem *zip = [[UIBarButtonItem alloc] initWithTitle:@"Zip" style:UIBarButtonItemStylePlain target:self action:@selector(selZip)];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(selShare:)];
    UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(selDelete)];
    del.tintColor = UIColor.systemRedColor;
    self.toolbarItems = @[copy, flex, move, flex, zip, flex, share, flex, del];
}

- (void)toggleSelect {
    [self setEditing:!self.isEditing animated:YES];
    [self.navigationController setToolbarHidden:!self.isEditing animated:YES];
    [self rebuildBar];
}

- (NSString *)pathForName:(NSString *)name { return [self.path stringByAppendingPathComponent:name]; }

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *err = nil;
    NSArray *all = [fm contentsOfDirectoryAtPath:self.path error:&err];
    NSMutableDictionary *flags = [NSMutableDictionary new];
    NSMutableDictionary *dates = [NSMutableDictionary new];
    NSMutableDictionary *sizes = [NSMutableDictionary new];
    NSMutableArray *names = [NSMutableArray new];
    NSString *q = self.query.lowercaseString;
    for (NSString *n in all) {
        if (q.length && [n.lowercaseString rangeOfString:q].location == NSNotFound) continue;
        NSDictionary *at = [fm attributesOfItemAtPath:[self pathForName:n] error:nil];
        BOOL dir = [at.fileType isEqualToString:NSFileTypeDirectory] || ([at.fileType isEqualToString:NSFileTypeSymbolicLink] && ({ BOOL d = NO; [fm fileExistsAtPath:[self pathForName:n] isDirectory:&d]; d; }));
        flags[n] = @(dir);
        dates[n] = at.fileModificationDate ?: NSDate.distantPast;
        sizes[n] = @(at.fileSize);
        [names addObject:n];
    }
    NSInteger mode = self.sortMode;
    [names sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL da = [flags[a] boolValue], db = [flags[b] boolValue];
        if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
        if (mode == 1) return [dates[b] compare:dates[a]];
        if (mode == 2 && !da) { NSComparisonResult r = [sizes[b] compare:sizes[a]]; if (r != NSOrderedSame) return r; }
        return [a localizedStandardCompare:b];
    }];
    self.names = names;
    self.dirFlags = flags;
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
    self.title = self.path.lastPathComponent.length ? self.path.lastPathComponent : @"Files";
    self.navigationItem.prompt = err ? err.localizedDescription : nil;
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.names.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.names.count ? [NSString stringWithFormat:@"%lu item%@", (unsigned long)self.names.count, self.names.count == 1 ? @"" : @"s"] : @"This folder is empty. Use + to add files.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"f"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    NSString *name = self.names[ip.row];
    NSString *full = [self pathForName:name];
    BOOL dir = [self.dirFlags[name] boolValue];
    NSString *ext = name.pathExtension;
    NSString *icon = dir ? @"folder.fill" : AMIsImageExt(ext) ? @"photo" : AMIsArchiveExt(ext) ? @"doc.zipper" : AMIsTextExt(ext) ? @"doc.text" : @"doc";
    cell.imageView.image = [UIImage systemImageNamed:icon];
    cell.imageView.tintColor = dir ? UIColor.systemPurpleColor : UIColor.secondaryLabelColor;
    cell.textLabel.text = name;
    NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:full error:nil];
    NSString *date = at.fileModificationDate ? [NSDateFormatter localizedStringFromDate:at.fileModificationDate dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"";
    if (dir) {
        NSArray *kids = [NSFileManager.defaultManager contentsOfDirectoryAtPath:full error:nil];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu item%@ · %@", (unsigned long)kids.count, kids.count == 1 ? @"" : @"s", date];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", AMSizeString(at.fileSize), date];
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (tv.isEditing) return;
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *name = self.names[ip.row];
    [self openName:name from:[tv cellForRowAtIndexPath:ip]];
}

- (void)openName:(NSString *)name from:(UIView *)source {
    NSString *full = [self pathForName:name];
    NSString *ext = name.pathExtension;
    if ([self.dirFlags[name] boolValue]) {
        [self.navigationController pushViewController:[[AMFileBrowserViewController alloc] initWithPath:full] animated:YES];
    } else if (AMIsImageExt(ext)) {
        [self.navigationController pushViewController:[[AMImageViewerViewController alloc] initWithPath:full] animated:YES];
    } else if (AMIsTextExt(ext) || ext.length == 0) {
        [self.navigationController pushViewController:[[AMTextEditorViewController alloc] initWithPath:full readOnly:NO] animated:YES];
    } else if (AMIsArchiveExt(ext)) {
        [self archiveSheet:full source:source];
    } else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:name message:@"No built-in viewer for this file type." preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"Open as text" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self.navigationController pushViewController:[[AMTextEditorViewController alloc] initWithPath:full readOnly:YES] animated:YES];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { AMShare(self, @[[NSURL fileURLWithPath:full]], source); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = source ?: self.view;
        a.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)archiveSheet:(NSString *)full source:(UIView *)source {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:full.lastPathComponent message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"List contents" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSError *err = nil;
        UZKArchive *arc = [[UZKArchive alloc] initWithPath:full error:&err];
        NSArray *files = [arc listFilenames:&err];
        if (!files) { AMAlert(self, @"Could not open", err.localizedDescription); return; }
        NSString *msg = [[files subarrayWithRange:NSMakeRange(0, MIN(files.count, 200))] componentsJoinedByString:@"\n"];
        if (files.count > 200) msg = [msg stringByAppendingFormat:@"\n… and %lu more", (unsigned long)(files.count - 200)];
        AMAlert(self, [NSString stringWithFormat:@"%lu files", (unsigned long)files.count], msg);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Extract here" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self extract:full intoFolder:NO]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Extract to new folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self extract:full intoFolder:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { AMShare(self, @[[NSURL fileURLWithPath:full]], source); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = source ?: self.view;
    a.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)extract:(NSString *)zip intoFolder:(BOOL)folder {
    NSString *dest = folder ? AMUniquePath([self.path stringByAppendingPathComponent:zip.lastPathComponent.stringByDeletingPathExtension]) : self.path;
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Extracting…" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = AMExtract(zip, dest);
        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:^{
                [self reload];
                if (err) AMAlert(self, @"Extraction failed", err);
            }];
        });
    });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *name = self.names[ip.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        AMConfirm(self, @"Delete?", name, @"Delete", YES, ^{
            NSError *e = nil;
            [NSFileManager.defaultManager removeItemAtPath:[self pathForName:name] error:&e];
            [self reload];
            if (e) AMAlert(self, @"Could not delete", e.localizedDescription);
            done(YES);
        });
    }];
    UIContextualAction *ren = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Rename" handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self rename:name];
        done(YES);
    }];
    ren.backgroundColor = UIColor.systemIndigoColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[del, ren]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSString *name = self.names[ip.row];
    NSString *full = [self pathForName:name];
    BOOL dir = [self.dirFlags[name] boolValue];
    __weak typeof(self) w = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *items = [NSMutableArray new];
        if (!dir) {
            [items addObject:[UIAction actionWithTitle:@"Open as text" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(UIAction *a) {
                [w.navigationController pushViewController:[[AMTextEditorViewController alloc] initWithPath:full readOnly:NO] animated:YES];
            }]];
        }
        [items addObject:[UIAction actionWithTitle:@"Rename" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a) { [w rename:name]; }]];
        [items addObject:[UIAction actionWithTitle:@"Duplicate" image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *a) {
            NSError *e = nil;
            [NSFileManager.defaultManager copyItemAtPath:full toPath:AMUniquePath(full) error:&e];
            [w reload];
            if (e) AMAlert(w, @"Could not duplicate", e.localizedDescription);
        }]];
        [items addObject:[UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) { gClipPaths = @[full]; gClipMove = NO; [w rebuildBar]; }]];
        [items addObject:[UIAction actionWithTitle:@"Move" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) { gClipPaths = @[full]; gClipMove = YES; [w rebuildBar]; }]];
        [items addObject:[UIAction actionWithTitle:@"Compress to .zip" image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil handler:^(UIAction *a) { [w zipPaths:@[full]]; }]];
        [items addObject:[UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { [w sharePaths:@[full] anchor:[w.tableView cellForRowAtIndexPath:ip]]; }]];
        UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
            AMConfirm(w, @"Delete?", name, @"Delete", YES, ^{ [NSFileManager.defaultManager removeItemAtPath:full error:nil]; [w reload]; });
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        [items addObject:del];
        return [UIMenu menuWithChildren:items];
    }];
}

#pragma mark Actions

- (void)rename:(NSString *)name {
    AMPrompt(self, @"Rename", nil, name, @"Rename", ^(NSString *text) {
        NSError *e = nil;
        [NSFileManager.defaultManager moveItemAtPath:[self pathForName:name] toPath:[self pathForName:text] error:&e];
        [self reload];
        if (e) AMAlert(self, @"Could not rename", e.localizedDescription);
    });
}

- (void)newItem:(BOOL)folder {
    AMPrompt(self, folder ? @"New Folder" : @"New File", nil, folder ? @"New Folder" : @"new.txt", @"Create", ^(NSString *text) {
        NSString *p = [self pathForName:text];
        NSError *e = nil;
        if (folder) [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:&e];
        else [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:&e];
        [self reload];
        if (e) AMAlert(self, @"Could not create", e.localizedDescription);
        else if (!folder) [self.navigationController pushViewController:[[AMTextEditorViewController alloc] initWithPath:p readOnly:NO] animated:YES];
    });
}

- (void)paste {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *errors = [NSMutableArray new];
    for (NSString *src in gClipPaths) {
        NSString *dst = AMUniquePath([self.path stringByAppendingPathComponent:src.lastPathComponent]);
        if ([dst hasPrefix:[src stringByAppendingString:@"/"]]) { [errors addObject:@"Can't paste a folder into itself"]; continue; }
        NSError *e = nil;
        BOOL ok = gClipMove ? [fm moveItemAtPath:src toPath:dst error:&e] : [fm copyItemAtPath:src toPath:dst error:&e];
        if (!ok) [errors addObject:e.localizedDescription ?: @"Failed"];
    }
    if (gClipMove) gClipPaths = nil;
    [self rebuildBar];
    [self reload];
    if (errors.count) AMAlert(self, @"Some items failed", [errors componentsJoinedByString:@"\n"]);
}

- (void)importFiles {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem, UTTypeFolder] asCopy:YES];
    p.allowsMultipleSelection = YES;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *errors = [NSMutableArray new];
    for (NSURL *u in urls) {
        NSError *e = nil;
        [NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:AMUniquePath([self.path stringByAppendingPathComponent:u.lastPathComponent])] error:&e];
        if (e) [errors addObject:e.localizedDescription];
    }
    [self reload];
    if (errors.count) AMAlert(self, @"Some imports failed", [errors componentsJoinedByString:@"\n"]);
}

- (NSArray<NSString *> *)selectedPaths {
    NSMutableArray *out = [NSMutableArray new];
    for (NSIndexPath *ip in self.tableView.indexPathsForSelectedRows) [out addObject:[self pathForName:self.names[ip.row]]];
    return out;
}

- (void)selCopy { NSArray *p = [self selectedPaths]; if (!p.count) return; gClipPaths = p; gClipMove = NO; [self toggleSelect]; }
- (void)selMove { NSArray *p = [self selectedPaths]; if (!p.count) return; gClipPaths = p; gClipMove = YES; [self toggleSelect]; }
- (void)selZip { NSArray *p = [self selectedPaths]; if (p.count) [self zipPaths:p]; }
- (void)selShare:(UIBarButtonItem *)b { NSArray *p = [self selectedPaths]; if (p.count) [self sharePaths:p anchor:b]; }
- (void)selDelete {
    NSArray *p = [self selectedPaths];
    if (!p.count) return;
    AMConfirm(self, [NSString stringWithFormat:@"Delete %lu item%@?", (unsigned long)p.count, p.count == 1 ? @"" : @"s"], @"This can't be undone.", @"Delete", YES, ^{
        for (NSString *x in p) [NSFileManager.defaultManager removeItemAtPath:x error:nil];
        [self toggleSelect];
        [self reload];
    });
}

- (void)sharePaths:(NSArray<NSString *> *)paths anchor:(id)anchor {
    NSMutableArray *urls = [NSMutableArray new];
    for (NSString *p in paths) {
        BOOL dir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir];
        if (!dir) [urls addObject:[NSURL fileURLWithPath:p]];
    }
    NSArray *folders = [paths filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *p, id b) { BOOL d = NO; [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&d]; return d; }]];
    if (!folders.count) { AMShare(self, urls, anchor); return; }
    __block NSInteger pending = folders.count;
    for (NSString *f in folders) {
        AMZip(f, ^(NSString *zip, NSError *e) {
            if (zip) [urls addObject:[NSURL fileURLWithPath:zip]];
            if (--pending == 0) AMShare(self, urls, anchor);
        });
    }
}

- (void)zipPaths:(NSArray<NSString *> *)paths {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Compressing…" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    __block NSInteger pending = paths.count;
    __block NSString *failure = nil;
    for (NSString *p in paths) {
        AMZip(p, ^(NSString *zip, NSError *e) {
            if (zip) {
                NSString *dst = AMUniquePath([self.path stringByAppendingPathComponent:[p.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"zip"]]);
                NSError *m = nil;
                [NSFileManager.defaultManager moveItemAtPath:zip toPath:dst error:&m];
                if (m) failure = m.localizedDescription;
            } else failure = e.localizedDescription;
            if (--pending == 0) {
                [wait dismissViewControllerAnimated:YES completion:^{
                    if (self.isEditing) [self toggleSelect];
                    [self reload];
                    if (failure) AMAlert(self, @"Could not compress", failure);
                }];
            }
        });
    }
}

@end

#pragma mark - Files hub (sidebar entry)

@interface AMFilesHubViewController ()
@property(nonatomic) NSArray<NSArray *> *shortcuts; // @[@[title, subtitle, icon, path]]
@end

@implementation AMFilesHubViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"Files";
    return self;
}

- (NSString *)imageName { return @"folder"; }

- (void)rebuild {
    NSString *game = AMGameDir();
    NSString *home = AMHomeDir();
    self.shortcuts = @[
        @[@"Game folder", game, @"gamecontroller", game],
        @[@"Mods", @"mods", @"puzzlepiece.extension", [game stringByAppendingPathComponent:@"mods"]],
        @[@"Config", @"config", @"slider.horizontal.3", [game stringByAppendingPathComponent:@"config"]],
        @[@"Resource packs", @"resourcepacks", @"paintpalette", [game stringByAppendingPathComponent:@"resourcepacks"]],
        @[@"Shader packs", @"shaderpacks", @"sparkles", [game stringByAppendingPathComponent:@"shaderpacks"]],
        @[@"Data packs & saves", @"saves", @"globe.americas", [game stringByAppendingPathComponent:@"saves"]],
        @[@"Logs", @"logs", @"text.alignleft", [game stringByAppendingPathComponent:@"logs"]],
        @[@"Crash reports", @"crash-reports", @"exclamationmark.triangle", [game stringByAppendingPathComponent:@"crash-reports"]],
        @[@"Screenshots", @"screenshots", @"photo.on.rectangle", [game stringByAppendingPathComponent:@"screenshots"]],
        @[@"options.txt", @"Minecraft settings file", @"gearshape", [game stringByAppendingPathComponent:@"options.txt"]],
        @[@"Amethyst folder", home, @"externaldrive", home],
        @[@"Backups", @"Amethyst backups", @"clock.arrow.circlepath", [home stringByAppendingPathComponent:@"backups"]],
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rebuild];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.shortcuts.count; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"Everything here also shows up in the Files app under On My iPhone → Amethyst.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"h"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"h"];
    NSArray *s = self.shortcuts[ip.row];
    cell.textLabel.text = s[0];
    cell.detailTextLabel.text = [s[1] hasPrefix:@"/"] ? [s[1] stringByReplacingOccurrencesOfString:AMHomeDir() withString:@"…"] : s[1];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [UIImage systemImageNamed:s[2]];
    cell.imageView.tintColor = UIColor.systemPurpleColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *s = self.shortcuts[ip.row];
    NSString *path = s[3];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&dir]) {
        if ([path.lastPathComponent isEqualToString:@"options.txt"]) { AMAlert(self, @"No options.txt yet", @"Launch the game once and it will be created."); return; }
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        dir = YES;
    }
    if (dir) [self.navigationController pushViewController:[[AMFileBrowserViewController alloc] initWithPath:path] animated:YES];
    else [self.navigationController pushViewController:[[AMTextEditorViewController alloc] initWithPath:path readOnly:NO] animated:YES];
}

@end

#pragma mark - Worlds

@interface AMWorldsViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSArray<NSString *> *worlds;
@property(nonatomic) NSArray<NSString *> *backups;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *sizeCache;
@end

@implementation AMWorldsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = @"Worlds";
    self.sizeCache = [NSMutableDictionary new];
    return self;
}

- (NSString *)imageName { return @"globe.americas"; }
- (NSString *)savesDir { return [AMGameDir() stringByAppendingPathComponent:@"saves"]; }
- (NSString *)backupsDir { return [AMHomeDir() stringByAppendingPathComponent:@"backups"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *ws = [NSMutableArray new];
    for (NSString *n in [fm contentsOfDirectoryAtPath:self.savesDir error:nil]) {
        BOOL d = NO;
        if ([fm fileExistsAtPath:[self.savesDir stringByAppendingPathComponent:n] isDirectory:&d] && d) [ws addObject:n];
    }
    [ws sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [[fm attributesOfItemAtPath:[self.savesDir stringByAppendingPathComponent:a] error:nil] fileModificationDate] ?: NSDate.distantPast;
        NSDate *db = [[fm attributesOfItemAtPath:[self.savesDir stringByAppendingPathComponent:b] error:nil] fileModificationDate] ?: NSDate.distantPast;
        return [db compare:da];
    }];
    self.worlds = ws;
    NSMutableArray *bs = [NSMutableArray new];
    for (NSString *n in [fm contentsOfDirectoryAtPath:self.backupsDir error:nil]) if ([n.pathExtension.lowercaseString isEqualToString:@"zip"]) [bs addObject:n];
    [bs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [b compare:a]; }];
    self.backups = bs;
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
    // sizes computed off the main thread
    NSArray *snapshot = ws;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *n in snapshot) {
            NSString *s = AMSizeString(AMSizeOf([self.savesDir stringByAppendingPathComponent:n]));
            dispatch_async(dispatch_get_main_queue(), ^{
                self.sizeCache[n] = s;
                NSUInteger i = [self.worlds indexOfObject:n];
                if (i != NSNotFound) {
                    NSIndexPath *ip = [NSIndexPath indexPathForRow:i + 1 inSection:0];
                    if ([self.tableView.indexPathsForVisibleRows containsObject:ip]) [self.tableView reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
                }
            });
        }
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? self.worlds.count + 1 : self.backups.count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"Worlds" : (self.backups.count ? @"Backups" : nil); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return self.worlds.count ? @"Tap a world to manage it. Backups are saved to the Amethyst folder." : @"No worlds in this game folder yet.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"w"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"w"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.tintColor = UIColor.systemPurpleColor;
    cell.imageView.layer.cornerRadius = 0;
    if (ip.section == 0 && ip.row == 0) {
        cell.textLabel.text = @"Import world (.zip)…";
        cell.detailTextLabel.text = @"Add a world from the Files app";
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
        return cell;
    }
    if (ip.section == 0) {
        NSString *n = self.worlds[ip.row - 1];
        NSString *dir = [self.savesDir stringByAppendingPathComponent:n];
        UIImage *icon = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]];
        cell.imageView.image = icon ? [icon imageByPreparingThumbnailOfSize:CGSizeMake(44, 44)] : [UIImage systemImageNamed:@"globe.americas.fill"];
        cell.imageView.layer.magnificationFilter = kCAFilterNearest;
        NSDate *d = [[NSFileManager.defaultManager attributesOfItemAtPath:dir error:nil] fileModificationDate];
        cell.textLabel.text = n;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", self.sizeCache[n] ?: @"…", d ? [NSDateFormatter localizedStringFromDate:d dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @""];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    NSString *b = self.backups[ip.row];
    NSDictionary *at = [NSFileManager.defaultManager attributesOfItemAtPath:[self.backupsDir stringByAppendingPathComponent:b] error:nil];
    cell.imageView.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
    cell.textLabel.text = b.stringByDeletingPathExtension;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", AMSizeString(at.fileSize), at.fileModificationDate ? [NSDateFormatter localizedStringFromDate:at.fileModificationDate dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @""];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UIView *src = [tv cellForRowAtIndexPath:ip];
    if (ip.section == 0 && ip.row == 0) { [self importWorld]; return; }
    UIAlertController *a;
    if (ip.section == 0) {
        NSString *n = self.worlds[ip.row - 1];
        a = [UIAlertController alertControllerWithTitle:n message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"Back up now" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self backup:n]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Browse files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self.navigationController pushViewController:[[AMFileBrowserViewController alloc] initWithPath:[self.savesDir stringByAppendingPathComponent:n]] animated:YES];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Export (zip)…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            AMZip([self.savesDir stringByAppendingPathComponent:n], ^(NSString *zip, NSError *e) {
                if (zip) AMShare(self, @[[NSURL fileURLWithPath:zip]], src); else AMAlert(self, @"Could not export", e.localizedDescription);
            });
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Duplicate" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *from = [self.savesDir stringByAppendingPathComponent:n];
            NSError *e = nil;
            [NSFileManager.defaultManager copyItemAtPath:from toPath:AMUniquePath([from stringByAppendingString:@" copy"]) error:&e];
            [self reload];
            if (e) AMAlert(self, @"Could not duplicate", e.localizedDescription);
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            AMPrompt(self, @"Rename world", @"This changes the folder name. The in-game name stays the same.", n, @"Rename", ^(NSString *t) {
                NSError *e = nil;
                [NSFileManager.defaultManager moveItemAtPath:[self.savesDir stringByAppendingPathComponent:n] toPath:[self.savesDir stringByAppendingPathComponent:t] error:&e];
                [self reload];
                if (e) AMAlert(self, @"Could not rename", e.localizedDescription);
            });
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            AMConfirm(self, @"Delete this world?", [NSString stringWithFormat:@"%@ will be removed. Back it up first if you want to keep it.", n], @"Delete", YES, ^{
                [NSFileManager.defaultManager removeItemAtPath:[self.savesDir stringByAppendingPathComponent:n] error:nil];
                [self reload];
            });
        }]];
    } else {
        NSString *b = self.backups[ip.row];
        NSString *full = [self.backupsDir stringByAppendingPathComponent:b];
        a = [UIAlertController alertControllerWithTitle:b message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"Restore as new world" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self importZip:full]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Share…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { AMShare(self, @[[NSURL fileURLWithPath:full]], src); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Delete backup" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [NSFileManager.defaultManager removeItemAtPath:full error:nil];
            [self reload];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = src ?: self.view;
    a.popoverPresentationController.sourceRect = src ? src.bounds : CGRectZero;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)backup:(NSString *)world {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Backing up…" message:world preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    AMZip([self.savesDir stringByAppendingPathComponent:world], ^(NSString *zip, NSError *e) {
        NSString *msg = nil;
        if (zip) {
            [NSFileManager.defaultManager createDirectoryAtPath:self.backupsDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSDateFormatter *f = [NSDateFormatter new];
            f.dateFormat = @"yyyy-MM-dd_HH-mm";
            NSString *dst = AMUniquePath([self.backupsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %@.zip", world, [f stringFromDate:NSDate.date]]]);
            NSError *m = nil;
            [NSFileManager.defaultManager moveItemAtPath:zip toPath:dst error:&m];
            if (m) msg = m.localizedDescription;
        } else msg = e.localizedDescription;
        [wait dismissViewControllerAnimated:YES completion:^{
            [self reload];
            if (msg) AMAlert(self, @"Backup failed", msg);
        }];
    });
}

- (void)importWorld {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP, UTTypeFolder] asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    if (!u) return;
    BOOL dir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:u.path isDirectory:&dir];
    if (dir) {
        NSError *e = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:self.savesDir withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager copyItemAtPath:u.path toPath:AMUniquePath([self.savesDir stringByAppendingPathComponent:u.lastPathComponent]) error:&e];
        [self reload];
        if (e) AMAlert(self, @"Could not import", e.localizedDescription);
    } else [self importZip:u.path];
}

// accepts zips with the world folder inside, several worlds, or level.dat at the root
- (void)importZip:(NSString *)zip {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Importing…" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"world-%u", arc4random()]];
        NSString *err = AMExtract(zip, tmp);
        NSUInteger count = 0;
        if (!err) {
            [fm createDirectoryAtPath:self.savesDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSMutableArray *found = [NSMutableArray new];
            if ([fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"level.dat"]]) {
                [found addObject:tmp];
            } else {
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:tmp];
                for (NSString *rel in en) {
                    if ([rel.lastPathComponent isEqualToString:@"level.dat"] && rel.pathComponents.count <= 3 && ![rel containsString:@"__MACOSX"]) {
                        [found addObject:[tmp stringByAppendingPathComponent:rel.stringByDeletingLastPathComponent]];
                    }
                }
            }
            if (!found.count) err = @"No world found in this file (no level.dat).";
            for (NSString *src in found) {
                NSString *name = [src isEqualToString:tmp] ? zip.lastPathComponent.stringByDeletingPathExtension : src.lastPathComponent;
                NSError *e = nil;
                if ([fm moveItemAtPath:src toPath:AMUniquePath([self.savesDir stringByAppendingPathComponent:name]) error:&e]) count++;
                else err = e.localizedDescription;
            }
        }
        [fm removeItemAtPath:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [wait dismissViewControllerAnimated:YES completion:^{
                [self reload];
                if (err) AMAlert(self, @"Import failed", err);
                else AMAlert(self, @"Imported", [NSString stringWithFormat:@"%lu world%@ added.", (unsigned long)count, count == 1 ? @"" : @"s"]);
            }];
        });
    });
}

@end

#pragma mark - Screenshots

@interface AMScreenshotCell : UICollectionViewCell
@property(nonatomic) UIImageView *image;
@end
@implementation AMScreenshotCell
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.image = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
    self.image.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.image.contentMode = UIViewContentModeScaleAspectFill;
    self.image.clipsToBounds = YES;
    self.image.layer.cornerRadius = 8;
    self.image.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.contentView addSubview:self.image];
    return self;
}
@end

@interface AMScreenshotsViewController ()
@property(nonatomic) NSArray<NSString *> *files;
@property(nonatomic) NSCache *thumbs;
@end

@implementation AMScreenshotsViewController

- (instancetype)init {
    UICollectionViewFlowLayout *l = [UICollectionViewFlowLayout new];
    l.minimumInteritemSpacing = 8;
    l.minimumLineSpacing = 8;
    l.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self = [super initWithCollectionViewLayout:l];
    self.title = @"Screenshots";
    self.thumbs = [NSCache new];
    return self;
}

- (NSString *)imageName { return @"photo.on.rectangle"; }
- (NSString *)dir { return [AMGameDir() stringByAppendingPathComponent:@"screenshots"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    [self.collectionView registerClass:AMScreenshotCell.class forCellWithReuseIdentifier:@"s"];
    self.collectionView.alwaysBounceVertical = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = self.refreshControl;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *fs = [NSMutableArray new];
    for (NSString *n in [fm contentsOfDirectoryAtPath:self.dir error:nil]) if (AMIsImageExt(n.pathExtension)) [fs addObject:n];
    [fs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [[fm attributesOfItemAtPath:[self.dir stringByAppendingPathComponent:a] error:nil] fileModificationDate] ?: NSDate.distantPast;
        NSDate *db = [[fm attributesOfItemAtPath:[self.dir stringByAppendingPathComponent:b] error:nil] fileModificationDate] ?: NSDate.distantPast;
        return [db compare:da];
    }];
    self.files = fs;
    [self.collectionView reloadData];
    [self.refreshControl endRefreshing];
    self.navigationItem.prompt = fs.count ? nil : @"No screenshots yet. Press F2 in game, or use the screenshot control.";
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.files.count; }

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)l sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat w = cv.bounds.size.width - 24;
    NSInteger cols = MAX(2, (NSInteger)(w / 150));
    CGFloat side = floor((w - (cols - 1) * 8) / cols);
    return CGSizeMake(side, side * 0.62);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    AMScreenshotCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"s" forIndexPath:ip];
    NSString *name = self.files[ip.item];
    NSString *full = [self.dir stringByAppendingPathComponent:name];
    UIImage *cached = [self.thumbs objectForKey:full];
    cell.image.image = cached;
    if (!cached) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:full], NULL);
            if (!src) return;
            NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES, (id)kCGImageSourceThumbnailMaxPixelSize: @(480)};
            CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
            CFRelease(src);
            if (!cg) return;
            UIImage *img = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
            [self.thumbs setObject:img forKey:full];
            dispatch_async(dispatch_get_main_queue(), ^{
                AMScreenshotCell *c = (AMScreenshotCell *)[cv cellForItemAtIndexPath:ip];
                if (c) c.image.image = img;
            });
        });
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [self.navigationController pushViewController:[[AMImageViewerViewController alloc] initWithPath:[self.dir stringByAppendingPathComponent:self.files[ip.item]]] animated:YES];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSString *full = [self.dir stringByAppendingPathComponent:self.files[ip.item]];
    __weak typeof(self) w = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        UIAction *del = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
            [NSFileManager.defaultManager removeItemAtPath:full error:nil];
            [w reload];
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { AMShare(w, @[[NSURL fileURLWithPath:full]], [cv cellForItemAtIndexPath:ip]); }],
            [UIAction actionWithTitle:@"Save to Photos" image:[UIImage systemImageNamed:@"photo"] identifier:nil handler:^(UIAction *a) {
                UIImage *i = [UIImage imageWithContentsOfFile:full];
                if (i) UIImageWriteToSavedPhotosAlbum(i, nil, nil, NULL);
            }],
            del,
        ]];
    }];
}

@end
