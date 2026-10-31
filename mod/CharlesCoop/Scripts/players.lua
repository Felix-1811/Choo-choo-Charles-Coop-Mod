-- Host-side fixes for guest characters.
-- The host's copy of a guest's character runs the game's intro setup (it spawns into the
-- boat), which leaves GravityScale = 0 and MaxWalkSpeed = 300. The guest finishes the
-- intro on its own machine, so its own copy is restored, but the host's never is: the
-- host then simulates every guest move with no gravity and half speed, rejects the
-- result, and the guest hangs in the air or crawls (runs 20261030-184714 .. 185931).
local M = {}
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end

local ALWAYS = { "GravityScale" }   -- re-checked every call, in case the intro sets it again
local COPY = { "MaxWalkSpeed", "MaxWalkSpeedCrouched", "JumpZVelocity", "MaxAcceleration",
  "BrakingDecelerationWalking", "GroundFriction", "AirControl" }

local function own_character()
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and not ch:GetFullName():find("Default__") and safe(function() return ch:IsLocallyControlled() end, false) then
      return ch
    end
  end
end

-- Copy the host's own movement settings onto every remote character and let the server
-- accept the guest's own position: this is co-op among friends, and the guest's copy of
-- the game changes speeds locally (sprint, crouch) that the host never hears about.
-- Settings are copied once per character (the host's own values change while it sprints);
-- the two authority flags are re-checked every call. Logs only when something changed.
-- Call from the game thread.
M.done = {}
function M.fix_remote(log)
  local me = own_character(); if not me then return end
  local ref = safe(function() return me.CharacterMovement end)
  if not valid(ref) then return end
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and not ch:GetFullName():find("Default__")
        and not safe(function() return ch:IsLocallyControlled() end, true) then
      local cm = safe(function() return ch.CharacterMovement end)
      if valid(cm) then
        local changed = {}
        local name = ch:GetFName():ToString()
        local keys = {}
        for _, k in ipairs(ALWAYS) do table.insert(keys, k) end
        if not M.done[name] then for _, k in ipairs(COPY) do table.insert(keys, k) end end
        for _, k in ipairs(keys) do
          local want, have = safe(function() return ref[k] end), safe(function() return cm[k] end)
          if type(want) == "number" and type(have) == "number" and math.abs(want - have) > 1e-3 then
            safe(function() cm[k] = want end)
            table.insert(changed, string.format("%s %.4g->%.4g", k, have, want))
          end
        end
        for _, k in ipairs({ "bIgnoreClientMovementErrorChecksAndCorrection", "bServerAcceptClientAuthoritativePosition" }) do
          if safe(function() return cm[k] end) ~= true then
            safe(function() cm[k] = true end); table.insert(changed, k .. "=true")
          end
        end
        M.done[name] = true
        if #changed > 0 then log("players: " .. name .. " " .. table.concat(changed, ", ")) end
      end
    end
  end
end
return M
