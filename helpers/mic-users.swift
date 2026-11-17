// Prints the bundle ID of every process currently capturing microphone input,
// one per line. Uses CoreAudio's per-process objects (macOS 14+).
import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}

var listAddress = address(kAudioHardwarePropertyProcessObjectList)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(
  AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr else { exit(1) }

var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(
  AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else { exit(1) }

for process in processes {
  var runningAddress = address(kAudioProcessPropertyIsRunningInput)
  var running: UInt32 = 0
  var runningSize = UInt32(MemoryLayout<UInt32>.size)
  guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
        running != 0 else { continue }

  var bundleAddress = address(kAudioProcessPropertyBundleID)
  var bundleID: Unmanaged<CFString>?
  var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  if AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundleID) == noErr,
     let id = bundleID?.takeRetainedValue() as String?, !id.isEmpty {
    print(id)
    continue
  }

  var pidAddress = address(kAudioProcessPropertyPID)
  var pid: pid_t = 0
  var pidSize = UInt32(MemoryLayout<pid_t>.size)
  if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr {
    print("pid:\(pid)")
  }
}
