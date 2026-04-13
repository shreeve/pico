# JavaScript on pico

This document covers the JavaScript runtime in pico — what the engine supports,
what APIs are available to scripts, and how it compares to KalumaJS (the most
similar embedded JS platform for microcontrollers).

## Engine: MicroQuickJS

pico runs **MicroQuickJS** (MQuickJS), a stripped-down variant of Fabrice
Bellard's QuickJS designed for memory-constrained targets. It compiles as ~80 KB
of ARM Thumb code and runs in a 64 KB heap on the RP2040.

Key characteristics:
- **ES2023** — nearly complete modern JavaScript
- Async/await, Promises, generators
- Arrow functions, template literals, destructuring
- Classes, symbols, iterators
- `import`/`export` modules
- Full RegExp, optional BigInt
- ~10 KB minimum RAM (pico uses 64 KB heap)
- MIT license

## Engine Comparison: MQuickJS vs JerryScript

KalumaJS uses Samsung's **JerryScript** engine. Here is a direct comparison:

| Feature                | MQuickJS (pico)         | JerryScript (Kaluma)    |
|------------------------|-------------------------|-------------------------|
| **ECMAScript version** | ES2023                  | ES5.1 + partial ES6     |
| **Minimum RAM**        | ~10 KB                  | ~64 KB                  |
| **Flash footprint**    | ~80–100 KB              | ~160–200 KB             |
| **Promises / async**   | Yes                     | No                      |
| **Arrow functions**    | Yes                     | Partial                 |
| **Template literals**  | Yes                     | No                      |
| **Destructuring**      | Yes                     | No                      |
| **Classes**            | Yes                     | No                      |
| **Modules (import)**   | Yes                     | No                      |
| **RegExp**             | Full                    | Full                    |
| **BigInt**             | Yes (optional)          | No                      |
| **Math object**        | Partial (config)        | Full ES5.1 Math         |
| **Date object**        | `Date.now()` only       | Full with RTC           |
| **License**            | MIT                     | Apache 2.0              |

MQuickJS is the more capable engine by a wide margin. Modern JavaScript —
async/await, arrow functions, classes, template literals, destructuring, and
modules — works out of the box. JerryScript is limited to ES5.1 with only
partial ES6 support.

The trade-off: Kaluma has had years of community work on its hardware binding
layer and peripheral APIs. pico is catching up rapidly — the core platform
bindings (WiFi, MQTT, GPIO, timers, console, storage) are already working.

## JavaScript API Reference

These are the functions available to user scripts running on pico. Scripts can
be evaluated over the telnet shell (`eval <expression>`) or pushed to flash
via TCP port 9001.

### console

Output to the UART serial console.

```javascript
console.log("hello from pico");     // standard output
console.warn("low memory");         // prefixed [WARN]
console.error("fault!");            // prefixed [ERR]
print("shorthand for log");         // global alias
```

Status: **Full implementation.**

### gpio

Digital GPIO on pins 0–29.

```javascript
gpio.mode(25, 1);                   // set pin 25 as output
gpio.write(25, 1);                  // drive high
gpio.write(25, 0);                  // drive low
let val = gpio.read(15);            // read pin 15
gpio.toggle(25);                    // flip output state
```

Status: **Full implementation.** No PWM, pull configuration, or analog
through this API (see Roadmap below).

### Timers

Standard JavaScript timer functions plus a millisecond clock.

```javascript
let id = setTimeout(() => {
  console.log("fired!");
}, 1000);

clearTimeout(id);

let iv = setInterval(() => {
  console.log("tick");
}, 500);

clearInterval(iv);

let ms = timer.millis();            // milliseconds since boot
let now = Date.now();               // same clock, Date-style
gc();                               // trigger garbage collection
```

Status: **Full implementation.** Maximum 16 concurrent JS timers.

### wifi

Wi-Fi management over the CYW43439.

```javascript
wifi.connect("MyNetwork", "password123");
wifi.disconnect();
let s = wifi.status();              // "connected" | "disconnected" | ...
let ip = wifi.ip();                 // "10.0.0.39"
```

Status: **Full implementation.** WPA2-PSK join with DHCP. AP mode exists
internally but is not yet exposed to JavaScript.

### mqtt

MQTT 3.1.1 client over TCP (plaintext or TLS).

```javascript
mqtt.publish("sensors/temp", "22.5");
mqtt.subscribe("commands/#");
let s = mqtt.status();              // "connected" | "disconnected"
mqtt.disconnect();
```

Status: **Publish, subscribe, status, and disconnect work.** Connection is
currently initiated from native code (`connectBroker` / `connectBrokerTls`),
not from script. QoS 0 only. Single broker. Incoming messages are logged but
do not yet fire a JS callback.

### storage

Key-value storage in flash (append-log format).

```javascript
let val = storage.get("device_id"); // read from flash KV
storage.set("device_id", "pico-1"); // not yet implemented
storage.del("device_id");           // not yet implemented
```

Status: **Read works** via XIP (execute-in-place from flash). Write and
delete require the RAM-resident flash write driver (not yet implemented).

### usb

USB host interface (for the Piccolo Xpress analyzer and future devices).

```javascript
usb.init();
let s = usb.status();               // "ready" | "not_initialized"
```

Status: **Init and status work.** Enumeration and transfer bindings are
stubs. The native USB host + FTDI + ASTM stack is fully operational.

### uart

UART is available through `console.log` / `print` on UART0. The low-level
`uart.zig` module provides Zig-only helpers (`init`, `write`) but is not
directly exposed to JavaScript — UART0 is reserved for the debug console.

### spi / i2c

```javascript
// Not yet available from JavaScript
```

Status: **Stubs.** The Zig binding files exist but contain no implementation.
CYW43 uses SPI internally; user-facing SPI and I2C peripherals need drivers.

## Comparison with Kaluma's JavaScript API

KalumaJS provides a mature set of hardware bindings built on JerryScript. Here
is how pico's JS API compares feature by feature:

| API                      | Kaluma (JerryScript) | pico (MQuickJS)         | Status        |
|--------------------------|----------------------|-------------------------|---------------|
| `console.log()`          | Yes                  | Yes                     | Done          |
| `print()`                | Yes                  | Yes                     | Done          |
| `setTimeout/setInterval` | Yes                  | Yes                     | Done          |
| `gpio.mode/write/read`   | Yes                  | Yes                     | Done          |
| `gpio.toggle`            | —                    | Yes                     | Done (extra)  |
| `wifi.connect/status/ip` | Yes                  | Yes                     | Done          |
| `mqtt.publish/subscribe` | Yes                  | Yes                     | Done          |
| `storage.get`            | Yes                  | Yes (read only)         | Partial       |
| `storage.set/del`        | Yes                  | Stub                    | Needs flash   |
| `usb.init/status`        | —                    | Yes                     | Done (extra)  |
| `Date.now()`             | Full `Date` object   | `Date.now()` only       | Partial       |
| `analogRead/analogWrite` | Yes                  | —                       | Needs ADC/PWM |
| `pwm`                    | Yes                  | —                       | Needs driver  |
| `adc`                    | Yes                  | —                       | Needs driver  |
| `i2c.read/write`         | Yes                  | Stub                    | Needs driver  |
| `spi.transfer`           | Yes                  | Stub                    | Needs driver  |
| `http` server/client     | Yes                  | —                       | TCP is ready  |
| `net.createServer`       | Yes                  | —                       | TCP is ready  |
| `uart.write/read`        | Yes                  | Console only            | Partial       |

### What pico already has that Kaluma does not

- **Modern JavaScript** (ES2023) — async/await, Promises, classes, modules,
  destructuring, template literals, arrow functions, BigInt
- **TLS 1.2** — BearSSL integrated for secure MQTT (Kaluma has no TLS)
- **USB Host** — FTDI driver + ASTM medical protocol parser
- **Telnet shell** — remote JS eval over WiFi on port 23
- **Smaller footprint** — ~80 KB engine vs ~160 KB, half the minimum RAM

### What Kaluma has that pico still needs

- **ADC / PWM / analog** — `analogRead()`, `analogWrite()`, PWM object
- **I2C / SPI peripherals** — full read/write/transfer from JavaScript
- **Full `Date` object** — constructor, formatting, timezone (needs RTC or NTP)
- **HTTP client/server** — pico has TCP, so this is buildable now
- **`net.createServer`** — TCP listener API for JS (the native stack supports
  `tcpListen`, just needs a JS binding)
- **Flash writes** — `storage.set()` / `storage.del()` need the flash driver
- **Events / callbacks** — MQTT incoming message callback to JS, GPIO
  interrupt handlers

## Roadmap: Closing the Gap

The path from current state to Kaluma-equivalent JS platform:

1. **MQTT callbacks** — wire incoming PUBLISH to a JS `mqtt.on("message", fn)`
   handler. The native client already receives and logs messages.

2. **Flash write driver** — RAM-resident flash programming enables
   `storage.set()`, `storage.del()`, and OTA updates.

3. **ADC binding** — RP2040 has a 12-bit ADC on GP26–GP29 + internal temp
   sensor. Wire to `adc.read(channel)`.

4. **PWM binding** — RP2040 has 8 PWM slices (16 channels). Wire to
   `pwm.init(pin, freq, duty)` / `pwm.setDuty(pin, duty)`.

5. **I2C driver + binding** — RP2040 has two I2C peripherals. Wire to
   `i2c.init(bus, sda, scl, freq)` / `i2c.write(bus, addr, data)` /
   `i2c.read(bus, addr, len)`.

6. **SPI driver + binding** — user-facing SPI (separate from CYW43's PIO SPI).
   Wire to `spi.init(bus, sck, mosi, miso, freq)` / `spi.transfer(bus, data)`.

7. **HTTP** — build on the proven TCP stack. A minimal `http.get(url, cb)` and
   `http.createServer(port, handler)` would cover most use cases.

8. **`net` module** — expose `net.createServer(port, handler)` and
   `net.connect(host, port, cb)` for raw TCP from JavaScript.

9. **Full `Date`** — MQuickJS supports the Date constructor; it just needs a
   platform time hook (NTP sync or RTC).

Items 1–2 are immediate priorities. Items 3–6 are peripheral drivers that
follow a pattern (HAL init → Zig wrapper → JS binding). Items 7–9 build on
existing infrastructure.

## Architecture

```
┌──────────────────────────────────────┐
│         User Scripts (JS)            │
│  ES2023 · async/await · modules      │
├──────────────────────────────────────┤
│       MQuickJS Runtime (C)           │
│  18K lines · 64 KB heap · MIT        │
├──────────────────────────────────────┤
│     JS Bindings (Zig → JS)           │
│  console · gpio · timers · wifi      │
│  mqtt · storage · usb · uart         │
├──────────────────────────────────────┤
│     pico Runtime (Zig)               │
│  superloop · timers · scheduler      │
├──────────────────────────────────────┤
│     Net Stack + TLS (Zig)            │
│  TCP/IP · DHCP · ARP · ICMP          │
│  BearSSL TLS 1.2 · MQTT 3.1.1        │
├──────────────────────────────────────┤
│     HAL / Drivers (Zig)              │
│  RP2040 · CYW43 · USB Host · FTDI    │
├──────────────────────────────────────┤
│           Hardware                   │
│  Pico W · 125 MHz · 264 KB SRAM      │
└──────────────────────────────────────┘
```
