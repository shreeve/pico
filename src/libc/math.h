#ifndef _RIP_MATH_H
#define _RIP_MATH_H

#define INFINITY (__builtin_inf())
#define NAN      (__builtin_nan(""))
#define HUGE_VAL (__builtin_huge_val())

#define isnan(x)    __builtin_isnan(x)
#define isinf(x)    __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define signbit(x)  __builtin_signbit(x)
#define copysign(x,y) __builtin_copysign(x,y)
#define copysignf(x,y) __builtin_copysignf(x,y)

double fabs(double x);
double floor(double x);
double ceil(double x);
double sqrt(double x);
double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);
double atan2(double y, double x);
double exp(double x);
double log(double x);
double log2(double x);
double log10(double x);
double pow(double x, double y);
double fmod(double x, double y);
double trunc(double x);
double round(double x);
double frexp(double x, int *exp);
double ldexp(double x, int exp);
double modf(double x, double *iptr);
double scalbn(double x, int n);
float  fabsf(float x);
float  floorf(float x);
float  sqrtf(float x);

#endif
