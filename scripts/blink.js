// blink.js — the "hello world" of pico
// Toggles the on-board LED every 500ms

var LED = 25;

gpio.mode(LED, 1); // output

setInterval(function() {
    gpio.toggle(LED);
    console.log("blink! " + timer.millis() + " ms");
}, 500);
