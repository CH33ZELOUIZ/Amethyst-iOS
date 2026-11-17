#import <Foundation/Foundation.h>
#include "config.h"

#if DUO_PRIVATE_BUILD

// Private developer build only. Builds a local, redacted, size-capped diagnostics report.
// There is no network code here: the user reviews the text and shares it via the system share sheet.
FOUNDATION_EXPORT const NSUInteger DuoMaxBundleBytes;
FOUNDATION_EXPORT const NSUInteger DuoMaxHsErrFiles;

@interface DuoDiagnosticsExport : NSObject
// Cheap, main-thread-safe status rows: @[@[label, value]]. Shown on screen only.
+ (NSArray<NSArray<NSString *> *> *)statusRows;
// Reads and redacts log files. Call from a background queue.
+ (NSString *)buildRedactedReport;
// Re-redacts and size-caps text immediately before it leaves the preview. This is deliberately
// separate from report generation so a stale or externally supplied preview buffer cannot be shared.
+ (NSString *)redactedExportTextFromReviewedText:(NSString *)text;
// Short human-readable statement of what is included and redacted (shown in consent and preview).
+ (NSString *)contentsSummary;
// Writes the reviewed text to a fresh temp directory and returns the file URL. Caller deletes the
// containing directory after sharing.
+ (NSURL *)writeReportText:(NSString *)text error:(NSError **)error;
@end

#endif
