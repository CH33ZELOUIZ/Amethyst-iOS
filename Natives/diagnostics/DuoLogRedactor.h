#ifndef DuoLogRedactor_h
#define DuoLogRedactor_h
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Pure, network-free redaction of launcher/game log text for the private developer
// diagnostics export. Returns a malloc'd NUL-terminated string (free() it), or NULL on
// allocation failure. `literals` are exact strings (account name, gamertag, home paths...)
// that are replaced with "<redacted>" before pattern rules run. Longest literals win.
char *DuoRedactLog(const char *input, size_t length, const char *const *literals, size_t literalCount);

#ifdef __cplusplus
}
#endif
#endif
