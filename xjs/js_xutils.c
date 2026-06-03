#include "xjs.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#endif

#include "../xargs.h"
#include "../xmacro.h"

#ifndef countof
#define countof(x) ((int)(sizeof(x) / sizeof((x)[0])))
#endif

static JSValue js_xutils_json_pack(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xutils.jsonPack: value expected");
    }
    return xjs_call_json_stringify(ctx, argv[0]);
}

static JSValue js_xutils_json_unpack(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xutils.jsonUnpack: text expected");
    }

    size_t len = 0;
    const char *text = JS_ToCStringLen(ctx, &len, argv[0]);
    if (!text) {
        return JS_EXCEPTION;
    }
    JSValue ret = xjs_call_json_parse(ctx, text, len);
    JS_FreeCString(ctx, text);
    return ret;
}

static JSValue js_xutils_load_config(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xutils.loadConfig: path expected");
    }

    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) {
        return JS_EXCEPTION;
    }
    int rc = xargs_load_config(path);
    JS_FreeCString(ctx, path);
    if (rc != 0) {
        return JS_ThrowInternalError(ctx, "xutils.loadConfig: load config failed");
    }
    return JS_TRUE;
}

static JSValue js_xutils_get_config(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xutils.getConfig: key expected");
    }

    const char *key = JS_ToCString(ctx, argv[0]);
    if (!key) {
        return JS_EXCEPTION;
    }
    const char *value = xargs_get(key);
    JS_FreeCString(ctx, key);

    if (value) {
        return JS_NewString(ctx, value);
    }
    if (argc >= 2) {
        return JS_DupValue(ctx, argv[1]);
    }
    return JS_NULL;
}

static char *path_join_dup(const char *a, const char *b) {
    size_t alen = strlen(a);
    size_t blen = strlen(b);
    bool need_sep = alen > 0 && a[alen - 1] != '/' && a[alen - 1] != '\\';
    char *out = (char *)malloc(alen + blen + (need_sep ? 2 : 1));
    if (!out) return NULL;
    memcpy(out, a, alen);
    if (need_sep) out[alen++] = '/';
    memcpy(out + alen, b, blen);
    out[alen + blen] = '\0';
    return out;
}

static char *rel_join_dup(const char *rel, const char *name) {
    char *out;
    if (!rel || rel[0] == '\0') {
        out = (char *)malloc(strlen(name) + 1);
        if (out) strcpy(out, name);
    } else {
        out = path_join_dup(rel, name);
    }
    if (!out) return NULL;
    for (char *p = out; *p; ++p) {
        if (*p == '\\') *p = '/';
    }
    return out;
}

static int scan_dir_push_file(JSContext *ctx, JSValueConst arr, uint32_t *count,
                              const char *path, const char *rel) {
    JSValue item = JS_NewObject(ctx);
    if (JS_IsException(item)) return -1;
    JS_SetPropertyStr(ctx, item, "path", JS_NewString(ctx, path));
    JS_SetPropertyStr(ctx, item, "rel", JS_NewString(ctx, rel));
    if (JS_SetPropertyUint32(ctx, arr, (*count)++, item) < 0) {
        return -1;
    }
    return 0;
}

static int scan_dir_recursive(JSContext *ctx, JSValueConst arr, uint32_t *count,
                              const char *dir, const char *rel,
                              char *errbuf, size_t errcap) {
#ifdef _WIN32
    char *pattern = path_join_dup(dir, "*");
    if (!pattern) {
        snprintf(errbuf, errcap, "out of memory");
        return -1;
    }

    WIN32_FIND_DATAA data;
    HANDLE h = FindFirstFileA(pattern, &data);
    free(pattern);
    if (h == INVALID_HANDLE_VALUE) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    do {
        const char *name = data.cFileName;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        char *full = path_join_dup(dir, name);
        char *child_rel = rel_join_dup(rel, name);
        if (!full || !child_rel) {
            free(full);
            free(child_rel);
            FindClose(h);
            snprintf(errbuf, errcap, "out of memory");
            return -1;
        }

        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (scan_dir_recursive(ctx, arr, count, full, child_rel,
                                   errbuf, errcap) != 0) {
                free(full);
                free(child_rel);
                FindClose(h);
                return -1;
            }
        } else if (scan_dir_push_file(ctx, arr, count, full, child_rel) != 0) {
            free(full);
            free(child_rel);
            FindClose(h);
            snprintf(errbuf, errcap, "out of memory");
            return -1;
        }
        free(full);
        free(child_rel);
    } while (FindNextFileA(h, &data));

    FindClose(h);
    return 0;
#else
    DIR *d = opendir(dir);
    if (!d) {
        snprintf(errbuf, errcap, "cannot open directory: %s", dir);
        return -1;
    }

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *name = ent->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        char *full = path_join_dup(dir, name);
        char *child_rel = rel_join_dup(rel, name);
        if (!full || !child_rel) {
            free(full);
            free(child_rel);
            closedir(d);
            snprintf(errbuf, errcap, "out of memory");
            return -1;
        }

        struct stat st;
        if (stat(full, &st) != 0) {
            free(full);
            free(child_rel);
            continue;
        }

        if (S_ISDIR(st.st_mode)) {
            if (scan_dir_recursive(ctx, arr, count, full, child_rel,
                                   errbuf, errcap) != 0) {
                free(full);
                free(child_rel);
                closedir(d);
                return -1;
            }
        } else if (S_ISREG(st.st_mode)) {
            if (scan_dir_push_file(ctx, arr, count, full, child_rel) != 0) {
                free(full);
                free(child_rel);
                closedir(d);
                snprintf(errbuf, errcap, "out of memory");
                return -1;
            }
        }
        free(full);
        free(child_rel);
    }

    closedir(d);
    return 0;
#endif
}

static JSValue js_xutils_scan_dir(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "xutils.scanDir: path expected");
    }

    const char *root = JS_ToCString(ctx, argv[0]);
    if (!root) {
        return JS_EXCEPTION;
    }

    char errbuf[512] = {0};
    uint32_t count = 0;
    JSValue arr = JS_NewArray(ctx);
    int rc = scan_dir_recursive(ctx, arr, &count, root, "", errbuf, sizeof(errbuf));
    JS_FreeCString(ctx, root);
    if (rc != 0) {
        JS_FreeValue(ctx, arr);
        return JS_ThrowInternalError(ctx, "%s", errbuf[0] ? errbuf : "scan directory failed");
    }
    return arr;
}

static const JSCFunctionListEntry xutils_funcs[] = {
    JS_CFUNC_DEF("jsonPack", 1, js_xutils_json_pack),
    JS_CFUNC_DEF("jsonUnpack", 1, js_xutils_json_unpack),
    JS_CFUNC_DEF("loadConfig", 1, js_xutils_load_config),
    JS_CFUNC_DEF("getConfig", 1, js_xutils_get_config),
    JS_CFUNC_DEF("scanDir", 1, js_xutils_scan_dir),
    JS_CFUNC_DEF("json_pack", 1, js_xutils_json_pack),
    JS_CFUNC_DEF("json_unpack", 1, js_xutils_json_unpack),
    JS_CFUNC_DEF("load_config", 1, js_xutils_load_config),
    JS_CFUNC_DEF("get_config", 1, js_xutils_get_config),
    JS_CFUNC_DEF("scan_dir", 1, js_xutils_scan_dir),
    JS_PROP_STRING_DEF("version", "xjs", JS_PROP_ENUMERABLE),
};

JSValue xjs_new_xutils_object(JSContext *ctx) {
    JSValue obj = JS_NewObject(ctx);
    if (JS_IsException(obj)) return obj;
    JS_SetPropertyFunctionList(ctx, obj, xutils_funcs, countof(xutils_funcs));
    JS_SetPropertyStr(ctx, obj, "jsonNull", JS_NULL);
    JS_SetPropertyStr(ctx, obj, "json_null", JS_NULL);
    return obj;
}

static int js_xutils_module_init(JSContext *ctx, JSModuleDef *m) {
    if (JS_SetModuleExportList(ctx, m, xutils_funcs, countof(xutils_funcs)) < 0) {
        return -1;
    }
    JS_SetModuleExport(ctx, m, "jsonNull", JS_NULL);
    JS_SetModuleExport(ctx, m, "json_null", JS_NULL);
    JS_SetModuleExport(ctx, m, "default", xjs_new_xutils_object(ctx));
    return 0;
}

JSModuleDef *js_init_module_xutils(JSContext *ctx, const char *module_name) {
    JSModuleDef *m = JS_NewCModule(ctx, module_name, js_xutils_module_init);
    if (!m) return NULL;
    JS_AddModuleExportList(ctx, m, xutils_funcs, countof(xutils_funcs));
    JS_AddModuleExport(ctx, m, "jsonNull");
    JS_AddModuleExport(ctx, m, "json_null");
    JS_AddModuleExport(ctx, m, "default");
    return m;
}
