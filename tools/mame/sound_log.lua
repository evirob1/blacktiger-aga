-- MAME autoboot script: play each sound command and log the sound CPU's YM2203
-- register writes, for the design of the A1200 sound (analysis/sound/).
--   mame blktiger -rompath roms -video none -nothrottle \
--        -autoboot_script tools/mame/sound_log.lua [-wavwrite analysis/sound/all.wav]
-- BT_CMDS = "20,21,..." (hex) commands, BT_SECS seconds each (default 20)
-- ym.txt: "C cmd frame" when a command starts, "W frame chip reg value" per
-- write; with time stamps (emulated seconds) at the end of each line, and
-- "L frame value" for every write to the sound latch (the game's own too),
-- "R frame 1/0" when the game puts the sound CPU into / out of reset (port 4
-- bit 5)
local out = "analysis/sound/"
os.execute("mkdir -p " .. out)
local log = io.open(out .. "ym.txt", "w")
local snd = manager.machine.devices[":audiocpu"].spaces["program"]
local function now() return manager.machine.time:as_double() end
local main_io = manager.machine.devices[":maincpu"].spaces["io"]
local frame, sel = 0, {0, 0}
local cmds = {}
for c in string.gmatch(os.getenv("BT_CMDS") or "20", "[^,]+") do cmds[#cmds + 1] = tonumber(c, 16) end
local secs = tonumber(os.getenv("BT_SECS") or "20")
-- (keep the handle: the tap lasts as long as it is referenced)
tap = snd:install_write_tap(0xe000, 0xe003, "ym", function(offset, data, mask)
  local chip = (offset >> 1) & 1
  if offset & 1 == 0 then sel[chip + 1] = data
  else log:write(string.format("W %d %d %02x %02x %.9f\n", frame, chip, sel[chip + 1], data, now())) end
  return data
end)
local held = -1
reset_tap = main_io:install_write_tap(0x04, 0x04, "sndreset", function(offset, data, mask)
  local h = (data >> 5) & 1
  if h ~= held then log:write(string.format("R %d %d %.9f\n", frame, h, now())); held = h end
  return data
end)
latch_tap = main_io:install_write_tap(0x00, 0x00, "latch", function(offset, data, mask)
  log:write(string.format("L %d %02x %.9f\n", frame, data & 0xff, now()))
  return data
end)
local start = 600            -- after the boot and RAM test
local i = 0
emu.register_frame_done(function()
  frame = frame + 1
  if frame >= start and (frame - start) % (secs * 60) == 0 then
    i = i + 1
    if i > #cmds then log:close(); manager.machine:exit(); return end
    log:write(string.format("C %02x %d\n", cmds[i], frame))
    main_io:write_u8(0, cmds[i])
  elseif frame > start then
    main_io:write_u8(0, 0xff)
  end
end)
