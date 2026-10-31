-- Host -> guest state channel over existing engine RPCs (technique from genesis-alpha-one-coop, MIT):
--   host -> guest : PlayerController:ClientMessage("COOP|<msg>")   (reliable client RPC with a string)
-- First user: the train. The host owns the train; the guest's copy follows the host's.
local M = { rx = 0, applied = 0, last_err = nil }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end
local train = require("train")
local fmt = string.format

local function remote_pcs()
  local out = {}
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and not safe(function() return pc:IsLocalController() end, true) then table.insert(out, pc) end
  end
  return out
end

-- Host: one train message. Numbers with %.3f use "." whatever the Windows locale (Lua's
-- string.format follows the C locale, which UE leaves at "C"; checked by the round trip below).
function M.train_msg()
  local t = train.find(); if not t then return nil end
  local l = t:K2_GetActorLocation(); local r = t:K2_GetActorRotation()
  return fmt("train|%.3f|%.3f|%d|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f|%s",
    t["Current Position on Rail"], t["Train Speed"], t["Lever Position"], l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, train.spline_id(t))
end

-- Host: one-off message to every guest.
function M.send(log, msg)
  for _, pc in ipairs(remote_pcs()) do
    local ok, err = pcall(function() pc:ClientMessage("COOP|" .. msg, FName("None"), 0.0) end)
    if not ok then log("sync: send failed: " .. tostring(err)) end
  end
end

function M.host_tick(log)
  local msg = safe(M.train_msg); if not msg then return end
  for _, pc in ipairs(remote_pcs()) do
    local ok, err = pcall(function() pc:ClientMessage("COOP|" .. msg, FName("None"), 0.0) end)
    if not ok and M.last_err ~= tostring(err) then M.last_err = tostring(err); log("sync: ClientMessage failed: " .. M.last_err) end
  end
end

-- Guest: apply a train message to the local train.
function M.apply_train(log, body)
  local f = {}
  for v in body:gmatch("[^|]+") do table.insert(f, v) end
  if #f ~= 11 then log("sync: bad train message (" .. #f .. " fields): " .. body); return end
  local railpos, speed, lever = tonumber(f[2]), tonumber(f[3]), tonumber(f[4])
  local x, y, z, p, yaw, r = tonumber(f[5]), tonumber(f[6]), tonumber(f[7]), tonumber(f[8]), tonumber(f[9]), tonumber(f[10])
  local t = train.find(); if not t then return end
  -- drift oracle: how far the guest's own train got from where the host says it is
  local own = safe(function() return t:K2_GetActorLocation() end)
  if own then
    local d = math.sqrt((own.X - x) ^ 2 + (own.Y - y) ^ 2 + (own.Z - z) ^ 2)
    M.err_n = (M.err_n or 0) + 1; M.err_sum = (M.err_sum or 0) + d
    if d > (M.err_max or 0) then M.err_max = d end
  end
  -- rail first: the train's own tick places it on its spline at railpos, so a stale spline
  -- after a segment change threw it back along the old rail (run 20261030-141220)
  if train.set_spline(t, f[11], log) then M.rail_changes = (M.rail_changes or 0) + 1 end
  safe(function() t["Current Position on Rail"] = railpos end)
  safe(function() t["Train Speed"] = speed end)
  safe(function() t["Lever Position"] = lever end)
  local ok, err = pcall(function()
    t:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z }, { Pitch = p, Yaw = yaw, Roll = r }, false, {}, true)
  end)
  if not ok then
    ok, err = pcall(function()
      t:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
      t:K2_SetActorRotation({ Pitch = p, Yaw = yaw, Roll = r }, true)
    end)
  end
  if ok then M.applied = M.applied + 1 elseif M.last_err ~= tostring(err) then M.last_err = tostring(err); log("sync: apply failed: " .. M.last_err) end
end

function M.err_summary()
  if not M.err_n then return "err n=0" end
  return fmt("err n=%d avg=%.0f max=%.0f", M.err_n, M.err_sum / M.err_n, M.err_max)
end

-- Guest -> host: PlayerController:ServerExecRPC(FString) is a reliable server RPC that
-- shipping builds keep but ignore (the console command only runs in development builds),
-- so the string reaches the host's hook and nothing else happens.
function M.guest_send(log, msg)
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and safe(function() return pc:IsLocalController() end, false) then
      local ok, err = pcall(function() pc:ServerExecRPC("COOP|" .. msg) end)
      M.tx = (M.tx or 0) + 1
      if not ok then log("sync: ServerExecRPC failed: " .. tostring(err)) end
      return
    end
  end
end

local TRAIN_FN = "/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C:"

-- Host: receive guest messages. Interactions are replayed on the host's train (the guest's
-- train is a local copy that follows the host's), and the train sync sends the result back.
function M.install_host(log)
  if M.host_installed then return end
  M.host_installed = true
  local ok, err = pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ServerExecRPC", function(self, s)
      local pc = self:get()
      -- the guest's own call runs through this hook on its machine too: only the server's
      -- copy of a remote controller counts
      if safe(function() return pc:IsLocalController() end, true) then return end
      local msg = safe(function() return s:get():ToString() end, "")
      if msg:sub(1, 5) ~= "COOP|" then return end
      M.hrx = (M.hrx or 0) + 1
      local body = msg:sub(6)
      ExecuteInGameThread(function() M.host_handle(log, body, pc) end)
    end)
  end)
  log("sync: host hook ServerExecRPC -> " .. (ok and "ok" or tostring(err)))
end

-- Host: a guest has finished loading (its own intro is done): hand it its character.
-- Before this the guest only looks through a camera; ClientRestart gives it the pawn.
function M.restart_guest(log, pc)
  local pawn = safe(function() return pc.Pawn end)
  if not valid(pawn) then log("sync: ready from " .. pc:GetFName():ToString() .. " but it has no pawn yet"); return end
  log("sync: guest ready -> ClientRestart(" .. pawn:GetFName():ToString() .. ") for " .. pc:GetFName():ToString())
  local ok, err = pcall(function() pc:ClientRestart(pawn) end)
  if not ok then log("sync: ClientRestart failed: " .. tostring(err)) end
  -- first time: bring the new player to the train (they start where the story starts)
  M.boarded = M.boarded or {}
  local key = pc:GetFullName()
  if M.boarded[key] then return end
  M.boarded[key] = true
  ExecuteWithDelay(2000, function() ExecuteInGameThread(function()
    local rs = require("respawn")
    local spot = rs.train_spot(rs.player_index(pc))
    if not (spot and valid(pc)) then return end
    log(string.format("sync: bringing %s to the train (%.0f %.0f %.0f)", pc:GetFName():ToString(), spot.X, spot.Y, spot.Z))
    local t = train.find()
    local yaw = t and safe(function() return t:K2_GetActorRotation().Yaw end) or 0
    pcall(function() pc:ClientMessage(string.format("COOP|board|%.2f|%.2f|%.2f|%.1f", spot.X, spot.Y, spot.Z, yaw), FName("None"), 0.0) end)
  end) end)
end

function M.host_handle(log, body, pc)
  local f = {}
  for v in body:gmatch("[^|]+") do table.insert(f, v) end
  if f[1] == "ready" then if valid(pc) then M.restart_guest(log, pc) end
  elseif f[1] == "died" then log("sync: guest reports its death"); require("respawn").queue(log, pc,
    f[4] and { X = tonumber(f[2]), Y = tonumber(f[3]), Z = tonumber(f[4]) } or nil)
  elseif f[1] == "gather" then require("progress").host_gathered_by_guest(log, f[2], pc)
  elseif f[1] == "pickup" and f[2] then
    require("progress").apply_pickup(log, f[2], f[3])
    for _, other in ipairs(remote_pcs()) do
      if not (valid(pc) and other:GetFullName() == pc:GetFullName()) then
        pcall(function() other:ClientMessage("COOP|pickup|" .. f[2] .. "|" .. (f[3] or "None"), FName("None"), 0.0) end)
      end
    end
  elseif f[1] == "ping" then log("sync: ping t=" .. tostring(f[2]) .. " sent " .. tostring(f[3]))
  elseif f[1] == "interact" then train.remote_interact(log, f[2], f[3] == "1")
  elseif f[1] == "release" then train.remote_release(log)
  else log("sync: host got unknown message " .. body) end
end

-- Guest: forward clicks on our own train to the host.
function M.forward_train_input(log)
  if M.fwd_installed then return end
  M.fwd_installed = true
  local ok1, e1 = pcall(function()
    RegisterHook(TRAIN_FN .. "Interact", function(self, comp, gamepad)
      local c = safe(function() return comp:get() end)
      local name = (c and safe(function() return c:IsValid() end, false)) and c:GetFName():ToString() or "none"
      local gp = safe(function() return gamepad:get() end, false) and "1" or "0"
      log("sync: guest clicked train part " .. name .. " -> host")
      M.guest_send(log, "interact|" .. name .. "|" .. gp)
    end)
  end)
  local ok2, e2 = pcall(function()
    RegisterHook(TRAIN_FN .. "Interact Released", function() M.guest_send(log, "release") end)
  end)
  log("sync: guest train input hooks -> " .. (ok1 and "ok" or tostring(e1)) .. ", " .. (ok2 and "ok" or tostring(e2)))
end

function M.install_guest(log)
  local ok, err = pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(self, s)
      local msg = safe(function() return s:get():ToString() end, "")
      if msg:sub(1, 5) ~= "COOP|" then return end
      M.rx = M.rx + 1
      local body = msg:sub(6)
      if body:sub(1, 6) == "train|" then ExecuteInGameThread(function() M.apply_train(log, body) end) end
      if body:sub(1, 6) == "board|" then
        local x, y, z, yaw = body:match("^board|([^|]+)|([^|]+)|([^|]+)|?([^|]*)")
        ExecuteInGameThread(function() train.board_self(log, tonumber(x), tonumber(y), tonumber(z), tonumber(yaw)) end)
      end
      if body:sub(1, 5) == "walk|" then
        local secs = tonumber(body:sub(6)) or 2
        ExecuteInGameThread(function() require("bot").walk(log, secs) end)
      end
      if body == "die" then ExecuteInGameThread(function()
        for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
          if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then pcall(function() ch:Damage(1000.0, 1.0, nil) end) end
        end
      end) end
      if body:sub(1, 7) == "pickup|" then ExecuteInGameThread(function() local n, id = body:match("^pickup|([^|]+)|?([^|]*)"); require("progress").apply_pickup(log, n, id) end) end
      if body:sub(1, 9) == "gathered|" then ExecuteInGameThread(function() require("progress").guest_apply(log, body:sub(10)) end) end
      if body:sub(1, 5) == "hurt|" then ExecuteInGameThread(function() require("respawn").hurt(log, tonumber(body:sub(6)) or 0) end) end
      if body == "fetch" then ExecuteInGameThread(function() require("progress").fetch_test(log) end) end
      if body == "levers" then ExecuteInGameThread(function() train.guest_lever_test(log) end) end
    end)
  end)
  log("sync: guest hook ClientMessage -> " .. (ok and "ok" or tostring(err)))
  train.make_addressable(nil, log)
end
return M
