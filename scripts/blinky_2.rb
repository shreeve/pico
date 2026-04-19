# blinky_2.rb — graduation sequence script #2.
# Adds literal-string puts to exercise the UART console path.

while true
  led_toggle
  puts "blink"
  sleep_ms(500)
end
