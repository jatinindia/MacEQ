import AppKit
import Carbon.HIToolbox
import CoreAudio
import Foundation
import MacEQCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// libsystem SPI: the PID of the app responsible for another PID (how Activity
/// Monitor groups helper processes under their app). Required to match browser
/// audio helpers against user-excluded apps; safe for Developer ID distribution.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// One graphic-EQ band: display label and peaking-filter center frequency.
struct EQBand {
    let label: String
    let frequency: Double
}

/// Which editing surface drives the DSP chain.
enum EQMode: String {
    case graphic
    case parametric
}

/// Everything a device remembers, keyed by its Core Audio UID.
/// The parametric chain is stored as APO config text (the native format).
struct DeviceProfile: Codable {
    var gains: [Double]
    var mode: String
    var parametricConfig: String
    var manualPreampDB: Double
    var autoPreampEnabled: Bool
    var eqEnabled: Bool
    // Optional so profiles saved before convolution existed still decode.
    var impulseResponsePath: String?
    var convolutionEnabled: Bool?
    // Optional so profiles saved before custom bands existed still decode.
    var bandFrequencies: [Double]?
}

/// Live spectrum levels, kept out of EQController on purpose: the popover
/// observes the controller, so publishing 20 fps spectrum frames there re-rendered
/// the entire popover (~99% CPU). Only the spectrum overlay observes this.
@MainActor
final class SpectrumModel: ObservableObject {
    @Published var levelsDB: [Double] = []
}

/// Status/diagnostics text refreshed twice a second, isolated from EQController
/// for the same reason as SpectrumModel: only the footer should re-render on
/// the poll tick, not the whole popover (sliders, menu, curve).
@MainActor
final class EngineStatusModel: ObservableObject {
    @Published var summary = "Not running"
    @Published var diagnosticLines: [String] = []
}

/// A user-named EQ snapshot, applied on demand from the presets menu. Captures
/// the tuning (bands, mode, parametric chain, preamp) but not device-level state
/// like the bypass switch or the impulse response.
struct NamedPreset: Codable {
    var name: String
    var gains: [Double]
    var mode: String
    var parametricConfig: String
    var manualPreampDB: Double
    var autoPreampEnabled: Bool
    // Optional so presets saved before custom bands existed still decode.
    var bandFrequencies: [Double]?
}

/// UI-facing state for the 10-band graphic EQ. Owns the audio engine, rebuilds
/// the DSP kernel on every change, persists settings, and mirrors status for
/// debugging. Main-actor: all mutations come from the UI or main-queue callbacks.
@MainActor
final class EQController: ObservableObject {
    /// Graphic-EQ bands, user-editable (add/remove) and persisted. Always kept
    /// index-aligned with `gains` — every mutation goes through the add/remove/
    /// restore methods below, which update both together.
    @Published private(set) var bands: [EQBand]
    /// PRD choice for octave-band graphic EQ.
    static let bandQ = 2.2
    static let gainRange: ClosedRange<Double> = -12...12

    @Published var gains: [Double] {
        didSet { settingsChanged() }
    }
    @Published var manualPreampDB: Double {
        didSet { settingsChanged() }
    }
    @Published var autoPreampEnabled: Bool {
        didSet { settingsChanged() }
    }
    @Published var eqEnabled: Bool {
        didSet { settingsChanged() }
    }
    @Published var mode: EQMode {
        didSet { settingsChanged() }
    }
    @Published var limiterEnabled: Bool {
        didSet { settingsChanged() }
    }
    @Published var parametricFilters: [FilterSpec] {
        didSet { settingsChanged() }
    }
    /// Last parse error from the config text editor, shown inline.
    @Published var configParseError: String?
    /// What the last successful paste/import left out (lines that don't affect
    /// the sound), shown under the parametric editor. nil when nothing was.
    @Published private(set) var configImportNotice: String?
    @Published var convolutionEnabled: Bool {
        didSet {
            guard !isApplyingProfile else { return }
            defaults.set(convolutionEnabled, forKey: "convolutionEnabled")
            saveProfileForCurrentDevice()
            rebuildConvolver()
        }
    }
    /// Display name of the loaded impulse response file, nil when none is set.
    @Published private(set) var impulseResponseName: String?
    @Published private(set) var namedPresets: [NamedPreset] = []

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var effectivePreampDB: Double = 0
    let spectrum = SpectrumModel()
    let statusModel = EngineStatusModel()
    private var cpuPercent: Double = 0
    @Published var bufferFrames: Int {
        didSet {
            guard !isApplyingProfile else { return }
            defaults.set(bufferFrames, forKey: "bufferFrames")
            // Not gated on isRunning: if the old size was the reason the
            // engine failed to start, picking another must retry right away.
            restartEngine()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isApplyingProfile else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorMessage = "Launch-at-login change failed: \(error)"
            }
        }
    }
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            guard !isApplyingProfile else { return }
            defaults.set(Array(excludedBundleIDs).sorted(), forKey: "excludedBundleIDs")
            restartForExclusionChange()
        }
    }

    private let engine = AudioTapEngine()
    /// Keeps recently replaced kernels alive so the audio thread's reference
    /// release is never the final one (final release may free memory, which is
    /// forbidden on the real-time thread).
    private var retiredKernels: [EQKernel] = []
    private var retiredConvolvers: [FIRConvolver] = []
    private var impulseResponseURL: URL?
    /// One block of added latency; 512 frames ≈ 10.7 ms at 48 kHz.
    static let convolutionBlockSize = 512
    /// Always-on while running: the zero-buffer watchdog's heartbeat. Slow on
    /// purpose — the status display has its own timer, gated on visibility.
    private var watchdogTimer: Timer?
    /// Runs only while the popover is on screen: status formatting and the
    /// Core Audio diagnostic queries are pure display work, and burning them
    /// twice a second around the clock was the bulk of MacEQ's idle CPU.
    private var statusTimer: Timer?
    /// Set by the popover's onAppear/onDisappear (same mechanism the spectrum
    /// display already uses).
    var popoverIsVisible = false {
        didSet { updateStatusPolling() }
    }
    private let defaults = UserDefaults.standard
    /// Suppresses persistence/kernel rebuilds while a device profile is being applied.
    private var isApplyingProfile = false
    /// UID of the device whose profile is currently loaded into the published state.
    private var activeProfileUID: String?

    init() {
        let frequencies = defaults.array(forKey: "bandFrequencies") as? [Double]
            ?? defaultGraphicBandFrequencies
        bands = frequencies.map { EQBand(label: graphicBandLabel(frequency: $0), frequency: $0) }
        let storedGains = defaults.array(forKey: "bandGains") as? [Double]
        gains = storedGains?.count == frequencies.count
            ? storedGains!
            : Array(repeating: 0.0, count: frequencies.count)
        manualPreampDB = defaults.object(forKey: "preampDB") as? Double ?? 0.0
        autoPreampEnabled = defaults.object(forKey: "autoPreampEnabled") as? Bool ?? true
        eqEnabled = defaults.object(forKey: "eqEnabled") as? Bool ?? true
        mode = EQMode(rawValue: defaults.string(forKey: "eqMode") ?? "") ?? .graphic
        limiterEnabled = defaults.object(forKey: "limiterEnabled") as? Bool ?? true
        // Parametric state persists in the native APO config.txt format.
        if let storedConfig = defaults.string(forKey: "parametricConfig"),
           let preset = try? parseAPOConfig(storedConfig).preset {
            parametricFilters = preset.filters
        } else {
            parametricFilters = []
        }

        excludedBundleIDs = Set(defaults.stringArray(forKey: "excludedBundleIDs") ?? [])
        bufferFrames = defaults.object(forKey: "bufferFrames") as? Int ?? 0
        convolutionEnabled = defaults.object(forKey: "convolutionEnabled") as? Bool ?? false
        if let path = defaults.string(forKey: "impulseResponsePath") {
            impulseResponseURL = URL(fileURLWithPath: path)
            impulseResponseName = (path as NSString).lastPathComponent
        }
        if let data = defaults.data(forKey: "namedPresets"),
           let presets = try? JSONDecoder().decode([NamedPreset].self, from: data) {
            namedPresets = presets
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // false until the user answers the one-time question (see setUpUpdateChecks).
        updateChecksEnabled = defaults.object(forKey: "updateChecksEnabled") as? Bool ?? false
        availableUpdateVersion = Self.newerKnownRelease(defaults: defaults)

        engine.onDefaultOutputDeviceChanged = { [weak self] in
            self?.handleDeviceChange()
        }
        engine.onProcessListChanged = { [weak self] in
            self?.processListChangedSinceScan = true
            self?.scheduleExclusionRecheck()
        }
        engine.onSampleRateChanged = { [weak self] in
            self?.handleDeviceChange()
        }
    }

    // MARK: - Exclude list

    /// Core Audio process objects whose *responsible app* is excluded.
    ///
    /// Browser/Electron audio comes from helper processes (WebKit GPU, Chrome
    /// Helper) whose own bundle IDs never match the app the user excluded, so each
    /// audio process is attributed to the app responsible for it (the same mapping
    /// Activity Monitor uses) before checking the exclude set.
    private func resolveExcludedAudioProcesses() -> (objects: [AudioObjectID], pids: [pid_t]) {
        guard !excludedBundleIDs.isEmpty else { return ([], []) }
        var objects: [AudioObjectID] = []
        var pids: [pid_t] = []
        do {
            for object in try audioProcessObjectIDs() {
                let processPID = try pid(ofAudioProcess: object)
                guard processPID > 0 else { continue }
                let responsiblePID = responsibility_get_pid_responsible_for_pid(processPID)
                let bundleID = NSRunningApplication(processIdentifier: responsiblePID)?.bundleIdentifier
                    ?? NSRunningApplication(processIdentifier: processPID)?.bundleIdentifier
                if let bundleID, excludedBundleIDs.contains(bundleID) {
                    objects.append(object)
                    pids.append(processPID)
                }
            }
        } catch {
            errorMessage = "Exclude-list resolution failed: \(error)"
        }
        return (objects, pids)
    }

    private func restartForExclusionChange() {
        guard isRunning else { return }
        restartEngine()
    }

    private var lastExcludedPIDs: [pid_t] = []
    private var exclusionRecheck: DispatchWorkItem?

    /// Core Audio's process list changed. If the resolved excluded process set
    /// differs from what the tap was built with, rebuild it (debounced — process
    /// churn is bursty and each rebuild briefly interrupts audio).
    private func scheduleExclusionRecheck() {
        guard isRunning, !excludedBundleIDs.isEmpty else { return }
        exclusionRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            let current = self.resolveExcludedAudioProcesses().pids.sorted()
            if current != self.lastExcludedPIDs {
                self.restartForExclusionChange()
            }
        }
        exclusionRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - Engine lifecycle

    /// What the user asked for (launch, Start/Stop in the menu), as opposed to
    /// `isRunning`, which is what the engine currently manages. The two differ
    /// while a failed start waits to be retried: every automatic restart path
    /// (device change, rate change, watchdog, retry) acts on this intent, so a
    /// single failure can no longer leave the EQ stopped for good.
    private var wantsRunning = false
    private var consecutiveStartFailures = 0
    private var engineRetry: DispatchWorkItem?

    func start() {
        wantsRunning = true
        consecutiveStartFailures = 0
        startEngine()
    }

    func stop() {
        wantsRunning = false
        engineRetry?.cancel()
        engineRetry = nil
        stopEngine()
    }

    /// Rebuilds the audio path for a configuration change, if the user wants
    /// the engine running. Also recovers an engine that is waiting on a retry.
    private func restartEngine() {
        guard wantsRunning else { return }
        stopEngine()
        startEngine()
    }

    private func startEngine() {
        engineRetry?.cancel()
        engineRetry = nil
        errorMessage = nil
        do {
            let excluded = resolveExcludedAudioProcesses()
            engine.excludedProcessObjects = excluded.objects
            lastExcludedPIDs = excluded.pids.sorted()
            engine.preferredBufferFrames = UInt32(max(bufferFrames, 0))
            try engine.start()
            isRunning = true
            consecutiveStartFailures = 0
            loadProfileForCurrentDevice()
            rebuildKernel()
            rebuildConvolver()
            startPolling()
        } catch {
            engine.stop()
            isRunning = false
            consecutiveStartFailures += 1
            let delay = engineRestartDelay(afterConsecutiveFailures: consecutiveStartFailures)
            errorMessage = "\(String(describing: error)) — retrying in \(Int(delay)) s"
            scheduleEngineRetry(after: delay)
        }
    }

    private func scheduleEngineRetry(after delay: TimeInterval) {
        engineRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsRunning, !self.isRunning else { return }
            self.startEngine()
        }
        engineRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopEngine() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        statusTimer?.invalidate()
        statusTimer = nil
        // Retired, not just dropped: the audio thread may still hold it as its
        // last-processed kernel, and its release must not be the final one.
        retire(engine.kernelHolder.kernel)
        engine.kernelHolder.kernel = nil
        retireConvolver(engine.convolverHolder.convolver)
        engine.convolverHolder.convolver = nil
        engine.stop()
        isRunning = false
        statusModel.summary = "Not running"
        statusModel.diagnosticLines = []
    }

    /// Clears the error line. Errors are otherwise only replaced or cleared by
    /// the next engine start, so a fixed problem could linger indefinitely. A
    /// failure that is still happening (e.g. the engine retry) reports again.
    func dismissError() {
        errorMessage = nil
    }

    func resetAllBands() {
        gains = Array(repeating: 0.0, count: bands.count)
    }

    // MARK: - Graphic band editing

    /// Adds a graphic band at `frequency` with 0 dB gain, keeping the list
    /// sorted. Returns false (and surfaces the reason) for invalid frequencies.
    func addGraphicBand(frequency: Double) -> Bool {
        do {
            let result = try insertGraphicBand(frequency: frequency, into: bands.map(\.frequency))
            bands = result.frequencies.map {
                EQBand(label: graphicBandLabel(frequency: $0), frequency: $0)
            }
            gains.insert(0, at: result.index)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Retunes one band. The list stays sorted, so the band (and its gain) may
    /// move; returns false and surfaces the reason if the frequency is invalid.
    @discardableResult
    func setGraphicBandFrequency(at index: Int, to frequency: Double) -> Bool {
        do {
            let result = try updateGraphicBand(
                at: index, to: frequency, in: bands.map(\.frequency)
            )
            let gain = gains[index]
            bands = result.frequencies.map {
                EQBand(label: graphicBandLabel(frequency: $0), frequency: $0)
            }
            gains.remove(at: index)
            gains.insert(gain, at: result.index)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    func removeGraphicBand(at index: Int) {
        do {
            let frequencies = try MacEQCore.removeGraphicBand(at: index, from: bands.map(\.frequency))
            bands = frequencies.map { EQBand(label: graphicBandLabel(frequency: $0), frequency: $0) }
            gains.remove(at: index)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Back to the classic 10-band octave layout. Gains carry over for
    /// frequencies present in both layouts; new bands start at 0 dB.
    func restoreDefaultGraphicBands() {
        let currentGains = Dictionary(
            zip(bands.map(\.frequency), gains),
            uniquingKeysWith: { first, _ in first }
        )
        bands = defaultGraphicBandFrequencies.map {
            EQBand(label: graphicBandLabel(frequency: $0), frequency: $0)
        }
        gains = defaultGraphicBandFrequencies.map { currentGains[$0] ?? 0 }
    }

    private func settingsChanged() {
        guard !isApplyingProfile else { return }
        persist()
        saveProfileForCurrentDevice()
        rebuildKernel()
    }

    // MARK: - Per-device profiles

    private func storedProfiles() -> [String: DeviceProfile] {
        guard let data = defaults.data(forKey: "deviceProfiles") else { return [:] }
        do {
            return try JSONDecoder().decode([String: DeviceProfile].self, from: data)
        } catch {
            // Corrupt store: surface it, keep running with empty profiles.
            errorMessage = "Failed to decode device profiles: \(error)"
            return [:]
        }
    }

    private func saveProfileForCurrentDevice() {
        guard let uid = engine.status?.outputDeviceUID else { return }
        var profiles = storedProfiles()
        profiles[uid] = DeviceProfile(
            gains: gains,
            mode: mode.rawValue,
            parametricConfig: serializeAPOConfig(EQPreset(preampDB: manualPreampDB, filters: parametricFilters)),
            manualPreampDB: manualPreampDB,
            autoPreampEnabled: autoPreampEnabled,
            eqEnabled: eqEnabled,
            impulseResponsePath: impulseResponseURL?.path,
            convolutionEnabled: convolutionEnabled,
            bandFrequencies: bands.map(\.frequency)
        )
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: "deviceProfiles")
        } catch {
            errorMessage = "Failed to encode device profiles: \(error)"
        }
    }

    /// Applies the stored profile for the active output device, if any. Without a
    /// stored profile the current settings carry over (and become that device's
    /// profile on the next change).
    private func loadProfileForCurrentDevice() {
        guard let uid = engine.status?.outputDeviceUID, uid != activeProfileUID else { return }
        activeProfileUID = uid
        guard let profile = storedProfiles()[uid] else { return }
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        if let frequencies = profile.bandFrequencies, frequencies.count == profile.gains.count {
            bands = frequencies.map { EQBand(label: graphicBandLabel(frequency: $0), frequency: $0) }
            gains = profile.gains
        } else if profile.gains.count == bands.count {
            gains = profile.gains
        }
        mode = EQMode(rawValue: profile.mode) ?? .graphic
        manualPreampDB = profile.manualPreampDB
        autoPreampEnabled = profile.autoPreampEnabled
        eqEnabled = profile.eqEnabled
        if let preset = try? parseAPOConfig(profile.parametricConfig).preset {
            parametricFilters = preset.filters
        }
        if let path = profile.impulseResponsePath {
            impulseResponseURL = URL(fileURLWithPath: path)
            impulseResponseName = (path as NSString).lastPathComponent
        } else {
            impulseResponseURL = nil
            impulseResponseName = nil
        }
        convolutionEnabled = profile.convolutionEnabled ?? false
    }

    private func persist() {
        defaults.set(bands.map(\.frequency), forKey: "bandFrequencies")
        defaults.set(gains, forKey: "bandGains")
        defaults.set(manualPreampDB, forKey: "preampDB")
        defaults.set(autoPreampEnabled, forKey: "autoPreampEnabled")
        defaults.set(eqEnabled, forKey: "eqEnabled")
        defaults.set(mode.rawValue, forKey: "eqMode")
        defaults.set(limiterEnabled, forKey: "limiterEnabled")
        defaults.set(
            serializeAPOConfig(EQPreset(preampDB: effectivePreampDB, filters: parametricFilters)),
            forKey: "parametricConfig"
        )
    }

    // MARK: - Parametric editing

    func addParametricBand() {
        parametricFilters.append(
            FilterSpec(type: .peaking, isEnabled: true, frequency: 1000, gainDB: 0, q: 1.0)
        )
    }

    /// Replaces one parametric filter from a band-table edit. The number fields
    /// accept any value, and Q 0 or a non-positive Fc would turn the audio into
    /// NaN, so an invalid edit is refused and explained instead of applied.
    func updateParametricFilter(at index: Int, to filter: FilterSpec) {
        guard parametricFilters.indices.contains(index) else { return }
        do {
            try validateFilter(filter)
            parametricFilters[index] = filter
        } catch {
            errorMessage = "Band \(index + 1) not changed: \(error)"
        }
    }

    func removeParametricBand(at index: Int) {
        guard parametricFilters.indices.contains(index) else { return }
        parametricFilters.remove(at: index)
    }

    /// The live APO config text for the editor tab.
    func currentConfigText() -> String {
        serializeAPOConfig(EQPreset(preampDB: settingsPreampDB(), filters: parametricFilters))
    }

    /// The preamp the current settings call for (Auto's value for the active
    /// curve, or the manual one). Unlike effectivePreampDB, which reads 0 while
    /// bypassed or stopped, this doesn't depend on engine state, so a preset
    /// written out while bypassed still carries the preamp that keeps it from
    /// clipping.
    private func settingsPreampDB() -> Double {
        guard autoPreampEnabled else { return manualPreampDB }
        let cascade = activeCascade(sampleRate: currentSampleRate).map(\.coefficients)
        return autoPreampDB(of: cascade, sampleRate: currentSampleRate)
    }

    /// The active mode's curve as an APO preset: what's being heard.
    private func activeModePreset() -> EQPreset {
        switch mode {
        case .graphic:
            return graphicEQPreset(
                frequencies: bands.map(\.frequency), gains: gains, q: Self.bandQ, preampDB: settingsPreampDB()
            )
        case .parametric:
            return EQPreset(preampDB: settingsPreampDB(), filters: parametricFilters)
        }
    }

    /// Applies edited/pasted APO config text (also the AutoEQ import path).
    /// Sets `configParseError` instead of throwing so the editor can show it
    /// inline, and `configImportNotice` when lines were skipped.
    func applyConfigText(_ text: String) {
        do {
            let result = try parseAPOConfig(text)
            let preset = result.preset
            configParseError = nil
            configImportNotice = describeSkippedLines(result.skippedLines)
            autoPreampEnabled = false
            manualPreampDB = preset.preampDB
            parametricFilters = preset.filters
            mode = .parametric
        } catch let error as APOParseError {
            configParseError = error.description
        } catch {
            configParseError = String(describing: error)
        }
    }

    /// Imports an APO/AutoEQ preset file (ParametricEQ.txt, config.txt) chosen
    /// in an open panel. Parse errors surface via configParseError + errorMessage.
    func importPresetFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Equalizer APO / AutoEQ preset (.txt)"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            applyConfigText(text)
            if let parseError = configParseError {
                errorMessage = "Import failed — \(parseError)"
            }
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error)"
        }
    }

    /// Exports the active mode's curve (graphic bands or the parametric chain)
    /// as an APO config.txt file.
    func exportPresetToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MacEQ Preset.txt"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try serializeAPOConfig(activeModePreset()).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error)"
        }
    }

    // MARK: - Named presets

    /// Saves the current tuning under a name, replacing an existing preset with
    /// the same (trimmed) name.
    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = NamedPreset(
            name: trimmed,
            gains: gains,
            mode: mode.rawValue,
            parametricConfig: serializeAPOConfig(
                EQPreset(preampDB: manualPreampDB, filters: parametricFilters)
            ),
            manualPreampDB: manualPreampDB,
            autoPreampEnabled: autoPreampEnabled,
            bandFrequencies: bands.map(\.frequency)
        )
        namedPresets.removeAll { $0.name == trimmed }
        namedPresets.append(preset)
        persistNamedPresets()
    }

    /// Applies a named preset to the current device (one rebuild, not one per field).
    func applyPreset(_ preset: NamedPreset) {
        isApplyingProfile = true
        if let frequencies = preset.bandFrequencies, frequencies.count == preset.gains.count {
            bands = frequencies.map { EQBand(label: graphicBandLabel(frequency: $0), frequency: $0) }
            gains = preset.gains
        } else if preset.gains.count == bands.count {
            gains = preset.gains
        }
        mode = EQMode(rawValue: preset.mode) ?? mode
        manualPreampDB = preset.manualPreampDB
        autoPreampEnabled = preset.autoPreampEnabled
        if let parsed = try? parseAPOConfig(preset.parametricConfig).preset {
            parametricFilters = parsed.filters
        }
        isApplyingProfile = false
        settingsChanged()
    }

    func deletePreset(named name: String) {
        namedPresets.removeAll { $0.name == name }
        persistNamedPresets()
    }

    private func persistNamedPresets() {
        do {
            defaults.set(try JSONEncoder().encode(namedPresets), forKey: "namedPresets")
        } catch {
            errorMessage = "Failed to encode presets: \(error)"
        }
    }

    // MARK: - Convolution

    /// Picks an impulse response file (room correction / headphone FIR) and
    /// enables convolution with it.
    func chooseImpulseResponse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an impulse response (WAV, AIFF, ...)"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        impulseResponseURL = url
        impulseResponseName = url.lastPathComponent
        defaults.set(url.path, forKey: "impulseResponsePath")
        // Assigning triggers didSet even for the same value: persists, saves the
        // device profile, and rebuilds the convolver with the new file.
        convolutionEnabled = true
    }

    func clearImpulseResponse() {
        impulseResponseURL = nil
        impulseResponseName = nil
        defaults.removeObject(forKey: "impulseResponsePath")
        convolutionEnabled = false
    }

    /// Loads the IR at the engine's sample rate and swaps a fresh convolver in.
    /// Separate from rebuildKernel on purpose: kernel rebuilds happen on every
    /// slider tick and must not re-FFT a 100k-tap impulse response each time.
    private func rebuildConvolver() {
        guard isRunning, convolutionEnabled, let url = impulseResponseURL else {
            retireConvolver(engine.convolverHolder.convolver)
            engine.convolverHolder.convolver = nil
            return
        }
        let sampleRate = engine.status?.sampleRate ?? 48000
        do {
            let impulseResponse = try loadImpulseResponse(url: url, sampleRate: sampleRate)
            guard let convolver = FIRConvolver(
                impulseResponse: impulseResponse,
                blockSize: Self.convolutionBlockSize,
                maxChannels: 2
            ) else {
                errorMessage = "Convolver construction failed (\(url.lastPathComponent), \(impulseResponse.first?.count ?? 0) frames at \(sampleRate) Hz)"
                return
            }
            retireConvolver(engine.convolverHolder.convolver)
            engine.convolverHolder.convolver = convolver
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
            retireConvolver(engine.convolverHolder.convolver)
            engine.convolverHolder.convolver = nil
        }
    }

    private func retireConvolver(_ convolver: FIRConvolver?) {
        guard let convolver else { return }
        retiredConvolvers.append(convolver)
        if retiredConvolvers.count > 4 {
            retiredConvolvers.removeFirst(retiredConvolvers.count - 4)
        }
    }

    /// Builds a fresh kernel off the audio thread and swaps it in. nil = bypass.
    private func rebuildKernel() {
        guard isRunning, eqEnabled else {
            retire(engine.kernelHolder.kernel)
            engine.kernelHolder.kernel = nil
            effectivePreampDB = 0
            return
        }
        let sampleRate = engine.status?.sampleRate ?? 48000
        let sections = activeCascade(sampleRate: sampleRate)
        let preamp = autoPreampEnabled
            ? autoPreampDB(of: sections.map(\.coefficients), sampleRate: sampleRate)
            : manualPreampDB
        effectivePreampDB = preamp
        guard let kernel = EQKernel(
            sections: sections, preampDB: preamp, sampleRate: sampleRate, maxChannels: 2,
            limiterEnabled: limiterEnabled
        ) else {
            errorMessage = "EQKernel construction failed (bands: \(gains), preamp: \(preamp))"
            return
        }
        retire(engine.kernelHolder.kernel)
        engine.kernelHolder.kernel = kernel
    }

    /// Id of the pass-through stand-in section; matches no band or filter.
    private static let passthroughSectionID = -1

    /// The biquad cascade for the current mode. Never empty: an identity peaking
    /// section stands in when the parametric list has no enabled filters.
    ///
    /// Section ids are each band's (or filter's) position in its list, so a
    /// slider or curve-point drag keeps its id, and its filter state, across the
    /// kernel rebuild every tick triggers (EQKernel.adoptState). Parametric ids
    /// count disabled filters too, so toggling one checkbox renumbers nothing.
    /// Graphic and parametric ids overlap; a mode switch is a wholesale change
    /// of curve anyway.
    func activeCascade(sampleRate: Double) -> [KernelSection] {
        let sections: [KernelSection]
        switch mode {
        case .graphic:
            sections = zip(bands, gains).enumerated().map { index, band in
                KernelSection(
                    id: index,
                    coefficients: peakingCoefficients(
                        sampleRate: sampleRate, frequency: band.0.frequency, q: Self.bandQ, gainDB: band.1
                    )
                )
            }
        case .parametric:
            sections = parametricFilters.enumerated().filter { $0.element.isEnabled }.map {
                KernelSection(id: $0.offset, coefficients: coefficients(for: $0.element, sampleRate: sampleRate))
            }
        }
        // Sections sitting at 0 dB are exactly H(z) = 1, so running them costs a
        // biquad per band per channel on every callback and changes nothing.
        // Dropping them makes a flat EQ nearly free, which matters most on Intel.
        let active = sections.filter { !isIdentitySection($0.coefficients) }
        guard !active.isEmpty else {
            // The kernel needs a non-empty cascade; one identity section is the
            // cheapest way to say "pass through".
            return [KernelSection(
                id: Self.passthroughSectionID,
                coefficients: peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 1.0, gainDB: 0)
            )]
        }
        return active
    }

    var currentSampleRate: Double {
        engine.status?.sampleRate ?? 48000
    }

    private func retire(_ kernel: EQKernel?) {
        guard let kernel else { return }
        retiredKernels.append(kernel)
        if retiredKernels.count > 8 {
            retiredKernels.removeFirst(retiredKernels.count - 8)
        }
    }

    /// Tears down and rebuilds the audio path on the new default output device
    /// (also used for sample-rate renegotiation on the same device). Runs even
    /// while a failed start awaits its retry: a new device is the most likely
    /// moment for the path to come back.
    private func handleDeviceChange() {
        restartEngine()
    }

    // MARK: - Global hotkey

    /// Human-readable current binding (e.g. "⌥⌘E"), for menus and tooltips.
    @Published private(set) var hotkeyDisplay: String = "⌥⌘E"
    private var hotkeyManager: HotkeyManager?

    private var storedHotkeyKeyCode: UInt32 {
        UInt32(defaults.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_E)
    }

    private var storedHotkeyModifiers: UInt32 {
        UInt32(defaults.object(forKey: "hotkeyModifiers") as? Int ?? (optionKey | cmdKey))
    }

    private func makeHotkeyManager(keyCode: UInt32, modifiers: UInt32) -> HotkeyManager? {
        HotkeyManager(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            DispatchQueue.main.async {
                self?.eqEnabled.toggle()
            }
        }
    }

    /// Registers the persisted (or default ⌥⌘E) global EQ-bypass hotkey.
    func registerHotkey() {
        hotkeyDisplay = defaults.string(forKey: "hotkeyDisplay") ?? "⌥⌘E"
        hotkeyManager = makeHotkeyManager(keyCode: storedHotkeyKeyCode, modifiers: storedHotkeyModifiers)
        if hotkeyManager == nil {
            errorMessage = "Could not register global hotkey \(hotkeyDisplay) — another app may already use it."
        }
    }

    /// Activates and persists a new hotkey binding (from the recorder window).
    ///
    /// The new combination is registered while the current one is still held,
    /// and only saved once that works. Saving first (as this used to) meant a
    /// combination another app owns replaced a working hotkey with none, on
    /// every launch after.
    func setHotkey(keyCode: UInt32, modifiers: UInt32, display: String) {
        let isCurrentBinding = keyCode == storedHotkeyKeyCode && modifiers == storedHotkeyModifiers
        // Our own registration would make the same combination fail to
        // register again; if it's already live there is nothing to change.
        if isCurrentBinding, hotkeyManager != nil { return }
        guard let manager = makeHotkeyManager(keyCode: keyCode, modifiers: modifiers) else {
            let keeping = hotkeyManager != nil ? " Keeping \(hotkeyDisplay)." : ""
            errorMessage = "Could not register \(display) — another app may already use it.\(keeping)"
            return
        }
        hotkeyManager = manager
        hotkeyDisplay = display
        defaults.set(Int(keyCode), forKey: "hotkeyKeyCode")
        defaults.set(Int(modifiers), forKey: "hotkeyModifiers")
        defaults.set(display, forKey: "hotkeyDisplay")
    }

    // MARK: - Update check

    /// Whether MacEQ checks GitHub for a newer release about once a day. Off
    /// until the user answers the one-time question: MacEQ made no network
    /// requests at all before this existed, and existing users are asked
    /// rather than opted in.
    @Published var updateChecksEnabled: Bool {
        didSet {
            defaults.set(updateChecksEnabled, forKey: "updateChecksEnabled")
            scheduleUpdateChecks()
        }
    }
    /// A release newer than the running app, e.g. "1.4.0"; nil when current.
    @Published private(set) var availableUpdateVersion: String?
    /// Outcome of the last check, for Diagnostics. Automatic checks report
    /// here rather than in the red error line: an offline laptop shouldn't nag.
    private var updateCheckStatus: String?
    private var updateTimer: Timer?

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The last release tag seen, compared to the running version. Makes the
    /// notice show at launch without a network request, and disappear by
    /// itself once the user has updated.
    private static func newerKnownRelease(defaults: UserDefaults) -> String? {
        guard let tag = defaults.string(forKey: "latestReleaseTag"),
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let newer = try? newerRelease(latestTag: tag, currentVersion: current)
        else { return nil }
        return newer.description
    }

    /// Called once at launch: asks the one-time question if it hasn't been
    /// answered, then starts the schedule if checks are on.
    func setUpUpdateChecks() {
        if defaults.object(forKey: "updateChecksEnabled") == nil {
            askAboutUpdateChecks()
        } else {
            scheduleUpdateChecks()
        }
    }

    private func askAboutUpdateChecks() {
        let alert = NSAlert()
        alert.messageText = "Check for MacEQ updates automatically?"
        alert.informativeText = "MacEQ can ask GitHub once a day whether a newer version is out, and "
            + "tell you in its menu. Nothing about you or your audio is sent; GitHub sees an ordinary "
            + "web request. You can change this at any time in the ⋯ menu."
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Assigning persists the answer (even "no"), so this is asked once.
        updateChecksEnabled = alert.runModal() == .alertFirstButtonReturn
    }

    /// Hourly wake-ups that only reach GitHub once the day has passed: a
    /// 24-hour timer would drift past a day whenever the Mac slept through it.
    private func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard updateChecksEnabled else { return }
        checkForUpdatesIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForUpdatesIfDue()
            }
        }
    }

    private func checkForUpdatesIfDue() {
        let lastCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        guard isUpdateCheckDue(lastCheck: lastCheck, now: Date()) else { return }
        Task {
            do {
                try await fetchUpdate()
            } catch {
                updateCheckStatus = "failed \(Date().formatted(date: .omitted, time: .shortened)): \(error)"
            }
        }
    }

    /// The "Check for Updates Now" menu item: runs regardless of the setting
    /// (it is an explicit request) and always reports the outcome.
    func checkForUpdatesNow() {
        Task {
            let alert = NSAlert()
            var offersDownload = false
            do {
                if let version = try await fetchUpdate() {
                    offersDownload = true
                    alert.messageText = "MacEQ \(version) is available"
                    alert.informativeText = "You have \(appVersion ?? "an unknown version")."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                } else {
                    alert.messageText = "MacEQ is up to date"
                    alert.informativeText = "\(appVersion ?? "This version") is the latest release."
                }
            } catch {
                updateCheckStatus = "failed \(Date().formatted(date: .omitted, time: .shortened)): \(error)"
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = String(describing: error)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn, offersDownload {
                NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
            }
        }
    }

    /// One check against GitHub. Records the time and the latest tag, and
    /// returns the newer version if there is one.
    @discardableResult
    private func fetchUpdate() async throws -> String? {
        guard let appVersion else {
            throw UpdateCheckError.unparseableVersion("(no CFBundleShortVersionString in the app bundle)")
        }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        let tag = try await UpdateChecker.fetchLatestReleaseTag(appVersion: appVersion)
        let newer = try newerRelease(latestTag: tag, currentVersion: appVersion)
        defaults.set(tag, forKey: "latestReleaseTag")
        availableUpdateVersion = newer?.description
        updateCheckStatus = "\(Date().formatted(date: .omitted, time: .shortened)), latest release \(tag)"
        return newer?.description
    }

    // MARK: - Zero-buffer watchdog

    /// The documented process-tap platform bug: after long uptime the tap starts
    /// delivering all-zero buffers even though apps are playing. Genuine silence is
    /// indistinguishable from the bug at the buffer level, so the tap silence is
    /// cross-checked against Core Audio's process list — if another (non-excluded)
    /// process has IO running while the tap has been silent for ~3 s, rebuild the
    /// path. A false positive only restarts during real silence, which is inaudible.
    private var lastWatchdogRestart: Date?
    private var watchdogRestartCount = 0
    private var lastWatchdogProcessScan: Date?
    /// Set on Core Audio process-list changes so a newly started audio app is
    /// scanned at the next watchdog tick instead of waiting out the throttle.
    private var processListChangedSinceScan = true

    private func checkZeroBufferWatchdog(status: EngineStatus, stats: IOStats) {
        let callbacksPerSecond = status.sampleRate / Double(max(status.bufferFrameSize, 1))
        guard Double(stats.consecutiveZeroBuffers) > 3 * callbacksPerSecond else { return }
        if let lastWatchdogRestart, Date().timeIntervalSince(lastWatchdogRestart) < 30 { return }
        // The zero streak persists for as long as the system is genuinely silent,
        // so without a throttle this scan (every Core Audio process object, three
        // property reads each) would run on every tick around the clock. Scan
        // when the process list changed, else at most every 10 s.
        let scanIsDue = processListChangedSinceScan
            || lastWatchdogProcessScan.map { Date().timeIntervalSince($0) >= 10 } ?? true
        guard scanIsDue else { return }
        lastWatchdogProcessScan = Date()
        processListChangedSinceScan = false
        guard otherAudioProcessIsPlaying() else { return }
        watchdogRestartCount += 1
        lastWatchdogRestart = Date()
        restartEngine()
    }

    /// Callback-stall watchdog state, reset on every successful start.
    private var lastSeenCallbackCount: UInt64?
    private var stalledWatchdogTicks = 0

    /// Records one watchdog observation of the IOProc callback counter and
    /// returns true once callbacks have stopped for
    /// `callbackStallTicksBeforeRestart` ticks in a row (see nextStalledTickCount).
    private func callbackStallDetected(stats: IOStats) -> Bool {
        stalledWatchdogTicks = nextStalledTickCount(
            previousCallbackCount: lastSeenCallbackCount,
            currentCallbackCount: stats.callbackCount,
            stalledTicks: stalledWatchdogTicks
        )
        lastSeenCallbackCount = stats.callbackCount
        return stalledWatchdogTicks >= callbackStallTicksBeforeRestart
    }

    /// True when any audio process other than ourselves and the excluded apps has
    /// IO running. Best-effort: an unreadable process list just means no restart.
    private func otherAudioProcessIsPlaying() -> Bool {
        guard let objects = try? audioProcessObjectIDs() else { return false }
        let selfPID = getpid()
        for object in objects {
            guard let processPID = try? pid(ofAudioProcess: object),
                  processPID != selfPID,
                  !lastExcludedPIDs.contains(processPID),
                  (try? audioProcessIsRunning(object)) == true
            else { continue }
            return true
        }
        return false
    }

    // MARK: - Spectrum display

    static let spectrumBands = logSpacedFrequencies(from: 20, to: 20000, count: 48)
    private let analyzer = SpectrumAnalyzer(fftSize: 2048)
    private var spectrumTimer: Timer?

    /// ~20 fps spectrum updates; runs only while a curve view is visible.
    func startSpectrum() {
        guard spectrumTimer == nil else { return }
        engine.captureRing.captureEnabled = true
        spectrumTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let analyzer = self.analyzer, self.isRunning else { return }
                self.spectrum.levelsDB = analyzer.bandMagnitudesDB(
                    samples: self.engine.captureRing.latest(analyzer.fftSize),
                    sampleRate: self.currentSampleRate,
                    bandFrequencies: Self.spectrumBands
                )
            }
        }
    }

    func stopSpectrum() {
        engine.captureRing.captureEnabled = false
        spectrumTimer?.invalidate()
        spectrumTimer = nil
        spectrum.levelsDB = []
    }

    // MARK: - CPU usage

    private var lastCPUTime: Double = 0
    private var lastCPUSample: Date?

    /// Process CPU%: rusage user+system delta over wall-clock delta.
    private func updateCPUUsage() {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let now = Date()
        if let lastSample = lastCPUSample {
            let wall = now.timeIntervalSince(lastSample)
            if wall > 0 {
                cpuPercent = max((seconds - lastCPUTime) / wall * 100, 0)
            }
        }
        lastCPUTime = seconds
        lastCPUSample = now
    }

    private func startPolling() {
        lastSeenCallbackCount = nil
        stalledWatchdogTicks = 0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let status = self.engine.status else { return }
                // A dead path first: with no callbacks at all, the zero-buffer
                // check below has nothing to count and would never fire.
                if self.callbackStallDetected(stats: self.engine.stats) {
                    self.watchdogRestartCount += 1
                    self.restartEngine()
                    return
                }
                self.checkZeroBufferWatchdog(status: status, stats: self.engine.stats)
            }
        }
        updateStatusPolling()
    }

    private func updateStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
        guard isRunning, popoverIsVisible else { return }
        refreshStatus()  // immediately, so the footer isn't stale on open
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshStatus()
            }
        }
    }

    private func refreshStatus() {
        guard let status = engine.status else { return }
        updateCPUUsage()
        let stats = engine.stats
        let peakDB: Double = stats.lastPeak > 0 ? Double(20 * log10(stats.lastPeak)) : -120
        statusModel.summary = String(
            format: "%@ · %.0f kHz · %.1f ms · CPU %.1f%%",
            status.outputDeviceName,
            status.sampleRate / 1000,
            Double(status.bufferFrameSize) / status.sampleRate * 1000,
            cpuPercent
        )
        var lines = [
            "Tap format: \(status.tapFormatDescription)",
            "Route: \(status.routeDescription)",
            String(format: "IO buffer: %u frames (~%.1f ms)", status.bufferFrameSize, Double(status.bufferFrameSize) / status.sampleRate * 1000),
            String(format: "Peak: %.1f dBFS", peakDB),
            "Callbacks: \(stats.callbackCount), silent streak: \(stats.consecutiveZeroBuffers)",
            "Watchdog restarts: \(watchdogRestartCount)",
        ]
        if let updateCheckStatus {
            lines.append("Update check: \(updateCheckStatus)")
        }
        if stats.layoutMismatches > 0 {
            lines.append("Layout mismatches (silenced callbacks): \(stats.layoutMismatches)")
        }
        if status.tapCompensationGain != 1 {
            lines.append(String(
                format: "Multi-output compensation: x%.0f (+%.1f dB)",
                status.tapCompensationGain,
                20 * log10(Double(status.tapCompensationGain))
            ))
        }
        statusModel.diagnosticLines = lines + convolutionDiagnostics(sampleRate: status.sampleRate) + engine.diagnostics()
    }

    private func convolutionDiagnostics(sampleRate: Double) -> [String] {
        guard let convolver = engine.convolverHolder.convolver else { return [] }
        return [String(
            format: "Convolution: %@ · %d taps · %d partitions · +%.1f ms",
            impulseResponseName ?? "?",
            convolver.irFrameCount,
            convolver.partitionCount,
            Double(convolver.latencyFrames) / sampleRate * 1000
        )]
    }

}
