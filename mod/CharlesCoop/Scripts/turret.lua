-- See where the other player aims the train gun.
-- Each machine has its own copy of the train, and the gun is turned on the copy of
-- whoever sits at it. While "Using Gun?" is true here, this machine sends the gun's world
-- rotation at up to 2 Hz; the other machine turns its copy to match, unless someone uses
-- the gun there. Firing is mirrored as effects only (flash, shells, light): never through
-- the gun's fire event, which would shoot real bullets a second time. A guest's hits already
-- go to the host.
local M = {}
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local fmt = string.format

-- send(msg) delivers to the other side (host: every guest, guest: the host).
function M.install(log, send)
  if M.installed then return end
  M.installed = true
  if os.getenv("COOP_TURRET") == "0" then log("turret: off (COOP_TURRET=0)"); return end
  M.send = send
  local sched = require("sched"); sched.install(log)
  sched.every("turret", 0.1, function() M.tick(log) end)
  log("turret: gun aim mirror on")
end

-- Message handlers only store the newest aim (plain Lua, any thread); the 10 Hz loop on
-- the game thread applies it. One queued game-thread call per aim message preceded a host
-- heap-corruption crash (run 20261031-182024).
function M.receive(body) M.pending = body end
pcall(function() require("sched").on_reset(function() M.pending, M.target, M.remote, M.was_using, M.fire, M.fire_at = nil, nil, false, false, 0, nil end) end)

-- Effect components of each gun, and the flag that says it is firing.
local GUNS = {
  { flag = "Shooting Machine Gun", fx = { "Muzzle Flash", "Sheel Ejection" }, light = "Muzzle Light" },
  { flag = "Shooting Range Gun", fx = { "Muzzle Flare Particle Left", "Muzzle Flare Particle Right", "Sheel Ejection1", "Sheel Ejection2" } },
  { flag = "Shooting Flamethrower", fx = { "P_Flamethrower" } },
}
local function fire_code(t)
  for i, g in ipairs(GUNS) do
    if safe(function() return t[g.flag] end, false) then return i end
  end
  return 0
end

-- Show which gun the other player fires (0 = none). Called on the game thread only.
local function set_fire(log, t, code)
  local old = M.fire or 0
  if code == old then return end
  M.fire = code
  local g = GUNS[old]
  if g then
    for _, n in ipairs(g.fx) do
      local c = safe(function() return t[n] end)
      if valid(c) then pcall(function() c:Deactivate() end) end
    end
    local l = g.light and safe(function() return t[g.light] end)
    if valid(l) then pcall(function() l:SetVisibility(false, false) end) end
  end
  g = GUNS[code]
  if g then
    for _, n in ipairs(g.fx) do
      local c = safe(function() return t[n] end)
      if valid(c) then pcall(function() c:Activate(true) end) end
    end
  end
  log(fmt("turret: other player's fire %d -> %d", old, code))
end

function M.tick(log)
  local t = require("train").find(); if not t then return end
  if M.pending then local b = M.pending; M.pending = nil; M.apply(log, b) end
  -- the sender repeats its state every second while firing: silence means it is gone
  if (M.fire or 0) ~= 0 and os.clock() - (M.fire_at or 0) > 3 then set_fire(log, t, 0) end
  if (M.fire or 0) ~= 0 then
    M.flick = not M.flick
    local g = GUNS[M.fire]
    local l = g and g.light and safe(function() return t[g.light] end)
    if valid(l) then pcall(function() l:SetVisibility(M.flick, false) end) end
  end
  -- ease our copy of the gun toward the other player's aim
  if M.remote and M.target and not safe(function() return t["Using Gun?"] end, false) then
    local rot = safe(function() return t["Gun Rotator"] end)
    local r = valid(rot) and safe(function() return rot:K2_GetComponentRotation() end)
    if r then
      local dy = M.target.Yaw - r.Yaw
      while dy > 180 do dy = dy - 360 end
      while dy < -180 do dy = dy + 360 end
      local k = 0.35
      pcall(function() rot:K2_SetWorldRotation({ Pitch = r.Pitch + (M.target.Pitch - r.Pitch) * k, Yaw = r.Yaw + dy * k, Roll = 0 }, false, {}, true) end)
    end
  end
  local using = safe(function() return t["Using Gun?"] end, false)
  if not using then
    if M.was_using then M.was_using = false; M.send("gunaim|off") end
    return
  end
  M.was_using = true
  local rot = safe(function() return t["Gun Rotator"] end)
  local r = valid(rot) and safe(function() return rot:K2_GetComponentRotation() end)
  if not r then return end
  local shooting = fire_code(t)
  -- at most 2 Hz: with up to 10 ServerExecRPC/s the guest crashed in 5 of 5 gun runs,
  -- with the mirror off in 0 of 2 (runs 182923 .. 191329); the receiver smooths
  if os.clock() - (M.sent_at or -99) < 0.5 then return end
  local key = fmt("%.0f|%.0f|%d", r.Yaw, r.Pitch, shooting)
  if key == M.last and (shooting == 0 or os.clock() - (M.sent_at or -99) < 1) then return end
  M.last = key
  M.sent_at = os.clock()
  M.send(fmt("gunaim|%.1f|%.1f|%d", r.Yaw, r.Pitch, shooting))
end

-- The other side's aim. Ignored while this machine's own player uses the gun.
function M.apply(log, body)
  local t = require("train").find(); if not t then return end
  if safe(function() return t["Using Gun?"] end, false) then set_fire(log, t, 0); return end
  if body == "gunaim|off" then M.remote = false; set_fire(log, t, 0); return end
  local yaw, pitch, code = body:match("^gunaim|([^|]+)|([^|]+)|([^|]+)")
  yaw, pitch, code = tonumber(yaw), tonumber(pitch), tonumber(code)
  if not (yaw and pitch) then return end
  M.fire_at = os.clock()
  set_fire(log, t, GUNS[code] and code or 0)
  M.target = { Yaw = yaw, Pitch = pitch }
  M.n = (M.n or 0) + 1
  if not M.remote then M.remote = true; log(fmt("turret: other player's gun aim yaw=%.0f pitch=%.0f", yaw, pitch)) end
end
return M
