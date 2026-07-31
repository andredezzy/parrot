import AVFoundation
import CoreAudio
import Foundation

// The private aggregate CoreAudio spins up for a client is only visible to that
// client, so create an engine and touch its input node before enumerating.
let engine = AVAudioEngine()
_ = engine.inputNode.outputFormat(forBus: 0)

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
             UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    return String(bytes: b, encoding: .ascii) ?? "?"
}

func devices() -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)
    return ids
}

func u32(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &a) else { return nil }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func str(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let ok = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard ok == noErr, let cf else { return nil }
    return cf.takeRetainedValue() as String
}

func inputChannels(_ id: AudioDeviceID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                       mScope: kAudioDevicePropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}

print(String(format: "%-42s %-4s %-8s %-7s %s", ("uid" as NSString).utf8String!,
             ("in" as NSString).utf8String!, ("hidden" as NSString).utf8String!,
             ("transp" as NSString).utf8String!, ("name" as NSString).utf8String!))
for id in devices() where inputChannels(id) > 0 {
    let uid = str(id, kAudioDevicePropertyDeviceUID) ?? "-"
    let name = str(id, kAudioObjectPropertyName) ?? "-"
    let hidden = u32(id, kAudioDevicePropertyIsHidden).map(String.init) ?? "n/a"
    let transport = u32(id, kAudioDevicePropertyTransportType).map(fourCC) ?? "n/a"
    print(String(format: "%-42@ %-4d %-8@ %-7@ %@", uid as NSString, inputChannels(id),
                 hidden as NSString, transport as NSString, name as NSString))
}

print("\n— composição dos aggregates —")
for id in devices() where inputChannels(id) > 0 {
    guard u32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate else { continue }
    var a = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &a) else {
        print("  \(str(id, kAudioDevicePropertyDeviceUID) ?? "?"): sem propriedade de composição")
        continue
    }
    var cf: Unmanaged<CFDictionary>?
    var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    let ok = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    guard ok == noErr, let cf else { print("  leitura falhou: \(ok)"); continue }
    let dict = cf.takeRetainedValue() as! [String: Any]
    print("  \(str(id, kAudioDevicePropertyDeviceUID) ?? "?")")
    for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
        print("     \(k) = \(v)")
    }
    print("     -> private key (\(kAudioAggregateDeviceIsPrivateKey)) = \(String(describing: dict[kAudioAggregateDeviceIsPrivateKey]))")
}
