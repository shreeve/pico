#ifndef _RIP_STDIO_H
#define _RIP_STDIO_H

#include <stddef.h>
#include <stdarg.h>

typedef struct _FILE FILE;

#define EOF (-1)
#define stdout ((FILE *)1)
#define stderr ((FILE *)2)

int snprintf(char *buf, size_t size, const char *fmt, ...);
int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int putchar(int c);
int fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);

#endif
