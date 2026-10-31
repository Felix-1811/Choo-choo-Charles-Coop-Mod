-- Debug: what is in the world (pickups, enemies) and what death does. Host-only test.
local M = {}
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end
local function valid(o) return o ~= nil and safe(function() return o:IsValid() end, false) end

function M.classes(log, pattern)
  local counts, near = {}, {}
  for _, a in ipairs(FindAllOf("Actor") or {}) do
    if valid(a) then
      local cn = safe(function() return a:GetClass():GetFName():ToString() end, "?")
      if cn:lower():find(pattern) then counts[cn] = (counts[cn] or 0) + 1 end
    end
  end
  local out = {}
  for k, v in pairs(counts) do table.insert(out, k .. "=" .. v) end
  table.sort(out)
  log("EXPLORE classes /" .. pattern .. "/: " .. table.concat(out, " "))
end

function M.own(log)
  for _, ch in ipairs(FindAllOf("BP_NMCharacter_Player_C") or {}) do
    if valid(ch) and safe(function() return ch:IsLocallyControlled() end, false) then return ch end
  end
end

function M.char_state(log, tag)
  local ch = M.own(log); if not ch then log("EXPLORE no own char"); return end
  log("EXPLORE " .. tag .. " char " .. ch:GetFName():ToString())
  for _, k in ipairs({ "Dead?", "varHealth", "varHealthMain", "Can Move?", "In train?" }) do
    log("EXPLORE " .. tag .. " " .. k .. "=" .. tostring(safe(function() return ch[k] end)))
  end
  local l = safe(function() return ch:K2_GetActorLocation() end)
  log("EXPLORE " .. tag .. " loc=" .. (l and string.format("(%.0f %.0f %.0f)", l.X, l.Y, l.Z) or "?"))
  local ds = FindFirstOf("DeathScreen_C")
  log("EXPLORE " .. tag .. " deathscreen=" .. tostring(valid(ds) and safe(function() return ds:IsInViewport() end, "?")))
end
return M
