-- See where the other player aims the train gun.
-- Each machine has its own copy of the train, and the gun is turned on the copy of
-- whoever sits at it. While "Using Gun?" is true here, this machine sends the gun's world
-- rotation at 10 Hz; the other machine turns its copy to match, unless someone uses
-- the gun there. (Shots are not mirrored: a guest's hits already go to the host.)
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
pcall(function() require("sched").on_reset(function() M.pending, M.target, M.remote, M.was_using = nil, nil, false, false end) end)

function M.tick(log)
  local t = require("train").find(); if not t then return end
  if M.pending then local b = M.pending; M.pending = nil; M.apply(log, b) end
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
  local shooting = safe(function() return t["Shooting Machine Gun"] end, false) and 1 or 0
  -- at most 2 Hz: with up to 10 ServerExecRPC/s the guest crashed in 5 of 5 gun runs,
  -- with the mirror off in 0 of 2 (runs 182923 .. 191329); the receiver smooths
  if os.clock() - (M.sent_at or -99) < 0.5 then return end
  local key = fmt("%.0f|%.0f|%d", r.Yaw, r.Pitch, shooting)
  if key == M.last then return end
  M.last = key
  M.sent_at = os.clock()
  M.send(fmt("gunaim|%.1f|%.1f|%d", r.Yaw, r.Pitch, shooting))
end

-- The other side's aim. Ignored while this machine's own player uses the gun.
function M.apply(log, body)
  local t = require("train").find(); if not t then return end
  if safe(function() return t["Using Gun?"] end, false) then return end
  if body == "gunaim|off" then M.remote = false; return end
  local yaw, pitch = body:match("^gunaim|([^|]+)|([^|]+)")
  yaw, pitch = tonumber(yaw), tonumber(pitch)
  if not (yaw and pitch) then return end
  M.target = { Yaw = yaw, Pitch = pitch }
  M.n = (M.n or 0) + 1
  if not M.remote then M.remote = true; log(fmt("turret: other player's gun aim yaw=%.0f pitch=%.0f", yaw, pitch)) end
end
return M
