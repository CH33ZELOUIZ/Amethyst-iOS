#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSNotificationName const PLProfilesDidChangeNotification;

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *> *profileDict;

+ (PLProfiles *)current;
+ (void)updateCurrent;

//+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

- (id)initWithCurrentInstance;
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *)profiles;

- (NSMutableDictionary<NSString *, NSString *> *)selectedProfile;
- (NSString *)selectedProfileName;
- (void)setSelectedProfileName:(NSString *)name;
// Callers that publish a profile must use this variant so write failures are not hidden.
- (BOOL)save:(NSError **)error;
- (void)save;

@end
