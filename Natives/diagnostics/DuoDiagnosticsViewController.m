#import "DuoDiagnosticsViewController.h"

#if DUO_PRIVATE_BUILD

#import "DuoDiagnosticsExport.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

static NSString *const kEnabledKey = @"duo.devlog.enabled";

#pragma mark - Preview (the user reviews exactly what will be shared)

@interface DuoLogPreviewViewController : UIViewController
@property(nonatomic, copy) NSString *reportText;
@end

@implementation DuoLogPreviewViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"duo.diag.preview.title", nil);
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *banner = [UILabel new];
    banner.numberOfLines = 0;
    banner.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    banner.adjustsFontForContentSizeCategory = YES;
    banner.textColor = UIColor.secondaryLabelColor;
    banner.text = [DuoDiagnosticsExport contentsSummary];
    UITextView *text = [UITextView new];
    text.editable = NO;
    text.alwaysBounceVertical = YES;
    text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    text.text = self.reportText;
    text.accessibilityLabel = localize(@"duo.diag.preview.a11y", nil);
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[banner, text]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
    ]];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithTitle:localize(@"Share", nil) style:UIBarButtonItemStyleDone target:self action:@selector(actionShare:)];
    share.accessibilityLabel = localize(@"duo.diag.share.a11y", nil);
    share.accessibilityHint = localize(@"duo.diag.share_hint", nil);
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:localize(@"duo.diag.copy", nil) style:UIBarButtonItemStylePlain target:self action:@selector(actionCopy)];
    self.navigationItem.rightBarButtonItems = @[share, copy];
}

- (void)actionCopy {
    // Fallback when no share destination is usable. Redact again immediately before export.
    UIPasteboard.generalPasteboard.string = [DuoDiagnosticsExport redactedExportTextFromReviewedText:self.reportText];
    showDialog(localize(@"duo.diag.copied.title", nil), localize(@"duo.diag.copied.message", nil));
}

- (void)actionShare:(UIBarButtonItem *)sender {
    NSError *error = nil;
    NSURL *file = [DuoDiagnosticsExport writeReportText:self.reportText error:&error];
    if (!file) {
        showDialog(localize(@"Error", nil), error.localizedDescription ?: localize(@"duo.diag.write_failed", nil));
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    NSURL *directory = file.URLByDeletingLastPathComponent;
    // The temp bundle never outlives the share sheet.
    activity.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *activityError) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        if (activityError) showDialog(localize(@"Error", nil), activityError.localizedDescription);
    };
    [self presentViewController:activity animated:YES completion:nil];
}

@end

#pragma mark - Diagnostics screen

@interface DuoDiagnosticsViewController ()
@property(nonatomic) NSArray<NSArray<NSString *> *> *status;
@property(nonatomic) BOOL building;
@end

@implementation DuoDiagnosticsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.title = localize(@"duo.diag.title", nil);
    return self;
}

- (NSString *)imageName { return @"stethoscope"; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.status = [DuoDiagnosticsExport statusRows];
    [self.tableView reloadData];
}

- (BOOL)exportEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? self.status.count : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return localize(section == 0 ? @"duo.diag.section.status" : @"duo.diag.section.export", nil);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? [DuoDiagnosticsExport contentsSummary] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.section == 0) {
        cell.textLabel.text = self.status[indexPath.row][0];
        cell.detailTextLabel.text = self.status[indexPath.row][1];
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", self.status[indexPath.row][0], self.status[indexPath.row][1]];
        return cell;
    }
    if (indexPath.row == 0) {
        cell.textLabel.text = localize(@"duo.diag.enable", nil);
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self exportEnabled];
        toggle.accessibilityLabel = localize(@"duo.diag.enable", nil);
        [toggle addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else {
        BOOL enabled = [self exportEnabled] && !self.building;
        cell.textLabel.text = self.building ? localize(@"duo.diag.building", nil) : localize(@"duo.diag.review_export", nil);
        cell.textLabel.textColor = enabled ? self.view.tintColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = enabled;
        cell.detailTextLabel.text = [self exportEnabled] ? nil : localize(@"duo.diag.disabled_reason", nil);
        cell.accessibilityTraits = UIAccessibilityTraitButton;
        if (self.building) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        }
    }
    return cell;
}

- (void)toggleEnabled:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:kEnabledKey];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1 || indexPath.row != 1 || ![self exportEnabled] || self.building) return;
    // Consent is intentionally per-report, not a persisted blanket permission.
    UIAlertController *consent = [UIAlertController alertControllerWithTitle:localize(@"duo.diag.consent.title", nil) message:[DuoDiagnosticsExport contentsSummary] preferredStyle:UIAlertControllerStyleAlert];
    [consent addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [consent addAction:[UIAlertAction actionWithTitle:localize(@"duo.diag.consent.continue", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self buildAndPreview];
    }]];
    [self presentViewController:consent animated:YES completion:nil];
}

- (void)buildAndPreview {
    self.building = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
    // File reads and regex redaction stay off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = [DuoDiagnosticsExport buildRedactedReport];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.building = NO;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
            if (!report.length) {
                showDialog(localize(@"Error", nil), localize(@"duo.diag.build_failed", nil));
                return;
            }
            DuoLogPreviewViewController *preview = [DuoLogPreviewViewController new];
            preview.reportText = report;
            [self.navigationController pushViewController:preview animated:YES];
        });
    });
}

@end

#endif
