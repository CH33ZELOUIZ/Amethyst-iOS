#import <Foundation/Foundation.h>

// Describes one installed/imported modpack profile for the Packs screen.
@interface DuoPackInfo : NSObject
@property(nonatomic, copy) NSString *profileName, *source, *gameVersion, *loader, *relativeGameDir, *installedAt;
@property(nonatomic, copy) NSString *absoluteGameDir;
@property(nonatomic) BOOL directoryExists, isSelected;
@end

// Source of truth is launcher_profiles.json (PLProfiles). Offline imports carry the Duo marker keys
// duoPackSource / duoPackInstalledAt; any other profile whose gameDir lives under custom_gamedir/ is
// listed as a modpack too (Modrinth/CurseForge installs).
@interface DuoPackLibrary : NSObject
+ (NSString *)customGameDirRoot;
+ (void)markProfile:(NSMutableDictionary *)profile source:(NSString *)source;
// Reads profiles (cheap). Sorted by name, case-insensitive: deterministic.
+ (NSArray<DuoPackInfo *> *)installedPacks;
// Recursive size; call from a background queue only.
+ (unsigned long long)storageBytesForPack:(DuoPackInfo *)pack;
// Removal is two steps so the slow folder delete stays off the main thread while profile JSON
// mutation stays on it. Shared versions/ and libraries/ are NOT removed: other profiles may rely on them.
+ (BOOL)canRemoveAnyPack;                                              // false when only one profile exists
+ (BOOL)removePackFolder:(DuoPackInfo *)pack error:(NSError **)error;  // any thread
+ (BOOL)removePackProfile:(DuoPackInfo *)pack error:(NSError **)error; // main thread only
// Last import outcome, persisted across launches (message never contains paths or secrets).
+ (void)recordImportResult:(BOOL)success message:(NSString *)message;
+ (NSDictionary *)lastImportResult;
@end
