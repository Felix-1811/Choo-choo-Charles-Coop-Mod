-- Shared progress: one inventory for the group, kept in the host's save.
-- Every pickup in the game ends in easySaveObject_C:"Gather Item"(ItemID, notify). Hooked on
-- every machine:
--   guest picks something up -> "gather|ID" to the host -> host gathers it too (its save is
--   the one that counts) and tells the other guests;
--   host picks something up  -> "gathered|ID" to every guest, so their counters match.
-- World pickups (scraps, dynamite, ...) don't go through Gather Item: ItemPickup_C:Interact
-- itself saves "<ItemID>" = count and "<ItemID>-<PickupName>" = Collected, then destroys the
-- actor (run 20261031-023631). So a pickup is sent as "pickup|<name>|<ItemID>" and the other
-- machines run the same Interact on their copy: everyone gets the item and nobody can
-- collect it a second time.
local M = { applying = false, installed = false, n_tx = 0, n_rx = 0 }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end

local SAVE_FN = "/Game/EasySave/easySaveObject.easySaveObject_C:Gather Item"
local PICKUP = "ItemPickup_C"

local function save_obj() return FindFirstOf("easySaveObject_C") end

local function gather_local(log, id)
  local so = save_obj(); if not valid(so) then log("progress: no save object"); return end
  M.applying = true
  local ok, err = pcall(function() so["Gather Item"](so, FName(id), true) end)
  M.applying = false
  if not ok then log("progress: Gather Item(" .. id .. ") failed: " .. tostring(err)) end
end

-- role "host" or "guest"; send(msg) goes to the host (guest) or to all guests (host)
function M.install(log, role, send)
  if M.installed then return end
  M.installed = true
  M.role, M.send = role, send
  local ok, err = pcall(function()
    RegisterHook(SAVE_FN, function(self, id, notify)
      if M.applying then return end
      local name = safe(function() return id:get():ToString() end, nil)
      if not name or name == "None" then return end
      M.n_tx = M.n_tx + 1
      log("progress: picked up " .. name .. " -> " .. (role == "host" and "guests" or "host"))
      send((role == "host" and "gathered|" or "gather|") .. name)
    end)
  end)
  log("progress: hook Gather Item -> " .. (ok and "ok" or tostring(err)))
  -- the Blueprint path of ItemPickup_C, from a loaded instance
  local o = FindFirstOf(PICKUP)
  local cpath = o and safe(function() return o:GetClass():GetFullName():match("%s(%S+)$") end)
  local ok2, err2 = false, "no ItemPickup_C loaded"
  if cpath then
    ok2, err2 = pcall(function()
      RegisterHook(cpath .. ":Interact", function(self)
        if M.applying then return end
        local a = self:get()
        local name = safe(function() return a:GetFName():ToString() end)
        local id = safe(function() return a["Item ID (Row Name)"]:ToString() end, "None")
        if not name then return end
        M.n_tx = M.n_tx + 1
        log("progress: picked up " .. name .. " (" .. id .. ") -> " .. (role == "host" and "guests" or "host"))
        send("pickup|" .. name .. "|" .. id)
      end)
    end)
  end
  log("progress: hook pickup removal -> " .. (ok2 and "ok" or tostring(err2)))
end

-- Host: a guest picked something up.
function M.host_gathered_by_guest(log, id, from_pc)
  if not id then return end
  M.n_rx = M.n_rx + 1
  log("progress: guest picked up " .. id .. ", added to the host's inventory")
  gather_local(log, id)
  -- the other guests get it too (not the one who picked it up)
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and not safe(function() return pc:IsLocalController() end, true)
        and not (valid(from_pc) and pc:GetFullName() == from_pc:GetFullName()) then
      pcall(function() pc:ClientMessage("COOP|gathered|" .. id, FName("None"), 0.0) end)
    end
  end
end

-- Guest: the host (or another guest) picked something up.
function M.guest_apply(log, id)
  M.n_rx = M.n_rx + 1
  log("progress: " .. id .. " picked up by another player, added here")
  gather_local(log, id)
end

-- Both: someone else collected a pickup; collect our copy too (item and save entry).
-- If the actor is not here (its level isn't loaded, or it was already collected here),
-- add the item directly when this machine's save is the one that counts.
function M.apply_pickup(log, name, id)
  M.n_rx = M.n_rx + 1
  for _, a in ipairs(FindAllOf(PICKUP) or {}) do
    if valid(a) and a:GetFName():ToString() == name then
      M.applying = true
      local ok, err = pcall(function() a:Interact(a.Item, false) end)
      M.applying = false
      log("progress: " .. name .. " (" .. tostring(id) .. ") collected by another player, collected here too -> " .. (ok and "ok" or tostring(err)))
      return true
    end
  end
  if M.role == "host" and id and id ~= "None" then
    log("progress: " .. name .. " not loaded here; adding " .. id .. " directly")
    gather_local(log, id)
    local so = save_obj()
    if valid(so) then pcall(function() so:SaveCore(id .. "-" .. name, "Collected", false) end) end
  else
    log("progress: " .. name .. " collected by another player (not here)")
  end
  return false
end

-- Test helper: nearest pickup to a location.
function M.nearest_pickup(loc)
  local best, bd
  for _, a in ipairs(FindAllOf(PICKUP) or {}) do
    if valid(a) then
      local l = safe(function() return a:K2_GetActorLocation() end)
      if l then
        local d = (l.X - loc.X) ^ 2 + (l.Y - loc.Y) ^ 2 + (l.Z - loc.Z) ^ 2
        if not bd or d < bd then best, bd = a, d end
      end
    end
  end
  return best, bd and math.sqrt(bd)
end
-- Test helper: go to the nearest pickup and pick it up the way a click does.
function M.fetch_test(log)
  local me
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then me = ch end
  end
  if not me then log("FETCH no own character"); return end
  local p, d = M.nearest_pickup(me:K2_GetActorLocation())
  if not p then log("FETCH no pickup"); return end
  local l = p:K2_GetActorLocation()
  local pname = p:GetFName():ToString()
  log(string.format("FETCH nearest %s at %.0f units", pname, d))
  pcall(function() me:K2_SetActorLocation({ X = l.X - 80, Y = l.Y, Z = l.Z + 60 }, false, {}, true) end)
  local tx0 = M.n_tx
  ExecuteWithDelay(3000, function() ExecuteInGameThread(function()
    -- what the character's click does: the pickup's own Interact(Item component)
    local id = safe(function() return p["Item ID (Row Name)"]:ToString() end, "?")
    local ok, err = pcall(function() p:Interact(p.Item, false) end)
    log("FETCH Interact on " .. pname .. " (" .. id .. ") -> " .. (ok and "ok" or tostring(err)))
    ExecuteWithDelay(1500, function() ExecuteInGameThread(function()
      log("FETCH picked up=" .. tostring(M.n_tx > tx0) .. " pickup still there=" .. tostring(valid(p)))
    end) end)
  end) end)
end
return M
