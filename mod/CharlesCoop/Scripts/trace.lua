-- Debug: log every call of a Blueprint class's functions (to see what a lever click runs).
-- Tick-like functions are skipped; each function logs at most `cap` times.
local M = { hooked = {}, counts = {} }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end

local SKIP = { ReceiveTick = true, UserConstructionScript = true }

function M.class(log, cls_path, cap)
  cap = cap or 20
  local cls = StaticFindObject(cls_path)
  if not cls or not safe(function() return cls:IsValid() end, false) then log("TRACE no class " .. cls_path); return end
  local names = {}
  safe(function()
    cls:ForEachFunction(function(fn) table.insert(names, fn:GetFName():ToString()) end)
  end)
  local n = 0
  for _, fname in ipairs(names) do
    local key = cls_path .. ":" .. fname
    if not SKIP[fname] and not M.hooked[key] then
      local ok = pcall(function()
        RegisterHook(key, function(self, a1)
          M.counts[key] = (M.counts[key] or 0) + 1
          if M.counts[key] > cap then return end
          local extra = ""
          if fname:find("^ExecuteUbergraph") then extra = " entry=" .. tostring(safe(function() return a1:get() end, "?")) end
          log("TRACE " .. fname .. extra .. " #" .. M.counts[key])
        end)
      end)
      if ok then M.hooked[key] = true; n = n + 1 end
    end
  end
  log("TRACE hooked " .. n .. "/" .. #names .. " functions of " .. cls_path)
end
return M
