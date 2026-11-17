# Call Quiet

A [Hammerspoon](https://www.hammerspoon.org) Spoon that silences notification sounds while you're on a call, and puts them back when you hang up.

When a meeting app (Zoom, Teams, a browser running Meet, a Slack huddle, FaceTime, WhatsApp, and so on) has your microphone open, Call Quiet:

- sets the macOS **alert volume** to 0, so banners still show but stop pinging. Call audio is untouched, because alert volume is separate from output volume.
- optionally **mutes chosen apps** (Slack by default) with a Core Audio process tap, for apps that play their own sounds in-app and ignore alert volume.

When the mic goes quiet it restores your previous alert volume. Apps used for dictation or recording (Wispr Flow, Granola, voice memos) are not in the default list, so using them alone never mutes anything.

## How it works

Hammerspoon watches input devices through Core Audio events, so nothing polls while your mic is off. When a device goes live, the `mic-users` helper lists which apps hold the mic (per-process Core Audio, macOS 14+). If one matches `meetingApps` for a few seconds, Call Quiet goes quiet. `app-mute` creates a process tap with mute behavior on the apps you list and holds it open; killing the helper unmutes, so a crash fails safe.

## Requirements

- macOS 14.2 or later (per-process audio objects and process taps)
- Hammerspoon
- Xcode Command Line Tools (`xcode-select --install`) to build the two small Swift helpers

## Install

```bash
git clone https://github.com/teeejlind/call-quiet.git
cd call-quiet
./scripts/install.sh
```

That compiles `helpers/mic-users.swift` and `helpers/app-mute.swift` into `CallQuiet.spoon/bin/` and copies the Spoon to `~/.hammerspoon/Spoons/`. Read the helpers first if you like; they're about 150 lines total. No prebuilt binaries are shipped.

Then add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("CallQuiet")
spoon.CallQuiet:bindHotkeys(spoon.CallQuiet.defaultHotkeys) -- ctrl+alt+cmd+Q resets
spoon.CallQuiet:start()
```

Reload Hammerspoon.

## Permissions

- **Microphone**: none requested. Call Quiet never records audio; it only asks Core Audio which processes have an input stream running. (Hammerspoon's own device-running watcher does the same.)
- **Audio capture (app muting only)**: `app-mute` uses a Core Audio process tap. macOS asks for "System Audio Recording" / audio capture permission the first time it runs (System Settings → Privacy & Security → Screen & System Audio Recording). Because Hammerspoon launches the helper, the grant is attached to Hammerspoon. If you don't want it, set `appMutePrefixes = {}` and only alert volume is changed.
- **Automation**: alert volume is set through AppleScript's `set volume alert volume`, run by Hammerspoon. No extra prompt is normally needed.

## Configure

Set fields before `start()`:

```lua
local cq = spoon.CallQuiet
cq.meetingApps = { "us.zoom.", "com.microsoft.teams", "com.google.Chrome" }
cq.appMutePrefixes = { "com.tinyspeck.slackmacgap", "com.hnc.Discord" }
cq.pollSeconds = 2
cq.muteAfterSeconds = 3      -- mic must be held this long before muting
cq.restoreAfterSeconds = 6   -- mic must be free this long before restoring
cq.detectZoomMeeting = true  -- also treat a running Zoom meeting as a call
cq.showAlerts = true
cq.logPath = nil             -- nil disables the log file
cq:bindHotkeys({ reset = { { "ctrl", "alt", "cmd" }, "Q" } })
cq:start()
```

| Field | Default | Meaning |
|---|---|---|
| `meetingApps` | Zoom, Teams, Chrome, Arc/Dia, Safari/WebKit, Firefox, FaceTime, Slack, WhatsApp, Discord | Bundle ID **prefixes** that count as a call when they hold the mic |
| `appMutePrefixes` | Slack | Apps to mute entirely during a call. `{}` disables app muting. An app that is itself the call (a Slack huddle) is never muted |
| `pollSeconds` | 2 | Timer tick. It spawns nothing; it only drives timing |
| `muteAfterSeconds` | 3 | Debounce before going quiet |
| `restoreAfterSeconds` | 6 | Debounce before restoring |
| `rescanSeconds` | 10 | How often to re-ask who holds the mic while it's live |
| `detectZoomMeeting` | true | Zoom's `CptHost` process counts as a call |
| `showAlerts` | true | On-screen 🔕/🔔 messages |
| `logPath` | `~/.hammerspoon/CallQuiet.log` | `nil` for no log |
| `helperDir` | `<spoon>/bin` | Where `mic-users` and `app-mute` live |

Find a bundle ID with `osascript -e 'id of app "Slack"'`, or run `CallQuiet.spoon/bin/mic-users` while the app is on a call.

Other methods: `spoon.CallQuiet:status()` returns a table of the current state; `:reset()` restores sounds immediately; `:stop()` stops watching.

## Known limits

- Browsers are matched by app, not by tab. Chrome holding the mic for any reason (a web dictation tool, a video recorder) counts as a call. Remove browsers from `meetingApps` if that bites.
- Apps that don't hold the mic while you're muted in a call may not be detected. Zoom is covered by the meeting check; others aren't.
- Alert volume is a system-wide setting. If Hammerspoon dies mid-call, the saved level is kept in Hammerspoon's settings and restored on next start, or use `:reset()`. If you change alert volume by hand during a call, it gets overwritten at restore.
- Muting uses the default system output device. Switching devices mid-call is picked up on the helper's next 3-second rescan.
- Apps that bypass alert volume and aren't in `appMutePrefixes` will keep making noise.
- Not tested on macOS versions before 14.2 (the helpers won't work there) or with multiple simultaneous output devices.
- Developed and used daily on one machine. Expect rough edges elsewhere; issues welcome.

## Layout

```
CallQuiet.spoon/init.lua   the Spoon
helpers/                   Swift source for mic-users and app-mute
scripts/build.sh           compile helpers (optionally to a custom dir)
scripts/install.sh         build + copy the Spoon into ~/.hammerspoon/Spoons
```

## License

MIT, see [LICENSE](LICENSE).
