# blinky_3.rb — graduation sequence script #3.
# Adds `millis` to exercise fixnum-from-native.

count = 0
while true
  led_toggle
  puts "blink"
  count = count + 1
  sleep_ms(500)
end
