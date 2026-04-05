// hello.js — basic pico test script

console.log("Hello from pico!");
console.log("Uptime: " + timer.millis() + " ms");

// Test basic JS
var nums = [1, 2, 3, 4, 5];
var sum = nums.reduce(function(a, b) { return a + b; }, 0);
console.log("Sum of [1..5] = " + sum);

// Test JSON
var config = JSON.parse('{"name":"pico","version":1}');
console.log("Device: " + config.name + " v" + config.version);
