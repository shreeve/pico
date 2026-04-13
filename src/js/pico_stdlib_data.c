/* This file is compiled for the firmware target. It includes the
   generated pico_stdlib.h which defines the js_stdlib symbol that
   the MQuickJS engine references at runtime.

   Forward-declare the custom C functions implemented in Zig services.
   These are exported as C-ABI symbols by the Zig code. */

#include "mquickjs.h"

/* console */
JSValue js_console_log(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_console_warn(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_console_error(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

/* gpio */
JSValue js_gpio_mode(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gpio_write(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gpio_read(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gpio_toggle(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

/* timer */
JSValue js_timer_millis(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_setTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_clearTimeout(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_setInterval(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_clearInterval(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_gc(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

/* wifi */
JSValue js_wifi_connect(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_wifi_disconnect(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_wifi_status(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_wifi_ip(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

/* mqtt */
JSValue js_mqtt_connect(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_mqtt_publish(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_mqtt_subscribe(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_mqtt_disconnect(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_mqtt_status(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_mqtt_on(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

/* storage */
JSValue js_storage_get(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_storage_set(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_storage_del(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

/* usb host */
JSValue js_usb_init(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_usb_control_in(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_usb_control_out(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_usb_next_address(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_usb_alloc_ep0(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_usb_status(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);
JSValue js_usb_on(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv);

#include "pico_stdlib.h"
