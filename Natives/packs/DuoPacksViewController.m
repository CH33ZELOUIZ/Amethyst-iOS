#import "DuoPacksViewController.h"
#import "DuoPackLibrary.h"
#import "LauncherPreferences.h"
#import "LauncherNavigationController.h"
#import "PLProfiles.h"
#import "installer/ModpackInstallViewController.h"
#import "tools/AMTools.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface DuoPacksViewController ()
@property(nonatomic) NSArray<DuoPackInfo *> *packs;
@property(nonatomic) NSMutableDictionary<NSString *, NSNumber *> *sizes; // profile name -> bytes, filled off-main
@property(nonatomic) BOOL loaded;
@property(nonatomic) UILabel *emptyLabel;
@property(nonatomic) NSUInteger reloadGeneration;
@end

@implementation DuoPacksViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = localize(@"duo.packs.title", nil);
    self.sizes = [NSMutableDictionary new];
    return self;
}

- (NSString *)imageName { return @"shippingbox"; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = nil;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:PLProfilesDidChangeNotification object:nil];
    self.emptyLabel = [UILabel new];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.text = localize(@"duo.packs.empty", nil);
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    // Profile list is a small JSON dictionary; folder sizing is the expensive part and runs in the background.
    self.reloadGeneration++;
    NSUInteger generation = self.reloadGeneration;
    self.sizes = [NSMutableDictionary new];
    self.packs = [DuoPackLibrary installedPacks];
    self.loaded = YES;
    self.tableView.backgroundView = self.packs.count ? nil : self.emptyLabel;
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
    NSArray<DuoPackInfo *> *snapshot = self.packs;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (DuoPackInfo *pack in snapshot) {
            unsigned long long bytes = [DuoPackLibrary storageBytesForPack:pack];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.reloadGeneration) return;
                self.sizes[pack.profileName] = @(bytes);
                NSUInteger row = [self.packs indexOfObjectPassingTest:^BOOL(DuoPackInfo *p, NSUInteger i, BOOL *stop) { return [p.profileName isEqualToString:pack.profileName]; }];
                if (row != NSNotFound && self.tableView.window) {
                    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:1]] withRowAnimation:UITableViewRowAnimationNone];
                }
            });
        }
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : self.packs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 && self.packs.count ? localize(@"duo.packs.section.installed", nil) : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        NSDictionary *last = [DuoPackLibrary lastImportResult];
        if (!last) return localize(@"duo.packs.no_last_import", nil);
        NSString *when = [NSDateFormatter localizedStringFromDate:last[@"date"] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
        return [NSString stringWithFormat:localize([last[@"success"] boolValue] ? @"duo.packs.last_ok" : @"duo.packs.last_failed", nil), when, last[@"message"]];
    }
    return self.packs.count ? localize(@"duo.packs.remove_footer", nil) : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (indexPath.section == 0) {
        BOOL first = indexPath.row == 0;
        cell.textLabel.text = localize(first ? @"duo.packs.import" : @"duo.packs.browse", nil);
        cell.textLabel.textColor = self.view.tintColor;
        cell.imageView.image = [UIImage systemImageNamed:first ? @"square.and.arrow.down" : @"magnifyingglass"];
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        return cell;
    }
    DuoPackInfo *pack = self.packs[indexPath.row];
    NSNumber *bytes = self.sizes[pack.profileName];
    NSString *size = !pack.directoryExists ? localize(@"duo.packs.folder_missing", nil) : bytes ? [NSByteCountFormatter stringFromByteCount:bytes.longLongValue countStyle:NSByteCountFormatterCountStyleFile] : localize(@"duo.packs.calculating", nil);
    NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@ · %@ %@ · %@", localize([@"duo.packs.source." stringByAppendingString:pack.source], nil), pack.loader, pack.gameVersion ?: @"?", size]];
    [lines addObject:localize(pack.isSelected ? @"duo.packs.state.selected" : (pack.directoryExists ? @"duo.packs.state.ready" : @"duo.packs.state.broken"), nil)];
    cell.textLabel.text = pack.profileName;
    cell.detailTextLabel.text = [lines componentsJoinedByString:@"\n"];
    cell.imageView.image = [UIImage systemImageNamed:pack.directoryExists ? @"shippingbox" : @"exclamationmark.triangle"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", pack.profileName, [lines componentsJoinedByString:@", "]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self importPack]; else [self browse];
        return;
    }
    [self showActionsForPack:self.packs[indexPath.row] fromCell:[tableView cellForRowAtIndexPath:indexPath]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    DuoPackInfo *pack = self.packs[indexPath.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:localize(@"Remove", nil) handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        [self confirmRemove:pack];
        done(NO);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

#pragma mark - Actions

- (void)importPack {
    // Presents the existing picker flow; the import itself reports through the progress sheet.
    ModpackInstallViewController *mp = [ModpackInstallViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:mp];
    [self presentViewController:nav animated:YES completion:^{ [mp performSelector:NSSelectorFromString(@"actionImportMrpack")]; }];
}

- (void)browse {
    ModpackInstallViewController *mp = [ModpackInstallViewController new];
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:mp] animated:YES completion:nil];
}

- (void)showActionsForPack:(DuoPackInfo *)pack fromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:pack.profileName message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    UIAlertAction *select = [UIAlertAction actionWithTitle:localize(@"duo.packs.action.select", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        PLProfiles.current.selectedProfileName = pack.profileName;
        [self reload];
        showDialog(localize(@"duo.packs.selected.title", nil), localize(@"duo.packs.selected.message", nil));
    }];
    select.enabled = pack.directoryExists;
    [sheet addAction:select];
    UIAlertAction *launch = [UIAlertAction actionWithTitle:localize(@"duo.packs.action.launch", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        PLProfiles.current.selectedProfileName = pack.profileName;
        LauncherNavigationController *launcher = (LauncherNavigationController *)self.splitViewController.viewControllers.lastObject;
        [launcher reloadProfileList];
        [self reload];
        // Let the action sheet dismiss before presenting account/JIT/download UI.
        dispatch_async(dispatch_get_main_queue(), ^{ [launcher launchMinecraft:nil]; });
    }];
    launch.enabled = pack.directoryExists;
    [sheet addAction:launch];
    UIAlertAction *files = [UIAlertAction actionWithTitle:localize(@"duo.packs.action.files", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self.navigationController pushViewController:[[AMFileBrowserViewController alloc] initWithPath:pack.absoluteGameDir] animated:YES];
    }];
    files.enabled = pack.directoryExists;
    [sheet addAction:files];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"duo.packs.action.remove", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self confirmRemove:pack]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRemove:(DuoPackInfo *)pack {
    NSString *message = [NSString stringWithFormat:localize(@"duo.packs.remove.confirm", nil), pack.profileName];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"preference.title.confirm", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Remove", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSError *validationError = nil;
        if (![DuoPackLibrary canRemovePackProfile:pack error:&validationError]) {
            showDialog(localize(@"Error", nil), validationError.localizedDescription);
            return;
        }
        // The main-thread validation above establishes ownership before the atomic same-volume
        // quarantine. Profile persistence validates again because UI actions can race each other.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSString *quarantine = [DuoPackLibrary quarantinePackFolder:pack error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL ok = quarantine && [DuoPackLibrary removePackProfile:pack error:&error];
                if (!ok) {
                    NSError *restoreError = nil;
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        if (quarantine && ![DuoPackLibrary restoreQuarantinedPackFolder:quarantine forPack:pack error:&restoreError]) {
                            dispatch_async(dispatch_get_main_queue(), ^{ showDialog(localize(@"Error", nil), restoreError.localizedDescription); });
                        }
                    });
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                } else {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        NSError *deleteError = nil;
                        if (![DuoPackLibrary deleteQuarantinedPackFolder:quarantine error:&deleteError]) NSLog(@"[DuoPacks] quarantined folder cleanup failed: %@", deleteError);
                    });
                }
                [(LauncherNavigationController *)self.splitViewController.viewControllers.lastObject performSelector:@selector(reloadProfileList)];
                [self reload];
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
