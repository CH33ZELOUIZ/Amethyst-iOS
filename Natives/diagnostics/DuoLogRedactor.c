// Pure C redaction pass for the Duo developer diagnostics export (no Foundation, no network).
#include "DuoLogRedactor.h"
#include <regex.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *data;
    size_t len, cap;
} Buf;

static int buf_reserve(Buf *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) return 1;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra + 1) cap *= 2;
    char *p = realloc(b->data, cap);
    if (!p) return 0;
    b->data = p;
    b->cap = cap;
    return 1;
}

static int buf_append(Buf *b, const char *s, size_t n) {
    if (!buf_reserve(b, n)) return 0;
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = 0;
    return 1;
}

// Replace every literal occurrence of `needle` with `replacement`.
static char *replace_literal(char *text, const char *needle, const char *replacement) {
    size_t nlen = strlen(needle);
    if (nlen < 3) return text; // refuse tiny literals: would shred unrelated text
    Buf out = {0};
    const char *p = text, *hit;
    size_t rlen = strlen(replacement);
    while ((hit = strstr(p, needle))) {
        if (!buf_append(&out, p, (size_t)(hit - p)) || !buf_append(&out, replacement, rlen)) { free(out.data); free(text); return NULL; }
        p = hit + nlen;
    }
    if (!buf_append(&out, p, strlen(p))) { free(out.data); free(text); return NULL; }
    free(text);
    return out.data ? out.data : strdup("");
}

typedef struct {
    const char *pattern;
    int icase;
    int keepGroup1;           // keep the text of capture group 1 before the replacement
    const char *replacement;
} Rule;

// Order matters: structured launch args / key=value first, then token shapes, then identities.
static const Rule kRules[] = {
    // Launch arguments that carry identity/session material.
    {"(--(accessToken|uuid|username|xuid|clientId|userProperties|session|userType)[[:space:]=]+)[^[:space:]]+", 0, 1, "<redacted>"},
    // key=value / key: value secrets (also HTTP headers).
    {"((x-api-key|api[_-]?key|authorization|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|token|password|passwd|secret|cookie)[\"']?[[:space:]]*[:=][[:space:]]*(Bearer[[:space:]]+)?)[^[:space:],;\"'&]+", 1, 1, "<redacted>"},
    {"Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+", 1, 0, "Bearer <redacted>"},
    {"eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*", 0, 0, "<jwt>"},
    {"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", 0, 0, "<email>"},
    // iOS container / user home paths (before the generic UUID rule so containers become <home>).
    {"(/private)?/var/mobile/Containers/[A-Za-z]+/[A-Za-z]+/[0-9A-Fa-f-]+", 0, 0, "<home>"},
    {"(/private)?/var/mobile/Documents", 0, 0, "<documents>"},
    {"(/Users|/home)/[^/[:space:]]+", 0, 0, "/<user-home>"},
    {"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", 0, 0, "<uuid>"},
    {"[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}", 0, 0, "<ip>"},
    {"[0-9a-fA-F:]*:[0-9a-fA-F:]*:[0-9a-fA-F:]+:[0-9a-fA-F]{1,4}", 0, 0, "<ip6>"},
    // Last resort: long opaque tokens (hex/base64/base64url keys).
    {"[A-Za-z0-9_+=-]{40,}", 0, 0, "<redacted-token>"},
};

static char *apply_rule(char *text, const Rule *rule) {
    regex_t re;
    int flags = REG_EXTENDED | (rule->icase ? REG_ICASE : 0);
    if (regcomp(&re, rule->pattern, flags) != 0) return text; // bad rule must not leak: caller treats unchanged as failure-safe below
    Buf out = {0};
    const char *p = text;
    size_t rlen = strlen(rule->replacement);
    regmatch_t m[4];
    int atLineStart = 1;
    while (*p) {
        int rc = regexec(&re, p, 4, m, atLineStart ? 0 : REG_NOTBOL);
        if (rc != 0 || m[0].rm_eo == m[0].rm_so) break;
        if (!buf_append(&out, p, (size_t)m[0].rm_so)) goto fail;
        if (rule->keepGroup1 && m[1].rm_so >= 0 && !buf_append(&out, p + m[1].rm_so, (size_t)(m[1].rm_eo - m[1].rm_so))) goto fail;
        if (!buf_append(&out, rule->replacement, rlen)) goto fail;
        p += m[0].rm_eo;
        atLineStart = 0;
    }
    if (!buf_append(&out, p, strlen(p))) goto fail;
    regfree(&re);
    free(text);
    return out.data ? out.data : strdup("");
fail:
    regfree(&re);
    free(out.data);
    free(text);
    return NULL;
}

char *DuoRedactLog(const char *input, size_t length, const char *const *literals, size_t literalCount) {
    if (!input) input = "";
    char *text = malloc(length + 1);
    if (!text) return NULL;
    memcpy(text, input, length);
    text[length] = 0;
    // Embedded NULs would hide the tail from string functions; blank them out.
    for (size_t i = 0; i < length; i++) if (text[i] == 0) text[i] = ' ';

    // Longest literals first so a path is replaced before its parent directory.
    size_t *order = literalCount ? malloc(literalCount * sizeof(size_t)) : NULL;
    if (literalCount && !order) { free(text); return NULL; }
    for (size_t i = 0; i < literalCount; i++) order[i] = i;
    for (size_t i = 1; i < literalCount; i++) {
        size_t v = order[i], j = i;
        while (j > 0 && literals[order[j - 1]] && literals[v] && strlen(literals[order[j - 1]]) < strlen(literals[v])) { order[j] = order[j - 1]; j--; }
        order[j] = v;
    }
    for (size_t i = 0; i < literalCount && text; i++) {
        const char *lit = literals[order[i]];
        if (lit && *lit) text = replace_literal(text, lit, "<redacted>");
    }
    free(order);
    for (size_t i = 0; i < sizeof kRules / sizeof kRules[0] && text; i++) text = apply_rule(text, &kRules[i]);
    return text;
}
