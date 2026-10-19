-- MAME autoboot script (needs -debug -debugger none): instruction trace with the
-- ROM bank on every line, written to the FIFO analysis/trace_fifo. tools/mame/trace_code.sh
-- collects the distinct (bank, address) pairs into data/code_entries.txt.
-- Covers attract mode (two rounds of the demo), then credited games with
-- random inputs (coin + start again every 3000 frames, to continue).
local f = 0
local d = manager.machine.debugger
local ports = manager.machine.ioport.ports
local function field(port, name) return ports[port].fields[name] end
local held = {}
local function set(port, name, v) local fl = field(port, name); if fl then fl:set_value(v) end end
emu.register_frame_done(function()
  f = f + 1
  if f == 1 then
    d:command('trace analysis/trace_fifo,maincpu,noloop,{tracelog "%02X ",b@e0e3}')
    d.execution_state = "run"
  end
  local g = f - 9000
  if g >= 0 and g % 3000 == 0 then set(":IN0", "Coin 1", 1) end
  if g >= 0 and g % 3000 == 10 then set(":IN0", "Coin 1", 0) end
  if g >= 0 and g % 3000 == 100 then set(":IN0", "1 Player Start", 1) end
  if g >= 0 and g % 3000 == 110 then set(":IN0", "1 Player Start", 0) end
  if g > 200 and f % 20 == 0 then
    for _, n in ipairs({"P1 Right", "P1 Left", "P1 Up", "P1 Down", "P1 Button 1", "P1 Button 2"}) do
      set(":IN1", n, (math.random() < 0.3) and 1 or 0)
    end
    set(":IN1", "P1 Right", (math.random() < 0.6) and 1 or 0)
  end
  if f >= 30000 then d:command('trace off,maincpu'); manager.machine:exit() end
end)
