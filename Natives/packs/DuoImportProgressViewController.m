#import "DuoImportProgressViewController.h"
#import "utils.h"

@interface DuoImportProgressViewController ()
@property(nonatomic, weak) MinecraftResourceDownloadTask *task;
@property(nonatomic, copy) NSString *headline;
@property(nonatomic) UILabel *phaseLabel, *detailLabel;
@property(nonatomic) UIProgressView *progressView;
@property(nonatomic) UIButton *cancelButton;
@property(nonatomic) NSTimer *timer;
@end

@implementation DuoImportProgressViewController

- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task title:(NSString *)title {
    self = [super init];
    self.task = task;
    self.headline = title;
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [UILabel new];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 0;
    title.text = self.headline;
    title.accessibilityTraits = UIAccessibilityTraitHeader;

    self.phaseLabel = [UILabel new];
    self.phaseLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.phaseLabel.adjustsFontForContentSizeCategory = YES;
    self.phaseLabel.numberOfLines = 0;
    self.phaseLabel.text = localize(@"duo.import.starting", nil);

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.accessibilityLabel = localize(@"duo.import.progress.a11y", nil);

    self.detailLabel = [UILabel new];
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.detailLabel.adjustsFontForContentSizeCategory = YES;
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.detailLabel.numberOfLines = 0;

    UILabel *note = [UILabel new];
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    note.adjustsFontForContentSizeCategory = YES;
    note.textColor = UIColor.secondaryLabelColor;
    note.numberOfLines = 0;
    note.text = localize(@"duo.import.hide_note", nil);

    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    [hide setTitle:localize(@"duo.import.hide", nil) forState:UIControlStateNormal];
    hide.accessibilityHint = localize(@"duo.import.hide_note", nil);
    [hide addTarget:self action:@selector(actionHide) forControlEvents:UIControlEventTouchUpInside];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:localize(@"Cancel", nil) forState:UIControlStateNormal];
    [self.cancelButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(actionCancel) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.cancelButton, hide]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.phaseLabel, self.progressView, self.detailLabel, note, buttons]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
    ]];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.timer invalidate];
    // Polls task state on the main run loop; no KVO lifetime to manage, so hiding is always safe.
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}

- (void)refresh {
    MinecraftResourceDownloadTask *task = self.task;
    if (!task) { [self actionHide]; return; } // task released: import finished or failed
    NSProgress *progress = task.progress;
    if (task.phase.length) self.phaseLabel.text = task.phase;
    BOOL indeterminate = progress.totalUnitCount <= 1 && progress.fractionCompleted == 0;
    self.progressView.progress = indeterminate ? 0 : (float)progress.fractionCompleted;
    NSString *detail = task.textProgress.localizedAdditionalDescription ?: progress.localizedAdditionalDescription;
    NSString *percent = indeterminate ? @"" : [NSString stringWithFormat:@"%d%%", (int)(progress.fractionCompleted * 100)];
    self.detailLabel.text = [@[percent, detail ?: @""] componentsJoinedByString:@"  "];
    self.progressView.accessibilityValue = percent;
    if (progress.cancelled) {
        self.cancelButton.enabled = NO;
        self.phaseLabel.text = localize(@"duo.import.cancelling", nil);
    }
    if (progress.finished) [self actionHide];
}

- (void)actionHide {
    [self.timer invalidate];
    self.timer = nil;
    if (self.presentingViewController) [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionCancel {
    [self.task.progress cancel];
    self.cancelButton.enabled = NO;
    self.phaseLabel.text = localize(@"duo.import.cancelling", nil);
}

@end
