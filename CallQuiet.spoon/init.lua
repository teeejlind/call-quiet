--- === CallQuiet ===
---
--- Silences notification sounds while you are on a call.
---
--- While a meeting app has the microphone open (or a Zoom meeting is running),
--- the macOS alert volume is set to 0 and, optionally, chosen apps are muted
--- with a Core Audio process tap. When the call ends everything is restored.
--- Call audio is never touched: alert volume is separate from output volume.
---
--- Download: https://github.com/teeejlind/call-quiet

local obj = {}
obj.__index = obj

obj.name = "CallQuiet"
obj.version = "0.1.0"
obj.author = "TJ Lind"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/teeejlind/call-quiet"

--- CallQuiet.meetingApps
--- Variable
--- Bundle ID prefixes that count as "a call" when they hold the mic. Matched as
--- prefixes, so "com.google.Chrome" also matches Chrome's helper processes.
--- Apps that use the mic for dictation or recording (Wispr Flow, Granola, voice
--- memos) are deliberately absent so they never trigger a mute.
obj.meetingApps = {
  "us.zoom.",
  "com.microsoft.teams",
  "com.google.Chrome",         -- Google Meet
  "company.thebrowser.",       -- Arc, Dia
  "com.apple.Safari",
  "com.apple.WebKit",          -- Safari captures through WebKit helpers
  "org.mozilla.firefox",
  "com.apple.FaceTime",
  "com.tinyspeck.slackmacgap", -- Slack huddles
  "net.whatsapp.",
  "com.hnc.Discord",
}

--- CallQuiet.appMutePrefixes
--- Variable
--- Bundle ID prefixes of apps to mute completely during a call, using the
--- app-mute helper. Use this for apps that play sounds in-app instead of through
--- macOS notifications (Slack does). Set to {} to disable app muting. An app that
--- is itself the call (e.g. a Slack huddle) is never muted.
obj.appMutePrefixes = { "com.tinyspeck.slackmacgap" }

--- CallQuiet.pollSeconds
--- Variable
--- How often the timer ticks, in seconds. The tick spawns no processes; it only
--- drives the mute/restore timing. Default 2.
obj.pollSeconds = 2

--- CallQuiet.muteAfterSeconds
--- Variable
--- How long the mic must be held by a meeting app before going quiet, so short
--- bursts don't trigger it. Default 3.
obj.muteAfterSeconds = 3

--- CallQuiet.restoreAfterSeconds
--- Variable
--- How long the mic must be free before restoring sounds, to ride out brief
--- drops mid-call. Default 6.
obj.restoreAfterSeconds = 6

--- CallQuiet.rescanSeconds
--- Variable
--- While the mic is live, how often to re-ask which apps hold it. Default 10.
obj.rescanSeconds = 10

--- CallQuiet.detectZoomMeeting
--- Variable
--- Also treat a running Zoom meeting (Zoom's CptHost process) as a call, even if
--- Zoom is not holding the mic. Default true.
obj.detectZoomMeeting = true

--- CallQuiet.showAlerts
--- Variable
--- Flash an on-screen message when going quiet and when restoring. Default true.
obj.showAlerts = true

--- CallQuiet.logPath
--- Variable
--- Log file path, or nil to disable logging. Default ~/.hammerspoon/CallQuiet.log
obj.logPath = os.getenv("HOME") .. "/.hammerspoon/CallQuiet.log"

--- CallQuiet.helperDir
--- Variable
--- Directory holding the compiled mic-users and app-mute helpers. Defaults to
--- the bin/ folder inside the Spoon (where scripts/build.sh puts them).
obj.helperDir = nil

--- CallQuiet.defaultHotkeys
--- Variable
--- Default hotkey mapping for bindHotkeys: reset = ctrl+alt+cmd+Q.
obj.defaultHotkeys = {
  reset = { { "ctrl", "alt", "cmd" }, "Q" },
}

local settingsKey = "CallQuiet.savedAlertVolume"

-- internal state
obj._quiet = false
obj._activeSince, obj._idleSince = nil, nil
obj._micUsers = {}
obj._micLive = false
obj._lastScan = 0
obj._zoomMeeting = false
obj._lastZoomCheck = 0
obj._watched = {}

function obj:_log(message)
  if not self.logPath then return end
  local file = io.open(self.logPath, "a")
  if file then
    file:write(os.date("%Y-%m-%d %H:%M:%S"), " ", message, "\n")
    file:close()
  end
end

function obj:_helper(name)
  local dir = self.helperDir or (hs.spoons.scriptPath() .. "bin")
  return dir .. "/" .. name
end

local function alertVolume()
  -- Ask for the field directly; the full record comes back as an empty table.
  local ok, value = hs.osascript.applescript("alert volume of (get volume settings)")
  if ok and type(value) == "number" then return value end
  return nil
end

local function setAlertVolume(value)
  hs.osascript.applescript("set volume alert volume " .. tostring(math.floor(value)))
end

local function hasPrefix(id, prefixes)
  for _, prefix in ipairs(prefixes) do
    if id:sub(1, #prefix) == prefix then return true end
  end
  return false
end

function obj:_refreshMicUsers(onDone)
  if self._micTask and self._micTask:isRunning() then return end
  self._lastScan = hs.timer.secondsSinceEpoch()
  self._micTask = hs.task.new(self:_helper("mic-users"), function(exitCode, stdOut)
    if exitCode == 0 then
      local users = {}
      for line in (stdOut or ""):gmatch("[^\n]+") do users[#users + 1] = line end
      self._micUsers = users
    end
    if onDone then onDone() end
  end)
  if self._micTask then self._micTask:start() end
end

local function anyInputRunning()
  for _, device in ipairs(hs.audiodevice.allInputDevices()) do
    if device:inUse() then return true end
  end
  return false
end

-- Core Audio pushes an event when any input device starts or stops, so the
-- mic-users scan only runs while the mic is live.
function obj:_syncMicLive()
  local live = anyInputRunning()
  if live == self._micLive then return end
  self._micLive = live
  if live then
    self:_refreshMicUsers(function() self:_tick() end)
  else
    self._micUsers = {}
    self:_tick()
  end
end

function obj:_watchInputs()
  for _, device in ipairs(self._watched) do
    if device:watcherIsRunning() then device:watcherStop() end
  end
  self._watched = {}
  for _, device in ipairs(hs.audiodevice.allInputDevices()) do
    -- "gone" is Hammerspoon's name for kAudioDevicePropertyDeviceIsRunningSomewhere.
    device:watcherCallback(function(_, event)
      if event == "gone" then self:_syncMicLive() end
    end)
    device:watcherStart()
    self._watched[#self._watched + 1] = device
  end
end

function obj:_meetingAppOnMic()
  for _, bundleID in ipairs(self._micUsers) do
    if hasPrefix(bundleID, self.meetingApps) then return true, bundleID end
  end
  return false, nil
end

-- Zoom spawns CptHost only while a meeting is open.
function obj:_refreshZoomMeeting()
  self._lastZoomCheck = hs.timer.secondsSinceEpoch()
  if not self.detectZoomMeeting or not hs.application.get("us.zoom.xos") then
    self._zoomMeeting = false
    return
  end
  if self._zoomTask and self._zoomTask:isRunning() then return end
  self._zoomTask = hs.task.new("/usr/bin/pgrep", function(exitCode)
    self._zoomMeeting = exitCode == 0
  end, { "-xq", "CptHost" })
  self._zoomTask:start()
end

function obj:_inCall()
  local mic, bundleID = self:_meetingAppOnMic()
  if mic then return true, "mic: " .. bundleID end
  if self._zoomMeeting then return true, "zoom meeting" end
  return false, nil
end

-- app-mute holds a Core Audio process tap that mutes the given apps' output
-- while it runs; killing it unmutes.
function obj:_startAppMute(reason)
  if #self.appMutePrefixes == 0 then return end
  -- Never mute an app while that app is itself the call.
  for _, prefix in ipairs(self.appMutePrefixes) do
    if reason:find(prefix, 1, true) then return end
  end
  if self._muteTask and self._muteTask:isRunning() then return end
  self._muteTask = hs.task.new(self:_helper("app-mute"), function(exitCode, _, stdErr)
    self:_log("app-mute exited " .. tostring(exitCode) .. " " .. (tostring(stdErr or ""):gsub("%s+$", "")))
  end, function(_, _, stdErr)
    if stdErr and stdErr ~= "" then self:_log((stdErr:gsub("%s+$", ""))) end
    return true
  end, self.appMutePrefixes)
  if self._muteTask then self._muteTask:start() end
end

function obj:_stopAppMute()
  if self._muteTask and self._muteTask:isRunning() then self._muteTask:terminate() end
  self._muteTask = nil
end

function obj:_alert(text)
  if self.showAlerts then hs.alert.show(text, 1) end
end

function obj:_goQuiet(reason)
  local current = alertVolume()
  if current == nil then return end
  -- Don't overwrite a saved level with our own 0.
  if hs.settings.get(settingsKey) == nil then hs.settings.set(settingsKey, current) end
  setAlertVolume(0)
  self:_startAppMute(reason)
  self._quiet = true
  self:_log("quiet on (" .. reason .. "), saved alert volume " .. tostring(hs.settings.get(settingsKey)))
  self:_alert("🔕 Notification sounds off")
end

function obj:_restore(reason)
  self:_stopAppMute()
  local saved = hs.settings.get(settingsKey)
  if saved ~= nil then
    -- A saved 0 would mean we captured our own mute; fall back to full.
    setAlertVolume(saved > 0 and saved or 100)
    hs.settings.clear(settingsKey)
  end
  self._quiet = false
  self:_log("quiet off (" .. reason .. "), restored alert volume " .. tostring(saved))
  self:_alert("🔔 Notification sounds on")
end

function obj:_tick()
  local now = hs.timer.secondsSinceEpoch()
  if now - self._lastZoomCheck >= self.rescanSeconds then
    self:_syncMicLive() -- backstop in case a watcher event was missed
    self:_refreshZoomMeeting()
  end
  if self._micLive and now - self._lastScan >= self.rescanSeconds then
    self:_refreshMicUsers()
  end
  local busy, reason = self:_inCall()

  if busy then
    self._idleSince = nil
    self._activeSince = self._activeSince or now
    if not self._quiet and now - self._activeSince >= self.muteAfterSeconds then
      self:_goQuiet(reason)
    elseif self._quiet then
      -- Covers a reload mid-call, or a helper that died.
      self:_startAppMute(reason)
    end
  else
    self._activeSince = nil
    self._idleSince = self._idleSince or now
    if self._quiet and now - self._idleSince >= self.restoreAfterSeconds then
      self:_restore("call ended")
    end
  end
end

--- CallQuiet:status() -> table
--- Method
--- Returns the current state: quiet, inCall, reason, micUsers, micLive,
--- zoomMeeting, appMuteRunning, alertVolume, savedAlertVolume.
function obj:status()
  local busy, reason = self:_inCall()
  return {
    quiet = self._quiet,
    inCall = busy,
    reason = reason,
    micUsers = self._micUsers,
    micLive = self._micLive,
    zoomMeeting = self._zoomMeeting,
    appMuteRunning = self._muteTask ~= nil and self._muteTask:isRunning(),
    alertVolume = alertVolume(),
    savedAlertVolume = hs.settings.get(settingsKey),
  }
end

--- CallQuiet:reset() -> CallQuiet
--- Method
--- Manual escape hatch: restore alert volume and stop app muting right now.
function obj:reset()
  self:_restore("manual reset")
  return self
end

--- CallQuiet:bindHotkeys(mapping)
--- Method
--- Binds hotkeys. Supported action: `reset`.
--- Example: `spoon.CallQuiet:bindHotkeys({ reset = { { "ctrl", "alt", "cmd" }, "Q" } })`
function obj:bindHotkeys(mapping)
  hs.spoons.bindHotkeysToSpec({
    reset = function() self:reset() end,
  }, mapping or self.defaultHotkeys)
  return self
end

--- CallQuiet:start() -> CallQuiet
--- Method
--- Starts watching for calls. Set your configuration before calling this.
function obj:start()
  if self._timer then return self end
  self._quiet = hs.settings.get(settingsKey) ~= nil

  -- Clear any helper left over from a previous Hammerspoon session.
  hs.execute("/usr/bin/pkill -x app-mute")

  self._deviceWatcher = hs.audiodevice.watcher
  hs.audiodevice.watcher.setCallback(function(event)
    if event == "dev#" then
      self:_watchInputs()
      self:_syncMicLive()
    end
  end)
  hs.audiodevice.watcher.start()
  self:_watchInputs()

  self._timer = hs.timer.doEvery(self.pollSeconds, function() self:_tick() end)
  self:_log("CallQuiet started. quiet=" .. tostring(self._quiet))
  self:_syncMicLive()
  self:_refreshZoomMeeting()
  self:_tick()
  return self
end

--- CallQuiet:stop() -> CallQuiet
--- Method
--- Stops watching. Restores sounds if currently quiet.
function obj:stop()
  if self._timer then self._timer:stop(); self._timer = nil end
  for _, device in ipairs(self._watched) do
    if device:watcherIsRunning() then device:watcherStop() end
  end
  self._watched = {}
  if hs.audiodevice.watcher.isRunning() then hs.audiodevice.watcher.stop() end
  if self._quiet then self:_restore("stopped") else self:_stopAppMute() end
  return self
end

return obj
