import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String
    var description: String {
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : ""
        return "\(what) failed: \(status)\(fourCC)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(status: status, what: what) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

enum CA {
    static func has(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(obj, &a)
    }

    static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) throws -> T {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value), "get '\(fourCC(addr.mSelector))'")
        return value
    }

    static func set<T: BitwiseCopyable>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) throws {
        var a = addr
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectSetPropertyData(obj, &a, 0, nil, size, &v), "set '\(fourCC(addr.mSelector))'")
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref)
        guard st == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    static func objectList(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}

/// A snapshot of an audio device's identifying details.
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let modelUID: String
    let transport: UInt32
    let outputChannels: Int

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isUSB: Bool { transport == kAudioDeviceTransportTypeUSB }

    /// Heuristic match for the Twelve South BassJump (C-Media, VID 0x0D8C / PID 0x013A).
    var looksLikeBassJump: Bool {
        if name.localizedCaseInsensitiveContains("bassjump") { return true }
        let m = modelUID.lowercased()
        return isUSB && m.contains("0d8c") && m.contains("013a")
    }
}

enum AudioSystem {
    static func allDevices() -> [AudioDeviceInfo] {
        CA.objectList(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
            .compactMap(info(for:))
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        allDevices().filter { $0.outputChannels > 0 && $0.transport != kAudioDeviceTransportTypeAggregate }
    }

    static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = CA.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = CA.string(id, kAudioObjectPropertyName) ?? uid
        let model = CA.string(id, kAudioDevicePropertyModelUID) ?? ""
        let transport = (try? CA.get(id, address(kAudioDevicePropertyTransportType), UInt32(0))) ?? 0
        return AudioDeviceInfo(id: id, uid: uid, name: name, modelUID: model,
                               transport: transport, outputChannels: outputChannelCount(id))
    }

    static func outputChannelCount(_ id: AudioObjectID) -> Int { channelCount(id, kAudioObjectPropertyScopeOutput) }
    static func inputChannelCount(_ id: AudioObjectID) -> Int { channelCount(id, kAudioObjectPropertyScopeInput) }

    static func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func device(uid: String) -> AudioDeviceInfo? {
        allDevices().first { $0.uid == uid }
    }

    /// The device's preferred stereo pair as 0-based channel indexes (defaults to 0/1).
    static func preferredStereo(_ id: AudioObjectID) -> (left: Int, right: Int) {
        struct Pair { var l: UInt32; var r: UInt32 }
        let a = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        guard CA.has(id, a), let p = try? CA.get(id, a, Pair(l: 1, r: 2)), p.l >= 1, p.r >= 1 else { return (0, 1) }
        return (Int(p.l) - 1, Int(p.r) - 1)
    }

    /// Channel labels from the device's preferred output channel layout (kAudioChannelLabel_*),
    /// one per channel; empty if the device doesn't describe its channels.
    static func outputChannelLabels(_ id: AudioObjectID) -> [UInt32] {
        var a = address(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        guard let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions) else { return [] }
        let descriptions = (raw + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { descriptions[$0].mChannelLabel }
    }

    static func defaultOutputDevice() -> AudioObjectID {
        (try? CA.get(AudioObjectID(kAudioObjectSystemObject),
                     address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(kAudioObjectUnknown)))
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// True when the device is a set of speakers the sub should accompany (built-in, display, USB/Thunderbolt
    /// speakers) — false for headphones, Bluetooth and AirPlay.
    static func isSpeakers(_ id: AudioObjectID) -> Bool {
        guard let info = info(for: id) else { return false }
        let wireless: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                                     kAudioDeviceTransportTypeAirPlay]
        if wireless.contains(info.transport) { return false }
        for word in ["headphone", "airpods", "headset", "earphone"] where info.name.localizedCaseInsensitiveContains(word) {
            return false
        }
        if info.isBuiltIn {
            let ds = address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
            if CA.has(id, ds), let source = try? CA.get(id, ds, UInt32(0)) {
                return source == 0x6973_706B // 'ispk' internal speakers ('hdpn' = headphones)
            }
        }
        return true
    }

    /// Output volume (0...1) of a device, or nil if it has no software volume control.
    static func volume(_ id: AudioObjectID) -> Float? {
        let main = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        if CA.has(id, main) { return try? CA.get(id, main, Float32(0)) }
        var values: [Float] = []
        for ch: UInt32 in [1, 2] {
            let a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
            if CA.has(id, a), let v = try? CA.get(id, a, Float32(0)) { values.append(v) }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    static func isMuted(_ id: AudioObjectID) -> Bool {
        let a = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        guard CA.has(id, a), let m = try? CA.get(id, a, UInt32(0)) else { return false }
        return m != 0
    }

    /// True if any process other than ours is currently sending audio to an output.
    static func otherProcessIsPlaying() -> Bool {
        let me = getpid()
        for p in CA.objectList(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyProcessObjectList)) {
            guard let running = try? CA.get(p, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)), running != 0 else { continue }
            if let pid = try? CA.get(p, address(kAudioProcessPropertyPID), pid_t(0)), pid != me { return true }
        }
        return false
    }

    static func ownProcessObject() -> AudioObjectID {
        var pid = getpid()
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr ? obj : AudioObjectID(kAudioObjectUnknown)
    }
}

/// Keeps a Core Audio property listener alive and removes it on deinit.
final class PropertyListener {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        self.object = object
        self.addr = addr
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &self.addr, DispatchQueue.main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &addr, DispatchQueue.main, block)
    }
}
