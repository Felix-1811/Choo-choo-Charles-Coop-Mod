-- Shared story. All progress goes through easySaveObject_C:SaveCore (one .sav per key), e.g.
-- "Canyon" = 1 when a mission is accepted (run 20261101-171544). So:
--   save mirror  : every shared key written on one machine is written on the others
--   join snapshot: the host sends its keys; the guest writes them and, if anything differed,
--                  loads the map again so the game's own load code restores the world
--   action mirror: a click on a door, chest, ... is replayed on the other copies of that actor.
--                  NPCs are not replayed (the conversation camera would take over the other
--                  player's screen): they follow the mission key.
-- Item counts belong to the host. Pickups already reach every machine as a replayed Interact,
-- so a guest never sends a count; the host sends its absolute count after any change.
local M = { writes = 0, tx = 0, rx = 0, acts_tx = 0, acts_rx = 0, out = {}, inq = {}, session = {}, item_dirty = {}, hooked = {}, snap = "idle" }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local fmt = string.format

local SO = "/Game/EasySave/easySaveObject.easySaveObject_C:"
local BP = "/Game/_GAME/Blueprints/"
local MODDIR = "Mods/CharlesCoop"

-- Each machine's own: settings, where this player stands, autosaved actor positions.
local LOCAL = {}
for _, k in ipairs({ "Brightness", "Camera Shake", "Controller Rumble", "Defaults Loaded", "Desktop X", "Desktop Y", "FOV", "FPS Limit",
  "InputMappings", "Invert X", "Invert Y", "Left Stick Sensitivity", "Map Height", "Mouse Sensitivity", "Player Health", "Retry Count",
  "Right Stick Sensitivity", "Screen Resolution", "Shown Subtitles Tip", "Subtitles", "Text Size", "Upscaling Mode", "Upscaling Sharpness",
  "Upscaling", "VSync", "VersionNumber", "Volume_Master", "Volume_Music", "Volume_SFX", "Volume_Voices", "Window Mode", "Indoors",
  "Charles Transform", "Patrol Time Elapsed", "Scraps to Restore" }) do LOCAL[k] = true end
local function is_local(k)
  return LOCAL[k] or k:find("^M_") ~= nil or k:find("StatusLocRot$") ~= nil
end

-- Only the host's value counts; a guest's own copy of these is not sent.
local function host_only(k)
  return k == "Weather State" or k == "Mode" or k == "Equipped Gun" or k == "Train Health" or k == "First Strike" or k:find("^ScrapCratePoint") ~= nil
end

local ITEMS = {}
for _, k in ipairs({ "01_KeyTony", "05_Scraps", "Bob_BobPiece", "Bob_Key", "Boomer_Dynamite", "Boomer_Rockets", "Boss_ShrineKey", "Bridge_Dynamite",
  "Canyon_BlueBox", "Egg1", "Egg2", "Egg3", "Files", "Fish", "Gear", "Journal", "Junkyard_LockPicks", "Junkyard_Tablet", "Key", "Lighthouse_Breaker",
  "Mine1_Egg", "Mine1_Key", "Mine2_Egg", "Mine2_Gear", "Mine2_Key", "Mine3_Egg", "Mine3_Key", "Pages_Drawing", "Pickles_Jar", "Port_Journal",
  "Swamp_Fish", "Towers_Files", "Train_Key", "Tutorial2_Key" }) do ITEMS[k] = true end

-- Never goes backwards: a late or stale write must not undo progress.
local FORWARD = {}
for _, k in ipairs({ "Bob", "Boomer", "BossMission", "Bridge", "Bugspray", "Canyon", "Junkyard", "Lighthouse", "Mine1", "Mine2", "Mine3", "Pages",
  "Pickles", "Port", "Swamp", "TonyBarn", "Towers", "Train", "Tutorial2" }) do FORWARD[k] = true end

-- Clickable things that change the world. ItemPickup has its own route (progress.lua), the
-- train has its own (sync.lua), NPCs follow their key, Notes only open a reading screen.
local ACTS = { "Door", "Chest", "ClickBox", "Bridge_PlaceExplosive", "PaintCan", "Prism", "Shrine", "ScrapCratePoint", "RailDirectionSwitcher" }

local function save_dir()
  local d = os.getenv("COOP_SAVE_DIR")
  if d and d ~= "" then return d end
  return (os.getenv("LOCALAPPDATA") or "") .. "/Obscure/Saved/SaveGames"
end

-- A .sav holds: savedKey, StrProperty, int64 size, one flag byte, int32 length, the string.
function M.read_value(key)
  local f = io.open(save_dir() .. "/" .. key .. ".sav", "rb")
  if not f then return nil end
  local d = f:read("a"); f:close()
  local i = d:find("savedKey\0", 1, true); if not i then return nil end
  local marker = "StrProperty\0"
  local j = d:find(marker, i, true); if not j then return nil end
  local p = j + #marker + 8 + 1
  if p + 4 > #d then return nil end
  local n = string.unpack("<i4", d, p)
  if n <= 0 or p + 4 + n - 1 > #d then return "" end
  return d:sub(p + 4, p + 4 + n - 2)
end

local function save_obj() return FindFirstOf("easySaveObject_C") end

local function enqueue(entry, dedupe_key)
  if dedupe_key then
    for i, e in ipairs(M.out) do if e.k == dedupe_key then table.remove(M.out, i); break end end
  end
  table.insert(M.out, { s = entry, k = dedupe_key })
end
local function enqueue_key(k, v) enqueue("s\t" .. k .. "\t" .. v, k) end

function M.is_live() return M.live_at ~= nil and os.clock() >= M.live_at end

local function on_write(log, key, val)
  M.writes = M.writes + 1
  if M.trace and not key:find("StatusLocRot$") and not key:find("^M_") and key ~= "Charles Transform" and key ~= "Weather State" then
    log("STORY save " .. key .. " = " .. val .. (M.applying and " (from other player)" or ""))
  end
  if M.applying or is_local(key) then return end
  if key == "05_Scraps" then M.last_scraps = val end
  -- While a guest loads, the game writes defaults (Train Color = 0, run 172727). They must not reach the host.
  if M.role == "guest" and not M.is_live() then return end
  if M.role == "host" then
    M.session[key] = val
    if ITEMS[key] then M.item_dirty[key] = val; M.item_at = os.clock() + 1; return end
    if key == "Weather State" then
      if os.clock() - (M.weather_at or -99) < 5 then return end
      M.weather_at = os.clock()
    end
    enqueue_key(key, val)
  else
    if ITEMS[key] or host_only(key) then return end
    enqueue_key(key, val)
    -- the upgrade menu writes the scrap count itself: a guest's purchase must reach the host,
    -- and so must a mission's reward
    if key:find(" Level$") or FORWARD[key] then M.scraps_at = os.clock() + 0.5 end
  end
end

-- A live NPC keeps its "already spoken" state from the time it loaded.
local function after_apply(log, key, val)
  if not FORWARD[key] then return end
  for _, n in ipairs(FindAllOf("NPC_C") or {}) do
    if valid(n) and safe(function() return n["Mission ID"]:ToString() end) == key then
      safe(function() n["Already spoken to NPC"] = true end)
      log("story: " .. n:GetFName():ToString() .. " knows mission " .. key .. " = " .. val)
    end
  end
end

local function apply_key(log, key, val, from)
  if is_local(key) then return end
  if FORWARD[key] then
    local old, new = tonumber(M.read_value(key) or ""), tonumber(val)
    if old and new and new < old then log(fmt("story: kept %s = %s (got older %s)", key, tostring(old), val)); return end
  end
  local so = save_obj(); if not valid(so) then return end
  M.applying = true
  local ok, err = pcall(function() so:SaveCore(key, val, false) end)
  M.applying = false
  if not ok then log("story: write " .. key .. " failed: " .. tostring(err)); return end
  M.applied = (M.applied or 0) + 1
  after_apply(log, key, val)
  if M.role == "host" then
    M.session[key] = val
    if ITEMS[key] then M.item_dirty[key] = val; M.item_at = os.clock() + 1
    elseif M.relay then M.relay("story|s\t" .. key .. "\t" .. val, from) end
  end
end

local function apply_act(log, cls, name, comp)
  M.acts_rx = M.acts_rx + 1
  for _, a in ipairs(FindAllOf(cls .. "_C") or {}) do
    if valid(a) and a:GetFName():ToString() == name then
      local c = comp ~= "none" and safe(function() return a[comp] end) or nil
      if comp ~= "none" and not valid(c) then log("story: " .. name .. " has no part " .. comp .. ", clicking anyway"); c = nil end
      M.applying = true
      local ok, err = pcall(function() a:Interact(c, false) end)
      M.applying = false
      log(fmt("story: %s %s clicked by another player, here too -> %s", cls, name, ok and "ok" or tostring(err)))
      return
    end
  end
  log(fmt("story: %s %s clicked by another player (not loaded here, its save key covers it)", cls, name))
end

local function handle(log, e, from)
  local t, a, b, c = e:match("^(%a)\t([^\t]*)\t?([^\t]*)\t?([^\t]*)")
  if t == "s" then
    if M.snap == "receiving" then
      M.snap_n = (M.snap_n or 0) + 1
      local here = M.read_value(a)
      if here ~= b then
        M.snap_diff = (M.snap_diff or 0) + 1
        if M.snap_diff <= 12 then log(fmt("story: snapshot differs: %s here=%s host=%s", a, tostring(here), b)) end
      end
    end
    apply_key(log, a, b, from)
  elseif t == "a" then
    apply_act(log, a, b, c)
    if M.role == "host" and M.relay then M.relay("story|a\t" .. a .. "\t" .. b .. "\t" .. c, from) end
  elseif t == "f" then
    M.apply_final(log)
  elseif t == "e" then
    log(fmt("story: snapshot complete, %d keys, %d differed", M.snap_n or 0, M.snap_diff or 0))
    M.snap = (M.snap_diff or 0) > 0 and "reload" or "done"
  end
end

-- The ending. Killing Charles plays the final cutscene only on the machine whose copy died, and
-- that is the host's copy (run 20261101-174943). The guest runs it on its own copy, once.
function M.apply_final(log)
  if M.final_done then log("story: the ending already runs here"); return end
  M.final_done = true
  for _, c in ipairs(FindAllOf("CharlesCharacter_C") or {}) do
    if valid(c) and not c:GetFullName():find("Default__") then
      M.applying = true
      local ok, err = pcall(function() c["Final Event"](c) end)
      M.applying = false
      log("story: the host's Charles died, playing the ending here -> " .. (ok and "ok" or tostring(err)))
      return
    end
  end
  log("story: the host's Charles died, but there is no Charles here")
end

local BOSS_EVENTS = { "Activate Boss Mode_Event", "Apply Boss Cosmetics", "Boss Bellow 75", "Boss bellow 50", "Boss Bellow 25", "End Cutscene" }
function M.register_final(log)
  if M.final_hooked then return end
  local c
  for _, x in ipairs(FindAllOf("CharlesCharacter_C") or {}) do
    if valid(x) and not x:GetFullName():find("Default__") then c = x; break end
  end
  if not c then return end
  local path = safe(function() return c:GetClass():GetFullName():match("%s(%S+)$") end)
  if not path then return end
  M.final_hooked = true
  local ok, err = pcall(function()
    RegisterHook(path .. ":Final Event", function()
      log("story: Final Event ran here" .. (M.applying and " (sent by the host)" or ""))
      if M.applying then return end
      M.final_done = true
      if M.role == "host" then enqueue("f\tfinal") end
    end)
  end)
  log("story: hook Final Event -> " .. (ok and "ok" or tostring(err)))
  if M.trace then
    for _, ev in ipairs(BOSS_EVENTS) do
      pcall(function() RegisterHook(path .. ":" .. ev, function() log("STORY event " .. ev) end) end)
    end
  end
end

-- Message from the other machine: stored, then applied on the scheduler's tick (game thread).
function M.receive(body, from)
  M.rx = M.rx + 1
  for e in body:sub(7):gmatch("[^\n]+") do table.insert(M.inq, { e = e, from = from }) end
end

function M.tick(log)
  M.register_acts(log)
  M.register_final(log)
  for _ = 1, 25 do
    local e = table.remove(M.inq, 1); if not e then break end
    local ok, err = pcall(handle, log, e.e, e.from)
    if not ok then log("story: apply failed: " .. tostring(err)) end
  end
  local now = os.clock()
  if M.scraps_at and now >= M.scraps_at then
    M.scraps_at = nil
    if M.last_scraps then enqueue_key("05_Scraps", M.last_scraps) end
  end
  if M.item_at and now >= M.item_at then
    M.item_at = nil
    for k, v in pairs(M.item_dirty) do enqueue_key(k, v) end
    M.item_dirty = {}
  end
  -- the snapshot goes out a little at a time: too many reliable RPCs at once close the connection
  if M.snap_out then
    for _ = 1, 12 do
      local e = table.remove(M.snap_out, 1)
      if not e then enqueue("e\tdone"); M.snap_out = nil; break end
      enqueue(e)
    end
  end
  if #M.out > 0 then
    local parts, size = {}, 0
    while M.out[1] and size + #M.out[1].s < 900 do
      local e = table.remove(M.out, 1)
      table.insert(parts, e.s); size = size + #e.s + 1
    end
    if #parts > 0 then M.tx = M.tx + 1; M.send("story|" .. table.concat(parts, "\n")) end
  end
end

-- Host: every shared key this save has. The launcher lists the save folder in savekeys.txt
-- (Lua can't list a folder without flashing a console window); keys written since are in session.
function M.build_snapshot(log)
  local keys = {}
  local f = io.open(MODDIR .. "/savekeys.txt", "r")
  if f then
    for line in f:lines() do local k = line:gsub("%s+$", ""); if k ~= "" then keys[k] = true end end
    f:close()
  else
    log("story: no savekeys.txt, the snapshot only has this session's keys")
  end
  for k in pairs(M.session) do keys[k] = true end
  local list = {}
  for k in pairs(keys) do
    if not is_local(k) then
      local v = M.session[k] or M.read_value(k)
      if v and v ~= "" then table.insert(list, "s\t" .. k .. "\t" .. v) end
    end
  end
  table.sort(list)
  return list
end

function M.host_snapshot_request(log)
  M.snap_out = M.build_snapshot(log)
  log(fmt("story: guest asked for the story, sending %d keys", #M.snap_out))
end

-- Guest, once per join: "wait", "reload" (load the map again) or "done".
function M.guest_join_step(log)
  if M.snap == "idle" then
    M.snap, M.snap_at = "receiving", os.clock()
    M.snap_n, M.snap_diff = 0, 0
    M.send("snapreq")
    log("story: asking the host for the story")
  end
  if M.snap == "receiving" and os.clock() - M.snap_at > 40 then
    log("story: no snapshot after 40 s, playing on with what we have")
    M.snap = "done"
  end
  if M.snap == "reload" then
    if M.reloaded then log("story: already reloaded once, playing on"); M.snap = "done"; return "done" end
    M.reloaded = true
    M.snap = "done"
    return "reload"
  end
  if M.snap == "done" then
    if not M.live_at then M.live_at = os.clock() + 8; log("story: joined, sharing our progress in 8 s") end
    return "done"
  end
  return "wait"
end

-- Guest: the connection is gone. The next join fetches the story again.
function M.guest_reset(log)
  M.snap, M.reloaded, M.live_at, M.final_done = "idle", nil, nil, nil
  M.out, M.inq = {}, {}
  log("story: disconnected, will fetch the story again")
end

-- Hooks need the class in memory, and most actors live in levels that stream in later.
function M.register_acts(log)
  local now = os.clock()
  if now < (M.acts_next or 0) then return end
  M.acts_next = now + 5
  for _, cls in ipairs(ACTS) do
    local o = not M.hooked[cls] and FindFirstOf(cls .. "_C")
    -- the path comes from a live object: not every class sits in the same folder
    local path = o and safe(function() return o:GetClass():GetFullName():match("%s(%S+)$") end)
    if path then
      M.hooked[cls] = true
      local ok, err = pcall(function()
        RegisterHook(path .. ":Interact", function(self, comp)
          if M.applying or (M.role == "guest" and not M.is_live()) then return end
          local a = self:get()
          local name = safe(function() return a:GetFName():ToString() end)
          if not name then return end
          local c = safe(function() return comp:get() end)
          local cname = (c and safe(function() return c:IsValid() end, false)) and c:GetFName():ToString() or "none"
          M.acts_tx = M.acts_tx + 1
          log(fmt("story: clicked %s %s (%s)", cls, name, cname))
          enqueue("a\t" .. cls .. "\t" .. name .. "\t" .. cname)
        end)
      end)
      log("story: hook " .. cls .. " -> " .. (ok and "ok" or tostring(err)))
    end
  end
end

function M.install(log, role, send, relay)
  if M.installed then return end
  M.installed, M.role, M.send, M.relay = true, role, send, relay
  M.trace = (os.getenv("COOP_TEST") or ""):find("^story") ~= nil
  local ok, err = pcall(function()
    RegisterHook(SO .. "SaveCore", function(self, k, v)
      local key = safe(function() return k:get():ToString() end)
      local val = safe(function() return v:get():ToString() end)
      if key and val then on_write(log, key, val) end
    end)
  end)
  log("story: hook SaveCore -> " .. (ok and "ok" or tostring(err)))
  local sched = require("sched"); sched.install(log)
  sched.every("story", 0.25, function() M.tick(log) end)
end

-- ===== Test bot =====
local function npcs()
  local out = {}
  for _, n in ipairs(FindAllOf("NPC_C") or {}) do
    if valid(n) and not n:GetFullName():find("Default__") then table.insert(out, n) end
  end
  table.sort(out, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
  return out
end

function M.describe(n)
  return fmt("%s mission=%s canuse=%s spoken=%s talking=%s", n:GetFName():ToString(),
    safe(function() return n["Mission ID"]:ToString() end, "?"),
    tostring(safe(function() return n["Can Use?"] end)),
    tostring(safe(function() return n["Already spoken to NPC"] end)),
    tostring(safe(function() return n["Talking to NPC"] end)))
end

local function own_char()
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then return ch end
  end
end

local function npc_named(want)
  for _, n in ipairs(npcs()) do if n:GetFName():ToString() == want then return n end end
end

-- Stand in front of an NPC and click it. A conversation advances on a real key press (the
-- subtitle widget's Tick reads WasInputKeyJustPressed), so the bot ends it through the widget.
function M.talk(log, tag, want)
  local me, n = own_char(), npc_named(want)
  if not (me and n) then log("STORY " .. tag .. " can't talk to " .. tostring(want)); return end
  local l = n:K2_GetActorLocation()
  log("STORY " .. tag .. " talks to " .. want .. " | " .. M.describe(n))
  pcall(function() me:K2_SetActorLocation({ X = l.X - 120, Y = l.Y, Z = l.Z + 60 }, false, {}, true) end)
  ExecuteWithDelay(2000, function() ExecuteInGameThread(function()
    if not valid(n) then return end
    local ok, err = pcall(function() n:Interact(n["Collision Box"], false) end)
    log("STORY " .. tag .. " Interact -> " .. (ok and "ok" or tostring(err)) .. " | " .. M.describe(n))
  end) end)
  ExecuteWithDelay(14000, function() ExecuteInGameThread(function()
    for _, w in ipairs(FindAllOf("Subtitles_C") or {}) do
      if valid(w) and not w:GetFullName():find("Default__") then pcall(function() w["End Convo"](w) end) end
    end
    log("STORY " .. tag .. " conversation ended | " .. (valid(n) and M.describe(n) or "?"))
  end) end)
end

-- A door somebody can click, by name order so both machines pick the same one.
function M.click_door(log, tag, index)
  local list = {}
  for _, d in ipairs(FindAllOf("Door_C") or {}) do
    if valid(d) and not d:GetFullName():find("Default__") then table.insert(list, d) end
  end
  table.sort(list, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
  log(fmt("STORY %s doors=%d", tag, #list))
  local d = list[index or 1]; if not d then return end
  local ok, err = pcall(function() d:Interact(nil, false) end)
  log("STORY " .. tag .. " clicked door " .. d:GetFName():ToString() .. " -> " .. (ok and "ok" or tostring(err)))
end

local WATCH = { "TutorialState", "Train", "Train_Key-Train_KeyPickup", "Canyon", "Port", "05_Scraps", "Armor Level" }
function M.verify(log, tag)
  local o = {}
  for _, k in ipairs(WATCH) do table.insert(o, k .. "=" .. tostring(M.read_value(k))) end
  log(fmt("STORY %s keys %s | writes=%d tx=%d rx=%d applied=%d acts tx=%d rx=%d", tag, table.concat(o, " "), M.writes, M.tx, M.rx, M.applied or 0, M.acts_tx, M.acts_rx))
  for _, name in ipairs({ "NPCTheodore", "NPCSantiago" }) do
    local n = npc_named(name)
    if n then log("STORY " .. tag .. " " .. M.describe(n)) end
  end
end

function M.guest_msg(log, body)
  local cmd, arg = body:match("^storytest|([^|]+)|?(.*)")
  if cmd == "talk" then M.talk(log, "guest", arg)
  elseif cmd == "verify" then M.verify(log, "guest")
  elseif cmd == "door" then M.click_door(log, "guest", 2)
  elseif cmd == "sweep" then for _ = 1, 4 do M.sweep_step(log) end
  elseif cmd == "endreport" then M.end_report(log, "guest")
  elseif cmd == "endshot" and M.shot then M.shot("guest end") end
end

-- Host side of the test, called every 3 s with the elapsed time.
function M.test_host(log, t, sync, touch)
  if t == 3 then M.verify(log, "host"); sync.send(log, "storytest|verify") end
  if t == 9 then M.talk(log, "host", "NPCTheodore") end
  if t == 33 then M.verify(log, "host"); sync.send(log, "storytest|verify") end
  if t == 36 then sync.send(log, "storytest|talk|NPCSantiago") end
  if t == 60 then M.verify(log, "host"); sync.send(log, "storytest|verify") end
  if t == 63 then M.click_door(log, "host", 1) end
  if t == 72 then sync.send(log, "storytest|door") end
  if t == 81 then M.verify(log, "host"); sync.send(log, "storytest|verify") end
  if t == 87 then touch("host_drive_done") end
end

-- ===== Endgame test: summon, boss, final cutscene =====
local function first_real(cls)
  for _, a in ipairs(FindAllOf(cls) or {}) do
    if valid(a) and not a:GetFullName():find("Default__") then return a end
  end
end

-- One line, logged only when something other than Charles's position changed.
function M.end_report(log, tag)
  local out = {}
  local pr = first_real("Prism_C")
  if pr then
    table.insert(out, "prism canuse=" .. tostring(safe(function() return pr["Can Use?"] end)))
  else
    table.insert(out, "prism=gone")
  end
  local playing = {}
  for _, p in ipairs(FindAllOf("LevelSequencePlayer") or {}) do
    if valid(p) and not p:GetFullName():find("Default__") and safe(function() return p:IsPlaying() end, false) then
      local n = p:GetFullName():match("PersistentLevel%.([^%.]+)") or "?"
      if not n:find("Flicker") then table.insert(playing, n) end
    end
  end
  table.sort(playing)
  table.insert(out, "seq=[" .. table.concat(playing, ",") .. "]")
  table.insert(out, "credits=" .. tostring(first_real("EndCredits_C") ~= nil))
  table.insert(out, "deadcharles=" .. tostring(first_real("DeadCharles_C") ~= nil))
  for _, k in ipairs({ "ChalesDead", "CharlesDead", "BossMission", "Boss Fight Started" }) do
    table.insert(out, k .. "=" .. tostring(M.read_value(k)))
  end
  local line = table.concat(out, " ")
  if line ~= M.end_last then
    M.end_last = line
    log("ENDTEST " .. tag .. " " .. line)
  end
end

function M.end_click(log, tag, cls, part)
  local a = first_real(cls)
  if not a then log("ENDTEST " .. tag .. " no " .. cls); return end
  local me = own_char()
  local l = a:K2_GetActorLocation()
  if me then pcall(function() me:K2_SetActorLocation({ X = l.X - 200, Y = l.Y, Z = l.Z + 100 }, false, {}, true) end) end
  ExecuteWithDelay(3000, function() ExecuteInGameThread(function()
    if not valid(a) then return end
    local c = safe(function() return a[part] end)
    local ok, err = pcall(function() a:Interact(c, false) end)
    log(fmt("ENDTEST %s clicked %s part %s (found=%s) -> %s", tag, a:GetFName():ToString(), part, tostring(valid(c)), ok and "ok" or tostring(err)))
  end) end)
end

function M.end_kill(log, tag)
  local c = first_real("CharlesCharacter_C")
  if not c then log("ENDTEST " .. tag .. " no Charles"); return end
  local ok, err = pcall(function() c:Damage(100000.0, 1.0, c["Body Hitbox"]) end)
  log("ENDTEST " .. tag .. " lethal hit on Charles -> " .. (ok and "ok" or tostring(err)))
end

function M.end_test_host(log, t, sync, touch, shot)
  if t % 3 == 0 then M.end_report(log, "host"); sync.send(log, "storytest|endreport") end
  if t == 12 then M.end_click(log, "host", "Prism_C", "ClickBox") end
  if t >= 18 and t % 15 == 0 then shot("host end t=" .. t); sync.send(log, "storytest|endshot") end
  if M.read_value("Boss Fight Started") == "true" then
    M.fight_t = (M.fight_t or 0) + 3
    if M.fight_t == 15 then M.end_kill(log, "host") end
    if M.fight_t >= 15 and M.fight_t % 6 == 0 then shot("host fight"); sync.send(log, "storytest|endshot") end
  end
  if t == 420 then touch("host_drive_done") end
end

-- ===== Sweep test: the guest clicks everything; does the host survive, and does it get moved? =====
local SWEEP = { "Door_C", "Chest_C", "ClickBox_C", "Bridge_PlaceExplosive_C", "PaintCan_C", "Shrine_C", "RailDirectionSwitcher_C", "ScrapCratePoint_C" }
-- the part a real click hits (component names from each Blueprint)
local SWEEP_PART = { ClickBox_C = "Click Box", Bridge_PlaceExplosive_C = "Hover Box", ScrapCratePoint_C = "ClickBox", RailDirectionSwitcher_C = "Click Box", Door_C = "Front" }
function M.sweep_build(log)
  M.sweep = {}
  for _, cls in ipairs(SWEEP) do
    local n = 0
    for _, a in ipairs(FindAllOf(cls) or {}) do
      if valid(a) and not a:GetFullName():find("Default__") then table.insert(M.sweep, { cls = cls, a = a, name = a:GetFName():ToString() }); n = n + 1 end
    end
    log(fmt("SWEEP %s = %d", cls, n))
  end
  M.sweep_i = 0
end

function M.sweep_step(log)
  if not M.sweep then M.sweep_build(log) end
  M.sweep_i = M.sweep_i + 1
  local e = M.sweep[M.sweep_i]
  if not e then if not M.sweep_end then M.sweep_end = true; log("SWEEP finished") end; return end
  if not valid(e.a) then log("SWEEP " .. e.name .. " gone"); return end
  log(fmt("SWEEP %d/%d %s %s", M.sweep_i, #M.sweep, e.cls, e.name))
  local part = SWEEP_PART[e.cls]
  local c = part and safe(function() return e.a[part] end) or nil
  if part and not valid(c) then log("SWEEP " .. e.name .. " has no part " .. part); c = nil end
  local ok, err = pcall(function() e.a:Interact(c, false) end)
  if not ok then log("SWEEP failed: " .. tostring(err)) end
end

function M.sweep_test_host(log, t, sync, touch)
  local me = own_char()
  local l = me and safe(function() return me:K2_GetActorLocation() end)
  if l then
    if M.host_at and math.abs(l.X - M.host_at.X) + math.abs(l.Y - M.host_at.Y) > 300 then
      log(fmt("SWEEP host MOVED (%.0f %.0f) -> (%.0f %.0f)", M.host_at.X, M.host_at.Y, l.X, l.Y))
    end
    M.host_at = { X = l.X, Y = l.Y }
  end
  local pc = FindFirstOf("PlayerController")
  if t >= 9 and t % 3 == 0 then sync.send(log, "storytest|sweep") end
  if t == 360 then touch("host_drive_done") end
end
return M
