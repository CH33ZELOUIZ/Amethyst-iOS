#ifndef OFFLINE_VANILLA_SEED_H
#define OFFLINE_VANILLA_SEED_H
#include <stddef.h>

// Securely seeds a disposable NeoForge installer root with the vanilla prerequisites
// ClientInstall needs: versions/<v>/<v>.json, versions/<v>/<v>.jar and a minimal
// launcher_profiles.json. Sources are read from the canonical game dir only after
// verifying that every path component is a real directory / regular file (no symlinks).
// Returns 0 on success, otherwise nonzero with an actionable message in err.
int OfflineSeedVanillaRoot(const char *gameDir, const char *isolatedRoot, const char *minecraftVersion,
                           char *err, size_t errLen);

#endif
