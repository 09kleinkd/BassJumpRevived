// Prints channel layout / volume capabilities of every output device.
// Build: swiftc -O tools/devinfo.swift -o /tmp/devinfo && /tmp/devinfo
import CoreAudio

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: el)
}
func has(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool { var a = a; return AudioObjectHasProperty(id, &a) }

var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)

for id in ids {
    var na = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
    var name: Unmanaged<CFString>?
    var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(id, &na, 0, nil, &ns, &name)
    let n = (name?.takeRetainedValue() as String?) ?? "?"

    var la = addr(kAudioDevicePropertyPreferredChannelLayout)
    var lsz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &la, 0, nil, &lsz) == noErr, lsz > 0 else { continue }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(lsz), alignment: 8)
    defer { raw.deallocate() }
    AudioObjectGetPropertyData(id, &la, 0, nil, &lsz, raw)
    let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    let count = Int(layout.pointee.mNumberChannelDescriptions)
    let descs = (raw + MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!)
        .assumingMemoryBound(to: AudioChannelDescription.self)
    let labels = (0..<count).map { descs[$0].mChannelLabel }
    print("\(n): tag=\(layout.pointee.mChannelLayoutTag) labels=\(labels)")

    var sa = addr(kAudioDevicePropertyPreferredChannelsForStereo)
    var st: [UInt32] = [0, 0]; var ssz = UInt32(8)
    AudioObjectGetPropertyData(id, &sa, 0, nil, &ssz, &st)
    let vol = has(id, addr(kAudioDevicePropertyVolumeScalar))
    let volCh = (1...8).filter { has(id, addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, UInt32($0))) }
    let mute = has(id, addr(kAudioDevicePropertyMute))
    let vmv = has(id, addr(0x766d7663 /* 'vmvc' virtual main volume */))
    print("   stereo=\(st) mainVolume=\(vol) perChannelVolume=\(volCh) mute=\(mute) virtualMainVolume=\(vmv)")
}
