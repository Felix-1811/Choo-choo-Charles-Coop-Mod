-- Give other players a visible body.
-- BP_NMCharacter_Player_C is first-person only: its inherited ACharacter Mesh has no
-- skeletal mesh, so the other player is an invisible capsule. On every machine, each
-- character this machine does not control gets one of the game's own walking NPC models
-- (the fleeing villagers: NPC_Flee_Skeleton2, walk/run blend space).
local M = { done = {}, anim_vars = nil }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end

local DIR = "/Game/_GAME/Props/Meshes/Characters/NPC_Flee_Assets/"
M.MESHES = { "Man1_Flee", "Man2_Flee", "Woman1_Flee", "Man3_Flee" }   -- one per remote player, in order
local ANIM_BP = "NPC_Flee_AnimBlueprint"

local function load(path)
  local o = StaticFindObject(path)
  if valid(o) then return o end
  safe(function() LoadAsset(path) end)
  o = StaticFindObject(path)
  return valid(o) and o or nil
end

local function oname(o) return valid(o) and safe(function() return o:GetFName():ToString() end, "?") or "none" end

-- One line about a character's Mesh component, for the log.
function M.describe(ch)
  local m = safe(function() return ch.Mesh end)
  if not valid(m) then return "no Mesh component" end
  return string.format("mesh=%s anim=%s visible=%s hidden=%s ownernosee=%s",
    oname(safe(function() return m.SkeletalMesh end)), oname(safe(function() return m.AnimClass end)),
    tostring(safe(function() return m:IsVisible() end, "?")), tostring(safe(function() return m.bHiddenInGame end, "?")),
    tostring(safe(function() return m.bOwnerNoSee end, "?")))
end

-- Is this our own character? IsLocallyControlled() alone is not enough: on the guest it
-- is false until the host's ClientRestart lands, and the guest then wore its own body
-- around its camera (run 20261030-192457). The local controller's view target counts too.
local function mine(ch)
  if safe(function() return ch:IsLocallyControlled() end, false) then return true end
  local full = ch:GetFullName()
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and safe(function() return pc:IsLocalController() end, false) then
      for _, o in ipairs({ safe(function() return pc.Pawn end), safe(function() return pc:GetViewTarget() end) }) do
        if valid(o) and o:GetFullName() == full then return true end
      end
    end
  end
  return false
end

-- Call on the game thread, every few seconds; works once per character.
function M.apply(log)
  local n = 0
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    local name = valid(ch) and ch:GetFName():ToString() or ""
    if M.done[name] and mine(ch) then
      -- given a body before it turned out to be ours: hide it again
      local m = safe(function() return ch.Mesh end)
      if valid(m) and safe(function() return m:IsVisible() end, false) then
        safe(function() m:SetVisibility(false, true) end)
        log("avatar: " .. name .. " is our own character, body hidden")
      end
    end
    if valid(ch) and not ch:GetFullName():find("Default__") and not mine(ch) then
      n = n + 1
      if not M.done[name] then
        M.done[name] = true
        local mname = M.MESHES[((n - 1) % #M.MESHES) + 1]
        local skm = load(DIR .. mname .. "." .. mname)
        load(DIR .. ANIM_BP .. "." .. ANIM_BP)
        local cls = StaticFindObject(DIR .. ANIM_BP .. "." .. ANIM_BP .. "_C")
        local m = safe(function() return ch.Mesh end)
        log("avatar: " .. name .. " before: " .. M.describe(ch))
        if valid(m) and skm then
          local steps = {}
          local function step(label, f) local ok, err = pcall(f); table.insert(steps, label .. (ok and "" or ("!" .. tostring(err)))) end
          step("mesh", function() m:SetSkeletalMesh(skm, true) end)
          if valid(cls) then step("anim", function() m:SetAnimClass(cls) end) end
          -- capsule centre is ~90 above the feet; these meshes face -Y: yaw -90 showed the
          -- body walking backwards (run 20261030-192457), so +90
          step("place", function() m:K2_SetRelativeLocationAndRotation({ X = 0, Y = 0, Z = -90 }, { Pitch = 0, Yaw = 90, Roll = 0 }, false, {}, true) end)
          step("show", function() m:SetHiddenInGame(false, true); m:SetVisibility(true, true); m:SetOwnerNoSee(false) end)
          log("avatar: " .. name .. " -> " .. mname .. " [" .. table.concat(steps, " ") .. "] after: " .. M.describe(ch))
        else
          log("avatar: " .. name .. " no mesh component or asset (" .. tostring(skm) .. ")")
        end
      end
    end
  end
end

-- List the anim instance's number/bool variables once (to see what drives walk/run).
function M.dump_anim(log)
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and not safe(function() return ch:IsLocallyControlled() end, true) then
      local m = safe(function() return ch.Mesh end)
      local ai = valid(m) and safe(function() return m:GetAnimInstance() end) or nil
      if not valid(ai) then log("avatar anim: no anim instance"); return end
      local out = {}
      safe(function()
        ai:GetClass():ForEachProperty(function(p)
          local pn = p:GetFName():ToString()
          local v = safe(function() return ai[pn] end)
          if type(v) == "number" or type(v) == "boolean" then table.insert(out, pn .. "=" .. tostring(v)) end
        end)
      end)
      log("avatar anim " .. oname(ai) .. ": " .. table.concat(out, " "))
      return
    end
  end
end
return M
