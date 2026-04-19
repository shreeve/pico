# blinky_3.rb — graduation sequence script #3.
# Prints an incrementing counter each toggle. Exercises:
#   - fixnum ADD opcode (`count = count + 1`)
#   - Integer#to_s (core native, allocates a heap String)
#   - String#+ (core native, allocates a new heap String)
#   - puts on the concatenated result
#   - GC under sustained loop pressure (new strings every tick)

count = 0
while true
  led_toggle
  puts "blink " + count.to_s
  count = count + 1
  sleep_ms(500)
end
