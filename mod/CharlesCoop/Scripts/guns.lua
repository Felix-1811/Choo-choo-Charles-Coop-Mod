-- Test bot (guest): mount the train's gun on this machine's copy of the train, aim at
-- Charles and hold the trigger. Hits go to the host through enemies.guest_install_hits.
local M = {}
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local fmt = string.format

local function state(t)
  return fmt("using=%s equipped=%s shootingMG=%s mgJam=%.2f jammed=%s lock=%s",
    tostring(safe(function() return t["Using Gun?"] end)), tostring(safe(function() return t["Equipped Gun"]:ToString() end)),
    tostring(safe(function() return t["Shooting Machine Gun"] end)), safe(function() return t["Machine Gun Jamming"] end, -1),
    tostring(safe(function() return t["Machine Gun Jammed"] end)), tostring(safe(function() return t["Gun Lock?"] end)))
end
M.state = state

-- What the gun's effect components are doing right now (how the game drives them).
-- Only members the component's class has (SDK dump): reading a wrong member, or going through
-- a null object, can fault inside UE4SS where pcall can't catch it (guest crash, runs 20261101-135836, 140824).
local PARTICLES = { "Muzzle Flash", "Sheel Ejection", "Muzzle Flare Particle Left", "Muzzle Flare Particle Right", "Sheel Ejection1", "Sheel Ejection2", "P_Flamethrower" }
local AUDIO = { "Audio", "OverheatingSound" }
function M.fx_report(t)
  local out = {}
  for _, n in ipairs(PARTICLES) do
    local c = safe(function() return t[n] end)
    if valid(c) then table.insert(out, fmt("%s[a=%s]", n, tostring(safe(function() return c:IsActive() end)))) end
  end
  for _, n in ipairs(AUDIO) do
    local c = safe(function() return t[n] end)
    if valid(c) then table.insert(out, fmt("%s[p=%s]", n, tostring(safe(function() return c:IsPlaying() end)))) end
  end
  local l = safe(function() return t["Muzzle Light"] end)
  if valid(l) then table.insert(out, fmt("Muzzle Light[v=%s]", tostring(safe(function() return l:IsVisible() end)))) end
  return table.concat(out, " ")
end

local function own_pc()
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and safe(function() return pc:IsLocalController() end, false) then return pc end
  end
end

local function aim(pc, from, to)
  local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
  local yaw = math.deg(math.atan(dy, dx))
  local pitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
  safe(function() pc:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }) end)
  return yaw, pitch
end

function M.guest_fire(log, secs)
  local train = require("train")
  local t = train.find(); if not t then log("GUNS no train"); return end
  log("GUNS before " .. state(t))
  for _, part in ipairs({ "Gun Collision", "Machine Gun Collision" }) do
    if safe(function() return t["Using Gun?"] end) then break end
    local c = safe(function() return t[part] end)
    if valid(c) then
      local ok, err = pcall(function() t:Interact(c, false) end)
      log("GUNS interact " .. part .. " -> " .. (ok and "ok" or tostring(err)) .. " | " .. state(t))
      pcall(function() t["Interact Released"](t) end)
    end
  end
  local pc = own_pc()
  local me
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then me = ch end
  end
  local key = { KeyName = FName("LeftMouseButton") }
  -- which input fires the mounted gun is unknown: try each for a few seconds
  local STAGES = {
    { at = 999999, name = "Interaction_12", f = function() me:InpActEvt_Interaction_K2Node_InputActionEvent_12(key) end, rel = function() me:InpActEvt_Interaction_K2Node_InputActionEvent_13(key) end },
    { at = 999998, name = "Interaction_2", f = function() me:InpActEvt_Interaction_K2Node_InputActionEvent_2(key) end, rel = function() me:InpActEvt_Interaction_K2Node_InputActionEvent_1(key) end },
    { at = 25, name = "Fire MAchine Gun Event", every = true, f = function() t["Fire MAchine Gun Event"](t) end },
  }
  local stage
  local ticks = 0
  local sched = require("sched"); sched.install(log)
  sched.every("test_gun", 0.1, function()
    ticks = ticks + 1
    do
      local ch = FindFirstOf("CharlesCharacter_C")
      local gun = safe(function() return t["Machine Gun"] end)
      local from = valid(gun) and safe(function() return gun:K2_GetComponentLocation() end) or safe(function() return t:K2_GetActorLocation() end)
      local to = valid(ch) and safe(function() return ch:K2_GetActorLocation() end)
      -- Charles far away: sweep the gun so the aim mirror has something to show
      if not to or (from and math.abs(to.X - from.X) + math.abs(to.Y - from.Y) > 20000) then
        local a = math.rad(ticks * 3)
        to = from and { X = from.X + math.cos(a) * 3000, Y = from.Y + math.sin(a) * 3000, Z = from.Z } or nil
      end
      if pc and from and to then
        local yaw, pitch = aim(pc, from, to)
        -- the gun follows mouse-look input, not the control rotation: turn it directly
        local rot = safe(function() return t["Gun Rotator"] end)
        local mode = os.getenv("COOP_GUN_AIM") or "rotator"
        if valid(rot) and mode == "rotator" then
          pcall(function() rot:K2_SetWorldRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 }, false, {}, true) end)
        end
        if ticks % 20 == 1 then
          local d = math.sqrt((to.X - from.X) ^ 2 + (to.Y - from.Y) ^ 2 + (to.Z - from.Z) ^ 2)
          local gr = valid(rot) and safe(function() return rot:K2_GetComponentRotation() end)
          local gun_r = valid(gun) and safe(function() return gun:K2_GetComponentRotation() end)
          log(fmt("GUNS t=%.1f aim yaw=%.0f pitch=%.0f dist=%.0f rotator=%s gun=%s | %s", ticks / 10, yaw, pitch, d,
            gr and fmt("(%.0f %.0f)", gr.Yaw, gr.Pitch) or "?", gun_r and fmt("(%.0f %.0f)", gun_r.Yaw, gun_r.Pitch) or "?", state(t)))
        end
      end
      for i, st in ipairs(STAGES) do
        if ticks == st.at then
          if stage and stage.rel then pcall(stage.rel) end
          stage = st
          local ok, err = pcall(st.f)
          log("GUNS stage " .. st.name .. " -> " .. (ok and "ok" or tostring(err)) .. " | " .. state(t) .. " hits_tx=" .. tostring(require("enemies").hits_tx))
        end
      end
      if stage and stage.every and me then pcall(stage.f) end
      if ticks % 10 == 5 and stage then log("GUNS " .. stage.name .. " t=" .. ticks / 10 .. " " .. state(t) .. " hits_tx=" .. tostring(require("enemies").hits_tx)) end
      if ticks % 20 == 3 then log("GUNFX t=" .. ticks / 10 .. " " .. M.fx_report(t)) end
    end
    if ticks >= secs * 10 then
      sched.stop("test_gun")
      log("GUNS released | " .. state(t))
    end
  end)
end
return M
