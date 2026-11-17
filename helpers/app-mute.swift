// Mutes the audio output of every process whose bundle ID starts with one of the
// given prefixes, for as long as this helper runs. Exiting (or being killed)
// releases the tap and the apps are audible again, so a crash fails safe.
//   usage: app-mute com.tinyspeck.slackmacgap [more.prefixes ...]
// Requires macOS 14.2+ (Core Audio process taps) and the audio-capture permission.
import AudioToolbox
import CoreAudio
import Foundation

let prefixes = Array(CommandLine.arguments.dropFirst())
guard !prefixes.isEmpty else {
  FileHandle.standardError.write("usage: app-mute <bundle-id-prefix> ...\n".data(using: .utf8)!)
  exit(2)
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}

func matchingProcesses() -> [AudioObjectID] {
  var listAddress = address(kAudioHardwarePropertyProcessObjectList)
  var size: UInt32 = 0
  let system = AudioObjectID(kAudioObjectSystemObject)
  guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return [] }
  var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == noErr else { return [] }

  return processes.filter { process in
    var bundleAddress = address(kAudioProcessPropertyBundleID)
    var bundleID: Unmanaged<CFString>?
    var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundleID) == noErr,
          let id = bundleID?.takeRetainedValue() as String? else { return false }
    return prefixes.contains { id.hasPrefix($0) }
  }.sorted()
}

func defaultOutputUID() -> String? {
  var deviceAddress = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
  var device = AudioObjectID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &size, &device) == noErr else { return nil }
  var uidAddress = address(kAudioDevicePropertyDeviceUID)
  var uid: Unmanaged<CFString>?
  var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { return nil }
  return uid?.takeRetainedValue() as String?
}

final class Muter {
  var tap = AudioObjectID(kAudioObjectUnknown)
  var aggregate = AudioObjectID(kAudioObjectUnknown)
  var ioProc: AudioDeviceIOProcID?
  var muted: [AudioObjectID] = []
  var outputUID: String?

  func apply(_ processes: [AudioObjectID]) {
    // Rebuild when the app list changes or the output device does (e.g. headphones
    // connecting mid-call), since the tap is clocked by that device.
    let uid = defaultOutputUID()
    guard processes != muted || uid != outputUID else { return }
    teardown()
    guard !processes.isEmpty, let outputUID = uid else { return }
    self.outputUID = uid

    let description = CATapDescription(stereoMixdownOfProcesses: processes)
    description.muteBehavior = .muted
    description.isPrivate = true
    description.name = "Call Quiet app mute"
    guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
      log("could not create tap (audio capture permission?)")
      return
    }

    // The mute only holds while the tap is being read, so run a private
    // aggregate device on it and throw the samples away.
    let settings: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Call Quiet",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: description.uuid.uuidString,
      ]],
    ]
    guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr,
          AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil, { _, _, _, _, _ in }) == noErr,
          AudioDeviceStart(aggregate, ioProc) == noErr else {
      log("could not start tap device")
      teardown()
      return
    }

    muted = processes
    log("muting \(processes.count) process(es)")
  }

  func teardown() {
    if aggregate != kAudioObjectUnknown {
      if let ioProc {
        AudioDeviceStop(aggregate, ioProc)
        AudioDeviceDestroyIOProcID(aggregate, ioProc)
      }
      AudioHardwareDestroyAggregateDevice(aggregate)
    }
    if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    tap = AudioObjectID(kAudioObjectUnknown)
    aggregate = AudioObjectID(kAudioObjectUnknown)
    ioProc = nil
    muted = []
  }
}

func log(_ message: String) {
  FileHandle.standardError.write("app-mute: \(message)\n".data(using: .utf8)!)
}

let muter = Muter()
muter.apply(matchingProcesses())

// Pick up Slack restarts or new audio helpers.
let rescan = Timer(timeInterval: 3, repeats: true) { _ in muter.apply(matchingProcesses()) }
RunLoop.main.add(rescan, forMode: .default)

// If the parent (Hammerspoon) dies or is killed, release the tap instead of
// leaving apps muted with nothing to turn them back on.
let parent = getppid()
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
if parent > 1 {
  parentWatch.setEventHandler {
    muter.teardown()
    exit(0)
  }
  parentWatch.resume()
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
  signal(sig, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  source.setEventHandler {
    muter.teardown()
    exit(0)
  }
  source.resume()
  signalSources.append(source)
}

RunLoop.main.run()
