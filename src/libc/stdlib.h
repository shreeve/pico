#ifndef _RIP_STDLIB_H
#define _RIP_STDLIB_H

#include <stddef.h>
#include <stdint.h>

#ifndef NULL
#define NULL ((void *)0)
#endif

void abort(void);
int abs(int x);
long labs(long x);

#endif
