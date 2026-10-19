-- MAME autoboot script (needs -debug -debugger none): log every Z80 data read
-- from the banked ROM window $8000-$BFFF (not instruction fetches) with the
-- program counter and bank, into analysis/bank_reads_raw.txt. Same inputs as
-- trace_code.lua. tools/mame/bank_reads.sh turns it into data/bank_reads.txt.
local f = 0
local d = manager.machine.debugger
local set = false
local frames = tonumber(os.getenv("BT_FRAMES") or "6000")
math.randomseed(1987)
local ports = manager.machine.ioport.ports
local function press(port, name, v)
  local fl = ports[port].fields[name]
  if fl then fl:set_value(v) end
end
emu.register_periodic(function()
  if not set then
    set = true
    -- MAME's pc here is past the opcode bytes already fetched; the script maps it back
    d:command('wpset 8000,4000,r,(wpaddr<pc)||(wpaddr>pc+3),{printf "R %x %x",pc,b@e0e3; g}')
    d.execution_state = "run"
  end
end)
emu.register_frame_done(function()
  f = f + 1
  if f == 2400 then press(":IN0", "Coin 1", 1) end
  if f == 2410 then press(":IN0", "Coin 1", 0) end
  if f == 2500 then press(":IN0", "1 Player Start", 1) end
  if f == 2510 then press(":IN0", "1 Player Start", 0) end
  if f > 2600 and f % 20 == 0 then
    for _, n in ipairs({"P1 Left", "P1 Up", "P1 Down", "P1 Button 1", "P1 Button 2"}) do
      press(":IN1", n, (math.random() < 0.3) and 1 or 0)
    end
    press(":IN1", "P1 Right", (math.random() < 0.6) and 1 or 0)
  end
  if f >= frames then
    local seen, fh = {}, io.open("analysis/bank_reads_raw.txt", "w")
    for _, l in ipairs(d.consolelog) do
      if l:sub(1, 2) == "R " and not seen[l] then seen[l] = true; fh:write(l, "\n") end
    end
    fh:close()
    manager.machine:exit()
  end
end)
