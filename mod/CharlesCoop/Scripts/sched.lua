-- One scheduler for every periodic job, run on the game thread without ExecuteInGameThread.
-- Up to 0.3 dev each module had its own LoopAsync(...) -> ExecuteInGameThread loop: ~50
-- cross-thread calls a second on each machine. Crashes inside UE4SS (access violations,
-- heap corruption, C++ exception 0xe06d7363) grew with every loop added (runs 182024 ..
-- 184948). Here the jobs run from a hook on PlayerTrain_C:ReceiveTick (the train ticks
-- every frame on every machine, on the game thread). Jobs only run while it ticks.
local M = { jobs = {}, hooked = false, ticks = 0 }
local function safe(f, d) local ok, v = pcall(f); if ok then return v end; return d end

local TRAIN_TICK = "/Game/_GAME/Blueprints/TrainBlueprints/PlayerTrain.PlayerTrain_C:ReceiveTick"

-- every(name, seconds, fn): run fn about every `seconds` (no faster than the frame rate).
function M.every(name, period, fn)
  M.jobs[name] = { period = period, fn = fn, next = 0 }
end

function M.stop(name) M.jobs[name] = nil end

-- on_reset(fn): called when the world changes (the ticking train is a different object).
-- Modules drop cached game objects there: after a level change they point at freed
-- memory, and even IsValid() on them can crash (guest crash on disconnect, run 202328).
M.resets = {}
function M.on_reset(fn) table.insert(M.resets, fn) end

local function run()
  local now = os.clock()
  M.last_run = now
  for name, j in pairs(M.jobs) do
    if now >= j.next then
      j.next = now + j.period
      local ok, err = pcall(j.fn)
      if not ok then
        j.errs = (j.errs or 0) + 1
        if j.errs <= 3 and M.log then M.log("sched: job " .. name .. " failed: " .. tostring(err)) end
      end
    end
  end
end

function M.install(log)
  if M.installed then return end
  M.installed = true
  M.log = log
  local ok, err = pcall(function()
    RegisterHook(TRAIN_TICK, function(self)
      local t = self:get()
      local addr = safe(function() return t:GetAddress() end) or safe(function() return t:GetFullName() end)
      if addr ~= M.train_addr then
        M.train_addr = addr
        for _, f in ipairs(M.resets) do pcall(f) end
        log("sched: new world (train " .. tostring(addr) .. "), caches cleared")
      end
      M.train = t
      M.from_hook = os.clock()
      run()
    end)
  end)
  M.hooked = ok
  log("sched: train tick hook -> " .. (ok and "ok" or tostring(err)))
  -- no fallback loop: jobs run only while a train ticks, i.e. while a world is alive
  -- (a fallback ran them during a disconnect's level teardown)
end
return M
