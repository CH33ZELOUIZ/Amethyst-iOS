#import "DuoLogRedaction.h"
#import "DuoLogRedactor.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherPreferences.h"

static NSArray<NSString *> *DuoRedactionLiterals(void) {
    NSMutableArray<NSString *> *literals = [NSMutableArray new];
    NSDictionary *auth = BaseAuthenticator.current.authData;
    for (NSString *key in @[@"username", @"xboxGamertag", @"profilePicURL"]) {
        id value = auth[key];
        if ([value isKindOfClass:NSString.class] && [value length] >= 3) [literals addObject:value];
    }
    for (NSString *name in @[@"AME_HOME", @"GAME_DIR"]) {
        const char *value = getenv(name.UTF8String);
        if (value && *value) [literals addObject:@(value)];
    }
    [literals addObject:NSHomeDirectory()];
    [literals addObject:NSTemporaryDirectory().stringByStandardizingPath];
    // User-configured launch values can contain tokens, credentials, or private endpoints.
    for (NSString *key in @[@"java.java_args", @"java.env_variables"]) {
        id value = getPrefObject(key);
        if ([value isKindOfClass:NSString.class] && [value length] >= 3) [literals addObject:value];
    }
    return literals;
}

NSString *DuoRedactedString(NSString *text) {
    if (text.length == 0) return @"";
    NSArray<NSString *> *literals = DuoRedactionLiterals();
    const char **cLiterals = calloc(literals.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < literals.count; i++) cLiterals[i] = literals[i].UTF8String;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    char *redacted = DuoRedactLog(data.bytes, data.length, cLiterals, literals.count);
    free(cLiterals);
    // Fail closed: never return the unredacted input.
    if (!redacted) return @"[redaction failed; content withheld]";
    NSString *result = [[NSString alloc] initWithUTF8String:redacted] ?: @"[redaction failed; content withheld]";
    free(redacted);
    return result;
}
