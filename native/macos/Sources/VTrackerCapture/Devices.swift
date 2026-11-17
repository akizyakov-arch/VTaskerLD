import AudioToolbox
import CoreAudio
import Foundation

struct InputDevice: Codable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isDefault: Bool

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value)
        guard status == noErr else { throw DeviceError.failure("Cannot read audio device property: \(status)") }
        guard let value = value else { throw DeviceError.failure("Audio device property is empty") }
        return value.takeRetainedValue() as String
    }
    static func list() throws -> [InputDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else {
            throw DeviceError.failure("Cannot enumerate audio devices")
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw DeviceError.failure("Cannot read audio device list: \(status)") }
        var defaultProperty = address(kAudioHardwarePropertyDefaultInputDevice)
        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultProperty, 0, nil, &defaultSize, &defaultID)
        var result: [InputDevice] = []
        for id in ids {
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }
            var aliveProperty = address(kAudioDevicePropertyDeviceIsAlive)
            var alive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &aliveProperty, 0, nil, &aliveSize, &alive) == noErr, alive != 0 else { continue }
            result.append(InputDevice(id: id, uid: try string(id, kAudioDevicePropertyDeviceUID), name: try string(id, kAudioObjectPropertyName), isDefault: id == defaultID))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func select(_ uid: String?) throws -> InputDevice {
        let devices = try list()
        guard let device = devices.first(where: { uid == nil || uid!.isEmpty ? $0.isDefault : $0.uid == uid }) else {
            throw DeviceError.failure("Selected microphone is unavailable; reconnect it or select another device")
        }
        return device
    }
}
private enum DeviceError: Error { case failure(String) }
