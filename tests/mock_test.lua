-- Logic test for CallQuiet with a mocked `hs`. Run with any Lua 5.3+/LuaJIT:
--   lua tests/mock_test.lua
-- (Hammerspoon itself is not needed; the Spoon's `hs` calls are faked.)
local here = (arg and arg[0] or "tests/mock_test.lua"):match("^(.*)/tests/") or "."
local noop = function() end
local started, helperPresent = {}, { ["mic-users"] = true, ["app-mute"] = true }

local function newHS()
  started = {}
  local h = { _now = 0, _vol = 100, _mic = false, _alerts = 0, _doAfter = {} }
  h.settings = { _d = {}, get = function(k) return h.settings._d[k] end,
    set = function(k, v) h.settings._d[k] = v end, clear = function(k) h.settings._d[k] = nil end }
  h.osascript = { applescript = function(s)
    local n = s:match("alert volume (%d+)$"); if n then h._vol = tonumber(n) end
    return true, h._vol end }
  h.spoons = { scriptPath = function() return "/x/CallQuiet.spoon/" end,
    bindHotkeysToSpec = function(spec, map) h._bound = map; assert(type(spec.reset) == "function") end }
  h.fs = { attributes = function(p)
    local name = p:match("([^/]+)$"); if helperPresent[name] then return { size = 1 } end end }
  h.audiodevice = { allInputDevices = function() return { { inUse = function() return h._mic end,
      watcherIsRunning = function() return false end, watcherCallback = noop, watcherStart = noop, watcherStop = noop } } end,
    watcher = { setCallback = noop, start = noop, stop = noop, isRunning = function() return false end } }
  h.caffeinate = { watcher = { systemDidWake = 1, new = function(cb) h._sleepCb = cb; return { start = noop, stop = noop } end } }
  h.timer = { secondsSinceEpoch = function() return h._now end,
    doEvery = function(_, f) return { stop = noop } end,
    doAfter = function(_, f) h._doAfter[#h._doAfter + 1] = f end }
  h.alert = { show = function() h._alerts = h._alerts + 1 end }
  h.application = { get = function() return nil end }
  h.execute = noop; h.printf = noop
  h.task = { new = function(path, cb, sc, args)
    local t = { path = path, cb = cb, args = args, running = false }
    t.isRunning = function() return t.running end
    t.start = function() t.running = true; started[#started + 1] = t end
    t.terminate = function() t.running = false end
    return t end }
  hs = h
  return h
end

local function fresh()
  local h = newHS()
  local cq = dofile(here .. "/CallQuiet.spoon/init.lua")
  cq.logPath = nil
  return h, cq
end
local function count(name) local c = 0
  for _, t in ipairs(started) do if t.path:find(name, 1, true) then c = c + 1 end end return c end
local function lastScan() for i = #started, 1, -1 do if started[i].path:find("mic-users", 1, true) then return started[i] end end end
local function finishScan(out, code) local t = lastScan(); t.running = false; t.cb(code or 0, out) end
local function at(h, cq, t) h._now = t; cq:_tick() end

local pass = 0
local function test(name, fn) fn(); pass = pass + 1; print("ok  " .. name) end

test("call starts, mutes Slack, restores at end", function()
  local h, cq = fresh(); cq:bindHotkeys():start()
  assert(h._bound.reset[2] == "Q")
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\ncom.tinyspeck.slackmacgap\n")
  at(h, cq, 5); assert(cq._quiet and h._vol == 0)
  assert(count("app-mute") == 1)
  h._mic = false; cq:_syncMicLive(); at(h, cq, 6); at(h, cq, 13)
  assert(not cq._quiet and h._vol == 100)
end)

test("Slack huddle goes quiet without muting Slack", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("com.tinyspeck.slackmacgap.helper\n")
  at(h, cq, 5); assert(cq._quiet and count("app-mute") == 0)
end)

test("dictation apps alone never mute", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("com.electron.wispr-flow\nco.granola.app\n")
  at(h, cq, 5); at(h, cq, 20); assert(not cq._quiet and h._vol == 100)
end)

test("short mic burst under debounce does not mute", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 1); at(h, cq, 2)
  assert(not cq._quiet)
end)

test("alert volume already 0 stays 0 (not forced to 100)", function()
  local h, cq = fresh(); h._vol = 0; cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(cq._quiet)
  h._mic = false; cq:_syncMicLive(); at(h, cq, 6); at(h, cq, 13)
  assert(not cq._quiet and h._vol == 0 and hs.settings.get("CallQuiet.savedAlertVolume") == nil)
end)

test("volume changed by user mid-call is respected", function()
  local h, cq = fresh(); h._vol = 60; cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(h._vol == 0)
  h._vol = 30
  h._mic = false; cq:_syncMicLive(); at(h, cq, 6); at(h, cq, 13); assert(h._vol == 30)
end)

test("reload mid-call: saved volume survives, restored when call is gone", function()
  local h, cq = fresh(); h._vol = 70; cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(h._vol == 0)
  -- simulate reload: new Spoon instance, same settings store and volume
  local settings, vol = h.settings, h._vol
  local h2, cq2 = fresh(); h2.settings = settings; h2._vol = vol; h2._now = 100; cq2:start()
  assert(cq2._quiet)
  at(h2, cq2, 101); at(h2, cq2, 108)
  assert(not cq2._quiet and h2._vol == 70)
end)

test("reset mid-call stays un-muted until the call ends, then re-arms", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(cq._quiet)
  cq:reset(); assert(not cq._quiet and h._vol == 100)
  at(h, cq, 8); at(h, cq, 12); assert(not cq._quiet, "must not re-mute during same call")
  h._mic = false; cq:_syncMicLive(); at(h, cq, 13); at(h, cq, 20); assert(not cq._snoozed)
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 21); at(h, cq, 26)
  assert(cq._quiet, "next call mutes again")
end)

test("mic-users failure clears stale users instead of sticking", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(cq._quiet)
  at(h, cq, 16)               -- rescan fires
  finishScan("", 1)
  assert(#cq._micUsers == 0)
  at(h, cq, 17); at(h, cq, 24); assert(not cq._quiet)
end)

test("hung mic-users is killed and rescanned", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive()            -- scan starts at t=0, never finishes
  local hung = lastScan(); assert(hung.running)
  at(h, cq, 3); assert(hung.running)
  at(h, cq, 6); assert(not hung.running, "hung helper killed")
  at(h, cq, 12); assert(lastScan() ~= hung and lastScan().running, "fresh scan started")
end)

test("missing helper: start() refuses cleanly", function()
  helperPresent["mic-users"] = false
  local h, cq = fresh(); cq:start(); assert(cq._timer == nil and h._alerts == 1)
  helperPresent["mic-users"] = true
end)

test("missing app-mute: still quiets, no mute task", function()
  helperPresent["app-mute"] = false
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5)
  assert(cq._quiet and count("app-mute") == 0)
  helperPresent["app-mute"] = true
end)

test("app-mute that keeps dying is not respawned every tick", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5)
  local function die() for _, t in ipairs(started) do if t.path:find("app-mute", 1, true) then t.running = false end end end
  die(); at(h, cq, 7); at(h, cq, 9); assert(count("app-mute") == 1)
  at(h, cq, 16); assert(count("app-mute") == 2)
end)

test("wake from sleep resets stale state", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(cq._quiet)
  h._mic = false; h._now = 5000        -- slept through the end of the call
  h._sleepCb(hs.caffeinate.watcher.systemDidWake)
  assert(#cq._micUsers == 0 and not cq._micLive)
  for _, f in ipairs(h._doAfter) do f() end
  at(h, cq, 5001); at(h, cq, 5008); assert(not cq._quiet and h._vol == 100)
end)

test("stop() restores and is restartable", function()
  local h, cq = fresh(); cq:start()
  h._mic = true; cq:_syncMicLive(); finishScan("us.zoom.xos\n"); at(h, cq, 5); assert(h._vol == 0)
  cq:stop(); assert(h._vol == 100 and not cq._quiet and cq._timer == nil)
  cq:start(); assert(cq._timer)
end)

print(pass .. " tests passed")
