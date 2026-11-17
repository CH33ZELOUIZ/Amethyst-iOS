#include "OfflineVanillaSeed.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SEED_MAX_JSON (16LL * 1024 * 1024)
#define SEED_MAX_JAR (512LL * 1024 * 1024)

static int seedFail(char *err, size_t n, const char *fmt, const char *a) {
    if (err && n) snprintf(err, n, fmt, a ? a : "");
    return 1;
}

static int versionSafe(const char *v) {
    size_t len = v ? strlen(v) : 0;
    if (!len || len > 64 || v[0] == '.' || strstr(v, "..")) return 0;
    for (size_t i = 0; i < len; i++) {
        char c = v[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '_' || c == '-')) return 0;
    }
    return 1;
}

static int isRealDir(const char *path) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

// Opens a regular, non-symlink file with size in (0, max]; returns fd or -1.
static int openRegular(const char *path, long long max, long long *sizeOut) {
    struct stat before, after;
    if (lstat(path, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size <= 0 || before.st_size > max) return -1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    if (fstat(fd, &after) != 0 || !S_ISREG(after.st_mode) || after.st_ino != before.st_ino || after.st_dev != before.st_dev || after.st_size != before.st_size) { close(fd); return -1; }
    *sizeOut = after.st_size;
    return fd;
}

static int readAll(int fd, off_t offset, void *buf, size_t n) {
    return pread(fd, buf, n, offset) == (ssize_t)n;
}

// Cheap structural JSON/jar checks; the caller additionally parses the JSON with a real parser.
static int jsonLooksValid(int fd, long long size, const char *version) {
    char *buf = NULL; int ok = 0;
    FILE *f = fdopen(dup(fd), "r");
    if (!f) return 0;
    buf = malloc((size_t)size + 1);
    if (buf && fread(buf, 1, (size_t)size, f) == (size_t)size) {
        buf[size] = 0;
        char needle[96]; snprintf(needle, sizeof needle, "\"%s\"", version);
        const char *s = buf; while (*s == ' ' || *s == '\n' || *s == '\r' || *s == '\t') s++;
        const char *e = buf + size; while (e > s && (e[-1] == ' ' || e[-1] == '\n' || e[-1] == '\r' || e[-1] == '\t')) e--;
        ok = *s == '{' && e > s && e[-1] == '}' && !memchr(buf, 0, (size_t)size) && strstr(buf, "\"id\"") && strstr(buf, needle) && strstr(buf, "\"downloads\"");
    }
    free(buf); fclose(f);
    return ok;
}

static int jarLooksValid(int fd, long long size) {
    unsigned char head[4], tail[22 + 65535];
    if (size < 22 || !readAll(fd, 0, head, 4) || memcmp(head, "PK\3\4", 4) != 0) return 0;
    size_t t = size < (long long)sizeof tail ? (size_t)size : sizeof tail;
    if (!readAll(fd, (off_t)(size - t), tail, t)) return 0;
    for (long i = (long)t - 22; i >= 0; i--) if (!memcmp(tail + i, "PK\5\6", 4)) return 1;
    return 0;
}

static int copyFd(int in, const char *dest) {
    char tmp[4096]; snprintf(tmp, sizeof tmp, "%s.part", dest);
    int out = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (out < 0) return 0;
    char buf[65536]; ssize_t n; off_t off = 0; int ok = 1;
    while (ok && (n = pread(in, buf, sizeof buf, off)) > 0) { ok = write(out, buf, (size_t)n) == n; off += n; }
    ok = ok && n == 0 && fsync(out) == 0;
    ok = close(out) == 0 && ok;
    if (!ok || rename(tmp, dest) != 0) { unlink(tmp); return 0; }
    return 1;
}

static int mkdirOK(const char *p) { return (mkdir(p, 0755) == 0 || errno == EEXIST) && isRealDir(p); }

int OfflineSeedVanillaRoot(const char *gameDir, const char *isolatedRoot, const char *v, char *err, size_t errLen) {
    if (!gameDir || !*gameDir || !isolatedRoot || !*isolatedRoot) return seedFail(err, errLen, "Invalid NeoForge seed request.%s", "");
    if (strlen(gameDir) > 2000 || strlen(isolatedRoot) > 2000) return seedFail(err, errLen, "Game directory path is too long.%s", "");
    if (!versionSafe(v)) return seedFail(err, errLen, "The pack's Minecraft version is not a safe version identifier.%s", "");
    char hint[256]; snprintf(hint, sizeof hint, "Install/download Minecraft %s in Duo first, then import this pack again.", v);
    char dir1[4096], dir2[4096], srcJson[4096], srcJar[4096];
    if (snprintf(dir1, sizeof dir1, "%s/versions", gameDir) >= (int)sizeof dir1 ||
        snprintf(dir2, sizeof dir2, "%s/%s", dir1, v) >= (int)sizeof dir2 ||
        snprintf(srcJson, sizeof srcJson, "%s/%s.json", dir2, v) >= (int)sizeof srcJson ||
        snprintf(srcJar, sizeof srcJar, "%s/%s.jar", dir2, v) >= (int)sizeof srcJar)
        return seedFail(err, errLen, "Game directory path is too long.%s", "");
    if (!isRealDir(isolatedRoot) || !isRealDir(dir1) || !isRealDir(dir2))
        return seedFail(err, errLen, "Vanilla Minecraft is not installed (missing or unsafe versions directory). %s", hint);
    long long jsonSize = 0, jarSize = 0;
    int jsonFd = openRegular(srcJson, SEED_MAX_JSON, &jsonSize);
    int jarFd = jsonFd < 0 ? -1 : openRegular(srcJar, SEED_MAX_JAR, &jarSize);
    if (jsonFd < 0 || jarFd < 0) { if (jsonFd >= 0) close(jsonFd); return seedFail(err, errLen, "Vanilla Minecraft files are missing, empty, oversized, or not regular files. %s", hint); }
    int bad = !jsonLooksValid(jsonFd, jsonSize, v) || !jarLooksValid(jarFd, jarSize);
    char vdir[4200], vsub[4300], dJson[4400], dJar[4400], profiles[4200];
    snprintf(vdir, sizeof vdir, "%s/versions", isolatedRoot);
    snprintf(vsub, sizeof vsub, "%s/%s", vdir, v);
    snprintf(dJson, sizeof dJson, "%s/%s.json", vsub, v);
    snprintf(dJar, sizeof dJar, "%s/%s.jar", vsub, v);
    snprintf(profiles, sizeof profiles, "%s/launcher_profiles.json", isolatedRoot);
    int ok = !bad && mkdirOK(vdir) && mkdirOK(vsub) && copyFd(jsonFd, dJson) && copyFd(jarFd, dJar);
    close(jsonFd); close(jarFd);
    if (bad) return seedFail(err, errLen, "Vanilla Minecraft files are corrupt. %s", hint);
    if (!ok) return seedFail(err, errLen, "Could not seed the isolated NeoForge install root.%s", "");
    static const char minimal[] = "{\"profiles\":{},\"version\":3}\n";
    int pf = open(profiles, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (pf < 0 || write(pf, minimal, sizeof minimal - 1) != (ssize_t)sizeof minimal - 1) { if (pf >= 0) close(pf); return seedFail(err, errLen, "Could not write launcher_profiles.json.%s", ""); }
    close(pf);
    return 0;
}
