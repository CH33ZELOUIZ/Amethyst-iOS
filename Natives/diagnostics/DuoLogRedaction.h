#import <Foundation/Foundation.h>

// Redacts secrets/identity/paths from text using the pure-C DuoRedactLog pass plus runtime
// literals (current account name, gamertag, home/game paths). Network-free. Safe to call from any
// thread; do not call on the main thread with very large input.
FOUNDATION_EXPORT NSString *DuoRedactedString(NSString *text);
