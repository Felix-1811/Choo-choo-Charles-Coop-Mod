-- Train probe: how does the train move, and does it replicate?
local M = {}
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end

function M.find()
  -- the scheduler's hook hands us the ticking train every frame: no FindAllOf (it walks
  -- every object, and find() runs ~30 times a second)
  local sc = package.loaded["sched"]
  if sc and sc.train and sc.from_hook and os.clock() - sc.from_hook < 1 then return sc.train end
  for _, t in ipairs(FindAllOf("PlayerTrain_C") or {}) do
    if valid(t) and not t:GetFullName():find("Default__") then return t end
  end
end

-- The train is spawned at runtime and not replicated, so the engine can't name it on the
-- wire: a guest standing on it sends "base = null" with a train-relative position, the
-- host rejects every move and the guest hangs in the air (run 20261030-183005).
-- bNetStartup makes AActor::IsNameStableForNetworking() true, so the reference goes by
-- path (…PersistentLevel.PlayerTrain_4), which both copies resolve to their own train.
-- Set it on host AND guest.
function M.make_addressable(t, log)
  t = t or M.find(); if not t then return false end
  local before = safe(function() return t.bNetStartup end, "?")
  local ok, err = pcall(function() t.bNetStartup = true end)
  if log then log(string.format("TRAIN bNetStartup %s -> %s (%s) %s", tostring(before),
    tostring(safe(function() return t.bNetStartup end, "?")), ok and "ok" or tostring(err), t:GetFullName())) end
  return ok
end

local function num(v) return type(v) == "number" and string.format("%.1f", v) or tostring(v) end

-- One line of the train state that matters for sync.
function M.state(t)
  t = t or M.find()
  if not t then return "no train" end
  local l = safe(function() return t:K2_GetActorLocation() end)
  local r = safe(function() return t:K2_GetActorRotation() end)
  return string.format("speed=%s railpos=%s lever=%s canmove=%s canmoveall=%s inside=%s tutorial=%s broken=%s stopping=%s loc=(%.0f %.0f %.0f) yaw=%.1f spline=%s",
    num(safe(function() return t["Train Speed"] end)), num(safe(function() return t["Current Position on Rail"] end)),
    tostring(safe(function() return t["Lever Position"] end)), tostring(safe(function() return t["Can Move?"] end)),
    tostring(safe(function() return t["Can move at all?"] end)), tostring(safe(function() return t["inside train?"] end)),
    tostring(safe(function() return t["Tutorial Mode"] end)), tostring(safe(function() return t["Broken Down"] end)),
    tostring(safe(function() return t["Stopping Train"] end)),
    l and l.X or 0, l and l.Y or 0, l and l.Z or 0, r and r.Yaw or 0,
    M.spline_id(t))
end

-- Name of an object property, or "none". Never call a method on an object property without
-- IsValid(): a null one crashes UE4SS 3.0.1 natively (run 20261030-140816), pcall can't catch it.
local function oname(o) return valid(o) and safe(function() return o:GetFName():ToString() end, "?") or "none" end

-- Which rail the train is on: "<Spline Path actor>/<Current Spline actor>/<Active Spline Component>".
-- Actor names come from the level, so host and guest agree on them.
function M.spline_id(t)
  return oname(safe(function() return t["Spline Path"] end)) .. "/" .. oname(safe(function() return t["Current Spline"] end))
    .. "/" .. oname(safe(function() return t["Active Spline Component"] end))
end

local rails = {}
local function rail(name)
  if name == "none" or name == "?" then return nil end
  if valid(rails[name]) then return rails[name] end
  for _, r in ipairs(FindAllOf("RailSpline_C") or {}) do
    if valid(r) and r:GetFName():ToString() == name then rails[name] = r; return r end
  end
end

-- Guest: put the train on the host's rail. Returns true if anything changed.
function M.set_spline(t, id, log)
  if id == M.spline_id(t) or id == M.last_rail_try then return false end
  M.last_rail_try = id   -- one attempt (and one log line) per host rail, not 10 per second
  local path, cur, comp = id:match("^([^/]+)/([^/]+)/([^/]+)$")
  if not path then return false end
  local rp, rc = rail(path), rail(cur)
  if rp then safe(function() t["Spline Path"] = rp end) end
  if rc then safe(function() t["Current Spline"] = rc end) end
  local owner = rc or rp
  if owner and comp ~= "none" then
    for _, field in ipairs({ "Spline Straight", "Spline Left", "Spline Right" }) do
      local c = safe(function() return owner[field] end)
      if valid(c) and c:GetFName():ToString() == comp then safe(function() t["Active Spline Component"] = c end); break end
    end
  end
  if log then log("TRAIN rail " .. id .. " -> now " .. M.spline_id(t) .. (rp and "" or " (path not found)")) end
  return true
end

function M.replication(t)
  t = t or M.find()
  if not t then return "no train" end
  return string.format("replicated=%s role=%s remote=%s name=%s",
    tostring(safe(function() return t:GetIsReplicated() end, "?")), tostring(safe(function() return t.Role end, "?")),
    tostring(safe(function() return t.RemoteRole end, "?")), t:GetFName():ToString())
end

-- Host-side driving experiment: A = game's own Speed Up event, B = force Train Speed,
-- C = push the rail position. 10 s each, state logged every second. Calls done() at the end.
-- Host: hold the train at full speed for `secs` seconds (crosses several rails). Calls done().
function M.drive_long(log, secs, done)
  local ticks = 0
  local sched = require("sched"); sched.install(log)
  sched.every("test_drive", 0.1, function()
    ticks = ticks + 1
    local t = M.find()
    if t then
      if ticks == 1 then safe(function() t["Can move at all?"] = true end); safe(function() t["Can Move?"] = true end) end
      safe(function() t["Train Speed"] = t["Forward Max Speed"] end)
      -- the train sometimes did not move at speed 8 with the brake lever up (runs 195524 ..
      -- 201348): release it for the test drive
      if os.getenv("COOP_DRIVE_RELEASE") ~= "0" then
        safe(function() t["Lever 3 up?"] = false end); safe(function() t["Stopping Train"] = false end)
      end
      if ticks % 50 == 0 then log("TRAIN L " .. M.state(t) .. " " .. M.flags(t)) end
    end
    if ticks >= secs * 10 then sched.stop("test_drive"); done() end
  end)
end

local function comp_loc(t, name)
  local c = safe(function() return t[name] end)
  return valid(c) and safe(function() return c:K2_GetComponentLocation() end) or nil
end
local function v3(v) return v and string.format("(%.0f %.0f %.0f)", v.X, v.Y, v.Z) or "?" end
M.comp_loc = comp_loc

-- Host (server): put every player character on the train, a little apart. The server owns
-- all pawns, so the guest's own client is corrected to this position.
function M.board(log)
  local t = M.find(); if not t then log("TRAIN board: no train"); return end
  M.make_addressable(t, log)
  local spot = comp_loc(t, "Respawn Point") or comp_loc(t, "InsideTrain Overlap") or t:K2_GetActorLocation()
  log("TRAIN board: respawn=" .. v3(comp_loc(t, "Respawn Point")) .. " inside=" .. v3(comp_loc(t, "InsideTrain Overlap"))
    .. " actor=" .. v3(t:K2_GetActorLocation()))
  -- host on the spawn spot (rode fine there, run 182554), guests 60 units forward along
  -- the train. Not a world-X offset: that put the guest in the cab wall (run 182554).
  local f = t:GetActorForwardVector()
  M.board_spots = {}
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and not ch:GetFullName():find("Default__") then
      -- the host stays where it is and each guest gets the spawn spot (one guest tested;
      -- two characters 60 units apart overlap: 2 capsule radii > 60)
      if not safe(function() return ch:IsLocallyControlled() end, false) then
        local dst = { X = spot.X, Y = spot.Y, Z = spot.Z + 50 }
        table.insert(M.board_spots, dst)
        local ok, err = pcall(function() ch:K2_SetActorLocation(dst, false, {}, true) end)
        log("TRAIN board " .. ch:GetFName():ToString() .. " -> " .. v3(dst) .. " " .. (ok and "ok" or tostring(err)))
        M.count_rpcs(log, { "/Script/Engine.Character:ServerMovePacked", "/Script/Engine.Character:ServerMove",
          "/Script/Engine.Character:ServerMoveNoBase" })
        local g = FindFirstOf("GameNetworkManager")
        if valid(g) then
          local parts = {}
          for _, k in ipairs({ "MaxMoveDeltaTime", "MAXCLIENTUPDATEINTERVAL", "MaxClientForcedUpdateDuration",
              "MAXPOSITIONERRORSQUARED", "ClientNetSendMoveDeltaTime", "ClientAuthorativePosition",
              "bMovementTimeDiscrepancyDetection", "bMovementTimeDiscrepancyResolution" }) do
            table.insert(parts, k .. "=" .. tostring(safe(function() return g[k] end, "?")))
          end
          log("GNM " .. g:GetFullName() .. " " .. table.concat(parts, " "))
        else log("GNM none") end
        local cm = safe(function() return ch.CharacterMovement end)
        local parts = {}
        for _, k in ipairs({ "GravityScale", "MaxSimulationTimeStep", "MaxSimulationIterations", "bRunPhysicsWithNoController",
            "bIgnoreClientMovementErrorChecksAndCorrection", "bServerAcceptClientAuthoritativePosition", "MaxWalkSpeed",
            "bCheatFlying", "NetworkSmoothingMode" }) do
          table.insert(parts, k .. "=" .. tostring(safe(function() return cm[k] end, "?")))
        end
        log("GUESTCM " .. table.concat(parts, " "))
        M.pawn_probe(log, ch, "host-view")
      else
        M.pawn_probe(log, ch, "host-own")
      end
    end
  end
end

-- Count movement RPCs (only increments in the hook: keep the hot path cheap).
M.rpc = {}
function M.count_rpcs(log, names)
  for _, fn in ipairs(names) do
    if not M.rpc[fn] then
      M.rpc[fn] = 0
      local ok, err = pcall(function() RegisterHook(fn, function() M.rpc[fn] = M.rpc[fn] + 1 end) end)
      log("hook " .. fn .. " -> " .. (ok and "ok" or tostring(err)))
    end
  end
end
local function rpc_counts()
  local out = {}
  for fn, n in pairs(M.rpc) do table.insert(out, fn:match("[^:]+$") .. "=" .. n) end
  table.sort(out); return table.concat(out, " ")
end

-- Log a character's movement state once a second for 12 s.
function M.pawn_probe(log, ch, tag)
  local n = 0
  LoopAsync(1000, function()
    n = n + 1
    ExecuteInGameThread(function()
      if not valid(ch) then return end
      local cm = safe(function() return ch.CharacterMovement end)
      local l = safe(function() return ch:K2_GetActorLocation() end)
      local v = safe(function() return cm.Velocity end)
      log(string.format("PAWNPROBE %s t=%d dil=%s/%s base=%s rpc[%s] loc=%s vel=%s mode=%s active=%s tick=%s ignoremove=%s",
        tag, n, tostring(safe(function() return ch.CustomTimeDilation end, "?")),
        tostring(safe(function() return ch:GetActorTimeDilation() end, "?")),
        -- BasedMovement is a plain struct property; the component's name only after IsValid
        (function() local b = safe(function() return ch.BasedMovement.MovementBase end)
          return valid(b) and safe(function() return b:GetFullName():match("[^%.]+%.[^%.]+$") end, "?") or "none" end)(),
        rpc_counts(), v3(l), v3(v), tostring(safe(function() return cm.MovementMode end, "?")),
        tostring(safe(function() return cm:IsActive() end, "?")),
        tostring(safe(function() return cm:IsComponentTickEnabled() end, "?")),
        tostring(safe(function() return ch.Controller:IsMoveInputIgnored() end, "?"))))
    end)
    return n >= 12
  end)
end

-- Guest: teleport our own pawn too, so client and server agree (a server-only teleport
-- left the guest frozen mid-air, moves rejected: runs 183005, 183532).
function M.board_self(log, x, y, z, yaw)
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then
      local ok, err = pcall(function() ch:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true) end)
      if yaw then
        -- a first-person character turns with its controller
        safe(function() ch.Controller:SetControlRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }) end)
      end
      log(string.format("TRAIN board_self -> (%.0f %.0f %.0f) yaw=%s %s", x, y, z, tostring(yaw), ok and "ok" or tostring(err)))
      if yaw then return end   -- "play" test: no movement probe
      M.count_rpcs(log, { "/Script/Engine.Character:ClientMoveResponsePacked", "/Script/Engine.Character:ClientAdjustPosition",
        "/Script/Engine.Character:ClientAckGoodMove", "/Script/Engine.Character:ClientVeryShortAdjustPosition" })
      M.pawn_probe(log, ch, "guest-own")
    end
  end
end

-- Host: replay a guest's click on a train part (lever, horn, ...) on the host's train.
function M.remote_interact(log, part, gamepad)
  local t = M.find(); if not t then return end
  local comp = safe(function() return t[part] end)
  if not valid(comp) then log("TRAIN remote interact: no part " .. part); return end
  local before = M.state(t)
  local ok, err = pcall(function() t:Interact(comp, gamepad) end)
  log("TRAIN remote interact " .. part .. " -> " .. (ok and "ok" or tostring(err)) .. " | before " .. before)
end

function M.remote_release(log)
  local t = M.find(); if not t then return end
  local ok, err = pcall(function() t["Interact Released"](t) end)
  if not ok then log("TRAIN remote release failed: " .. tostring(err)) end
end

-- Guest test: click each lever-like part of our own train, as the player's interaction
-- trace would, 6 s apart. The forwarding hook sends each click to the host.
M.LEVER_PARTS = { "Lever1", "Lever2 HOVER", "Lever3", "Lever1 HOVER", "Lever3 HOVER" }
function M.guest_lever_test(log)
  local i = 0
  LoopAsync(6000, function()
    i = i + 1
    local part = M.LEVER_PARTS[i]
    if not part then return true end
    ExecuteInGameThread(function()
      local t = M.find(); if not t then return end
      local comp = safe(function() return t[part] end)
      if not valid(comp) then log("LEVERTEST no part " .. part); return end
      log("LEVERTEST guest clicks " .. part)
      local ok, err = pcall(function() t:Interact(comp, false) end)
      if not ok then log("LEVERTEST Interact failed: " .. tostring(err)) end
    end)
    ExecuteWithDelay(800, function()
      ExecuteInGameThread(function()
        local t = M.find(); if t then pcall(function() t["Interact Released"](t) end) end
      end)
    end)
    return false
  end)
end

-- Host-only probe, through the player's real input path: aim at a lever (angles found by
-- the hover scan in run 20261030-193628), hold Interaction (InputActionEvent_12 = press,
-- _13 = release), feed the mouse LookUp axis from the character's tick, release, and log
-- the train after each drag.
local AIM = { ["Lever1 HOVER"] = { -35, 52 }, ["Lever2 HOVER"] = { -35, 82 }, ["Lever3 HOVER"] = { -35, 112 } }
function M.lever_probe(log, done)
  local t0 = M.find(); if not t0 then log("LEVERPROBE no train"); done(); return end
  local me, pc
  for _, c in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(c) and safe(function() return c:IsLocalController() end, false) then pc = c end
  end
  local p = pc and (safe(function() return pc.Pawn end) or safe(function() return pc:GetViewTarget() end))
  if valid(p) and p:GetClass():GetFName():ToString() == "BP_NMCharacter_Player_C" then me = p end
  if not me then log("LEVERPROBE no character"); done(); return end
  local spot = comp_loc(t0, "Respawn Point")
  me:K2_SetActorLocation({ X = spot.X, Y = spot.Y, Z = spot.Z + 50 }, false, {}, true)
  log("LEVERPROBE boarded; " .. M.state(t0))
  M.axis = 0
  pcall(function()
    RegisterHook("/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C:ReceiveTick", function(self)
      if M.axis == 0 then return end
      local ch = self:get()
      if not safe(function() return ch:IsLocallyControlled() end, false) then return end
      pcall(function() ch:InpAxisEvt_LookUp_K2Node_InputAxisEvent_1(M.axis) end)
    end)
  end)
  -- plan: per lever: aim, press, drag up 1.5 s, release, wait; press, drag down, release, wait
  local plan = {}
  for _, lv in ipairs({ "Lever1 HOVER", "Lever2 HOVER", "Lever3 HOVER" }) do
    for _, dir in ipairs({ -1, 1 }) do
      table.insert(plan, { "aim", lv }); table.insert(plan, { "press", lv, dir })
      table.insert(plan, { "drag", lv, dir }); table.insert(plan, { "drag", lv, dir })
      table.insert(plan, { "release", lv, dir }); table.insert(plan, { "wait", lv, dir })
      table.insert(plan, { "log", lv, dir })
    end
  end
  local i = 0
  LoopAsync(750, function()
    i = i + 1
    local st = plan[i]
    if not st then done(); return true end
    ExecuteInGameThread(function()
      local kind, lv, dir = st[1], st[2], st[3]
      if kind == "aim" then
        safe(function() pc:SetControlRotation({ Pitch = AIM[lv][1], Yaw = AIM[lv][2], Roll = 0 }) end)
      elseif kind == "press" then
        local hc = safe(function() return me["Component Hovered"] end)
        log(string.format("LEVERPROBE press %s (hovered %s) drag %d", lv, valid(hc) and hc:GetFName():ToString() or "none", dir))
        pcall(function() me:InpActEvt_Interaction_K2Node_InputActionEvent_12({ KeyName = FName("E") }) end)
        M.axis = dir
      elseif kind == "release" then
        M.axis = 0
        pcall(function() me:InpActEvt_Interaction_K2Node_InputActionEvent_13({ KeyName = FName("E") }) end)
      elseif kind == "log" then
        log(string.format("LEVERPROBE after %s drag %d: %s", lv, dir, M.state(M.find())))
      end
    end)
    return false
  end)
end

-- Each character: distance to the train and what it stands on.
function M.ride_report()
  local t = M.find(); if not t then return "no train" end
  local tl = t:K2_GetActorLocation()
  local out = {}
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and not ch:GetFullName():find("Default__") then
      local l = safe(function() return ch:K2_GetActorLocation() end)
      -- not GetMovementBase()/GetOuter(): calling them crashed both copies natively in
      -- UE4SS 3.0.1 (run 20261030-182105); movement mode is a plain property read
      local mode = tostring(safe(function() return ch.CharacterMovement.MovementMode end, "?"))
      local d = l and math.sqrt((l.X - tl.X) ^ 2 + (l.Y - tl.Y) ^ 2 + (l.Z - tl.Z) ^ 2) or -1
      table.insert(out, string.format("%s%s d=%.0f mode=%s", ch:GetFName():ToString(),
        safe(function() return ch:IsLocallyControlled() end, false) and "*" or "", d, mode))
    end
  end
  return table.concat(out, " | ")
end

function M.drive_experiment(log, done)
  local t0 = M.find()
  if not t0 then log("TRAIN no train found"); done(); return end
  log("TRAIN " .. M.replication(t0))
  log("TRAIN start " .. M.state(t0))
  local step, ticks = "A", 0
  LoopAsync(100, function()
    ticks = ticks + 1
    ExecuteInGameThread(function()
      local t = M.find(); if not t then return end
      if ticks == 1 then
        safe(function() t["Can move at all?"] = true end); safe(function() t["Can Move?"] = true end)
        local ok, err = pcall(function() t["Speed Up"](t) end)
        log("TRAIN A: flags set, Speed Up called -> " .. (ok and "ok" or tostring(err)))
      elseif ticks == 101 then step = "B"; log("TRAIN B: forcing Train Speed = Forward Max Speed (" .. num(safe(function() return t["Forward Max Speed"] end)) .. ")")
      elseif ticks == 201 then step = "C"; log("TRAIN C: pushing Current Position on Rail +50 per 100 ms")
      end
      if step == "B" then safe(function() t["Train Speed"] = t["Forward Max Speed"] end) end
      if step == "C" then safe(function() t["Current Position on Rail"] = t["Current Position on Rail"] + 50 end) end
      if ticks % 10 == 0 then log("TRAIN " .. step .. " " .. M.state(t)) end
    end)
    if ticks >= 300 then done(); return true end
    return false
  end)
end
-- Debug: every bool on the train plus tick state (to find why it sometimes won't move).
local FLAGS = { "Stopping Train", "inside train?", "Setting Movement", "Horn Pulled?", "Can Move?", "Using Gun?",
  "Using Upgrade Menu?", "Using Map", "Tutorial Mode", "Broken Down", "Charles Alive", "Lever 1 up?", "Lever 2 up?",
  "Lever 3 up?", "Inside 2", "Inside 1", "Lever Tutorial?", "Just Hit", "Side Levers Activated? Tutorial", "Gun Lock?",
  "Movement During Cutscene", "Can move at all?", "Made on spawn" }
function M.flags(t)
  t = t or M.find(); if not t then return "no train" end
  local on = {}
  for _, k in ipairs(FLAGS) do if safe(function() return t[k] end) == true then table.insert(on, k) end end
  return string.format("tick=%s dil=%s on=[%s]", tostring(safe(function() return t:IsActorTickEnabled() end)),
    tostring(safe(function() return t.CustomTimeDilation end)), table.concat(on, ","))
end
return M
