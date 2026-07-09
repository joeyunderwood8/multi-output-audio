// dualaudio — play Mac audio to two AirPods (or any two outputs) at once.
//
// Usage:
//   dualaudio list                 Show all output devices
//   dualaudio on                   Combine the two connected Bluetooth outputs
//   dualaudio on "Name A" "Name B" Combine two specific devices (partial names ok)
//   dualaudio off                  Remove the combo and switch back to built-in output
//   dualaudio watch                Keep the combo as output when macOS auto-switches away
//   dualaudio install              Run the watcher in the background, starting at login
//   dualaudio uninstall            Remove the background watcher

import CoreAudio
import Foundation

let comboUID = "com.dualaudio.multi-output"
let comboName = "Both AirPods"

// MARK: - CoreAudio helpers

func systemObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func globalAddress(_ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var address = globalAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject(), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject(), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = globalAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    let err = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    guard err == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func deviceName(_ id: AudioDeviceID) -> String { stringProperty(id, kAudioObjectPropertyName) ?? "(unnamed)" }
func deviceUID(_ id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

func transportType(_ id: AudioDeviceID) -> UInt32 {
    var address = globalAddress(kAudioDevicePropertyTransportType)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    return value
}

func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

func isBuiltIn(_ id: AudioDeviceID) -> Bool { transportType(id) == kAudioDeviceTransportTypeBuiltIn }

func outputChannelCount(_ id: AudioDeviceID) -> Int {
    var address = globalAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func isOutputDevice(_ id: AudioDeviceID) -> Bool { outputChannelCount(id) > 0 }

@discardableResult
func trySetDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID = id
    let err = AudioObjectSetPropertyData(systemObject(), &address, 0, nil,
                                         UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
    return err == noErr
}

func setDefaultOutput(_ id: AudioDeviceID) {
    if !trySetDefaultOutput(id) { fail("Could not set default output device") }
}

func currentDefaultOutput() -> AudioDeviceID {
    var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var id: AudioDeviceID = 0
    AudioObjectGetPropertyData(systemObject(), &address, 0, nil, &size, &id)
    return id
}

func existingCombo() -> AudioDeviceID? {
    allDevices().first { deviceUID($0) == comboUID }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("Error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Commands

func listCommand() {
    print("Output devices:")
    for id in allDevices() where isOutputDevice(id) {
        var tags: [String] = []
        if isBluetooth(id) { tags.append("bluetooth") }
        if isBuiltIn(id) { tags.append("built-in") }
        if deviceUID(id) == comboUID { tags.append("combo — created by this tool") }
        let suffix = tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))"
        print("  • \(deviceName(id))\(suffix)")
    }
}

func resolveDevice(matching query: String) -> AudioDeviceID {
    let matches = allDevices().filter {
        isOutputDevice($0) && deviceUID($0) != comboUID &&
        deviceName($0).lowercased().contains(query.lowercased())
    }
    if matches.isEmpty { fail("No output device matching \"\(query)\". Run `dualaudio list` to see devices.") }
    if matches.count > 1 { fail("\"\(query)\" matches more than one device — be more specific.") }
    return matches[0]
}

func onCommand(_ args: [String]) {
    if let old = existingCombo() {
        AudioHardwareDestroyAggregateDevice(old)
    }

    let devices: [AudioDeviceID]
    if args.count == 2 {
        devices = [resolveDevice(matching: args[0]), resolveDevice(matching: args[1])]
        if devices[0] == devices[1] { fail("Both names matched the same device.") }
    } else if args.isEmpty {
        let bt = allDevices().filter { isOutputDevice($0) && isBluetooth($0) }
        if bt.count < 2 {
            let found = bt.map(deviceName).joined(separator: ", ")
            fail("Need two connected Bluetooth audio devices, found \(bt.count)"
                 + (bt.isEmpty ? "." : " (\(found)).")
                 + "\nConnect both AirPods in System Settings → Bluetooth, then try again."
                 + "\nOr name devices explicitly: dualaudio on \"AirPods A\" \"AirPods B\"")
        }
        if bt.count > 2 {
            fail("Found \(bt.count) Bluetooth outputs: \(bt.map(deviceName).joined(separator: ", "))."
                 + "\nName the two you want: dualaudio on \"Name A\" \"Name B\"")
        }
        devices = bt
    } else {
        fail("`on` takes zero or two device names.")
    }

    guard let uid1 = deviceUID(devices[0]), let uid2 = deviceUID(devices[1]) else {
        fail("Could not read device UIDs.")
    }

    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: comboName,
        kAudioAggregateDeviceUIDKey as String: comboUID,
        kAudioAggregateDeviceIsStackedKey as String: 1,  // stacked = multi-output (same audio to both)
        kAudioAggregateDeviceMainSubDeviceKey as String: uid1,
        kAudioAggregateDeviceSubDeviceListKey as String: [
            [kAudioSubDeviceUIDKey as String: uid1],
            [kAudioSubDeviceUIDKey as String: uid2,
             kAudioSubDeviceDriftCompensationKey as String: 1],
        ],
    ]

    var comboID: AudioDeviceID = 0
    let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &comboID)
    if err != noErr { fail("Could not create the multi-output device (error \(err))") }

    setDefaultOutput(comboID)
    print("✓ \"\(comboName)\" is now your Mac's output:")
    print("    \(deviceName(devices[0]))  +  \(deviceName(devices[1]))")
    print("Note: the Mac volume keys don't control multi-output devices —")
    print("set each AirPods' volume from the Sound menu or on the AirPods themselves.")
}

func offCommand() {
    guard let combo = existingCombo() else {
        print("No combo device found — nothing to remove.")
        return
    }
    // Move output off the combo before destroying it so audio doesn't drop to nowhere.
    if let builtIn = allDevices().first(where: { isOutputDevice($0) && isBuiltIn($0) }) {
        setDefaultOutput(builtIn)
        print("Output switched back to \(deviceName(builtIn)).")
    }
    let err = AudioHardwareDestroyAggregateDevice(combo)
    if err != noErr { fail("Could not remove the combo device (error \(err))") }
    print("✓ Combo device removed.")
}

// MARK: - Volume

func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioDevicePropertyScopeOutput,
                               mElement: element)
}

func getVolume(_ id: AudioDeviceID) -> Float32? {
    for element in [UInt32(kAudioObjectPropertyElementMain), 1, 2] {
        var address = volumeAddress(element)
        guard AudioObjectHasProperty(id, &address) else { continue }
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr { return value }
    }
    return nil
}

func setVolume(_ id: AudioDeviceID, _ volume: Float32) -> Bool {
    var didSet = false
    for element in [UInt32(kAudioObjectPropertyElementMain), 1, 2] {
        var address = volumeAddress(element)
        guard AudioObjectHasProperty(id, &address) else { continue }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &address, &settable)
        guard settable.boolValue else { continue }
        var value = volume
        if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
            didSet = true
            if element == kAudioObjectPropertyElementMain { break }
        }
    }
    return didSet
}

func volumeTargets() -> [AudioDeviceID] {
    // With a combo active, control the real devices inside it (the combo itself has no volume).
    if existingCombo() != nil {
        let bt = allDevices().filter { isOutputDevice($0) && isBluetooth($0) }
        if !bt.isEmpty { return bt }
    }
    return [currentDefaultOutput()]
}

func volCommand(_ args: [String]) {
    let targets = volumeTargets()
    if targets.isEmpty { fail("No output devices found to adjust.") }

    if let arg = args.first {
        for id in targets {
            let current = getVolume(id) ?? 0.5
            let new: Float32
            switch arg {
            case "up", "+": new = min(current + 0.1, 1)
            case "down", "-": new = max(current - 0.1, 0)
            default:
                guard let pct = Float32(arg.replacingOccurrences(of: "%", with: "")), (0...100).contains(pct) else {
                    fail("Give a percentage (0–100), or up/down. Example: dualaudio vol 40")
                }
                new = pct / 100
            }
            if !setVolume(id, new) {
                print("  \(deviceName(id)): volume not adjustable from the Mac — use the device's own controls")
            }
        }
    }
    for id in targets {
        let display = getVolume(id).map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
        print("  \(deviceName(id)): \(display)")
    }
}

func reassertCombo() {
    guard let combo = existingCombo() else { return }
    if currentDefaultOutput() != combo {
        if trySetDefaultOutput(combo) {
            print("Output stolen by another device — switched back to \(comboName).")
        }
    }
}

func watchCommand() {
    let listener: AudioObjectPropertyListenerBlock = { _, _ in reassertCombo() }
    var defaultOutputAddress = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceListAddress = globalAddress(kAudioHardwarePropertyDevices)
    AudioObjectAddPropertyListenerBlock(systemObject(), &defaultOutputAddress, .main, listener)
    AudioObjectAddPropertyListenerBlock(systemObject(), &deviceListAddress, .main, listener)
    reassertCombo()
    print("Watching. While a \"\(comboName)\" combo exists, it stays the Mac's output. Ctrl-C to stop.")
    dispatchMain()
}

let launchAgentLabel = "com.dualaudio.watch"
var launchAgentPlistPath: String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
}

func runLaunchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func installCommand() {
    let exePath = URL(fileURLWithPath: CommandLine.arguments[0],
                      relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(launchAgentLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(exePath)</string>
            <string>watch</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
    </dict>
    </plist>
    """
    do {
        try FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                                withIntermediateDirectories: true)
        try plist.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
    } catch {
        fail("Could not write \(launchAgentPlistPath): \(error.localizedDescription)")
    }
    let domain = "gui/\(getuid())"
    runLaunchctl(["bootout", domain, launchAgentPlistPath])  // reload if already installed
    runLaunchctl(["bootstrap", domain, launchAgentPlistPath])
    print("✓ Background watcher installed (runs now and at every login).")
    print("While a \"\(comboName)\" combo exists, macOS can't steal the output from it.")
    print("Remove anytime with: dualaudio uninstall")
}

func uninstallCommand() {
    runLaunchctl(["bootout", "gui/\(getuid())", launchAgentPlistPath])
    try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
    print("✓ Background watcher removed.")
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list": listCommand()
case "on": onCommand(Array(args.dropFirst()))
case "off": offCommand()
case "vol", "volume": volCommand(Array(args.dropFirst()))
case "watch": watchCommand()
case "install": installCommand()
case "uninstall": uninstallCommand()
default:
    print("""
    dualaudio — listen on two AirPods at once

    Usage:
      dualaudio list                  Show output devices
      dualaudio on                    Combine the two connected Bluetooth outputs
      dualaudio on "Name A" "Name B"  Combine two specific devices
      dualaudio off                   Remove the combo, back to built-in output
      dualaudio vol                   Show volume of both AirPods
      dualaudio vol 40                Set both to 40%  (also: vol up / vol down)
      dualaudio watch                 Keep the combo as output (foreground)
      dualaudio install               Run the watcher in the background at login
      dualaudio uninstall             Remove the background watcher
    """)
}
