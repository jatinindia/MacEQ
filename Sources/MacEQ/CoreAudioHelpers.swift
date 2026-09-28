import CoreAudio
import Foundation

/// Error type carrying the failing Core Audio call and its OSStatus so failures are debuggable.
struct CoreAudioError: Error, CustomStringConvertible {
    let call: String
    let status: OSStatus

    var description: String {
        "CoreAudioError: \(call) failed with OSStatus \(status) ('\(fourCharCode(status))')"
    }
}

/// Renders an OSStatus as its four-character code when printable (e.g. 'what', '!dev').
private func fourCharCode(_ status: OSStatus) -> String {
    let bigEndian = UInt32(bitPattern: status).bigEndian
    let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }
    let characters = bytes.map { byte -> Character in
        let scalar = Unicode.Scalar(byte)
        return scalar.properties.isAlphabetic || scalar == " " ? Character(scalar) : "?"
    }
    return String(characters)
}

/// Throws if a Core Audio call did not return noErr.
func checkOSStatus(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else {
        throw CoreAudioError(call: call, status: status)
    }
}

private func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// The current system default output device.
func defaultOutputDeviceID() throws -> AudioDeviceID {
    var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
        "AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice)"
    )
    guard deviceID != kAudioObjectUnknown else {
        throw CoreAudioError(call: "defaultOutputDeviceID: no default output device", status: OSStatus(kAudioObjectUnknown))
    }
    return deviceID
}

/// Reads a CFString property (UID, name) from an audio object.
private func stringProperty(of objectID: AudioObjectID, selector: AudioObjectPropertySelector, call: String) throws -> String {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
        call
    )
    guard let cfString = value?.takeRetainedValue() else {
        throw CoreAudioError(call: "\(call): returned nil string", status: noErr)
    }
    return cfString as String
}

/// The persistent UID of a device, needed to reference it inside an aggregate device description.
func deviceUID(of deviceID: AudioDeviceID) throws -> String {
    try stringProperty(
        of: deviceID,
        selector: kAudioDevicePropertyDeviceUID,
        call: "AudioObjectGetPropertyData(kAudioDevicePropertyDeviceUID, device \(deviceID))"
    )
}

/// Human-readable device name for status display.
func deviceName(of deviceID: AudioDeviceID) throws -> String {
    try stringProperty(
        of: deviceID,
        selector: kAudioObjectPropertyName,
        call: "AudioObjectGetPropertyData(kAudioObjectPropertyName, device \(deviceID))"
    )
}

/// Nominal sample rate of a device, for status display and later coefficient computation.
func nominalSampleRate(of deviceID: AudioDeviceID) throws -> Double {
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate),
        "AudioObjectGetPropertyData(kAudioDevicePropertyNominalSampleRate, device \(deviceID))"
    )
    return rate
}

/// Translates a Unix PID to its Core Audio process object. Needed to exclude our own
/// process from the global tap: a muted global tap that includes us would mute our own
/// EQ'd playback (silence) and re-capture it into the tap input (feedback).
func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
    var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pidValue = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try checkOSStatus(
        withUnsafeMutablePointer(to: &pidValue) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &objectID
            )
        },
        "AudioObjectGetPropertyData(kAudioHardwarePropertyTranslatePIDToProcessObject, pid \(pid))"
    )
    guard objectID != kAudioObjectUnknown else {
        throw CoreAudioError(
            call: "processObjectID: pid \(pid) has no Core Audio process object",
            status: OSStatus(kAudioObjectUnknown)
        )
    }
    return objectID
}

/// The sub-devices an aggregate actually activated (not just what was requested).
/// If the real output device is missing here, IOProc output writes go nowhere.
func activeSubDeviceIDs(of aggregateID: AudioObjectID) throws -> [AudioObjectID] {
    var address = propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList)
    var size: UInt32 = 0
    try checkOSStatus(
        AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(kAudioAggregateDevicePropertyActiveSubDeviceList, aggregate \(aggregateID))"
    )
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard count > 0 else { return ids }
    try checkOSStatus(
        AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &ids),
        "AudioObjectGetPropertyData(kAudioAggregateDevicePropertyActiveSubDeviceList, aggregate \(aggregateID))"
    )
    return ids
}

/// Sub-device count of a multi-output/aggregate device; 1 for plain devices
/// (which have no sub-device list — that read failing is the normal case).
/// The process tap attenuates the captured mix by this factor.
func outputSubDeviceCount(of deviceID: AudioObjectID) -> Int {
    guard let subDevices = try? activeSubDeviceIDs(of: deviceID) else { return 1 }
    return max(subDevices.count, 1)
}

/// Number of output streams a device exposes. For our aggregate this must include
/// the real output device's stream, or there is nothing audible to write to.
func outputStreamCount(of deviceID: AudioObjectID) throws -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try checkOSStatus(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreams output, device \(deviceID))"
    )
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

/// Channels per buffer of a device's IOProc buffer list in one scope: exactly
/// the layout its AudioBufferList will have. Empty when the device has no
/// streams in that scope.
func streamConfiguration(of deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [Int] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try checkOSStatus(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreamConfiguration, device \(deviceID), scope \(scope))"
    )
    let byteCount = max(Int(size), MemoryLayout<AudioBufferList>.size)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw),
        "AudioObjectGetPropertyData(kAudioDevicePropertyStreamConfiguration, device \(deviceID), scope \(scope))"
    )
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
}

/// The output channels (1-based) the device plays stereo on, as set in Audio
/// MIDI Setup > Configure Speakers. macOS sends stereo here, so MacEQ does too.
func preferredStereoChannels(of deviceID: AudioObjectID) throws -> (Int, Int) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var channels: (UInt32, UInt32) = (0, 0)
    var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &channels),
        "AudioObjectGetPropertyData(kAudioDevicePropertyPreferredChannelsForStereo, device \(deviceID))"
    )
    return (Int(channels.0), Int(channels.1))
}

/// Whether the device is running IO right now.
func deviceIsRunning(_ deviceID: AudioObjectID) throws -> Bool {
    var address = propertyAddress(kAudioDevicePropertyDeviceIsRunning)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running),
        "AudioObjectGetPropertyData(kAudioDevicePropertyDeviceIsRunning, device \(deviceID))"
    )
    return running != 0
}

/// All Core Audio process objects (processes that are audio clients right now).
func audioProcessObjectIDs() throws -> [AudioObjectID] {
    var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    try checkOSStatus(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(kAudioHardwarePropertyProcessObjectList)"
    )
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    try checkOSStatus(
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids),
        "AudioObjectGetPropertyData(kAudioHardwarePropertyProcessObjectList)"
    )
    return ids
}

/// The Unix PID behind a Core Audio process object.
func pid(ofAudioProcess objectID: AudioObjectID) throws -> pid_t {
    var address = propertyAddress(kAudioProcessPropertyPID)
    var processPID: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &processPID),
        "AudioObjectGetPropertyData(kAudioProcessPropertyPID, object \(objectID))"
    )
    return processPID
}

/// Whether an audio process has IO running right now (actively playing/recording).
/// Drives the zero-buffer watchdog: a silent tap while another process is running
/// IO indicates the known tap-goes-silent platform bug, not genuine silence.
func audioProcessIsRunning(_ objectID: AudioObjectID) throws -> Bool {
    var address = propertyAddress(kAudioProcessPropertyIsRunning)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running),
        "AudioObjectGetPropertyData(kAudioProcessPropertyIsRunning, object \(objectID))"
    )
    return running != 0
}

/// The bundle ID Core Audio records for an audio process (works for helper
/// processes that NSRunningApplication cannot see).
func bundleID(ofAudioProcess objectID: AudioObjectID) throws -> String {
    try stringProperty(
        of: objectID,
        selector: kAudioProcessPropertyBundleID,
        call: "AudioObjectGetPropertyData(kAudioProcessPropertyBundleID, object \(objectID))"
    )
}

/// The stream format the tap delivers (sample rate, channels, interleaving).
func tapStreamFormat(of tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = propertyAddress(kAudioTapPropertyFormat)
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
        "AudioObjectGetPropertyData(kAudioTapPropertyFormat, tap \(tapID))"
    )
    return format
}
