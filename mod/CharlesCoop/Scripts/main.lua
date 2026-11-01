-- CharlesCoop probe (Choo-Choo Charles, UE 4.26.2, UE4SS 3.0.1)
-- Phase 1 goal: can the engine's own netcode put a second player in the host's world?
-- Role comes from the environment (COOP_ROLE=host|guest), never from keys: UE4SS key
-- binds reach every running copy (playbook/lessons.md #55).
local VERSION = "0.4.0"
-- Players set role and host address in Mods/CharlesCoop/coop.ini (written by the
-- launcher scripts); the environment overrides it for the test harness.
-- This mod's folder: from the script path, so it works whatever the working directory is.
local MODDIR = "Mods/CharlesCoop"
do
  local ok, info = pcall(debug.getinfo, 1, "S")
  local d = ok and info and info.source and info.source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/Scripts/[^/]*$")
  if d then MODDIR = d end
end
local CFG = {}
do
  local f = io.open(MODDIR .. "/coop.ini", "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k then CFG[k:lower()] = v end
    end
    f:close()
  end
end
local ROLE = os.getenv("COOP_ROLE") or CFG.role or "off"
local SYNC = os.getenv("COOP_SYNC_DIR")            -- shared folder for the same-PC hand-off (tests only)
local HOST_ADDR = os.getenv("COOP_HOST_ADDR") or CFG.host or "127.0.0.1"
local NET = os.getenv("COOP_NET") or "ip"           -- ip: rewrite GameNetDriver to IpNetDriver
local TEST = os.getenv("COOP_TEST") or ""            -- optional experiment, e.g. train_drive

local LOGFILE = (SYNC or MODDIR) .. "/probe_" .. ROLE .. ".log"
local function log(s)
  local line = "[CharlesCoop/" .. ROLE .. "] " .. tostring(s)
  print(line .. "\n")
  local f = io.open(LOGFILE, "a"); if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end
end
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local function touch(name) if SYNC then local f = io.open(SYNC .. "/" .. name, "w"); if f then f:write(os.date()); f:close() end end end
local function exists(name) if not SYNC then return false end; local f = io.open(SYNC .. "/" .. name, "r"); if f then f:close(); return true end; return false end

log("loaded " .. VERSION .. " role=" .. ROLE .. " net=" .. NET .. " sync=" .. tostring(SYNC))
if ROLE == "off" then return end

local function local_pc()
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and safe(function() return pc:IsLocalController() end, false) then return pc end
  end
end

local function world_path()
  local pc = local_pc(); if not pc then return nil end
  return safe(function() return pc:GetWorld():GetFullName():match("(/Game/[^%.%s]+)") end)
end

local function console(cmd)
  local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
  local pc = local_pc()
  if not (valid(ksl) and pc) then log("console: missing KSL or PC for: " .. cmd); return false end
  log("exec: " .. cmd)
  ksl:ExecuteConsoleCommand(pc, cmd, pc)
  return true
end

-- Strip typographic double quotes (UTF-8 E2 80 9C / E2 80 9D) and plain ones.
local LQ, RQ = string.char(0xE2, 0x80, 0x9C), string.char(0xE2, 0x80, 0x9D)
local function unquote(s)
  return (s:gsub(LQ, ""):gsub(RQ, ""):gsub('"', ""))
end

local function dump_driver_defs(rewrite)
  local engine = FindFirstOf("GameEngine")
  if not valid(engine) then log("no GameEngine"); return end
  engine.NetDriverDefinitions:ForEach(function(i, e)
    local d = e:get()
    local raw = d.DefName:ToString()
    -- The shipped config wraps every value in typographic quotes (U+201C/U+201D), so the
    -- engine's lookup of "GameNetDriver" never matches. Strip them (bytes E2 80 9C / 9D).
    local name = unquote(raw)
    log(string.format("driverdef %d: %s -> %s (fallback %s)", i, raw,
      d.DriverClassName:ToString(), d.DriverClassNameFallback:ToString()))
    if name == "GameNetDriver" then
      d.DefName = FName("GameNetDriver")
      local drv = rewrite and "/Script/OnlineSubsystemUtils.IpNetDriver" or unquote(d.DriverClassName:ToString())
      d.DriverClassName = FName(drv)
      d.DriverClassNameFallback = FName(unquote(d.DriverClassNameFallback:ToString()))
      log("  fixed -> " .. d.DefName:ToString() .. " -> " .. d.DriverClassName:ToString() .. " (fallback " .. d.DriverClassNameFallback:ToString() .. ")")
    end
  end)
end

local function vec(v) return v and string.format("(%.0f %.0f %.0f)", v.X, v.Y, v.Z) or "?" end

-- One status line set: map, net role, players, train. Compared run to run, it is the test oracle.
local function status(tag)
  local pc = local_pc()
  local wp = world_path() or "?"
  local nd = pc and safe(function() return pc:GetWorld().NetDriver end)
  local net = "standalone"
  if valid(nd) then
    local sc = safe(function() return nd.ServerConnection end)
    if valid(sc) then net = "client(" .. nd:GetClass():GetFName():ToString() .. ")"
    else net = "listen(" .. nd:GetClass():GetFName():ToString() .. ", conns=" ..
      tostring(safe(function() return nd.ClientConnections:GetArrayNum() end, "?")) .. ")" end
  end
  local pcs = FindAllOf("PlayerController") or {}
  local chars = FindAllOf("BP_NMCharacter_Player_C") or {}
  local parts = {}
  for _, ch in ipairs(chars) do
    if valid(ch) then
      local mine = safe(function() return ch:IsLocallyControlled() end, false)
      table.insert(parts, ch:GetFName():ToString() .. (mine and "*" or "") .. vec(safe(function() return ch:K2_GetActorLocation() end)))
    end
  end
  local trains = FindAllOf("PlayerTrain_C") or {}
  local tr = (#trains > 0 and valid(trains[1])) and vec(safe(function() return trains[1]:K2_GetActorLocation() end)) or "none"
  local pawn = pc and safe(function() return pc.Pawn end)
  log(string.format("STATUS[%s] map=%s net=%s pcs=%d chars=%d [%s] train=%s(%d) pawn=%s", tag, wp, net, #pcs, #chars,
    table.concat(parts, " "), tr, #trains, valid(pawn) and pawn:GetClass():GetFName():ToString() or "none"))
  return wp, net
end

-- Who controls what: each PlayerController's pawn + view target, each character's controller.
local function who(tag)
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) then
      local pawn = safe(function() return pc.Pawn end)
      local vt = safe(function() return pc:GetViewTarget() end)
      log(string.format("WHO[%s] pc=%s local=%s pawn=%s viewtarget=%s", tag, pc:GetFName():ToString(),
        tostring(safe(function() return pc:IsLocalController() end, "?")),
        valid(pawn) and pawn:GetFName():ToString() or "none", valid(vt) and vt:GetFName():ToString() or "none"))
    end
  end
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) then
      local c = safe(function() return ch.Controller end)
      local cm = safe(function() return ch.CharacterMovement end)
      log(string.format("WHO[%s] char=%s controller=%s role=%s remote=%s local=%s mode=%s maxwalk=%s cmactive=%s ignoremove=%s", tag, ch:GetFName():ToString(),
        valid(c) and c:GetFName():ToString() or "none", tostring(safe(function() return ch.Role end, "?")),
        tostring(safe(function() return ch.RemoteRole end, "?")),
        tostring(safe(function() return ch:IsLocallyControlled() end, "?")),
        tostring(safe(function() return cm.MovementMode end, "?")), tostring(safe(function() return cm.MaxWalkSpeed end, "?")),
        tostring(safe(function() return cm:IsActive() end, "?")),
        tostring(valid(c) and safe(function() return c:IsMoveInputIgnored() end, "?") or "-")))
    end
  end
end

-- Bot input: push the pawn this guest controls (or views) forward. Returns what it pushed.
local function bot_walk()
  local pc = local_pc(); if not pc then return "no pc" end
  local p = safe(function() return pc.Pawn end)
  if not valid(p) then p = safe(function() return pc:GetViewTarget() end) end
  if not valid(p) then return "no pawn/viewtarget" end
  -- The game's own W handler (BP_NMCharacter_C input axis event), same path as a key press,
  -- but needs no window focus. Fallback: raw AddMovementInput.
  local ok, err = pcall(function() p:InpAxisEvt_MoveForward_K2Node_InputAxisEvent_3(1.0) end)
  if ok then return p:GetFName():ToString() .. " axis ok" end
  local fwd = safe(function() return p:GetActorForwardVector() end)
  if not fwd then return "no forward vector on " .. p:GetFName():ToString() end
  local ok2, err2 = pcall(function() p:AddMovementInput(fwd, 1.0, true) end)
  return p:GetFName():ToString() .. " axis failed (" .. tostring(err) .. "), raw " .. (ok2 and "ok" or tostring(err2))
end

local function in_menu(wp) return wp == nil or wp:find("MainMenu") or wp:find("Pre%-MenuLevel") end

-- Menu walker: the first-run flow can stack several screens. Each tick press the first
-- visible screen's "go on" button, from the most specific dialog to the main menu.
-- (Reset saves only ever runs inside the per-run -userdir, never the owner's saves.)
local MENU_STEPS = {
  { "Main_Languages_C", "BndEvt__Main_Languages_English_K2Node_ComponentBoundEvent_27_OnButtonPressedEvent__DelegateSignature" },
  { "Main_Settings_ControlPreferences_C", "BndEvt__Main_Settings_ControlPreferences_ContinueButton_K2Node_ComponentBoundEvent_11_OnButtonPressedEvent__DelegateSignature" },
  { "Main_ResetSaves_C", "BndEvt__Main_QuitGame_YesButton_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature" },
  { "Main_MainMenu_C", "BndEvt__Main_MainMenu_NewGameButton_K2Node_ComponentBoundEvent_9_OnButtonPressedEvent__DelegateSignature" },
}
local function visible_widget(cls)
  for _, w in ipairs(FindAllOf(cls) or {}) do
    if valid(w) and not w:GetFullName():find("Default__") then
      local inv = safe(function() return w:IsInViewport() end, false)
      local vis = safe(function() return w:IsVisible() end, false)
      if inv and vis then return w end
    end
  end
end
local pressed = {}
local function walk_menu()
  local seen = {}
  for _, s in ipairs(MENU_STEPS) do if visible_widget(s[1]) then table.insert(seen, s[1]) end end
  log("menu visible: [" .. table.concat(seen, ", ") .. "]")
  for _, s in ipairs(MENU_STEPS) do
    local w = visible_widget(s[1])
    if w then
      pressed[s[1]] = (pressed[s[1]] or 0) + 1
      if pressed[s[1]] > 3 then log("already pressed " .. s[1] .. " 3x, still visible"); return false end
      log("pressing " .. s[1] .. " -> " .. s[2])
      local ok, err = pcall(function() w[s[2]](w) end)
      if not ok then log("  press failed: " .. tostring(err)) end
      return true
    end
  end
  return false
end

local shots = 0
-- Test screenshots are off unless a test asks for them (run_pair.ps1 -Shots).
local function shot(tag)
  if os.getenv("COOP_SHOTS") ~= "1" then return end
  shots = shots + 1
  console("HighResShot 960x540")
  log("screenshot #" .. shots .. " (" .. tag .. ")")
end

-- Host: from the menu, open the island directly as a listen server -> wait for the guest.
-- (Calling the New Game button handler from Lua did nothing; see NOTES.md.)
-- Guest: wait at the menu until the host is listening -> open host address.
local MAP = os.getenv("COOP_MAP") or "/Game/Island_a_Landscape/Maps/Photorealistic_Island"
-- Co-op services, the same in normal play and in tests. Called every 3 s on the game thread.
local function host_services(conns)
  local sync = require("sync")
  local rs = require("respawn")
  rs.install(log, "host")
  rs.tick(log, function() require("players").fix_remote(log) end)
  if conns == 0 then return end
  sync.install_host(log)
  require("players").fix_remote(log)
  require("avatar").apply(log)
  require("progress").install(log, "host", function(m) sync.send(log, m) end)
  require("turret").install(log, function(m) sync.send(log, m) end)
  require("story").install(log, "host", function(m) sync.send(log, m) end, function(m, from) sync.send_except(log, m, from) end)
  if os.getenv("COOP_RETARGET") ~= "0" then local en = require("enemies"); en.install(log); en.retarget(log) end
  if not M_stream then
    M_stream = true
    local sched = require("sched"); sched.install(log)
    sched.every("train_stream", 0.1, function() sync.host_tick(log) end)
    log("host: train stream on")
  end
end
local function guest_services()
  local sy = require("sync")
  if not M_guest_svc then
    M_guest_svc = true
    sy.install_guest(log); sy.forward_train_input(log)
    require("respawn").install(log, "guest", function(m) sy.guest_send(log, m) end)
    require("progress").install(log, "guest", function(m) sy.guest_send(log, m) end)
    require("turret").install(log, function(m) sy.guest_send(log, m) end)
    require("story").install(log, "guest", function(m) sy.guest_send(log, m) end)
  end
  require("respawn").watch_screens(log)
end

-- Normal play (no test harness): host opens its saved game as a listen server, guests
-- join by address. Everything the tests check runs here too, without the test steps.
if not SYNC then
  local phase, phase_t = "boot", 0
  local function go(p) log("phase " .. phase .. " -> " .. p); phase = p; phase_t = 0 end
  LoopAsync(3000, function()
    phase_t = phase_t + 3
    ExecuteInGameThread(function()
      if ROLE == "guest" and phase == "joining" and phase_t < 15 then return end
      local wp, net = status(phase)
      if ROLE == "host" then
        if phase == "boot" and phase_t >= 9 and FindFirstOf("Main_MainMenu_C") then
          dump_driver_defs(NET == "ip"); go("listen"); console("open " .. MAP .. "?listen")
        elseif phase == "listen" and net:find("^listen") and not in_menu(wp) then
          log("hosting on " .. wp); go("serve")
        elseif phase == "serve" then
          if in_menu(wp) then log("back in the menu: hosting stopped"); go("stopped"); return end
          host_services(tonumber(net:match("conns=(%d+)")) or 0)
        end
      elseif ROLE == "guest" then
        if phase == "boot" and phase_t >= 9 and FindFirstOf("Main_MainMenu_C") then
          dump_driver_defs(NET == "ip"); go("joining"); console("open " .. HOST_ADDR)
        elseif phase == "joining" then
          if net:find("^client") and not in_menu(wp) then log("joined " .. HOST_ADDR .. " " .. wp); go("joined")
          elseif phase_t >= 90 then log("could not reach the host at " .. HOST_ADDR .. ", retrying"); go("boot") end
        elseif phase == "joined" then
          if in_menu(wp) then log("disconnected: back to the menu, joining again"); M_early_ready, M_vt_ok = nil, 0; require("story").guest_reset(log); go("boot"); return end
          local sy = require("sync")
          guest_services()
          local st = require("story").guest_join_step(log)
          if st == "reload" then
            log("story: loading the world again with the host's story")
            M_early_ready, M_vt_ok = nil, 0; go("joining"); console("open " .. HOST_ADDR); return
          end
          if st == "wait" then return end
          -- the host hands over the character once the guest's own intro has run. The intro
          -- is over when our camera rests on a player character (the boat intro uses its own
          -- camera); 6 s of that -> ready. 45 s / 60 s stay as the fallback.
          local pc = local_pc()
          local vt = pc and safe(function() return pc:GetViewTarget() end)
          local pawn = pc and safe(function() return pc.Pawn end)
          -- the guest has a pawn right after joining (run 194350), so look at the camera:
          -- on our own pawn = the boat intro's camera is gone
          local on_char = valid(vt) and valid(pawn) and vt:GetFullName() == pawn:GetFullName()
          M_vt_ok = on_char and (M_vt_ok or 0) + 3 or 0
          if phase_t >= 12 and M_vt_ok >= 6 and not M_early_ready then
            M_early_ready = true
            log("intro over at " .. phase_t .. " s (camera on our character) -> ready")
            sy.guest_send(log, "ready")
          end
          if (phase_t == 45 or phase_t == 60) and not M_early_ready then sy.guest_send(log, "ready") end
          if phase_t == 60 and M_early_ready then sy.guest_send(log, "ready") end   -- once more, in case the intro took it back
          if phase_t >= 45 or M_early_ready then require("avatar").apply(log) end
          if phase_t == 66 then
            local pc = local_pc()
            if pc and not valid(safe(function() return pc.Pawn end)) then
              local vt = safe(function() return pc:GetViewTarget() end)
              if valid(vt) then log("still no pawn -> local ClientRestart"); pcall(function() pc:ClientRestart(vt) end) end
            end
          end
        end
      end
    end)
    return false
  end)
  return
end

local phase, t, phase_t = "boot", 0, 0
local function go(p) log("phase " .. phase .. " -> " .. p); phase = p; phase_t = 0 end

LoopAsync(3000, function()
  t = t + 3; phase_t = phase_t + 3
  if t % 30 == 0 then log("heartbeat t=" .. t .. " (async thread)") end
  ExecuteInGameThread(function()
    -- skip the FindAllOf-heavy status while the guest loads the host's map
    if ROLE == "guest" and phase == "joining" and phase_t < 15 then return end
    local wp, net = status(phase)
    if ROLE == "host" then
      if phase == "boot" and phase_t >= 9 and FindFirstOf("Main_MainMenu_C") then
        dump_driver_defs(NET == "ip"); go("listen")
        console("open " .. MAP .. "?listen")
      elseif phase == "listen" then
        if net:find("^listen") and not in_menu(wp) and phase_t >= 20 then
          shot("host listening"); touch("host_ready"); log("host listening on " .. wp .. ", ready file written"); go("wait_guest")
        end
        if phase_t >= 180 then log("FAIL: host not listening"); shot("host failed"); touch("host_failed"); go("done") end
      elseif phase == "wait_guest" and TEST == "explore" then
        -- die twice: do the hooks still fire for the character RestartPlayer made?
        local rs = require("respawn")
        rs.install(log, "host")
        rs.tick(log)
        local me = require("explore").own(log)
        if phase_t % 3 == 0 and phase_t >= 33 then
          log(string.format("EXPLORE t=%d me=%s class=%s", phase_t, me and me:GetFName():ToString() or "none",
            me and safe(function() return me:GetClass():GetFullName() end, "?") or "-"))
        end
        if (phase_t == 39 or phase_t == 60) and me then log("EXPLORE die"); pcall(function() me:Damage(1000.0, 1.0, nil) end) end
        if phase_t == 81 and me then log("EXPLORE hit 10"); pcall(function() me:Damage(10.0, 1.0, nil) end) end
        if phase_t >= 87 then touch("host_done"); go("done") end
      elseif phase == "wait_guest" and TEST == "charles_probe" then
        -- host only: what makes Charles move? (state dump + function trace, train ride, walk off)
        local en, train = require("enemies"), require("train")
        if phase_t == 30 then
          require("trace").class(log, "/Game/_GAME/Blueprints/TrainBlueprints/CharlesCharacter.CharlesCharacter_C", 8)
          local ac = FindFirstOf("CharlesAIController_C")
          if valid(ac) then require("trace").class(log, ac:GetClass():GetFullName():match("^%S+%s+(.+)$") or "", 8) end
        end
        if phase_t >= 27 and phase_t % 6 == 0 then en.charles_state(log, "t=" .. phase_t) end
        if phase_t == 45 then log("CPROBE drive"); train.drive_long(log, 60, function() log("CPROBE drive done") end) end
        if phase_t == 120 then
          local me = require("explore").own(log)
          local ch = FindFirstOf("CharlesCharacter_C")
          if me and valid(ch) then
            local l, c = me:K2_GetActorLocation(), ch:K2_GetActorLocation()
            local dx, dy = c.X - l.X, c.Y - l.Y
            local d = math.sqrt(dx * dx + dy * dy)
            log(string.format("CPROBE host to 6000 from Charles (was %.0f)", d))
            pcall(function() ch:K2_SetActorLocation({ X = l.X + dx / d * 6000, Y = l.Y + dy / d * 6000, Z = c.Z }, false, {}, true) end)
          end
        end
        if phase_t == 126 or phase_t == 150 then shot("charles probe") end
        if phase_t >= 180 then touch("host_done"); go("done") end
      elseif phase == "wait_guest" and TEST == "lever_probe" then
        if phase_t >= 45 and not M_probe_started then   -- after the boat intro hands over the character
          M_probe_started = true
          require("train").lever_probe(log, function() touch("host_done") end)
        end
      elseif phase == "wait_guest" and TEST == "train_drive" then
        if phase_t >= 15 and not M_train_started then
          M_train_started = true
          log("TEST train_drive starting")
          require("train").drive_experiment(log, function() touch("host_done"); log("TEST train_drive finished") end)
        end
      elseif phase == "wait_guest" then
        local conns = tonumber(net:match("conns=(%d+)")) or 0
        if conns > 0 and phase_t % 15 == 0 then shot("host with guest") end
        if TEST:find("^story") and conns > 0 then
          require("sync").install_host(log)
          require("story").install(log, "host", function(m) require("sync").send(log, m) end, function(m, from) require("sync").send_except(log, m, from) end)
        end
        if exists("guest_intro_done") and not M_restart then
          M_restart = true
          for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(pc) and not safe(function() return pc:IsLocalController() end, true) then
              local pawn = safe(function() return pc.Pawn end)
              if valid(pawn) then
                log("host -> ClientRestart(" .. pawn:GetFName():ToString() .. ") for " .. pc:GetFName():ToString())
                local ok, err = pcall(function() pc:ClientRestart(pawn) end)
                if not ok then log("  ClientRestart failed: " .. tostring(err)) end
              end
            end
          end
        end
        if M_restart then
          -- always on: movement fix, bodies for other players, guest -> host messages,
          -- train state to the guest at 10 Hz
          host_services(1)
        end
        if TEST == "coop" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          local sync = require("sync")
          local function remote_char()
            for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
              if valid(ch) and not safe(function() return ch:IsLocallyControlled() end, true) then return ch end
            end
          end
          if M_play_t == 6 then
            local me = require("explore").own(log)
            if me then
              local l, f, r = me:K2_GetActorLocation(), me:GetActorForwardVector(), me:K2_GetActorRotation()
              sync.send(log, string.format("board|%.2f|%.2f|%.2f|%.1f", l.X + f.X * 300, l.Y + f.Y * 300, l.Z + 20, r.Yaw + 180))
            end
          end
          if M_play_t == 12 then shot("coop host sees guest") end
          if M_play_t == 15 then log("COOP step host fetch"); require("progress").fetch_test(log) end
          if M_play_t == 27 then log("COOP step guest fetch"); sync.send(log, "fetch") end
          if M_play_t == 39 then log("COOP step guest dies on its own machine"); sync.send(log, "die") end
          if M_play_t == 54 then
            local rc = remote_char()
            log("COOP step guest dies on the host: " .. tostring(rc and rc:GetFName():ToString()))
            if rc then pcall(function() rc:Damage(1000.0, 1.0, nil) end) end
          end
          if M_play_t == 69 then
            log("COOP step host dies")
            local me = require("explore").own(log)
            if me then pcall(function() me:Damage(1000.0, 1.0, nil) end) end
          end
          if M_play_t == 84 then log("COOP step guest dies again on its own machine"); sync.send(log, "die") end
          if M_play_t == 99 then
            log("COOP step host dies again")
            local me = require("explore").own(log)
            if me then pcall(function() me:Damage(1000.0, 1.0, nil) end) end
          end
          if M_play_t == 72 or M_play_t == 90 or M_play_t == 108 then shot("coop host after death") end
          if M_play_t % 3 == 0 then
            local pr = require("progress")
            log(string.format("COOP t=%d progress tx=%d rx=%d", M_play_t, pr.n_tx, pr.n_rx))
          end
          if M_play_t == 117 then touch("host_drive_done") end
        end
        if TEST == "cultists" and M_restart then
          -- do kills show on both machines? host kills one, guest kills another
          M_play_t = (M_play_t or 0) + 3
          local en, sync = require("enemies"), require("sync")
          local cs = {}
          for _, e in ipairs(FindAllOf("Cultist_C") or {}) do if valid(e) and not e:GetFullName():find("Default__") then table.insert(cs, e) end end
          table.sort(cs, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
          local A, B = cs[1], cs[2]
          if M_play_t == 9 and A then log("CULTTEST host kills " .. A:GetFName():ToString()); pcall(function() A:Damage(100.0, 1.0, nil) end) end
          if M_play_t == 18 and B then log("CULTTEST guest kills " .. B:GetFName():ToString()); sync.send(log, "killcultist|" .. B:GetFName():ToString()) end
          if M_play_t % 6 == 0 then
            for _, e in ipairs({ A, B }) do if valid(e) then log("CULTTEST host " .. en.describe(e)) end end
          end
          if M_play_t == 15 then require("respawn").mark_false_death(12); local me = require("explore").own(log); if me then log("CULTTEST host false death"); pcall(function() me:Damage(1000.0, 1.0, nil) end) end end
          if M_play_t == 45 then touch("host_drive_done") end
        end
        if TEST == "story_sweep" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          require("story").sweep_test_host(log, M_play_t, require("sync"), touch)
        end
        if TEST == "story_end" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          require("story").end_test_host(log, M_play_t, require("sync"), touch, shot)
        end
        if TEST == "story" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          require("story").test_host(log, M_play_t, require("sync"), touch)
        end
        if TEST == "guns" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          local en, sync, train = require("enemies"), require("sync"), require("train")
          if M_play_t == 6 then
            -- the train's own spawn spot: 300 units in front of the host could be on the
            -- rails ahead of the train (the train hardly moved in 181147)
            local rs = require("respawn")
            local spot = rs.train_spot(1)
            local t0 = train.find()
            if spot and t0 then sync.send(log, string.format("board|%.2f|%.2f|%.2f|%.1f", spot.X, spot.Y, spot.Z, t0:K2_GetActorRotation().Yaw)) end
          end
          if M_play_t == 12 then log("GUNTEST drive"); train.drive_long(log, 75, function() log("GUNTEST drive done") end) end
          local ch = FindFirstOf("CharlesCharacter_C")
          local t = train.find()
          local d = (valid(ch) and t) and (function() local a, b = ch:K2_GetActorLocation(), t:K2_GetActorLocation(); return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2) end)() or -1
          if M_play_t >= 12 and valid(ch) then
            local gr = t and safe(function() return t["Gun Rotator"]:K2_GetComponentRotation() end)
            if gr then log(string.format("GUNTEST host gun rotator yaw=%.0f pitch=%.0f mirrored=%s", gr.Yaw, gr.Pitch, tostring(require("turret").n))) end
            if t then log("GUNTEST host fx " .. require("guns").fx_report(t)) end
            log(string.format("GUNTEST t=%d charles-train=%.0f recent=%s hit=%s %s", M_play_t, d, tostring(safe(function() return ch["Recent Damage"] end)),
              tostring(safe(function() return ch["Was Just Hit"] end)), en.describe(ch)))
          end
          if not M_gun_sent and M_play_t >= 24 and ((d > 0 and d < 7000) or M_play_t >= 45) then
            M_gun_sent = true
            log("GUNTEST guest opens fire"); sync.send(log, "gunfire|30")
            -- (teleporting Charles next to the train got him stuck against it and stopped
            -- the train, run 174321: let him come by himself)
            M_gun_t = M_play_t
            sync.send(log, "hitcharles|7.5")
          end
          if M_play_t == 42 or M_play_t == 54 then shot("guns") end
          if M_play_t == 96 then touch("host_drive_done") end
        end
        if TEST == "deathcall" and M_restart then
          -- repro for the guest crash after Charles catches it (runs 153031, 154123, 155123)
          -- COOP_DC: "die" = also kill the guest on its machine (what 0.3 dev did), "none" = only Death call
          M_play_t = (M_play_t or 0) + 3
          local rc
          for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
            if valid(ch) and not safe(function() return ch:IsLocallyControlled() end, true) then rc = ch end
          end
          if M_play_t == 12 or M_play_t == 60 then
            local v = os.getenv("COOP_DC") or "die"
            log("DEATHCALL step variant=" .. v .. " on " .. tostring(rc and rc:GetFName():ToString()))
            if rc then
              require("respawn").mark_false_death(12)
              local ok, err = pcall(function() rc["Death call"](rc) end)
              log("DEATHCALL -> " .. (ok and "ok" or tostring(err)))
              if v == "die" then require("sync").send(log, "die") end
            end
          end
          if M_play_t % 6 == 0 then log("DEATHCALL t=" .. M_play_t) end
          if M_play_t == 105 then touch("host_drive_done") end
        end
        if TEST == "enemies" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          local en, sync, train = require("enemies"), require("sync"), require("train")
          local function remote_char()
            for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
              if valid(ch) and not safe(function() return ch:IsLocallyControlled() end, true) then return ch end
            end
          end
          if M_play_t == 6 then
            local me = require("explore").own(log)
            if me then
              local l, f, r = me:K2_GetActorLocation(), me:GetActorForwardVector(), me:K2_GetActorRotation()
              sync.send(log, string.format("board|%.2f|%.2f|%.2f|%.1f", l.X + f.X * 300, l.Y + f.Y * 300, l.Z + 20, r.Yaw + 180))
            end
          end
          if M_play_t % 12 == 0 then en.scan(log, "host t=" .. M_play_t) end
          if M_play_t % 6 == 0 then log("ENEMYTEST train " .. train.state() .. " " .. train.flags()) end
          -- 1. Charles sleeps (MovementMode 0) until the train moves: drive
          if M_play_t == 12 then log("ENEMYTEST drive"); train.drive_long(log, 45, function() log("ENEMYTEST drive done") end) end
          M_charles = FindFirstOf("CharlesCharacter_C")
          -- 2. drop the guest between Charles and the train: Charles must switch to it
          if M_play_t == 57 and os.getenv("COOP_TRACE") == "1" then
            require("trace").class(log, "/Game/_GAME/Blueprints/TrainBlueprints/CharlesCharacter.CharlesCharacter_C", 6)
            require("trace").class(log, "/Game/_GAME/Blueprints/DeathScreen.DeathScreen_C", 6)
            require("trace").class(log, "/Game/NaturalMovementV3/Blueprint/Character/BP_NMCharacter.BP_NMCharacter_C", 4)
          end
          if M_play_t == 60 and valid(M_charles) then
            local t = train.find()
            local c, tl = M_charles:K2_GetActorLocation(), t and t:K2_GetActorLocation()
            if tl then
              local dx, dy = tl.X - c.X, tl.Y - c.Y
              local d = math.sqrt(dx * dx + dy * dy)
              local k = math.min(2000, d / 2) / d
              log(string.format("ENEMYTEST guest off the train near Charles (Charles-train %.0f)", d))
              sync.send(log, string.format("board|%.2f|%.2f|%.2f|0", c.X + dx * k, c.Y + dy * k, c.Z + 400))
            end
          end
          if valid(M_charles) and M_play_t >= 12 then log("CHARLESTEST " .. en.describe(M_charles)) end
          if valid(M_charles) and M_play_t % 6 == 0 then log("CHARLESBB " .. en.blackboard(M_charles)) end
          if valid(M_charles) and M_play_t % 3 == 0 then log("CHARLESNET " .. en.net_state(M_charles)) end
          if M_play_t % 15 == 0 then
            for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
              if valid(pc) and not safe(function() return pc:IsLocalController() end, true) then
                local vt = safe(function() return pc:GetViewTarget() end)
                local cam = safe(function() return pc.PlayerCameraManager end)
                local camloc = valid(cam) and safe(function() return cam:GetCameraLocation() end)
                local vl = valid(vt) and safe(function() return vt:K2_GetActorLocation() end)
                log(string.format("VIEW guest pc=%s viewtarget=%s at %s camera=%s pcloc=%s", pc:GetFName():ToString(),
                  valid(vt) and vt:GetFName():ToString() or "none", vl and string.format("(%.0f %.0f %.0f)", vl.X, vl.Y, vl.Z) or "?",
                  camloc and string.format("(%.0f %.0f %.0f)", camloc.X, camloc.Y, camloc.Z) or "?",
                  (function() local l = safe(function() return pc:K2_GetActorLocation() end); return l and string.format("(%.0f %.0f %.0f)", l.X, l.Y, l.Z) or "?" end)()))
              end
            end
          end
          -- 3. a cultist next to the (now distant) guest, aimed at the host: must switch
          if M_play_t == 105 then
            local rc = remote_char()
            local pick
            for _, e in ipairs(en.list()) do if e:GetClass():GetFName():ToString() == "Cultist_C" and not safe(function() return e.Dead end, false) then pick = e; break end end
            if rc and pick then M_enemy = pick; en.bring(log, pick, rc, 1500, require("explore").own(log)) else log("ENEMYTEST no cultist to bring") end
          end
          if M_enemy and valid(M_enemy) then log("ENEMYTEST " .. en.describe(M_enemy)) end
          if M_play_t == 12 then local c1 = FindFirstOf("Cultist_C"); if valid(c1) then log("CULTISTBB " .. en.blackboard(c1)) end end
          if M_enemy and valid(M_enemy) and M_play_t % 6 == 0 then log("CULTISTBB " .. en.blackboard(M_enemy)) end
          if M_play_t == 24 or M_play_t == 45 or M_play_t == 66 or M_play_t == 75 or M_play_t == 111 or M_play_t == 126 then shot("enemies") end
          if M_play_t == 153 then touch("host_drive_done") end
        end
        if TEST == "play" and M_restart then
          M_play_t = (M_play_t or 0) + 3
          local sync, train = require("sync"), require("train")
          if M_play_t == 9 then
            -- put the guest 400 units in front of the host, facing it
            local me
            for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
              if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then me = ch end
            end
            if me then
              local l, f, r = me:K2_GetActorLocation(), me:GetActorForwardVector(), me:K2_GetActorRotation()
              local x, y, z = l.X + f.X * 400, l.Y + f.Y * 400, l.Z + 20
              log(string.format("PLAY host at %s yaw %.0f, guest to (%.0f %.0f %.0f)", vec(l), r.Yaw, x, y, z))
              sync.send(log, string.format("board|%.2f|%.2f|%.2f|%.1f", x, y, z, r.Yaw + 180))
            end
          end
          if M_play_t == 15 then shot("host sees guest"); require("avatar").dump_anim(log); sync.send(log, "walk|1") end
          if M_play_t == 18 then shot("host sees guest walking") end
          if M_play_t == 21 then require("trace").class(log, "/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C", 15) end
          if M_play_t == 24 then log("PLAY guest lever test; " .. train.state()); sync.send(log, "levers") end
          if M_play_t >= 24 and M_play_t % 3 == 0 then log("PLAY host train " .. train.state() .. " guest_msgs=" .. tostring(sync.hrx or 0)) end
          if M_play_t == 60 then touch("host_drive_done") end
        end
        if (TEST == "train_sync" or TEST == "train_long" or TEST == "train_ride") and M_restart and not M_sync_started then
          M_sync_t = (M_sync_t or 0) + 3
          if M_sync_t >= 9 then
            M_sync_started = true
            local sync, train = require("sync"), require("train")
            log("TEST train_sync: host streams train state at 10 Hz and drives the train; " .. train.replication())
            local function finished()
              ExecuteInGameThread(function() log("TRAINSYNC host final " .. train.state()) end)
              touch("host_drive_done")
            end
            if TEST == "train_ride" then
              train.board(log)
              for _, d in ipairs(train.board_spots or {}) do sync.send(log, string.format("board|%.2f|%.2f|%.2f", d.X, d.Y, d.Z)) end
              ExecuteWithDelay(5000, function() train.drive_long(log, 60, finished) end)
            elseif TEST == "train_long" then train.drive_long(log, 120, finished) else train.drive_experiment(log, finished) end
          end
        end
        if (TEST == "train_sync" or TEST == "train_long" or TEST == "train_ride") and phase_t % 3 == 0 and M_sync_started then
          log("TRAINSYNC host " .. require("train").state())
          if TEST == "train_ride" then log("RIDE host " .. require("train").ride_report()) end  -- already on the game thread: nesting ExecuteInGameThread crashed (runs 182105, 182331)
        end
        if exists("guest_walk_start") and not M_walk_s then M_walk_s = true; who("host walk start") end
        if exists("guest_walk_end") and not M_walk_e then M_walk_e = true; who("host walk end") end
        if exists("guest_done") then shot("host final"); go("done"); touch("host_done") end
        if phase_t >= (TEST:find("^story_") and 720 or 300) then log("timeout waiting for guest"); touch("host_done"); go("done") end
      end
    elseif ROLE == "guest" then
      if phase == "boot" and phase_t >= 9 and FindFirstOf("Main_MainMenu_C") then go("wait_host") end
      if phase == "wait_host" then
        if exists("host_failed") then log("host failed, giving up"); touch("guest_done"); go("done")
        elseif exists("host_ready") then dump_driver_defs(NET == "ip"); console("open " .. HOST_ADDR); go("joining") end
      elseif phase == "joining" then
        if net:find("^client") and not in_menu(wp) then log("JOINED host world " .. wp); go("joined") end
        if phase_t >= 120 then log("FAIL: guest did not join within 120 s"); shot("guest join failed"); touch("guest_done"); go("done") end
      elseif phase == "joined" and ((TEST == "train_sync" or TEST == "train_long" or TEST == "train_ride") or TEST == "play" or TEST == "coop" or TEST == "enemies" or TEST == "deathcall" or TEST == "guns" or TEST == "cultists" or TEST == "story" or TEST == "story_end" or TEST == "story_sweep") then
        if phase_t >= 3 then guest_services() end
        if TEST:find("^story") and phase_t >= 6 then
          require("story").shot = shot
          local st = require("story").guest_join_step(log)
          if st == "reload" then
            log("story: loading the world again with the host's story")
            go("joining"); console("open " .. HOST_ADDR); return
          end
          if st == "wait" then return end
        end
        if phase_t >= 51 then require("avatar").apply(log) end
        if (TEST == "play" or TEST == "coop" or TEST == "guns") and phase_t >= 51 and phase_t % 6 == 0 then shot("guest play") end
        if TEST == "cultists" and phase_t >= 51 and phase_t % 6 == 0 then
          local cs = {}
          for _, e in ipairs(FindAllOf("Cultist_C") or {}) do if valid(e) and not e:GetFullName():find("Default__") then table.insert(cs, e) end end
          table.sort(cs, function(a, b) return a:GetFName():ToString() < b:GetFName():ToString() end)
          for i = 1, 2 do if cs[i] then log("CULTTEST guest " .. require("enemies").describe(cs[i])) end end
        end
        if TEST == "enemies" and phase_t >= 51 and phase_t % 6 == 0 then require("enemies").scan(log, "guest t=" .. phase_t); shot("guest enemies") end
        if TEST == "enemies" and phase_t >= 51 and phase_t % 3 == 0 then
          local c = FindFirstOf("CharlesCharacter_C")
          if c then log("CHARLESNET guest " .. require("enemies").describe(c) .. " " .. require("enemies").net_state(c)) end
        end
        if TEST == "coop" and phase_t % 3 == 0 then
          require("sync").guest_send(log, "ping|" .. phase_t .. "|" .. os.date("%H:%M:%S"))
          local pr = require("progress")
          local pc = safe(function() return FindFirstOf("PlayerController") end)
          log(string.format("COOP guest t=%d pawn=%s progress tx=%d rx=%d", phase_t,
            tostring(pc and valid(safe(function() return pc.Pawn end))), pr.n_tx, pr.n_rx))
        end
        if phase_t == 51 then touch("guest_intro_done") end
        if phase_t >= 51 and TEST ~= "play" then
          local sy = package.loaded["sync"]
          log(string.format("TRAINSYNC guest rx=%d applied=%d rails=%d %s %s", sy and sy.rx or -1, sy and sy.applied or -1, sy and sy.rail_changes or 0, sy and sy.err_summary() or "", require("train").state()))
        end
        if TEST == "train_ride" and phase_t >= 51 then log("RIDE guest " .. require("train").ride_report()) end
        if phase_t % 30 == 0 or (TEST == "train_ride" and phase_t % 9 == 0) then shot("guest train sync") end
        if exists("host_drive_done") and not M_gdone then M_gdone = phase_t end
        if (M_gdone and phase_t >= M_gdone + 6) or phase_t >= 300 then log("guest observation finished"); touch("guest_done"); go("done") end
      elseif phase == "joined" then
        if phase_t >= 3 then guest_services() end
        if phase_t >= 51 then require("avatar").apply(log) end
        if phase_t == 15 or phase_t == 57 or phase_t == 78 then shot("guest in host world") end
        if phase_t == 51 then who("guest before restart"); touch("guest_intro_done") end
        if phase_t == 57 then
          who("guest after host restart")
          local pc = local_pc()
          if pc and not valid(safe(function() return pc.Pawn end)) then
            local vt = safe(function() return pc:GetViewTarget() end)
            if valid(vt) then
              log("guest still has no pawn -> local ClientRestart(" .. vt:GetFName():ToString() .. ")")
              local ok, err = pcall(function() pc:ClientRestart(vt) end)
              if not ok then log("  local ClientRestart failed: " .. tostring(err)) end
            end
          else log("guest has a pawn after the host's ClientRestart") end
        end
        if phase_t == 60 or phase_t == 78 then who("guest") end
        if phase_t == 60 then touch("guest_walk_start") end
        if phase_t == 60 then
          log("bot_walk first: " .. bot_walk())
          require("bot").walk(log, 9)
        end
        if phase_t == 69 then touch("guest_key_start"); log("lua walk window over; launcher now holds W in the guest window") end
        if phase_t == 78 then touch("guest_walk_end") end
        if phase_t >= 90 then log("guest observation finished"); touch("guest_done"); go("done") end
      end
    end
  end)
  return false
end)

-- (v5: removed NotifyOnNewObject on NetConnection; guest crashed inside UE4SS.dll during the
-- map load in run 20261030-123609 and that hook was the only per-object callback.)
