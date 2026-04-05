// wifi_blink.js — connect to WiFi, then blink LED and report status

var LED = 25;
gpio.mode(LED, 1);

// Connect to WiFi (credentials from config, or specify here)
// wifi.connect("MyNetwork", "MyPassword");

console.log("WiFi status: " + wifi.status());

// Blink pattern: fast while connecting, slow when connected
var blink_interval = 100; // fast = connecting

var handle = setInterval(function() {
    gpio.toggle(LED);

    var status = wifi.status();
    if (status === "connected" && blink_interval !== 1000) {
        blink_interval = 1000;
        clearInterval(handle);
        handle = setInterval(function() {
            gpio.toggle(LED);
            console.log("connected - IP: " + wifi.ip());
        }, 1000);
    }
}, blink_interval);
