-- MAME autoboot script: measures how busy the main Z80 is.
-- The game's task scheduler spins at $00C3 when no task is ready; counting
-- those spins per second gives the idle time.  Needs -debug -debugger none.
local f = 0
local cpu = manager.machine.devices[":maincpu"]
local d = manager.machine.debugger
local hist = {}
emu.register_frame_done(function()
  f = f + 1
  if f == 1 then cpu.debug:bpset(0x00c3, "1", "temp0=temp0+1;g"); d.execution_state = "run" end
  if f % 60 == 0 then
    d:command("printf \"%d\",temp0"); d:command("temp0=0")
    hist[#hist + 1] = d.consolelog[#d.consolelog]
  end
  if f >= 18000 then
    local fh = io.open("analysis/idle.txt", "w")
    for _, v in ipairs(hist) do fh:write(tostring(v), "\n") end
    fh:close()
    manager.machine:exit()
  end
end)
