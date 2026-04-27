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

// utils.h
void console_set_consolas_font();

#ifdef __cplusplus
}
#endif
#endif
