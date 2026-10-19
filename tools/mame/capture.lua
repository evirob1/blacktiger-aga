-- MAME autoboot script: every 30 frames dump sprite/palette/background/text RAM
-- and take a snapshot.  Used for the colour / sprite statistics in docs/PLAN.md.
--   mame blktiger -rompath roms -video none -sound none -nothrottle \
--        -snapshot_directory analysis/snap -autoboot_script tools/mame/capture.lua
local f = 0
local sh = manager.machine.memory.shares
local out = "analysis/frames/"
os.execute("mkdir -p " .. out)
local function dump(name, s)
  local t = {}
  for i = 0, s.size - 1 do t[#t + 1] = string.char(s:read_u8(i)) end
  local fh = io.open(name, "wb"); fh:write(table.concat(t)); fh:close()
end
emu.register_frame_done(function()
  f = f + 1
  if f % 30 == 0 then
    local p = string.format("%s%06d", out, f)
    dump(p .. ".spr", sh[":spriteram"]); dump(p .. ".pal", sh[":palette"]); dump(p .. ".palx", sh[":palette_ext"])
    dump(p .. ".bg", sh[":scrollram"]); dump(p .. ".tx", sh[":txvideoram"])
    manager.machine.video:snapshot()
  end
  if f >= 18000 then manager.machine:exit() end
end)
