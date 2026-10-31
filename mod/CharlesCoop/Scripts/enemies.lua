-- Enemies with more than one player.
-- Charles (CharlesCharacter_C) and the cultists (Cultist_C) each keep ONE target in
-- "Player Ref" (a BP_NMCharacter_C). The host owns the AI (AI controllers only exist with
-- authority); this module looks at what the enemies do and points them at the nearest
-- living player.
local M = { log_n = 0 }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local fmt = string.format

M.CLASSES = { "CharlesCharacter_C", "Cultist_C" }

-- cooldowns follow the player (its controller), not the character: a respawned guest
-- is a new character, and was caught again 17 s after the first catch (run 195524)
local function player_key(ch)
  local c = safe(function() return ch.Controller end)
  return valid(c) and c:GetFullName() or ch:GetFullName()
end


local function name(o) return valid(o) and safe(function() return o:GetFName():ToString() end, "?") or "none" end
local function loc(a) return safe(function() return a:K2_GetActorLocation() end) end
local function v3(v) return v and fmt("(%.0f %.0f %.0f)", v.X, v.Y, v.Z) or "?" end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end

local function reset()
  M.charles, M.cultists, M.gch, M.target, M.puppet_done, M.boxes_off = nil, {}, nil, nil, nil, nil
end
pcall(function() require("sched").on_reset(reset) end)

function M.list()
  local out = {}
  for _, cls in ipairs(M.CLASSES) do
    for _, e in ipairs(FindAllOf(cls) or {}) do
      if valid(e) and not e:GetFullName():find("Default__") then table.insert(out, e) end
    end
  end
  return out
end

-- Living player characters (any machine's).
function M.players()
  local out = {}
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and not ch:GetFullName():find("Default__") then
      local hidden = safe(function() return ch.bHidden end, false)
      if not hidden and valid(safe(function() return ch.Controller end)) then table.insert(out, ch) end
    end
  end
  return out
end

function M.describe(e)
  local cls = safe(function() return e:GetClass():GetFName():ToString() end, "?")
  local pr = safe(function() return e["Player Ref"] end)
  local c = safe(function() return e.Controller end)
  local extra
  if cls == "Cultist_C" then
    extra = fmt("hp=%s dead=%s shooting=%s near=%s", tostring(safe(function() return e.Health end)),
      tostring(safe(function() return e.Dead end)), tostring(safe(function() return e["Is Shooting"] end)),
      tostring(safe(function() return e["Player Near Cultist?"] end)))
  else
    extra = fmt("chasing=%s chasingP=%s patrol=%s boss=%s dead=%s tut=%s nearP=%s", tostring(safe(function() return e.Chasing end)),
      tostring(safe(function() return e["Chasing Player"] end)), tostring(safe(function() return e.Patroling end)),
      tostring(safe(function() return e["Boss Mode?"] end)), tostring(safe(function() return e["Charles Dead"] end)),
      tostring(safe(function() return e["Tutorial Mode"] end)), tostring(safe(function() return e["Player Near Charles?"] end)))
  end
  return fmt("%s %s role=%s/%s ctrl=%s target=%s %s", name(e), v3(loc(e)), tostring(safe(function() return e.Role end, "?")),
    tostring(safe(function() return e.RemoteRole end, "?")), name(c), name(pr), extra)
end

function M.scan(log, tag)
  local es = M.list()
  log(fmt("ENEMY[%s] count=%d", tag, #es))
  for _, e in ipairs(es) do log("ENEMY[" .. tag .. "] " .. M.describe(e)) end
  return es
end

-- Host: each enemy targets the nearest living player. Returns how many changed.
-- Only Player Ref is touched; the AI's own logic decides what to do with it.
function M.retarget(log)
  M.charles = FindFirstOf("CharlesCharacter_C")
  if not valid(M.charles) or M.charles:GetFullName():find("Default__") then M.charles = nil end
  -- the guest's copy of Charles got no movement updates for minutes while he chased
  -- (ReplicatedMovement stayed 0 on the guest, run 20261031-152522), and its own Blueprint
  -- moved it instead. One actor, so keep him relevant to every connection.
  if M.charles and os.getenv("COOP_CHARLES_RELEVANT") ~= "0" and safe(function() return M.charles.bAlwaysRelevant end) == false then
    safe(function() M.charles.bAlwaysRelevant = true end)
    log("enemies: Charles bAlwaysRelevant = true")
  end
  M.cultists = {}
  for _, e in ipairs(FindAllOf("Cultist_C") or {}) do
    if valid(e) and not e:GetFullName():find("Default__") then table.insert(M.cultists, e) end
  end
  pcall(M.host_sync_dead, log)
  local ps = M.players()
  if #ps < 2 then return 0 end
  local changed = 0
  local all = { M.charles }
  for _, e in ipairs(M.cultists) do table.insert(all, e) end
  for _, e in ipairs(all) do
    local el = loc(e)
    if el then
      local best, bd
      for _, p in ipairs(ps) do
        local cool = e == M.charles and M.cooldown and (M.cooldown[player_key(p)] or 0) > os.clock()
        local pl = not cool and loc(p) or nil
        if pl then local d = dist(el, pl); if not bd or d < bd then best, bd = p, d end end
      end
      local cur = safe(function() return e["Player Ref"] end)
      if best and not (valid(cur) and cur:GetFullName() == best:GetFullName()) then
        -- keep the current target unless the other player is clearly nearer (no flapping)
        local cd = valid(cur) and loc(cur) and dist(el, loc(cur)) or math.huge
        -- far away the gap must be large too (20% or the enemy is close), or every enemy on
        -- the island flips whenever two players standing together move a little
        if bd < cd - 250 and (bd < 0.8 * cd or bd < 3000) then
          safe(function() e["Player Ref"] = best end)
          changed = changed + 1
          M.log_n = M.log_n + 1
          if M.log_n <= 40 then log(fmt("enemies: %s -> target %s (%.0f, was %s %.0f)", name(e), name(best), bd, name(cur), cd == math.huge and -1 or cd)) end
        end
      end
    end
  end
  M.focus_cultists(log)
  return changed
end

-- Test helper (host): put an enemy next to a character and make it go for it.
function M.bring(log, e, target, offset, aim)
  local tl = loc(target); if not tl then return false end
  local f = safe(function() return target:GetActorForwardVector() end) or { X = 1, Y = 0, Z = 0 }
  local spot = { X = tl.X + f.X * (offset or 800), Y = tl.Y + f.Y * (offset or 800), Z = tl.Z + 100 }
  local ok, err = pcall(function() e:K2_SetActorLocation(spot, false, {}, true) end)
  safe(function() e["Player Ref"] = aim or target end)
  log(fmt("enemies: bring %s to %s at %s aimed at %s -> %s", name(e), name(target), v3(spot), name(aim or target), ok and "ok" or tostring(err)))
  return ok
end
-- Debug: Charles's movement and AI state, one line.
function M.charles_state(log, tag)
  local e = FindFirstOf("CharlesCharacter_C")
  if not valid(e) then log("CHARLES[" .. tag .. "] none"); return end
  local cm = safe(function() return e.CharacterMovement end)
  local c = safe(function() return e.Controller end)
  local brain = valid(c) and safe(function() return c.BrainComponent end)
  local vel = valid(cm) and safe(function() return cm.Velocity end)
  local parts = { fmt("loc=%s vel=%s mode=%s maxwalk=%s tick=%s dil=%s brain=%s running=%s paused=%s", v3(loc(e)), v3(vel),
    tostring(valid(cm) and safe(function() return cm.MovementMode end)), tostring(valid(cm) and safe(function() return cm.MaxWalkSpeed end)),
    tostring(safe(function() return e:IsActorTickEnabled() end)), tostring(safe(function() return e.CustomTimeDilation end)),
    name(brain), tostring(valid(brain) and safe(function() return brain:IsRunning() end)), tostring(valid(brain) and safe(function() return brain:IsPaused() end))) }
  for _, k in ipairs({ "Chasing", "Chasing Player", "Patroling", "Searching Radius", "Count Patrol Time?", "Patrol Time Elapsed",
      "Stopped for attack", "Pause Stuck Check", "In Volume", "Fight Over", "Boss Mode?", "Tutorial Mode", "Always Move Train",
      "Player Out of Reach", "Using Map", "Can Damage", "Hit Player Recently", "Overlapping Train", "Walk Speed Override", "Current WS", "Chase Speed", "Distance" }) do
    table.insert(parts, k .. "=" .. tostring(safe(function() return e[k] end)))
  end
  log("CHARLES[" .. tag .. "] " .. table.concat(parts, " "))
end
-- Debug: every key of an enemy's blackboard with its value ("name=value ...").
function M.blackboard(e)
  local c = safe(function() return e.Controller end)
  local bbc = valid(c) and safe(function() return c.Blackboard end)
  if not valid(bbc) then return "no blackboard" end
  local asset = safe(function() return bbc.DefaultBlackboardAsset end)
  if not valid(asset) then asset = safe(function() return bbc.BlackboardAsset end) end
  if not valid(asset) then return "no blackboard asset" end
  local out = {}
  pcall(function()
    asset.Keys:ForEach(function(_, entry)
      local en = entry:get()
      local key = safe(function() return en.EntryName:ToString() end, "?")
      local kt = safe(function() return en.KeyType:GetClass():GetFName():ToString() end, "?")
      local fk = FName(key)
      local v
      if kt:find("Object") then v = name(safe(function() return bbc:GetValueAsObject(fk) end))
      elseif kt:find("Vector") then v = v3(safe(function() return bbc:GetValueAsVector(fk) end))
      elseif kt:find("Bool") then v = tostring(safe(function() return bbc:GetValueAsBool(fk) end))
      elseif kt:find("Int") then v = tostring(safe(function() return bbc:GetValueAsInt(fk) end))
      elseif kt:find("Float") then v = tostring(safe(function() return bbc:GetValueAsFloat(fk) end))
      else v = "(" .. kt .. ")" end
      table.insert(out, key .. "=" .. tostring(v))
    end)
  end)
  return table.concat(out, " ")
end
-- The behavior trees don't read "Player Ref": they read blackboard keys (run 20261031-145423).
--   Charles: "Actor Ref" (always player 0), "Is Player In Train?", "Is player visible?",
--            "Sensed Actor Location" (his perception already senses guests: the location
--            sometimes was the guest's exact position, but the chase followed player 0).
--   Cultist: "Actor Ref" (none until it hunts), "Hunting Player", "Is Player In Train?".
local function bb_of(e)
  local c = safe(function() return e.Controller end)
  local bbc = valid(c) and safe(function() return c.Blackboard end)
  return valid(bbc) and bbc or nil
end
M.bb_of = bb_of

local function on_train(ch)
  if safe(function() return ch["In train?"] end, false) then return true end
  local t = require("train").find()
  local tl, cl = t and loc(t), loc(ch)
  return tl and cl and dist(tl, cl) < 900 or false
end
M.on_train = on_train

local K_ACTOR, K_INTRAIN, K_VISIBLE, K_SENSED = FName("Actor Ref"), FName("Is Player In Train?"), FName("Is player visible?"), FName("Sensed Actor Location")
M.focus_n = 0

-- Charles's own catch always takes player 0, and the game then destroys the host's
-- character, which crashed the guest every time (5 of 5: runs 153031 .. 162848). So while
-- he hunts a guest off the train his catch boxes are off and the mod catches instead.
local CATCH_BOXES = { "Damage Box", "Bounce Box", "Box" }   -- not "Distance Box": with it off he stopped approaching (run 163848)
local function set_boxes(ch, on)
  for _, n in ipairs(CATCH_BOXES) do
    local c = safe(function() return ch[n] end)
    if valid(c) then safe(function() c:SetGenerateOverlapEvents(on) end) end
  end
end
M.CATCH_DIST = 1000
M.COOLDOWN = 20

local function host_char()
  for _, p in ipairs(M.players()) do if safe(function() return p:IsLocallyControlled() end, false) then return p end end
end

-- Host, 10 Hz: Charles goes for the player "Player Ref" names (set by retarget).
function M.focus_charles(log)
  local ch = M.charles
  if not valid(ch) then return end
  local tgt = safe(function() return ch["Player Ref"] end)
  if not valid(tgt) then return end
  local remote = not safe(function() return tgt:IsLocallyControlled() end, true)
  local hunting_guest = remote and not on_train(tgt)
  -- turning his boxes off made him stop short of the guest (runs 163848 .. 165249: 0 of 4
  -- approaches); his own catch happens at 120..200 units, so the mod catches at 1000
  if os.getenv("COOP_CHARLES_BOXES") == "off" and hunting_guest ~= M.boxes_off then
    set_boxes(ch, not hunting_guest)
    M.boxes_off = hunting_guest
    log("enemies: Charles catch boxes " .. (hunting_guest and "off (hunting a guest)" or "on"))
  end
  if hunting_guest then
    local cl, tl = loc(ch), loc(tgt)
    if cl and tl and dist(cl, tl) < M.CATCH_DIST then
      local pc = safe(function() return tgt.Controller end)
      log(fmt("enemies: Charles caught %s (%.0f away): guest dies, Charles back to the host", name(tgt), dist(cl, tl)))
      if valid(pc) then pcall(function() pc:ClientMessage("COOP|die", FName("None"), 0.0) end) end
      M.cooldown = M.cooldown or {}
      M.cooldown[player_key(tgt)] = os.clock() + M.COOLDOWN
      local h = host_char()
      if h then safe(function() ch["Player Ref"] = h end); tgt = h; remote = false end
    end
  end
  local bbc = bb_of(ch); if not bbc then return end
  local cur = safe(function() return bbc:GetValueAsObject(K_ACTOR) end)
  if not valid(cur) then return end           -- no player target in this state (cutscene, retreat...)
  local same = cur:GetFullName() == tgt:GetFullName()
  if not same then
    pcall(function() bbc:SetValueAsObject(K_ACTOR, tgt) end)
    M.focus_n = M.focus_n + 1
    if M.focus_n <= 30 then log("enemies: Charles blackboard Actor Ref -> " .. name(tgt)) end
  end
  if remote then
    local intrain = on_train(tgt)
    pcall(function() bbc:SetValueAsBool(K_INTRAIN, intrain) end)
    if safe(function() return bbc:GetValueAsBool(K_VISIBLE) end, false) then
      local tl = loc(tgt)
      if tl then pcall(function() bbc:SetValueAsVector(K_SENSED, tl) end) end
    end
  end
end

-- Host: cultists already hunting someone hunt the player retarget picked.
function M.focus_cultists(log)
  for _, e in ipairs(M.cultists or {}) do
    if valid(e) then
      local tgt = safe(function() return e["Player Ref"] end)
      local bbc = bb_of(e)
      if valid(tgt) and bbc then
        local cur = safe(function() return bbc:GetValueAsObject(K_ACTOR) end)
        if valid(cur) and cur:GetFullName() ~= tgt:GetFullName() and cur:IsA(StaticFindObject("/Script/Engine.Character")) then
          pcall(function() bbc:SetValueAsObject(K_ACTOR, tgt) end)
          pcall(function() bbc:SetValueAsBool(K_INTRAIN, on_train(tgt)) end)
          M.focus_n = M.focus_n + 1
          if M.focus_n <= 30 then log("enemies: " .. name(e) .. " blackboard Actor Ref -> " .. name(tgt)) end
        end
      end
    end
  end
end

-- Host: start the 4 Hz Charles loop once.
function M.install(log)
  if M.installed then return end
  M.installed = true
  local sched = require("sched"); sched.install(log)
  sched.every("charles_focus", 0.1, function() M.focus_charles(log) end)
  log("enemies: Charles focus loop on (10 Hz)")
  -- Charles's grab ("Jumpscare", and "Death call" on a character) always kills player 0,
  -- the host, even when he caught a guest (run 20261031-151438). Hooks run after the
  -- function, but the death screen only shows ~5 s later: mark that death as false (the
  -- host gets back up in place) and kill the guest on its own machine instead.
  local function grabbed(src)
    local ch = M.charles
    if not valid(ch) then return end
    local tgt = safe(function() return ch["Player Ref"] end)
    if not valid(tgt) or safe(function() return tgt:IsLocallyControlled() end, true) then return end
    local cl, tl = loc(ch), loc(tgt)
    if not (cl and tl) or dist(cl, tl) > 2000 then return end
    if os.clock() < (M.grab_until or 0) then return end
    M.grab_until = os.clock() + 10
    require("respawn").mark_false_death(12)
    local pc = safe(function() return tgt.Controller end)
    log(fmt("enemies: Charles caught %s (%s, %.0f away): host death marked false, guest dies", name(tgt), src, dist(cl, tl)))
    if valid(pc) then pcall(function() pc:ClientMessage("COOP|die", FName("None"), 0.0) end) end
  end
  local ok1 = pcall(function()
    RegisterHook("/Game/_GAME/Blueprints/TrainBlueprints/CharlesCharacter.CharlesCharacter_C:Jumpscare", function() grabbed("Jumpscare") end)
  end)
  local ok2 = pcall(function()
    RegisterHook("/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:Death call", function(self)
      local who = safe(function() return self:get() end)
      log("enemies: Death call on " .. name(who) .. " (local=" .. tostring(valid(who) and safe(function() return who:IsLocallyControlled() end)) .. ")")
      grabbed("Death call")
    end)
  end)
  log("enemies: grab hooks -> " .. tostring(ok1) .. ", " .. tostring(ok2))
end
-- Debug: replication state of an actor (both machines).
function M.net_state(e)
  local rm = safe(function() return e.ReplicatedMovement end)
  local cm = safe(function() return e.CharacterMovement end)
  return fmt("repmove=%s replocation=%s repvel=%s mode=%s vel=%s gravity=%s freq=%s cull=%s always=%s dormancy=%s hidden=%s tick=%s cmtick=%s",
    tostring(safe(function() return e.bReplicateMovement end)),
    v3(rm and safe(function() return rm.Location end)), v3(rm and safe(function() return rm.LinearVelocity end)),
    tostring(valid(cm) and safe(function() return cm.MovementMode end)), v3(valid(cm) and safe(function() return cm.Velocity end)),
    tostring(valid(cm) and safe(function() return cm.GravityScale end)),
    tostring(safe(function() return e.NetUpdateFrequency end)), tostring(safe(function() return e.NetCullDistanceSquared end)),
    tostring(safe(function() return e.bAlwaysRelevant end)), tostring(safe(function() return e.NetDormancy end)),
    tostring(safe(function() return e.bHidden end)), tostring(safe(function() return e:IsActorTickEnabled() end)),
    tostring(valid(cm) and safe(function() return cm:IsComponentTickEnabled() end)))
end
-- Charles on guests. The engine sent his movement only while he stood still (the guest's
-- ReplicatedMovement stayed at his old spot during a whole chase, run 20261031-153031) and
-- the guest's copy ran its own Blueprint: it teleported, floated upward, and may have
-- crashed the guest after a respawn. So, like the train: the host streams him, and the
-- guest's copy is a puppet (no tick, no movement, no damage boxes).
function M.host_msg()
  local ch = M.charles
  if not valid(ch) then return nil end
  local l, r = loc(ch), safe(function() return ch:K2_GetActorRotation() end)
  if not (l and r) then return nil end
  local key = fmt("%.0f|%.0f|%.0f|%.0f", l.X, l.Y, l.Z, r.Yaw)
  if key == M.last_key and (M.same_n or 0) < 10 then M.same_n = (M.same_n or 0) + 1; return nil end
  M.last_key, M.same_n = key, 0
  local hidden = safe(function() return ch.bHidden end, false) and 1 or 0
  return fmt("charles|%.1f|%.1f|%.1f|%.1f|%d", l.X, l.Y, l.Z, r.Yaw, hidden)
end

local PUPPET_OFF = { "Damage Box", "Bounce Box", "Distance Box", "Box" }
local function puppet(log, ch)
  if M.puppet_done == ch:GetFullName() then return end
  M.puppet_done = ch:GetFullName()
  safe(function() ch:SetActorTickEnabled(false) end)
  local cm = safe(function() return ch.CharacterMovement end)
  if valid(cm) then
    safe(function() cm:SetComponentTickEnabled(false) end)
    safe(function() cm:SetMovementMode(0, 0) end)
  end
  local off = {}
  for _, n in ipairs(PUPPET_OFF) do
    local c = safe(function() return ch[n] end)
    if valid(c) then safe(function() c:SetGenerateOverlapEvents(false) end); table.insert(off, n) end
  end
  log("enemies: guest Charles is a puppet now (tick, movement, " .. table.concat(off, ", ") .. " off)")
end

-- Guest: a host message "charles|x|y|z|yaw|hidden".
function M.guest_apply(log, body)
  local x, y, z, yaw, hid = body:match("^charles|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?(%d*)")
  x, y, z, yaw = tonumber(x), tonumber(y), tonumber(z), tonumber(yaw)
  if not (x and y and z and yaw) then return end
  M.target = { X = x, Y = y, Z = z, Yaw = yaw, t = os.clock() }
  M.rx = (M.rx or 0) + 1
  if not M.guest_loop then
    M.guest_loop = true
    local sched = require("sched"); sched.install(log)
    sched.every("charles_puppet", 0.033, function() M.guest_step(log) end)
    log("enemies: guest Charles stream on")
  end
end

local function wrap(a) while a > 180 do a = a - 360 end; while a < -180 do a = a + 360 end; return a end

-- Guest, 30 Hz: move the puppet toward the last host position.
function M.guest_step(log)
  local tg = M.target; if not tg then return end
  local ch = M.gch
  if not valid(ch) then
    ch = FindFirstOf("CharlesCharacter_C")
    if not valid(ch) or ch:GetFullName():find("Default__") then return end
    M.gch = ch
  end
  puppet(log, ch)
  local l = loc(ch); if not l then return end
  local r = safe(function() return ch:K2_GetActorRotation() end) or { Pitch = 0, Yaw = tg.Yaw, Roll = 0 }
  local d = dist(l, tg)
  local k = d > 3000 and 1 or 0.3
  local nl = { X = l.X + (tg.X - l.X) * k, Y = l.Y + (tg.Y - l.Y) * k, Z = l.Z + (tg.Z - l.Z) * k }
  local ny = r.Yaw + wrap(tg.Yaw - r.Yaw) * k
  pcall(function() ch:K2_SetActorLocationAndRotation(nl, { Pitch = 0, Yaw = ny, Roll = 0 }, false, {}, true) end)
  -- (no Velocity write for the animation: one struct write per frame for an unchecked
  -- benefit, while guests crashed with signs of memory corruption, run 193048)
end
-- Guns. A guest fires its own copy of the train's guns; the hits land on its copies of
-- Charles and the cultists, which the host's AI never sees. Every Damage on a guest's
-- enemy copy is the guest's own shot (the puppet's damage boxes are off), so it is sent
-- to the host, which applies it to the real enemy.
local CHARLES_FN = "/Game/_GAME/Blueprints/TrainBlueprints/CharlesCharacter.CharlesCharacter_C:Damage"
local CULTIST_FN = "/Game/_GAME/Blueprints/Cultist.Cultist_C:Damage"
function M.guest_install_hits(log, send)
  if M.hits_installed then return end
  M.hits_installed = true
  local function hook(fn)
    local ok, err = pcall(function()
      RegisterHook(fn, function(self, amount, slow, comp)
        if M.applying then return end
        local e = safe(function() return self:get() end)
        local a = safe(function() return amount:get() end, 0)
        local sl = safe(function() return slow:get() end, 1)
        local c = safe(function() return comp:get() end)
        local cn = valid(c) and name(c) or "None"
        M.hits_tx = (M.hits_tx or 0) + 1
        if M.hits_tx <= 30 or M.hits_tx % 50 == 0 then log(fmt("enemies: guest hit %s %.2f (slow %.2f, %s) -> host [%d]", name(e), a, sl, cn, M.hits_tx)) end
        send(fmt("hit|%s|%.3f|%.3f|%s", name(e), a, sl, cn))
      end)
    end)
    log("enemies: guest hit hook " .. fn:match("[^.]+$") .. " -> " .. (ok and "ok" or tostring(err)))
  end
  hook(CHARLES_FN)
  hook(CULTIST_FN)
end

-- Host: a guest's hit. Applied with the hit component of the host's copy (same name),
-- so face/body/leg multipliers work as for the host's own shots.
function M.host_hit(log, who, amount, slow, comp, pc)
  if not (who and amount) then return end
  local e
  if valid(M.charles) and name(M.charles) == who then e = M.charles end
  if not e then
    for _, c in ipairs(M.cultists or {}) do if valid(c) and name(c) == who then e = c; break end end
  end
  if not e then
    for _, c in ipairs(M.list()) do if name(c) == who then e = c; break end end
  end
  if not e then log("enemies: hit on unknown enemy " .. tostring(who)); return end
  local c = (comp and comp ~= "None") and safe(function() return e[comp] end) or nil
  M.applying = true
  local ok, err = pcall(function() e:Damage(amount, slow or 1, valid(c) and c or nil) end)
  M.applying = false
  M.hits_rx = (M.hits_rx or 0) + 1
  if M.hits_rx <= 30 or M.hits_rx % 50 == 0 then
    log(fmt("enemies: host applied guest hit on %s %.2f %s -> %s [%d]", who, amount, tostring(comp), ok and "ok" or tostring(err), M.hits_rx))
  end
end
-- Dead cultists. A cultist the host killed stayed alive on the guest (hp 6, run
-- 20261031-180500; death is not replicated). The guest's own kills already show on both
-- sides through the hit forwarding. Every 3 s the host tells each guest which cultists are
-- dead (once per guest and cultist, so late joiners and save-dead cultists are covered).
M.dead_sent = {}
function M.host_sync_dead(log)
  local dead = {}
  for _, e in ipairs(M.cultists or {}) do
    if valid(e) and (safe(function() return e.Dead end, false) or (safe(function() return e.Health end, 1) or 1) <= 0) then
      table.insert(dead, name(e))
    end
  end
  if #dead == 0 then return end
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and not safe(function() return pc:IsLocalController() end, true) then
      local key = pc:GetFullName()
      M.dead_sent[key] = M.dead_sent[key] or {}
      local new = {}
      for _, n in ipairs(dead) do if not M.dead_sent[key][n] then M.dead_sent[key][n] = true; table.insert(new, n) end end
      -- several names per message keeps it to one RPC
      for i = 1, #new, 8 do
        local chunk = table.concat(new, ",", i, math.min(i + 7, #new))
        pcall(function() pc:ClientMessage("COOP|cultdead|" .. chunk, FName("None"), 0.0) end)
      end
      if #new > 0 then log("enemies: told " .. pc:GetFName():ToString() .. " about " .. #new .. " dead cultist(s)") end
    end
  end
end

-- Guest: kill our copies of the cultists the host says are dead.
function M.guest_dead(log, list)
  local want = {}
  for n in list:gmatch("[^,]+") do want[n] = true end
  local n = 0
  for _, e in ipairs(FindAllOf("Cultist_C") or {}) do
    if valid(e) and want[name(e)] and not safe(function() return e.Dead end, false) then
      M.applying = true
      pcall(function() e:Damage(1000.0, 1.0, nil) end)
      M.applying = false
      n = n + 1
    end
  end
  log("enemies: " .. n .. " cultist(s) killed on the host's word")
end
return M
