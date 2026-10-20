-- MAME autoboot script: record a reference run for the translation test harness.
--
--   mame blktiger -rompath roms -video none -sound none -nothrottle \
--        -autoboot_script tools/mame/record.lua
--
-- Writes into analysis/rec/:
--   io.txt      every main CPU I/O access, in order:  R port value / W port value,
--               and "V n" at the start of vblank interrupt n
--   ram.bin     per vblank interrupt: $E000-$FFFF (8K), background RAM (16K),
--               text RAM (2K), palette RAM (2K)  = 28K per record
--
-- Inputs: attract mode, then a coin and a 1 player game with random joystick
-- movement. The harness replays the recorded reads, so the inputs don't need
-- to be reproducible themselves.

local FRAMES = tonumber(os.getenv("BT_FRAMES") or "3000")
local COIN = tonumber(os.getenv("BT_COIN") or "2400")   -- frame of the first coin
local out = "analysis/rec/"
os.execute("mkdir -p " .. out)
local io_log = io.open(out .. "io.txt", "w")
local ram_log = io.open(out .. "ram.bin", "wb")

local cpu = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]
local iosp = cpu.spaces["io"]
local sh = manager.machine.memory.shares
local vbl = 0

local function dump_share(s)
  local t = {}
  for i = 0, s.size - 1 do t[#t + 1] = string.char(s:read_u8(i)) end
  ram_log:write(table.concat(t))
end

local function snapshot()
  local t = {}
  for a = 0xe000, 0xffff do t[#t + 1] = string.char(prog:read_u8(a)) end
  ram_log:write(table.concat(t))
  dump_share(sh[":scrollram"])
  dump_share(sh[":txvideoram"])
  -- palette RAM: low bytes then high bytes, as at $D800/$DC00
  dump_share(sh[":palette"])
  dump_share(sh[":palette_ext"])
end

-- taps must stay referenced (globals) or they are garbage collected
bt_rtap = iosp:install_read_tap(0x00, 0xff, "rec_r", function(offset, data, mask)
  local port = offset & 0xff
  local v = data & 0xff
  if port == 0 and (v & 8) ~= 0 then
    local pc = cpu.state["PC"].value
    if pc >= 0x0050 and pc <= 0x0054 then
      vbl = vbl + 1
      io_log:write(string.format("V %d\n", vbl))
      snapshot()
    end
  end
  io_log:write(string.format("R %02x %02x\n", port, v))
end)
bt_wtap = iosp:install_write_tap(0x00, 0xff, "rec_w", function(offset, data, mask)
  io_log:write(string.format("W %02x %02x\n", offset & 0xff, data & 0xff))
end)

local f = 0
local ports = manager.machine.ioport.ports
local function set(port, name, v)
  local fl = ports[port].fields[name]
  if fl then fl:set_value(v) end
end
math.randomseed(1987)
emu.register_frame_done(function()
  f = f + 1
  local g = f - COIN                  -- coin + start, again every 3000 frames
  if g >= 0 and g % 3000 == 0 then set(":IN0", "Coin 1", 1) end
  if g >= 0 and g % 3000 == 10 then set(":IN0", "Coin 1", 0) end
  if g >= 0 and g % 3000 == 100 then set(":IN0", "1 Player Start", 1) end
  if g >= 0 and g % 3000 == 110 then set(":IN0", "1 Player Start", 0) end
  if g > 200 and f % 20 == 0 then
    for _, n in ipairs({"P1 Left", "P1 Up", "P1 Down", "P1 Button 1", "P1 Button 2"}) do
      set(":IN1", n, (math.random() < 0.3) and 1 or 0)
    end
    set(":IN1", "P1 Right", (math.random() < 0.6) and 1 or 0)
  end
  if f >= FRAMES then
    io_log:close(); ram_log:close()
    manager.machine:exit()
  end
end)
