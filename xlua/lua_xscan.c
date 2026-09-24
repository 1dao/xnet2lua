/* lua_xscan.c -- configurable tokenizer + bracket matcher for source indexing.
**
** One C lexer serves every language: a Lua table describes the language
** (identifier chars, keywords, operators, comments, string forms, and the
** C-preprocessor / Python-indentation switches), and per-language parsers
** written in Lua walk the token arrays this module produces. Bodies are
** skipped with the precomputed bracket match table, so the parsers stay
** small and the byte-level work stays here.
**
**   local L = xscan.lang{
**       ident_start = 'A-Za-z_', ident_char = 'A-Za-z0-9_',  -- bytes >= 0x80 always count
**       keywords = { 'if', 'return', ... },
**       ops = { '->', '>>=', ... },                          -- longest match wins
**       line_comment = { '//' }, block_comment = { { open, close } },
**       strings = { { '"', '"', escape = '\\', multiline = false }, ... },
**       string_prefixes = 'rbfu',                            -- letters allowed before a quote
**       directive = '#',                                     -- whole-line directive at line start
**       pp_first_branch = true,                              -- C: see directive() below
**       indent = true,                                       -- Python: nl/indent/dedent tokens
**       long_brackets = true,                                -- Lua: [==[ str ]==], --[==[ comment ]==]
**   }
**   local T = L:tokenize(src)
**
** T is a plain table so parsers can index the arrays directly in hot loops:
**   T.n, T.src, T.k[i] (kind string), T.s[i] / T.e[i] (1-based inclusive byte
**   span), T.l[i] / T.el[i] (start / end line), T.m[i] (matching bracket or
**   indent/dedent index, nil when unmatched)
** plus methods: T:kind(i), T:text(i), T:line(i), T:eline(i), T:match(i),
**   T:is(i, text), T:calls(i, j), T:idents(i, j).
**
** Kinds: id kw op str num dir nl indent dedent.
**
** A pure-Lua implementation with the same contract exists for runtimes
** without this module; behavior must stay identical between the two. */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#if defined(LUA_EMBEDDED)
#include "../3rd/minilua.h"
#else
#include "lua.h"
#include "lauxlib.h"
#endif

#define XSCAN_LANG_META   "xscan.lang"
#define XSCAN_RAW_META    "xscan.raw"
#define XSCAN_TOKENS_META "xscan.tokens"

#define XS_MAX_LIST 8

enum { K_ID = 1, K_KW, K_OP, K_STR, K_NUM, K_DIR, K_NL, K_INDENT, K_DEDENT, K_COUNT };
static const char* const k_kind_names[K_COUNT] = {
    NULL, "id", "kw", "op", "str", "num", "dir", "nl", "indent", "dedent"
};

typedef struct {
    char* s;
    size_t len;
} XsStr;

typedef struct {
    XsStr open, close;
    int esc;        /* escape byte, -1 for none */
    int multiline;
} XsDelim;

typedef struct {
    uint8_t id_start[256], id_char[256], prefix[256];
    XsStr* kw;      /* open-addressing set, len == 0 marks an empty slot */
    uint32_t kw_cap;
    XsStr* ops[256];
    int nops[256];
    XsStr lc[XS_MAX_LIST];
    int nlc;
    XsDelim bc[XS_MAX_LIST];
    int nbc;
    XsDelim st[XS_MAX_LIST];
    int nst;
    int directive;  /* -1 for none */
    int pp_first_branch;
    int indent;
    int long_brackets;  /* Lua [==[ strings ]==] and --[==[ comments ]==] */
} XsLang;

typedef struct {
    int n, cap;
    uint8_t* k;
    int32_t *s, *e, *l, *el, *m;
    const char* src;    /* borrowed: the source string is pinned as uservalue 1 */
    size_t len;
} XsRaw;

/* ------------------------------------------------------------------------ */
/* Language config                                                          */

static char* xs_dup(const char* s, size_t n) {
    char* p = (char*)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

static uint32_t xs_hash(const char* s, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= (uint8_t)s[i]; h *= 16777619u; }
    return h;
}

static int xs_is_keyword(const XsLang* g, const char* s, size_t n) {
    if (!g->kw_cap) return 0;
    uint32_t i = xs_hash(s, n) & (g->kw_cap - 1);
    while (g->kw[i].len) {
        if (g->kw[i].len == n && memcmp(g->kw[i].s, s, n) == 0) return 1;
        i = (i + 1) & (g->kw_cap - 1);
    }
    return 0;
}

static void xs_char_set(uint8_t* set, const char* r, size_t n) {
    memset(set, 0, 256);
    for (int c = 128; c < 256; c++) set[c] = 1;
    size_t k = 0;
    while (k < n) {
        if (k + 2 < n && r[k + 1] == '-') {
            for (int c = (uint8_t)r[k]; c <= (uint8_t)r[k + 2]; c++) set[c] = 1;
            k += 3;
        } else {
            set[(uint8_t)r[k]] = 1;
            k += 1;
        }
    }
}

static void xs_lang_free(XsLang* g) {
    if (g->kw) {
        for (uint32_t i = 0; i < g->kw_cap; i++) free(g->kw[i].s);
        free(g->kw);
        g->kw = NULL;
    }
    for (int b = 0; b < 256; b++) {
        for (int i = 0; i < g->nops[b]; i++) free(g->ops[b][i].s);
        free(g->ops[b]);
        g->ops[b] = NULL;
        g->nops[b] = 0;
    }
    for (int i = 0; i < g->nlc; i++) free(g->lc[i].s);
    for (int i = 0; i < g->nbc; i++) { free(g->bc[i].open.s); free(g->bc[i].close.s); }
    for (int i = 0; i < g->nst; i++) { free(g->st[i].open.s); free(g->st[i].close.s); }
    g->nlc = g->nbc = g->nst = 0;
}

static int l_lang_gc(lua_State* L) {
    xs_lang_free((XsLang*)luaL_checkudata(L, 1, XSCAN_LANG_META));
    return 0;
}

/* String field `name` of the table at index 1, or def. */
static const char* xs_opt_field(lua_State* L, const char* name, const char* def, size_t* n) {
    const char* s = def;
    lua_getfield(L, 1, name);
    if (lua_isstring(L, -1)) s = lua_tolstring(L, -1, n);
    else if (n) *n = def ? strlen(def) : 0;
    lua_pop(L, 1);          /* still referenced by the config table */
    return s;
}

static int xs_opt_bool(lua_State* L, const char* name) {
    lua_getfield(L, 1, name);
    int v = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return v;
}

static int xs_read_str(lua_State* L, int idx, XsStr* out) {
    size_t n = 0;
    const char* s = lua_tolstring(L, idx, &n);
    if (!s || n == 0) return 0;
    out->s = xs_dup(s, n);
    out->len = n;
    return out->s != NULL;
}

/* Reads config table at index 1 into the userdata at the top of the stack. */
static void xs_lang_load(lua_State* L, XsLang* g) {
    size_t n = 0;
    const char* r;
    r = xs_opt_field(L, "ident_start", "A-Za-z_", &n);
    xs_char_set(g->id_start, r, n);
    r = xs_opt_field(L, "ident_char", "A-Za-z0-9_", &n);
    xs_char_set(g->id_char, r, n);

    memset(g->prefix, 0, sizeof g->prefix);
    r = xs_opt_field(L, "string_prefixes", "", &n);
    for (size_t i = 0; i < n; i++) {
        uint8_t c = (uint8_t)r[i];
        g->prefix[c] = 1;
        if (c >= 'a' && c <= 'z') g->prefix[c - 32] = 1;
    }

    r = xs_opt_field(L, "directive", NULL, &n);
    g->directive = (r && n > 0) ? (uint8_t)r[0] : -1;
    g->pp_first_branch = xs_opt_bool(L, "pp_first_branch");
    g->indent = xs_opt_bool(L, "indent");
    g->long_brackets = xs_opt_bool(L, "long_brackets");

    /* keywords: open addressing at <= 50% load */
    lua_getfield(L, 1, "keywords");
    if (lua_istable(L, -1)) {
        lua_Integer nk = luaL_len(L, -1);
        uint32_t cap = 16;
        while (cap < (uint32_t)(nk * 2 + 1)) cap <<= 1;
        g->kw = (XsStr*)calloc(cap, sizeof(XsStr));
        if (!g->kw) luaL_error(L, "xscan: out of memory");
        g->kw_cap = cap;
        for (lua_Integer i = 1; i <= nk; i++) {
            lua_rawgeti(L, -1, i);
            size_t kn = 0;
            const char* ks = lua_tolstring(L, -1, &kn);
            if (ks && kn > 0 && !xs_is_keyword(g, ks, kn)) {
                uint32_t h = xs_hash(ks, kn) & (cap - 1);
                while (g->kw[h].len) h = (h + 1) & (cap - 1);
                g->kw[h].s = xs_dup(ks, kn);
                g->kw[h].len = kn;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    /* operators, bucketed by first byte, longest first */
    lua_getfield(L, 1, "ops");
    if (lua_istable(L, -1)) {
        lua_Integer no = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= no; i++) {
            lua_rawgeti(L, -1, i);
            XsStr op = { NULL, 0 };
            if (xs_read_str(L, -1, &op)) {
                int b = (uint8_t)op.s[0];
                XsStr* grown = (XsStr*)realloc(g->ops[b], sizeof(XsStr) * (size_t)(g->nops[b] + 1));
                if (!grown) { free(op.s); luaL_error(L, "xscan: out of memory"); }
                g->ops[b] = grown;
                int at = g->nops[b]++;
                /* insertion keeps each bucket sorted by length, longest first;
                ** equal lengths keep config order (the Lua version's sort is
                ** only ever asked to break ties between distinct strings) */
                while (at > 0 && g->ops[b][at - 1].len < op.len) {
                    g->ops[b][at] = g->ops[b][at - 1];
                    at--;
                }
                g->ops[b][at] = op;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "line_comment");
    if (lua_istable(L, -1)) {
        lua_Integer nl = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= nl && g->nlc < XS_MAX_LIST; i++) {
            lua_rawgeti(L, -1, i);
            if (xs_read_str(L, -1, &g->lc[g->nlc])) g->nlc++;
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "block_comment");
    if (lua_istable(L, -1)) {
        lua_Integer nb = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= nb && g->nbc < XS_MAX_LIST; i++) {
            lua_rawgeti(L, -1, i);
            if (lua_istable(L, -1)) {
                XsDelim* d = &g->bc[g->nbc];
                memset(d, 0, sizeof *d);
                lua_rawgeti(L, -1, 1);
                int ok = xs_read_str(L, -1, &d->open);
                lua_pop(L, 1);
                lua_rawgeti(L, -1, 2);
                ok = ok && xs_read_str(L, -1, &d->close);
                lua_pop(L, 1);
                if (ok) g->nbc++;
                else { free(d->open.s); free(d->close.s); }
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);

    lua_getfield(L, 1, "strings");
    if (lua_istable(L, -1)) {
        lua_Integer ns = luaL_len(L, -1);
        for (lua_Integer i = 1; i <= ns && g->nst < XS_MAX_LIST; i++) {
            lua_rawgeti(L, -1, i);
            if (lua_istable(L, -1)) {
                XsDelim* d = &g->st[g->nst];
                memset(d, 0, sizeof *d);
                d->esc = -1;
                lua_rawgeti(L, -1, 1);
                int ok = xs_read_str(L, -1, &d->open);
                lua_pop(L, 1);
                lua_rawgeti(L, -1, 2);
                ok = ok && xs_read_str(L, -1, &d->close);
                lua_pop(L, 1);
                lua_getfield(L, -1, "escape");
                size_t en = 0;
                const char* es = lua_tolstring(L, -1, &en);
                if (es && en > 0) d->esc = (uint8_t)es[0];
                lua_pop(L, 1);
                lua_getfield(L, -1, "multiline");
                d->multiline = lua_toboolean(L, -1);
                lua_pop(L, 1);
                if (ok) g->nst++;
                else { free(d->open.s); free(d->close.s); }
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}

static int l_lang(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    XsLang* g = (XsLang*)lua_newuserdatauv(L, sizeof(XsLang), 0);
    memset(g, 0, sizeof *g);
    luaL_setmetatable(L, XSCAN_LANG_META);
    xs_lang_load(L, g);
    return 1;
}

/* ------------------------------------------------------------------------ */
/* Tokenizer                                                                */

static int xs_grow(XsRaw* t) {
    int cap = t->cap ? t->cap * 2 : 256;
    uint8_t* k = (uint8_t*)realloc(t->k, (size_t)cap);
    if (!k) return 0;
    t->k = k;
#define XS_GROW_ARR(f) do { \
        int32_t* p = (int32_t*)realloc(t->f, sizeof(int32_t) * (size_t)cap); \
        if (!p) return 0; \
        t->f = p; \
    } while (0)
    XS_GROW_ARR(s);
    XS_GROW_ARR(e);
    XS_GROW_ARR(l);
    XS_GROW_ARR(el);
#undef XS_GROW_ARR
    t->cap = cap;
    return 1;
}

typedef struct {
    int parent, taken, keep_all;
} XsPP;

typedef struct {
    const XsLang* g;
    const char* src;
    int len;
    XsRaw* t;
    int line, depth, skip;
    XsPP* pp;
    int npp, cap_pp;
    int oom;
} XsScan;

/* 1-based byte access; 0 outside the source (mirrors Lua's nil -> false). */
#define B(p) (((p) >= 1 && (p) <= sc->len) ? (uint8_t)sc->src[(p) - 1] : 0)

static int xs_starts(const XsScan* sc, int p, const XsStr* lit) {
    return p >= 1 && (size_t)p + lit->len - 1 <= (size_t)sc->len
        && memcmp(sc->src + p - 1, lit->s, lit->len) == 0;
}

static int xs_count_nl(const XsScan* sc, int a, int b) {
    int n = 0;
    for (int p = a; p <= b && p <= sc->len; p++) if (sc->src[p - 1] == '\n') n++;
    return n;
}

/* Lua long bracket opening at p: '[' '='* '['. Returns its level (the
** number of '='), or -1 when p does not open one. */
static int xs_long_open(const XsScan* sc, int p) {
    if (B(p) != '[') return -1;
    int q = p + 1, level = 0;
    while (B(q) == '=') { q++; level++; }
    return B(q) == '[' ? level : -1;
}

/* Last byte of the long bracket opened at p: the first ']' '='*level ']'
** after it, or the end of the source when it is never closed. */
static int xs_long_close(const XsScan* sc, int p, int level) {
    for (int q = p + level + 2; q <= sc->len; q++) {
        if (B(q) != ']') continue;
        int k = 0;
        while (k < level && B(q + 1 + k) == '=') k++;
        if (k == level && B(q + 1 + level) == ']') return q + level + 1;
    }
    return sc->len;
}

static void xs_push(XsScan* sc, int kind, int a, int b, int l1, int l2) {
    if (sc->skip || sc->oom) return;
    XsRaw* t = sc->t;
    if (t->n == t->cap && !xs_grow(t)) { sc->oom = 1; return; }
    int i = t->n++;
    t->k[i] = (uint8_t)kind;
    t->s[i] = a;
    t->e[i] = b;
    t->l[i] = l1;
    t->el[i] = l2;
}

static int xs_is_space(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

static int xs_is_alpha(int c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/* Preprocessor branch tracking. At file scope (depth 0) every #if arm is
** kept: platform variants of whole functions (#ifdef _WIN32 ... #else ...)
** are separate, balanced definitions worth indexing. Inside brackets only
** the first live arm is kept, because that is where arms split a construct
** (`#ifdef X  if (a) {  #else  if (b) {  #endif`) and would unbalance braces.
** `#if 0` arms are dropped. */
static void xs_directive(XsScan* sc, const char* text, int n) {
    if (!sc->g->pp_first_branch) return;
    int p = 1;                                  /* skip '#' */
    while (p < n && xs_is_space((uint8_t)text[p])) p++;
    int w0 = p;
    while (p < n && xs_is_alpha((uint8_t)text[p])) p++;
    int wl = p - w0;
    const char* w = text + w0;
    if ((wl == 2 && memcmp(w, "if", 2) == 0) || (wl == 5 && memcmp(w, "ifdef", 5) == 0)
        || (wl == 6 && memcmp(w, "ifndef", 6) == 0)) {
        int zero = 0;
        if (wl == 2) {
            /* ^#%s*if%s+0%s*$ */
            int q = p, sp = 0;
            while (q < n && xs_is_space((uint8_t)text[q])) { q++; sp = 1; }
            if (sp && q < n && text[q] == '0') {
                q++;
                while (q < n && xs_is_space((uint8_t)text[q])) q++;
                zero = q == n;
            }
        }
        if (sc->npp == sc->cap_pp) {
            int cap = sc->cap_pp ? sc->cap_pp * 2 : 16;
            XsPP* grown = (XsPP*)realloc(sc->pp, sizeof(XsPP) * (size_t)cap);
            if (!grown) { sc->oom = 1; return; }
            sc->pp = grown;
            sc->cap_pp = cap;
        }
        XsPP* f = &sc->pp[sc->npp++];
        f->parent = sc->skip;
        f->taken = !zero;
        f->keep_all = sc->depth == 0 && !zero;
        if (zero) sc->skip = 1;
    } else if (((wl == 4 && memcmp(w, "elif", 4) == 0) || (wl == 4 && memcmp(w, "else", 4) == 0)) && sc->npp > 0) {
        XsPP* f = &sc->pp[sc->npp - 1];
        if (f->keep_all) sc->skip = f->parent;
        else if (f->taken) sc->skip = 1;
        else { sc->skip = f->parent; f->taken = 1; }
    } else if (wl == 5 && memcmp(w, "endif", 5) == 0 && sc->npp > 0) {
        sc->skip = sc->pp[--sc->npp].parent;
    }
}

static int xs_open_of(int c) { return c == ')' ? '(' : c == ']' ? '[' : c == '}' ? '{' : 0; }
static int xs_is_open(int c) { return c == '(' || c == '[' || c == '{'; }

/* Pair brackets and indent/dedent. An unbalanced closer is left unmatched
** instead of unwinding the stack, so one stray brace (usually from a
** preprocessor branch) doesn't break every later match. */
static int xs_matches(XsRaw* t) {
    t->m = (int32_t*)calloc((size_t)(t->n > 0 ? t->n : 1), sizeof(int32_t));
    int32_t* stack = (int32_t*)malloc(sizeof(int32_t) * (size_t)(t->n > 0 ? t->n : 1));
    if (!t->m || !stack) { free(stack); return 0; }
    int sp = 0;
    for (int i = 0; i < t->n; i++) {
        int kind = t->k[i];
        if (kind == K_OP && t->s[i] == t->e[i]) {
            int c = (uint8_t)t->src[t->s[i] - 1];
            if (xs_is_open(c)) {
                stack[sp++] = i;
            } else if (xs_open_of(c)) {
                if (sp > 0) {
                    int top = stack[sp - 1];
                    if (t->k[top] == K_OP && (uint8_t)t->src[t->s[top] - 1] == xs_open_of(c)) {
                        sp--;
                        t->m[top] = i + 1;
                        t->m[i] = top + 1;
                    }
                }
            }
        } else if (kind == K_INDENT) {
            stack[sp++] = i;
        } else if (kind == K_DEDENT) {
            if (sp > 0 && t->k[stack[sp - 1]] == K_INDENT) {
                int top = stack[--sp];
                t->m[top] = i + 1;
                t->m[i] = top + 1;
            }
        }
    }
    free(stack);
    return 1;
}

static int xs_tokenize(const XsLang* g, const char* src, int len, XsRaw* t) {
    XsScan scan;
    XsScan* sc = &scan;
    memset(sc, 0, sizeof *sc);
    sc->g = g;
    sc->src = src;
    sc->len = len;
    sc->t = t;
    sc->line = 1;
    int pos = 1;
    int bol = 1;
    int nind = 1, cap_ind = 16;
    int* ind = (int*)malloc(sizeof(int) * (size_t)cap_ind);
    if (!ind) return 0;
    ind[0] = 0;

    while (pos <= len && !sc->oom) {
        int c = B(pos);
        if (c == '\n') {
            if (g->indent && sc->depth == 0 && t->n > 0 && t->k[t->n - 1] != K_NL && !sc->skip)
                xs_push(sc, K_NL, pos, pos, sc->line, sc->line);
            sc->line++;
            pos++;
            bol = 1;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
            pos++;
            continue;
        }

        /* Indentation (Python): measured at the first real token of a line. */
        if (g->indent && bol && sc->depth == 0) {
            int col_start = pos;
            while (col_start > 1 && B(col_start - 1) != '\n') col_start--;
            int width = 0;
            for (int x = col_start; x < pos; x++)
                width += (B(x) == '\t') ? (8 - width % 8) : 1;
            int is_comment = 0;
            for (int i = 0; i < g->nlc; i++) if (xs_starts(sc, pos, &g->lc[i])) is_comment = 1;
            if (!is_comment) {
                if (width > ind[nind - 1]) {
                    if (nind == cap_ind) {
                        cap_ind *= 2;
                        int* grown = (int*)realloc(ind, sizeof(int) * (size_t)cap_ind);
                        if (!grown) { sc->oom = 1; break; }
                        ind = grown;
                    }
                    ind[nind++] = width;
                    xs_push(sc, K_INDENT, pos, pos - 1, sc->line, sc->line);
                } else {
                    while (width < ind[nind - 1]) {
                        nind--;
                        xs_push(sc, K_DEDENT, pos, pos - 1, sc->line, sc->line);
                    }
                }
            }
        }

        int handled = 0;
        /* Directive line (C preprocessor), with '\' continuations. */
        if (g->directive >= 0 && c == g->directive && bol) {
            int p = pos;
            int l0 = sc->line;
            for (;;) {
                const char* nlp = (const char*)memchr(src + p - 1, '\n', (size_t)(len - p + 1));
                int nl = nlp ? (int)(nlp - src) + 1 : len + 1;
                int q = nl - 1;
                if (B(q) == '\r') q--;
                if (B(q) == '\\' && nl <= len) {
                    sc->line++;
                    p = nl + 1;
                } else {
                    p = nl;
                    break;
                }
            }
            /* A directive is kept when either side of it is live code, so
            ** #include/#define in taken branches still reach the parser. */
            int was_skip = sc->skip;
            xs_directive(sc, src + pos - 1, p - pos);
            if (!(was_skip && sc->skip)) {
                int now = sc->skip;
                sc->skip = 0;
                xs_push(sc, K_DIR, pos, p - 1, l0, sc->line);
                sc->skip = now;
            }
            pos = p;
            handled = 1;
        }
        bol = 0;

        if (!handled) {
            for (int i = 0; i < g->nlc; i++) {
                if (xs_starts(sc, pos, &g->lc[i])) {
                    int after = pos + (int)g->lc[i].len;
                    int lb = g->long_brackets ? xs_long_open(sc, after) : -1;
                    if (lb >= 0) {
                        /* --[==[ block comment ]==] */
                        int stop = xs_long_close(sc, after, lb);
                        sc->line += xs_count_nl(sc, pos, stop);
                        pos = stop + 1;
                    } else {
                        const char* nlp = (const char*)memchr(src + pos - 1, '\n', (size_t)(len - pos + 1));
                        pos = nlp ? (int)(nlp - src) + 1 : len + 1;
                    }
                    handled = 1;
                    break;
                }
            }
        }
        if (!handled) {
            for (int i = 0; i < g->nbc; i++) {
                const XsDelim* d = &g->bc[i];
                if (xs_starts(sc, pos, &d->open)) {
                    int stop = len;
                    for (int p = pos + (int)d->open.len; p + (int)d->close.len - 1 <= len; p++) {
                        if (xs_starts(sc, p, &d->close)) { stop = p + (int)d->close.len - 1; break; }
                    }
                    sc->line += xs_count_nl(sc, pos, stop);
                    pos = stop + 1;
                    handled = 1;
                    break;
                }
            }
        }
        if (!handled && g->long_brackets) {
            int lb = xs_long_open(sc, pos);
            if (lb >= 0) {
                int stop = xs_long_close(sc, pos, lb);
                int l0 = sc->line;
                sc->line += xs_count_nl(sc, pos, stop);
                xs_push(sc, K_STR, pos, stop, l0, sc->line);
                pos = stop + 1;
                handled = 1;
            }
        }
        if (!handled) {
            /* String, optionally after a prefix (r"", b'', f"""..."""). */
            int q = pos;
            while (g->prefix[B(q)] && q - pos < 2) q++;
            for (int i = 0; i < g->nst; i++) {
                const XsDelim* d = &g->st[i];
                if (xs_starts(sc, q, &d->open) && (q == pos || !g->id_char[B(pos - 1)])) {
                    int p = q + (int)d->open.len;
                    int stop = -1;
                    while (p <= len) {
                        int b = B(p);
                        if (d->esc >= 0 && b == d->esc) {
                            p += 2;
                        } else if (xs_starts(sc, p, &d->close)) {
                            stop = p + (int)d->close.len - 1;
                            break;
                        } else if (b == '\n' && !d->multiline) {
                            stop = p - 1;
                            break;
                        } else {
                            p++;
                        }
                    }
                    if (stop < 0) stop = len;
                    int l0 = sc->line;
                    sc->line += xs_count_nl(sc, pos, stop);
                    xs_push(sc, K_STR, pos, stop, l0, sc->line);
                    pos = stop + 1;
                    handled = 1;
                    break;
                }
            }
        }
        if (!handled) {
            if (g->id_start[c]) {
                int p = pos + 1;
                while (p <= len && g->id_char[B(p)]) p++;
                int kw = xs_is_keyword(g, src + pos - 1, (size_t)(p - pos));
                xs_push(sc, kw ? K_KW : K_ID, pos, p - 1, sc->line, sc->line);
                pos = p;
            } else if ((c >= '0' && c <= '9') || (c == '.' && B(pos + 1) >= '0' && B(pos + 1) <= '9')) {
                int p = pos + 1;
                while (p <= len) {
                    int b = B(p);
                    int prev = B(p - 1);
                    if (g->id_char[b] || b == '.' || b == '\'') {
                        p++;
                    } else if ((b == '+' || b == '-') && (prev == 'e' || prev == 'E' || prev == 'p' || prev == 'P')) {
                        p++;        /* exponent sign: 1e-5, 0x1p+3 */
                    } else {
                        break;
                    }
                }
                xs_push(sc, K_NUM, pos, p - 1, sc->line, sc->line);
                pos = p;
            } else {
                int w = 1;
                for (int i = 0; i < g->nops[c]; i++) {
                    if (xs_starts(sc, pos, &g->ops[c][i])) { w = (int)g->ops[c][i].len; break; }
                }
                if (w == 1 && !sc->skip) {
                    if (xs_is_open(c)) sc->depth++;
                    else if (xs_open_of(c) && sc->depth > 0) sc->depth--;
                }
                xs_push(sc, K_OP, pos, pos + w - 1, sc->line, sc->line);
                pos += w;
            }
        }
    }
    if (g->indent && !sc->oom) {
        if (t->n > 0 && t->k[t->n - 1] != K_NL) xs_push(sc, K_NL, len + 1, len, sc->line, sc->line);
        for (int i = 1; i < nind; i++) xs_push(sc, K_DEDENT, len + 1, len, sc->line, sc->line);
    }
    free(ind);
    free(sc->pp);
    if (sc->oom) return 0;
    return xs_matches(t);
}

#undef B

/* ------------------------------------------------------------------------ */
/* Tokens                                                                   */

static void xs_raw_free(XsRaw* t) {
    free(t->k); free(t->s); free(t->e); free(t->l); free(t->el); free(t->m);
    t->k = NULL; t->s = t->e = t->l = t->el = t->m = NULL;
    t->n = t->cap = 0;
}

static int l_raw_gc(lua_State* L) {
    xs_raw_free((XsRaw*)luaL_checkudata(L, 1, XSCAN_RAW_META));
    return 0;
}

static void xs_push_int_array(lua_State* L, const int32_t* a, int n, const char* field) {
    lua_createtable(L, n, 0);
    for (int i = 0; i < n; i++) {
        lua_pushinteger(L, a[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, field);
}

static int l_tokenize(lua_State* L) {
    const XsLang* g = (const XsLang*)luaL_checkudata(L, 1, XSCAN_LANG_META);
    size_t len = 0;
    const char* src = luaL_checklstring(L, 2, &len);
    if (len > 0x7ffffff0u) return luaL_error(L, "xscan: source too large");

    lua_createtable(L, 0, 10);                           /* T */
    XsRaw* t = (XsRaw*)lua_newuserdatauv(L, sizeof(XsRaw), 1);
    memset(t, 0, sizeof *t);
    luaL_setmetatable(L, XSCAN_RAW_META);
    lua_pushvalue(L, 2);
    lua_setiuservalue(L, -2, 1);                         /* pin src for t->src */
    t->src = src;
    t->len = len;
    if (!xs_tokenize(g, src, (int)len, t)) {
        xs_raw_free(t);
        return luaL_error(L, "xscan: out of memory");
    }
    lua_setfield(L, -2, "_raw");

    lua_pushvalue(L, 2);
    lua_setfield(L, -2, "src");
    lua_pushinteger(L, t->n);
    lua_setfield(L, -2, "n");

    /* kind strings: one pushed copy each, reused per token */
    int base = lua_gettop(L);
    for (int k = 1; k < K_COUNT; k++) lua_pushstring(L, k_kind_names[k]);
    lua_createtable(L, t->n, 0);
    for (int i = 0; i < t->n; i++) {
        lua_pushvalue(L, base + t->k[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, base, "k");
    lua_settop(L, base);

    xs_push_int_array(L, t->s, t->n, "s");
    xs_push_int_array(L, t->e, t->n, "e");
    xs_push_int_array(L, t->l, t->n, "l");
    xs_push_int_array(L, t->el, t->n, "el");

    lua_createtable(L, 0, 0);
    for (int i = 0; i < t->n; i++) {
        if (t->m[i]) {
            lua_pushinteger(L, t->m[i]);
            lua_rawseti(L, -2, i + 1);
        }
    }
    lua_setfield(L, -2, "m");

    luaL_setmetatable(L, XSCAN_TOKENS_META);
    return 1;
}

static XsRaw* xs_self(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "_raw");
    XsRaw* t = (XsRaw*)luaL_checkudata(L, -1, XSCAN_RAW_META);
    lua_pop(L, 1);          /* still referenced by T */
    return t;
}

/* Index argument at `arg` as a 0-based token index, or -1 when outside. */
static int xs_index(lua_State* L, const XsRaw* t, int arg) {
    lua_Integer i = luaL_optinteger(L, arg, 0);
    return (i >= 1 && i <= t->n) ? (int)(i - 1) : -1;
}

static int l_kind(lua_State* L) {
    XsRaw* t = xs_self(L);
    int i = xs_index(L, t, 2);
    if (i < 0) lua_pushnil(L);
    else lua_pushstring(L, k_kind_names[t->k[i]]);
    return 1;
}

static int l_text(lua_State* L) {
    XsRaw* t = xs_self(L);
    int i = xs_index(L, t, 2);
    if (i < 0 || t->e[i] < t->s[i]) lua_pushliteral(L, "");
    else lua_pushlstring(L, t->src + t->s[i] - 1, (size_t)(t->e[i] - t->s[i] + 1));
    return 1;
}

static int l_line(lua_State* L) {
    XsRaw* t = xs_self(L);
    int i = xs_index(L, t, 2);
    if (i < 0) lua_pushnil(L);
    else lua_pushinteger(L, t->l[i]);
    return 1;
}

static int l_eline(lua_State* L) {
    XsRaw* t = xs_self(L);
    int i = xs_index(L, t, 2);
    if (i < 0) lua_pushnil(L);
    else lua_pushinteger(L, t->el[i]);
    return 1;
}

static int l_match(lua_State* L) {
    XsRaw* t = xs_self(L);
    int i = xs_index(L, t, 2);
    if (i < 0 || !t->m[i]) lua_pushnil(L);
    else lua_pushinteger(L, t->m[i]);
    return 1;
}

static int l_is(lua_State* L) {
    XsRaw* t = xs_self(L);
    int i = xs_index(L, t, 2);
    size_t n = 0;
    const char* s = luaL_checklstring(L, 3, &n);
    int ok = 0;
    if (i >= 0 && t->k[i] != K_STR) {
        size_t tn = t->e[i] >= t->s[i] ? (size_t)(t->e[i] - t->s[i] + 1) : 0;
        ok = tn == n && memcmp(t->src + t->s[i] - 1, s, n) == 0;
    }
    lua_pushboolean(L, ok);
    return 1;
}

static int xs_is_call_paren(const XsRaw* t, int x) {
    return x < t->n && t->k[x] == K_OP && t->src[t->s[x] - 1] == '(' && t->e[x] == t->s[x];
}

/* Identifiers in [i, j) directly followed by '(' -- call sites. */
static int l_calls(lua_State* L) {
    XsRaw* t = xs_self(L);
    lua_Integer i = luaL_checkinteger(L, 2), j = luaL_checkinteger(L, 3);
    if (i < 1) i = 1;
    if (j > t->n) j = t->n;
    lua_createtable(L, 0, 0);
    int out = 0;
    for (lua_Integer x = i; x <= j - 1; x++) {
        int k = (int)x - 1;
        if (t->k[k] == K_ID && xs_is_call_paren(t, k + 1)) {
            lua_pushinteger(L, x);
            lua_rawseti(L, -2, ++out);
        }
    }
    return 1;
}

/* Identifiers in [i, j] not followed by '(' -- candidate value references. */
static int l_idents(lua_State* L) {
    XsRaw* t = xs_self(L);
    lua_Integer i = luaL_checkinteger(L, 2), j = luaL_checkinteger(L, 3);
    if (i < 1) i = 1;
    if (j > t->n) j = t->n;
    lua_createtable(L, 0, 0);
    int out = 0;
    for (lua_Integer x = i; x <= j; x++) {
        int k = (int)x - 1;
        int paren = k + 1 < t->n && t->k[k + 1] == K_OP && t->src[t->s[k + 1] - 1] == '(';
        if (t->k[k] == K_ID && !paren) {
            lua_pushinteger(L, x);
            lua_rawseti(L, -2, ++out);
        }
    }
    return 1;
}

static const luaL_Reg lang_methods[] = {
    { "tokenize", l_tokenize },
    { NULL, NULL }
};

static const luaL_Reg token_methods[] = {
    { "kind",   l_kind },
    { "text",   l_text },
    { "line",   l_line },
    { "eline",  l_eline },
    { "match",  l_match },
    { "is",     l_is },
    { "calls",  l_calls },
    { "idents", l_idents },
    { NULL, NULL }
};

static const luaL_Reg xscan_funcs[] = {
    { "lang", l_lang },
    { NULL, NULL }
};

LUALIB_API int luaopen_xscan(lua_State* L) {
    if (luaL_newmetatable(L, XSCAN_LANG_META)) {
        lua_pushcfunction(L, l_lang_gc);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        luaL_setfuncs(L, lang_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, XSCAN_RAW_META)) {
        lua_pushcfunction(L, l_raw_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);

    if (luaL_newmetatable(L, XSCAN_TOKENS_META)) {
        lua_newtable(L);
        luaL_setfuncs(L, token_methods, 0);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);

    luaL_newlib(L, xscan_funcs);
    lua_pushliteral(L, "1");
    lua_setfield(L, -2, "version");
    return 1;
}
