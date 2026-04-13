/* Minimal libc stubs for MQuickJS on freestanding ARM.
 * Most of these are thin wrappers around compiler builtins.
 * setjmp/longjmp use inline assembly for Cortex-M. */

#include <stddef.h>
#include <stdint.h>

/* ── errno ───────────────────────────────────────────────────────────── */

int errno;

/* ── memory ──────────────────────────────────────────────────────────── */

void *memcpy(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dest;
}

void *memmove(void *dest, const void *src, size_t n)
{
    unsigned char *d = dest;
    const unsigned char *s = src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dest;
}

void *memset(void *s, int c, size_t n)
{
    unsigned char *p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

int memcmp(const void *s1, const void *s2, size_t n)
{
    const unsigned char *a = s1, *b = s2;
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i])
            return a[i] - b[i];
    }
    return 0;
}

/* ── string ──────────────────────────────────────────────────────────── */

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return p - s;
}

int strcmp(const char *s1, const char *s2)
{
    while (*s1 && *s1 == *s2) { s1++; s2++; }
    return *(unsigned char *)s1 - *(unsigned char *)s2;
}

int strncmp(const char *s1, const char *s2, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (s1[i] != s2[i] || !s1[i])
            return (unsigned char)s1[i] - (unsigned char)s2[i];
    }
    return 0;
}

char *strcpy(char *dest, const char *src)
{
    char *d = dest;
    while ((*d++ = *src++));
    return dest;
}

char *strncpy(char *dest, const char *src, size_t n)
{
    size_t i;
    for (i = 0; i < n && src[i]; i++)
        dest[i] = src[i];
    for (; i < n; i++)
        dest[i] = 0;
    return dest;
}

char *strcat(char *dest, const char *src)
{
    char *d = dest + strlen(dest);
    while ((*d++ = *src++));
    return dest;
}

char *strchr(const char *s, int c)
{
    while (*s) {
        if (*s == (char)c) return (char *)s;
        s++;
    }
    return (c == 0) ? (char *)s : NULL;
}

char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    while (*s) {
        if (*s == (char)c) last = s;
        s++;
    }
    if (c == 0) return (char *)s;
    return (char *)last;
}

char *strstr(const char *haystack, const char *needle)
{
    if (!*needle) return (char *)haystack;
    size_t nlen = strlen(needle);
    while (*haystack) {
        if (strncmp(haystack, needle, nlen) == 0)
            return (char *)haystack;
        haystack++;
    }
    return NULL;
}

/* ── stdio stubs ─────────────────────────────────────────────────────── */
/* MQuickJS has its own js_vprintf; these are only needed for debug code
   and assert messages.  We stub them to do nothing or minimal output. */

typedef struct _FILE FILE;

int printf(const char *fmt, ...)
{
    (void)fmt;
    return 0;
}

int fprintf(FILE *f, const char *fmt, ...)
{
    (void)f;
    (void)fmt;
    return 0;
}

int snprintf(char *buf, size_t size, const char *fmt, ...)
{
    (void)fmt;
    if (size > 0) buf[0] = 0;
    return 0;
}

int vsnprintf(char *buf, size_t size, const char *fmt, __builtin_va_list ap)
{
    (void)fmt;
    (void)ap;
    if (size > 0) buf[0] = 0;
    return 0;
}

int putchar(int c)
{
    (void)c;
    return c;
}

int fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream)
{
    (void)ptr;
    (void)stream;
    return size * nmemb;
}

/* ── abort / assert ──────────────────────────────────────────────────── */

__attribute__((noreturn))
void abort(void)
{
    __asm__ volatile("cpsid i");
    while (1) { __asm__ volatile("wfi"); }
}

void __assert_fail(const char *expr, const char *file, int line)
{
    (void)expr;
    (void)file;
    (void)line;
    abort();
}

/* ── misc ────────────────────────────────────────────────────────────── */

int abs(int x)
{
    return x < 0 ? -x : x;
}

long labs(long x)
{
    return x < 0 ? -x : x;
}

struct timeval { long tv_sec; long tv_usec; };

int gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    if (tv) { tv->tv_sec = 0; tv->tv_usec = 0; }
    return 0;
}

/* ── BearSSL system RNG stub ──────────────────────────────────────────
 * BearSSL's engine init references br_prng_seeder_system for auto-seeding.
 * On freestanding ARM we provide entropy manually via ROSC jitter, so
 * this returns NULL (no system seeder available). */

typedef int (*br_prng_seeder)(const void **ctx);

br_prng_seeder br_prng_seeder_system(const char **name)
{
    if (name) *name = 0;
    return 0;
}

/* ── setjmp / longjmp (ARM Cortex-M Thumb) ───────────────────────────
 * Save/restore callee-saved registers: r4-r11, sp (r13), lr (r14).
 * jmp_buf is unsigned long[10]. */

__attribute__((naked))
int setjmp(unsigned long env[10])
{
    __asm__ volatile(
        "stmia r0!, {r4-r7}\n"    /* save r4-r7 */
        "mov   r1, r8\n"
        "mov   r2, r9\n"
        "mov   r3, r10\n"
        "stmia r0!, {r1-r3}\n"    /* save r8-r10 */
        "mov   r1, r11\n"
        "mov   r2, sp\n"
        "mov   r3, lr\n"
        "stmia r0!, {r1-r3}\n"    /* save r11, sp, lr */
        "movs  r0, #0\n"
        "bx    lr\n"
    );
}

__attribute__((naked, noreturn))
void longjmp(unsigned long env[10], int val)
{
    __asm__ volatile(
        "ldmia r0!, {r4-r7}\n"    /* restore r4-r7 */
        "ldmia r0!, {r2-r4}\n"    /* r2=r8, r3=r9, r4=r10 */
        "mov   r8, r2\n"
        "mov   r9, r3\n"
        "mov   r10, r4\n"
        "ldmia r0!, {r2-r4}\n"    /* r2=r11, r3=sp, r4=lr */
        "mov   r11, r2\n"
        "mov   sp, r3\n"
        "mov   lr, r4\n"
        "movs  r0, r1\n"          /* return val */
        "bne   1f\n"
        "movs  r0, #1\n"          /* if val==0, return 1 */
        "1: bx lr\n"
    );
}
