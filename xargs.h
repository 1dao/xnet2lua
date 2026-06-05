#ifndef XARGS_H
#define XARGS_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char short_opt;
    char* long_opt;
    char* default_value;
    int is_flag;  // 1 = flag option (no value), 0 = option with value
} xArgsCFG;

void xargs_init(xArgsCFG* configs, int count, int argc, char* argv[]);
int  xargs_load_config(const char* filepath);
void xargs_cleanup();

const char* xargs_get(const char* key);
const char* xargs_get_other();

/* Typed accessors: look the key up via xargs_get() and convert the raw string
** on read, so new `key=value` parameters never need to be registered in the
** xArgsCFG table. Missing/empty/invalid values fall back to the defaults below:
**   xargs_get_str    -> NULL  if the key is absent
**   xargs_get_int    -> 0     (accepts 0x.. / 0.. bases via strtol base 0)
**   xargs_get_double -> 0.0
**   xargs_get_bool   -> 0; a bare flag (key present, empty value) counts as 1,
**                       as do 1/true/yes/on/daemon (case-insensitive)
*/
const char* xargs_get_str(const char* key);
int         xargs_get_int(const char* key);
double      xargs_get_double(const char* key);
int         xargs_get_bool(const char* key);

// utils.h
void console_set_consolas_font();

#ifdef __cplusplus
}
#endif
#endif
