-- Test bot: walk this machine's own character forward for a few seconds.
-- Input is pushed from the character's own tick, so it lands in the frame that consumes
-- it (a 16 ms LoopAsync gave ~100 units in 9 s) and needs no window focus (a desktop W
-- key got focus in 2 of 8 runs).
local M = { until_t = 0, hooked = false }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end

function M.walk(log, secs)
  M.until_t = os.time() + secs   -- wall clock; os.clock() is process CPU time
  if M.hooked then log("bot: walking " .. secs .. " s"); return end
  M.hooked = true
  local ok, err = pcall(function()
    RegisterHook("/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:ReceiveTick", function(self)
      if os.time() > M.until_t then return end
      local ch = self:get()
      if not safe(function() return ch:IsLocallyControlled() end, false) then return end
      pcall(function() ch:AddMovementInput(ch:GetActorForwardVector(), 1.0, true) end)
    end)
  end)
  log("bot: tick hook -> " .. (ok and "ok" or tostring(err)) .. ", walking " .. secs .. " s")
end
return M
