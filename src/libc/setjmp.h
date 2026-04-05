#ifndef _RIP_SETJMP_H
#define _RIP_SETJMP_H

/* ARM Cortex-M jmp_buf: save r4-r11, sp, lr = 10 registers */
typedef unsigned long jmp_buf[10];

int  setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

#endif
