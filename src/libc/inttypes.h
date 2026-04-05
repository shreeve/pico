#ifndef _RIP_INTTYPES_H
#define _RIP_INTTYPES_H

#include <stdint.h>

/* Format macros for printf-family (used in mquickjs.h) */
#ifndef PRId32
#define PRId32  "d"
#endif
#ifndef PRId64
#define PRId64  "lld"
#endif
#ifndef PRIu32
#define PRIu32  "u"
#endif
#ifndef PRIu64
#define PRIu64  "llu"
#endif
#ifndef PRIx32
#define PRIx32  "x"
#endif
#ifndef PRIx64
#define PRIx64  "llx"
#endif
#ifndef PRIX32
#define PRIX32  "X"
#endif
#ifndef PRIo32
#define PRIo32  "o"
#endif
#ifndef PRIo64
#define PRIo64  "llo"
#endif

#endif
