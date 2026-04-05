/* pico_bringup.c — C-side wrappers for milestone bring-up.
 *
 * Provides:
 *   pico_test_setjmp()  — verify setjmp/longjmp on this hardware
 *   pico_js_init()      — create MQuickJS context from SRAM arena
 *   pico_js_eval()      — evaluate JS source, returning status code
 *   pico_js_eval_simple() — evaluate without calling any native callbacks
 *
 * These avoid Zig↔C boundary issues for the most fragile APIs.
 * Return conventions: 1 = success, negative = distinct failure codes.
 */

#include "mquickjs.h"
#include <setjmp.h>
#include <stddef.h>

_Static_assert(sizeof(JSValue) == 4, "JSValue must be 4 bytes on ARM");
_Static_assert(sizeof(void *) == 4, "expected 32-bit pointers");

/* ── setjmp/longjmp smoke test ────────────────────────────────────────── */

int pico_test_setjmp(void)
{
    jmp_buf jb;
    volatile int marker = 1234;
    int r = setjmp(jb);

    if (r == 0) {
        marker = 5678;
        longjmp(jb, 42);
        return -1; /* unreachable */
    }

    if (r != 42) return -2;      /* wrong return value */
    if (marker != 5678) return -3; /* state not preserved */
    return 1; /* success */
}

/* ── MQuickJS wrappers ────────────────────────────────────────────────── */

extern const JSSTDLibraryDef js_stdlib;

static JSContext *rip_ctx = NULL;

/* UART write function provided by Zig console layer */
extern void js_console_log(JSContext *ctx, JSValue *this_val,
                           int argc, JSValue *argv);

int pico_js_init(void *heap, size_t size)
{
    if (!heap) return -1;
    if (size < 8192) return -2;

    /* Alignment check (4-byte aligned for ARM Cortex-M) */
    if ((size_t)heap & 3) return -3;

    rip_ctx = JS_NewContext(heap, size, &js_stdlib);
    if (!rip_ctx) return -4;

    return 1;
}

int pico_js_set_log(JSWriteFunc *wf)
{
    if (!rip_ctx) return -1;
    JS_SetLogFunc(rip_ctx, wf);
    return 1;
}

/* Evaluate JS source. Returns:
 *   1  = success
 *  -1  = no context
 *  -2  = exception (eval failed)
 */
int pico_js_eval(const char *source, size_t len)
{
    if (!rip_ctx) return -1;

    JSValue val = JS_Eval(rip_ctx, source, len,
                          "<test>", JS_EVAL_RETVAL);
    if (JS_IsException(val)) {
        /* Try to print exception via log func */
        JSValue exc = JS_GetException(rip_ctx);
        JS_PrintValueF(rip_ctx, exc, 1 /* JS_DUMP_LONG */);
        return -2;
    }
    return 1;
}

size_t pico_js_sizeof_jsvalue(void)
{
    return sizeof(JSValue);
}

size_t pico_js_sizeof_context_ptr(void)
{
    return sizeof(JSContext *);
}
