-- Respawn without reloading the level.
-- The game's death screen offers "Retry" and "Respawn at train"; both reload the map
-- (run 20261030-232630: the host dropped from listen to standalone), which ends the co-op
-- session for everyone. Instead the host gives a dead player a new character itself
-- (GameMode:RestartPlayer) on the train's respawn point, and every machine closes its own
-- death screen before anyone can press a button.
--
-- Deaths are noticed by what the player sees, not by the game's "Death call": that event
-- only fires for the first character of a session; a character made by RestartPlayer dies
-- (and is destroyed) without it (run 20261031-024235). Every 100 ms each machine checks its
-- own player: death screen up, or the character it had is gone -> dead.
local M = { pending = {}, installed = false }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end

M.DELAY = 5          -- seconds on the death screen before the respawn

local CHAR = "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:"

local function local_pc()
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and safe(function() return pc:IsLocalController() end, false) then return pc end
  end
end

local function own_char()
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then return ch end
  end
end

-- The death screen is found through a hook on its Construct, not by searching: FindAllOf
-- walks every object in the game, and three of those searches every 100 ms starved the
-- host's game thread until guest messages arrived up to 22 s late (run 20261031-030621).
local SCREEN_FN = "/Game/_GAME/Blueprints/DeathScreen.DeathScreen_C:Construct"
local function hook_screen(log)
  if M.screen_hooked then return end
  local ok = pcall(function()
    RegisterHook(SCREEN_FN, function(self) M.screen_widget = self:get() end)
  end)
  if ok then M.screen_hooked = true; log("respawn: hook death screen -> ok") end
end

local function death_screen_up()
  local w = M.screen_widget
  return valid(w) and safe(function() return w:IsInViewport() end, false)
end

-- Close this machine's death screen and give mouse and keys back to the game.
function M.close_death_screen(log)
  local n = 0
  for _, w in ipairs(FindAllOf("DeathScreen_C") or {}) do
    if valid(w) and safe(function() return w:IsInViewport() end, false) then
      pcall(function() w:RemoveFromParent() end); n = n + 1
    end
  end
  local pc = local_pc()
  if pc then
    safe(function() pc.bShowMouseCursor = false end)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if valid(wbl) then pcall(function() wbl:SetInputMode_GameOnly(pc) end) end
    safe(function() pc:SetIgnoreMoveInput(false) end)
    safe(function() pc:SetIgnoreLookInput(false) end)
    safe(function() pc:ResetIgnoreInputFlags() end)
  end
  if n > 0 then log("respawn: closed " .. n .. " death screen(s)") end
  return n
end

-- Damage goes to the right player. Health is not per character: Damage() on ANY character
-- lowers MainUI's single PlayerHealthBar (player 0's) and at zero kills player 0, so a
-- guest's fall on the host's copy killed the host (run 20261030-233125).
-- UE4SS 3.0.1 runs Lua hooks on Blueprint functions after the function (run 233946), so the
-- damage cannot be zeroed beforehand. Instead:
--   * falls: every 100 ms, characters this machine doesn't control get
--     "Cancel Fall Damage on Reset" = true (the game's own one-landing skip, run 234221);
--   * other hits on them: the hook puts the health bar back to its last value, and the
--     host sends the hit to the guest who owns the character;
--   * a lethal one kills player 0 inside the Damage call: that death is "false" and the
--     player gets a new character on the spot at once, with the health bar restored
--     (run 20261031-023829).
local function health_bar()
  if valid(M.pb) then return M.pb end
  local ui = FindFirstOf("MainUI_C")
  local pb = ui and safe(function() return ui.PlayerHealthBar end)
  M.pb = valid(pb) and pb or nil
  return M.pb
end

-- This machine's player died. Host: queue (or do at once) the respawn. Guest: ask the host.
local function on_death(log)
  local h = M.last_remote_hit
  local false_death = h and os.clock() - h.t < 0.6
  local l = M.my_last_loc
  local spot = false_death and l and { X = l.X, Y = l.Y, Z = l.Z + 20 } or nil
  log("respawn: this player died" .. (false_death and " (from a hit on another player's copy: respawn in place)" or ""))
  if M.role == "host" then
    local pc = local_pc(); if not pc then return end
    if false_death then
      M.pending[pc:GetFullName()] = nil
      -- wait until the game's own death sequence has let go of the controller (~1 s),
      -- or it takes the new character away again (run 20261031-031640)
      local old = M.my_char
      M.ignore_screen_until = os.clock() + 6
      ExecuteWithDelay(1500, function() ExecuteInGameThread(function()
        M.respawn(log, { pc = pc, spot = spot, bar = h.bar, old = old })
      end) end)
    else
      M.pending[pc:GetFullName()] = { pc = pc, at = os.time() + M.DELAY, old = M.my_char }
    end
  elseif M.send then
    if spot then M.send(string.format("died|%.1f|%.1f|%.1f", spot.X, spot.Y, spot.Z)) else M.send("died") end
  end
end

function M.guard_tick(log)
  M.ticks = (M.ticks or 0) + 1
  if not M.screen_hooked and M.ticks % 50 == 1 then hook_screen(log) end
  local me
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) then
      if safe(function() return ch:IsLocallyControlled() end, false) then me = ch
      else safe(function() ch["Cancel Fall Damage on Reset"] = true end) end
    end
  end
  local screen = death_screen_up()
  -- right after an in-place respawn the game can still bring up the screen of the false
  -- death (run 20261031-031045): close it, it is not a new death
  if screen and os.clock() < (M.ignore_screen_until or 0) then
    M.close_death_screen(log); screen = false
  end
  -- the death screen shows at once; the dead character itself stays ~15 s before the game
  -- removes it, and "Dead?" is never set (run 20261031-025544)
  if me and not screen then
    local pb = health_bar()
    if pb then M.bar_last = safe(function() return pb.Percent end, M.bar_last) end
    M.my_last_loc = safe(function() return me:K2_GetActorLocation() end, M.my_last_loc)
    M.my_char = me
    M.had_char = true
    M.gone_ticks = 0
    -- after a death, the dying character (screen closed) and the swap to the new one must
    -- not count as another death
    local name = safe(function() return me:GetFName():ToString() end)
    if os.clock() >= (M.dead_hold or 0) or name ~= M.dead_char then M.dead = false end
    M.my_name = name
    return
  end
  if M.dead then return end
  if screen then
    M.dead = true
    M.dead_hold = os.clock() + M.DELAY + 6
    M.dead_char = M.my_name
    M.had_char = false
    on_death(log)
    return
  end
  if not M.had_char then return end
  -- no character but no death screen: the controller lost it (a guest's controller does,
  -- some seconds after a respawn, while the host still has it possessed: run 031045).
  -- Take it back; only if that fails for 10 s is it a death.
  M.gone_ticks = (M.gone_ticks or 0) + 1
  if M.gone_ticks == 10 then
    log("respawn: this player lost its character; taking it back")
    if M.role == "host" then
      local pc = local_pc()
      if pc and valid(M.my_char) then pcall(function() pc:Possess(M.my_char) end) end
    elseif M.send then M.send("ready") end
  elseif M.gone_ticks >= 100 then
    M.dead = true
    M.dead_hold = os.clock() + M.DELAY + 6
    M.dead_char = M.my_name
    M.had_char = false
    on_death(log)
  end
end

-- Both roles. send(msg) goes to the host (guests only).
function M.install(log, role, send)
  if M.installed then return end
  M.installed = true
  M.role, M.send = role, send
  LoopAsync(100, function() ExecuteInGameThread(function() M.guard_tick(log) end); return false end)
  local ok, err = pcall(function()
    RegisterHook(CHAR .. "Damage", function(self, amount)
      if M.applying_hurt then return end
      local ch = self:get()
      local a = safe(function() return amount:get() end, 0)
      local mine = safe(function() return ch:IsLocallyControlled() end, true)
      log(string.format("respawn: Damage %.1f on %s (local=%s)", a, safe(function() return ch:GetFName():ToString() end, "?"), tostring(mine)))
      if mine then
        M.last_local_hit = { t = os.clock(), amount = a }
        return
      end
      -- not ours: undo what it did to our health bar
      M.last_remote_hit = { t = os.clock(), bar = M.bar_last }
      local pb = health_bar()
      if pb and M.bar_last then pcall(function() pb:SetPercent(M.bar_last) end) end
      if role == "host" and a > 0 then
        local pc = safe(function() return ch.Controller end)
        if valid(pc) then
          pcall(function() pc:ClientMessage(string.format("COOP|hurt|%.3f", a), FName("None"), 0.0) end)
        end
      end
    end)
  end)
  log("respawn: hook Damage -> " .. (ok and "ok" or tostring(err)))
end

-- Guest: damage the host routed to us. Skips a hit the guest's own machine already took
-- (a fall is computed on both machines).
function M.hurt(log, amount)
  local lh = M.last_local_hit
  if lh and os.clock() - lh.t < 1.0 and math.abs((lh.amount or 0) - amount) < 0.01 then return end
  local me = own_char()
  if not me then return end
  M.applying_hurt = true
  pcall(function() me:Damage(amount, 1.0, nil) end)
  M.applying_hurt = false
  log(string.format("respawn: took %.1f damage from the host's world", amount))
end

-- Host: a guest reported its death (its character on the host may still be alive).
-- spot: respawn there at once (a false death) instead of on the train after the delay.
function M.queue(log, pc, spot)
  if not valid(pc) then return end
  if spot then M.pending[pc:GetFullName()] = nil; M.respawn(log, { pc = pc, spot = spot })
  else M.pending[pc:GetFullName()] = { pc = pc, at = os.time() + M.DELAY } end
end

-- Host: spot on the train for player i (0 = host), a little apart.
local function train_spot(i)
  return M.train_spot(i)
end
function M.train_spot(i)
  local train = require("train")
  local t = train.find(); if not t then return nil end
  local p = train.comp_loc(t, "Respawn Point") or safe(function() return t:K2_GetActorLocation() end)
  if not p then return nil end
  local f = safe(function() return t:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
  return { X = p.X + f.X * 60 * i, Y = p.Y + f.Y * 60 * i, Z = p.Z + 50 }
end

-- Both roles, every few seconds: close a death screen 2 s after it shows (a button press
-- would reload the map and end the session). A guest's death can also put a screen on the
-- host's display, because the game creates it for player 0.
function M.watch_screens(log)
  if not death_screen_up() then M.seen_at = nil; return end
  M.seen_at = M.seen_at or os.time()
  if os.time() - M.seen_at >= 2 then M.close_death_screen(log); M.seen_at = nil end
end

-- Host: called every few seconds. Respawns queued players whose delay is over, and guests
-- whose character vanished on the host without a report.
function M.tick(log, on_new_guest_pawn)
  M.on_new_guest_pawn = on_new_guest_pawn or M.on_new_guest_pawn
  M.watch_screens(log)
  M.had_pawn = M.had_pawn or {}
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and not safe(function() return pc:IsLocalController() end, true) then
      local key = pc:GetFullName()
      if valid(safe(function() return pc.Pawn end)) then M.had_pawn[key] = true
      elseif M.had_pawn[key] and not M.pending[key] then
        M.had_pawn[key] = nil
        log("respawn: " .. pc:GetFName():ToString() .. " lost its character")
        M.pending[key] = { pc = pc, at = os.time() + M.DELAY }
      end
    end
  end
  local now = os.time()
  for key, job in pairs(M.pending) do
    if now >= job.at then
      M.pending[key] = nil
      M.respawn(log, job)
    end
  end
end

-- Host: 1, 2, ... for guests (0 is the host), to keep their train spots apart.
function M.player_index(pc)
  for i, other in ipairs(FindAllOf("PlayerController") or {}) do
    if other:GetFullName() == pc:GetFullName() then return i end
  end
  return 1
end

-- Host: give job.pc a new character, at job.spot or on the train.
function M.respawn(log, job)
  local pc = job.pc
  if not valid(pc) then return end
  local is_local = safe(function() return pc:IsLocalController() end, false)
  -- the dying character: the game may already have taken it from the controller, and if it
  -- is left alive its death sequence later takes the NEW character away from the player
  -- (run 20261031-030021). A guest can also die on its own machine only (fall, water) while
  -- the host's copy lives: replace that one too.
  local cur = safe(function() return pc.Pawn end)
  if valid(job.old) then safe(function() job.old:K2_DestroyActor() end) end
  if valid(cur) then safe(function() cur:K2_DestroyActor() end) end
  local gm = FindFirstOf("GameModeBase")
  local ok, err = pcall(function() gm:RestartPlayer(pc) end)
  local pawn = safe(function() return pc.Pawn end)
  local spot = job.spot or train_spot(is_local and 0 or M.player_index(pc))
  if valid(pawn) and spot then pcall(function() pawn:K2_SetActorLocation(spot, false, {}, true) end) end
  log(string.format("respawn: %s RestartPlayer -> %s pawn=%s spot=%s", pc:GetFName():ToString(),
    ok and "ok" or tostring(err), valid(pawn) and pawn:GetFName():ToString() or "none",
    spot and string.format("(%.0f %.0f %.0f)", spot.X, spot.Y, spot.Z) or "none"))
  if is_local then
    if valid(pawn) then M.my_char = pawn end
    M.close_death_screen(log)
    if job.bar then
      ExecuteWithDelay(500, function() ExecuteInGameThread(function()
        local pb = health_bar()
        if pb then pcall(function() pb:SetPercent(job.bar) end); M.bar_last = job.bar end
      end) end)
    end
  elseif valid(pawn) then
    pcall(function() pc:ClientRestart(pawn) end)
    if M.on_new_guest_pawn then M.on_new_guest_pawn(pc, pawn) end
  end
end
return M
