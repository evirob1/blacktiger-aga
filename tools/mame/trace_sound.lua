-- MAME autoboot script (needs -debug -debugger none): instruction trace of the
-- sound CPU while every sound command plays (music 12 s, effects 3 s each),
-- written to the FIFO analysis/trace_fifo. tools/mame/trace_sound.sh collects
-- the distinct addresses into data/sound_entries.txt.
local f = 0
local d = manager.machine.debugger
local main_io = manager.machine.devices[":maincpu"].spaces["io"]
local cmds = {}
for c = 0x01, 0x1e do cmds[#cmds + 1] = {c, 180} end
for c = 0x20, 0x37 do cmds[#cmds + 1] = {c, 720} end
for c = 0x39, 0x43 do cmds[#cmds + 1] = {c, 180} end
cmds[#cmds + 1] = {0x00, 120}
local i, next_at = 0, 600
emu.register_frame_done(function()
  f = f + 1
  if f == 1 then
    d:command('trace analysis/trace_fifo,audiocpu,noloop')
    d.execution_state = "run"
  end
  if f == next_at then
    i = i + 1
    if i > #cmds then d:command('trace off,audiocpu'); manager.machine:exit(); return end
    main_io:write_u8(0, cmds[i][1])
    next_at = f + cmds[i][2]
  elseif f > 600 then
    main_io:write_u8(0, 0xff)
  end
end)
