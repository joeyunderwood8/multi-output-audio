// Multi-Output Audio — menu-bar GUI for playing Mac audio to several devices at once.
//
// Shows every output device live (Bluetooth devices flagged as they connect),
// gives each device its own volume slider, and combines the selected outputs into
// one multi-output device with a single click.
//
// Build: ./build-app.sh   (produces "Multi-Output Audio.app")

import SwiftUI
import CoreAudio

// MARK: - CoreAudio layer

private let comboUID = "com.dualaudio.multi-output"
private let comboName = "Combined Output"

private func systemObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

private func allDeviceIDs() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject(), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>? = nil
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard err == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

private func deviceName(_ id: AudioDeviceID) -> String { stringProperty(id, kAudioObjectPropertyName) ?? "(unnamed)" }
private func deviceUID(_ id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }

private func transportType(_ id: AudioDeviceID) -> UInt32 {
    var addr = address(kAudioDevicePropertyTransportType)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return value
}

private func isBluetooth(_ id: AudioDeviceID) -> Bool {
    let t = transportType(id)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}
private func isBuiltIn(_ id: AudioDeviceID) -> Bool { transportType(id) == kAudioDeviceTransportTypeBuiltIn }

private func outputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}
private func isOutputDevice(_ id: AudioDeviceID) -> Bool { outputChannelCount(id) > 0 }

private let volumeElements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

private func getVolume(_ id: AudioDeviceID) -> Float? {
    for element in volumeElements {
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(id, &addr) else { continue }
        var size = UInt32(MemoryLayout<Float>.size)
        var value: Float = 0
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr { return value }
    }
    return nil
}

@discardableResult
private func applyVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
    var didSet = false
    for element in volumeElements {
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(id, &addr) else { continue }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &addr, &settable)
        guard settable.boolValue else { continue }
        var value = max(0, min(1, volume))
        if AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr {
            didSet = true
            if element == kAudioObjectPropertyElementMain { break }
        }
    }
    return didSet
}

private func isVolumeSettable(_ id: AudioDeviceID) -> Bool {
    for element in volumeElements {
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(id, &addr) else { continue }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &addr, &settable)
        if settable.boolValue { return true }
    }
    return false
}

private func currentDefaultOutput() -> AudioDeviceID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var id: AudioDeviceID = 0
    AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, &id)
    return id
}

@discardableResult
private func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID = id
    return AudioObjectSetPropertyData(systemObject(), &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID) == noErr
}

private func existingCombo() -> AudioDeviceID? { allDeviceIDs().first { deviceUID($0) == comboUID } }

private func comboSubDeviceUIDs(_ id: AudioDeviceID) -> [String] {
    var addr = address(kAudioAggregateDevicePropertyFullSubDeviceList)
    var arr: Unmanaged<CFArray>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
    let err = withUnsafeMutablePointer(to: &arr) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard err == noErr, let arr else { return [] }
    return (arr.takeRetainedValue() as? [String]) ?? []
}

// MARK: - View model

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
    let isBuiltIn: Bool
    let isCombo: Bool
    let volumeSettable: Bool
    var volume: Double   // 0...1; 0 when not readable
}

final class AudioModel: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var comboActive = false
    @Published var defaultOutputID: AudioDeviceID = 0
    @Published var statusMessage: String?
    @Published var selected: Set<AudioDeviceID> = []

    private var knownBluetoothUIDs: Set<String> = []
    private var volumeListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        reload(announceNewDevices: false)
        registerSystemListeners()
    }

    // Devices with an adjustable volume slider — the real AirPods, not the aggregate combo.
    var sliderDevices: [OutputDevice] { devices.filter { !$0.isCombo } }

    var bluetoothOutputs: [OutputDevice] { devices.filter { $0.isBluetooth && !$0.isCombo } }

    var selectedCount: Int { devices.filter { selected.contains($0.id) && !$0.isCombo }.count }

    var combinableCount: Int { devices.filter { !$0.isCombo }.count }

    // MARK: Listeners

    private func registerSystemListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.reload(announceNewDevices: true) }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            if AudioObjectAddPropertyListenerBlock(systemObject(), &addr, DispatchQueue.main, block) == noErr {
                systemListeners.append((addr, block))
            }
        }
    }

    private func refreshVolumeListeners() {
        for (id, var addr, block) in volumeListeners {
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        }
        volumeListeners.removeAll()

        for device in devices where device.volumeSettable {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateVolume(for: device.id) }
            }
            var addr = address(kAudioDevicePropertyVolumeScalar,
                               scope: kAudioDevicePropertyScopeOutput,
                               element: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(device.id, &addr, DispatchQueue.main, block) == noErr {
                volumeListeners.append((device.id, addr, block))
            }
        }
    }

    private func updateVolume(for id: AudioDeviceID) {
        guard let idx = devices.firstIndex(where: { $0.id == id }), let v = getVolume(id) else { return }
        if abs(devices[idx].volume - Double(v)) > 0.001 { devices[idx].volume = Double(v) }
    }

    // MARK: State

    func reload(announceNewDevices: Bool) {
        // If a mix is running but fewer than two of its devices are still
        // connected, there's nothing left to share — tear it down and let
        // macOS route audio to whatever single device remains.
        if let combo = existingCombo() {
            let liveUIDs = Set(allDeviceIDs().filter { isOutputDevice($0) }.compactMap { deviceUID($0) })
            let stillPresent = comboSubDeviceUIDs(combo).filter { liveUIDs.contains($0) }
            if stillPresent.count < 2 {
                if let builtIn = allDeviceIDs().first(where: { isOutputDevice($0) && isBuiltIn($0) }) {
                    setDefaultOutput(builtIn)
                }
                AudioHardwareDestroyAggregateDevice(combo)
                flash("A device dropped — your Mac is handling audio again")
            }
        }

        let combo = existingCombo()
        comboActive = combo != nil
        defaultOutputID = currentDefaultOutput()

        let list = allDeviceIDs()
            .filter { isOutputDevice($0) }
            .map { id -> OutputDevice in
                OutputDevice(id: id,
                             uid: deviceUID(id) ?? "",
                             name: deviceName(id),
                             isBluetooth: isBluetooth(id),
                             isBuiltIn: isBuiltIn(id),
                             isCombo: deviceUID(id) == comboUID,
                             volumeSettable: isVolumeSettable(id),
                             volume: Double(getVolume(id) ?? 0))
            }
            .sorted { ($0.isBluetooth ? 0 : 1, $0.name) < ($1.isBluetooth ? 0 : 1, $1.name) }

        let currentBT = Set(list.filter { $0.isBluetooth }.map { $0.uid })
        if announceNewDevices {
            let newlyConnected = currentBT.subtracting(knownBluetoothUIDs)
            if let uid = newlyConnected.first, let dev = list.first(where: { $0.uid == uid }) {
                flash("🎧 \(dev.name) connected")
            }
        }
        knownBluetoothUIDs = currentBT

        devices = list
        syncSelection()
        refreshVolumeListeners()
    }

    // Keep the checkbox selection consistent with reality: mirror an existing
    // combo's members, prune vanished devices, and default to the Bluetooth
    // outputs when nothing is chosen yet.
    private func syncSelection() {
        let selectableIDs = Set(devices.filter { !$0.isCombo }.map { $0.id })
        if let combo = existingCombo() {
            let subUIDs = Set(comboSubDeviceUIDs(combo))
            let inCombo = devices.filter { subUIDs.contains($0.uid) }.map { $0.id }
            if !inCombo.isEmpty { selected = Set(inCombo); return }
        }
        selected.formIntersection(selectableIDs)
        if selected.isEmpty {
            selected = Set(devices.filter { $0.isBluetooth && !$0.isCombo }.map { $0.id })
        }
    }

    func toggleSelection(_ id: AudioDeviceID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func flash(_ message: String) {
        statusMessage = message
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.statusMessage == shown { self?.statusMessage = nil }
        }
    }

    // MARK: Actions

    func setVolume(_ id: AudioDeviceID, _ value: Double) {
        if let idx = devices.firstIndex(where: { $0.id == id }) { devices[idx].volume = value }
        applyVolume(id, Float(value))
    }

    func combine() {
        let chosen = devices.filter { selected.contains($0.id) && !$0.isCombo }
        guard chosen.count >= 2 else {
            flash("Select at least two devices to combine")
            return
        }
        if let old = existingCombo() { AudioHardwareDestroyAggregateDevice(old) }

        // First device is the clock master; the rest get drift compensation so
        // their independent clocks stay aligned with it.
        let subDeviceList: [[String: Any]] = chosen.enumerated().map { index, device in
            var entry: [String: Any] = [kAudioSubDeviceUIDKey as String: device.uid]
            if index > 0 { entry[kAudioSubDeviceDriftCompensationKey as String] = 1 }
            return entry
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: comboName,
            kAudioAggregateDeviceUIDKey as String: comboUID,
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceMainSubDeviceKey as String: chosen[0].uid,
            kAudioAggregateDeviceSubDeviceListKey as String: subDeviceList,
        ]
        var comboID: AudioDeviceID = 0
        if AudioHardwareCreateAggregateDevice(description as CFDictionary, &comboID) == noErr {
            setDefaultOutput(comboID)
            flash("Playing to \(chosen.count) devices")
        } else {
            flash("Couldn't create the combined device")
        }
        reload(announceNewDevices: false)
    }

    func separate() {
        guard let combo = existingCombo() else { return }
        if let builtIn = devices.first(where: { $0.isBuiltIn }) { setDefaultOutput(builtIn.id) }
        AudioHardwareDestroyAggregateDevice(combo)
        flash("Split back to a single output")
        reload(announceNewDevices: false)
    }
}

// MARK: - Views

struct DeviceRow: View {
    @ObservedObject var model: AudioModel
    let device: OutputDevice

    private var isSelected: Bool { model.selected.contains(device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.toggleSelection(device.id) } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Include in the combined output")
                Image(systemName: iconName)
                    .foregroundStyle(device.isBluetooth ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if device.id == model.defaultOutputID {
                    Text("output").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if device.volumeSettable {
                    Text("\(Int((device.volume * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if device.volumeSettable {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Slider(value: Binding(
                        get: { model.devices.first(where: { $0.id == device.id })?.volume ?? device.volume },
                        set: { model.setVolume(device.id, $0) }
                    ), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            } else {
                Text("Volume set on the device itself")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        if device.isCombo { return "airpodspro.chargingcase.wireless.fill" }
        if device.isBluetooth { return "airpodspro" }
        if device.isBuiltIn { return "laptopcomputer" }
        return "hifispeaker.fill"
    }
}

struct ContentView: View {
    @StateObject var model = AudioModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "headphones")
                Text("Multi-Output Audio").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if let msg = model.statusMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.vertical, 5).padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    .transition(.opacity)
            }

            if model.sliderDevices.isEmpty {
                Text("No output devices found.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(model.sliderDevices) { device in
                    DeviceRow(model: model, device: device)
                }
            }

            Divider()

            Button(action: model.combine) {
                Label(model.comboActive ? "Update mix — \(model.selectedCount) devices"
                                        : "Play to \(model.selectedCount) devices",
                      systemImage: "airpodspro")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.selectedCount < 2)

            if model.comboActive {
                Button(action: model.separate) {
                    Label("Stop — back to one output", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
            }

            if model.combinableCount < 2 {
                Text("Only one output connected — your Mac is playing to it normally. Connect another to combine.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if model.selectedCount < 2 {
                Text("Tick at least two devices to combine them.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.2), value: model.statusMessage)
        .animation(.easeInOut(duration: 0.2), value: model.comboActive)
    }
}

@main
struct MultiOutputAudioApp: App {
    var body: some Scene {
        MenuBarExtra("Multi-Output Audio", systemImage: "headphones") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
