/* rv_libc.c -- memcpy / memset for code the compiler generates itself (loader CPU only) */
#include <stddef.h>
#include "util.h"

void *memcpy(void *d, const void *s, size_t n) { u_memcpy(d, s, n); return d; }
void *memset(void *d, int c, size_t n)         { u_memset(d, c, n); return d; }
