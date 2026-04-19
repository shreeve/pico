# blinky.rb — graduation sequence script #1.
#
# Exercises: engine → binding → hardware (LED toggle).
# No blocks; see docs/NANORUBY.md A5 graduation sequence + ISSUES.md
# entry on Ruby block serialisation (current .nrb format does not
# roundtrip child_funcs, so Phase A scripts use `while true` not
# `loop do … end`).

while true
  led_toggle
  sleep_ms(500)
end
