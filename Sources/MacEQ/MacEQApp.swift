import SwiftUI

/// Starts the audio engine at launch (before the menu-bar popover is ever opened)
/// so the permission prompt appears immediately and EQ is active from login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let controller = EQController()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(controller: Self.controller)
        Self.controller.start()
        Self.controller.registerHotkey()
        // After launch finishes: the one-time question is a modal alert, and
        // the engine should already be running behind it.
        DispatchQueue.main.async {
            Self.controller.setUpUpdateChecks()
        }
    }
}

@main
struct MacEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Never shown: the real menu-bar item is StatusItemController's. SwiftUI
        // opens the first scene at launch (even a Settings scene) unless it is
        // a MenuBarExtra, and defaultLaunchBehavior(.suppressed) needs macOS 15.
        MenuBarExtra("MacEQ", systemImage: "slider.vertical.3", isInserted: .constant(false)) {
            EmptyView()
        }

        Window("Excluded Apps", id: "excluded-apps") {
            ExcludedAppsView(controller: AppDelegate.controller)
        }
        .windowResizability(.contentSize)

        Window("MacEQ Hotkey", id: "hotkey-recorder") {
            HotkeyRecorderView(controller: AppDelegate.controller)
        }
        .windowResizability(.contentSize)

        Window("Save Preset", id: "save-preset") {
            PresetNameView(controller: AppDelegate.controller)
        }
        .windowResizability(.contentSize)

        Window("About MacEQ", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

struct EQPopoverView: View {
    @ObservedObject var controller: EQController
    @Environment(\.openWindow) private var openWindow
    @State private var showAddBand = false
    @State private var addBandText = ""
    /// Which band's frequency label is currently being retuned, and its draft
    /// text. Only one at a time: a permanent text field per column would be
    /// unreadably narrow once there are more than a handful of bands.
    @State private var editingBandIndex: Int?
    @State private var editingBandText = ""
    @FocusState private var bandFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let version = controller.availableUpdateVersion {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                    Text("MacEQ \(version) is available")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button("Download") {
                        NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
                    }
                    .controlSize(.small)
                    .help("Open the MacEQ releases page on GitHub")
                }
            }
            if let errorMessage = controller.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        controller.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $controller.mode) {
                    Text("Graphic").tag(EQMode.graphic)
                    Text("Parametric").tag(EQMode.parametric)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                if controller.mode == .graphic {
                    Spacer()
                    Button {
                        showAddBand.toggle()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .controlSize(.small)
                    .help("Add a band at a custom frequency")
                    Button("Reset") {
                        controller.resetAllBands()
                    }
                    .controlSize(.small)
                    .help("Reset all bands to 0 dB (this device's profile only)")
                }
            }
            if controller.mode == .graphic, showAddBand {
                addBandRow
            }

            Group {
                if controller.mode == .graphic {
                    bandSliders
                } else {
                    ParametricView(controller: controller)
                }
                preampRow
            }
            .opacity(controller.eqEnabled ? 1 : 0.4)
            .disabled(!controller.eqEnabled)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { controller.popoverIsVisible = true }
        .onDisappear { controller.popoverIsVisible = false }
    }

    private var header: some View {
        HStack {
            Text("MacEQ")
                .font(.headline)
            Spacer()
            Toggle("", isOn: $controller.eqEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Enable or bypass the equalizer (\(controller.hotkeyDisplay) anywhere)")
            Menu {
                Button("Reset All Bands") { controller.resetAllBands() }
                Button("Restore Default Bands") { controller.restoreDefaultGraphicBands() }
                Toggle("Safety Limiter", isOn: $controller.limiterEnabled)
                Toggle("Launch at Login", isOn: $controller.launchAtLogin)
                Button("Change Hotkey… (\(controller.hotkeyDisplay))") {
                    openWindow(id: "hotkey-recorder")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Picker("Buffer Size", selection: $controller.bufferFrames) {
                    Text("Device Default").tag(0)
                    Text("128 frames (lowest latency)").tag(128)
                    Text("256 frames").tag(256)
                    Text("512 frames").tag(512)
                    Text("1024 frames (safest)").tag(1024)
                }
                Button("Excluded Apps…") {
                    openWindow(id: "excluded-apps")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Divider()
                if let irName = controller.impulseResponseName {
                    Toggle("Convolution (\(irName))", isOn: $controller.convolutionEnabled)
                    Button("Replace Impulse Response…") { controller.chooseImpulseResponse() }
                    Button("Clear Impulse Response") { controller.clearImpulseResponse() }
                } else {
                    Button("Load Impulse Response…") { controller.chooseImpulseResponse() }
                }
                Divider()
                Menu("Presets") {
                    ForEach(controller.namedPresets, id: \.name) { preset in
                        Button(preset.name) { controller.applyPreset(preset) }
                    }
                    if controller.namedPresets.isEmpty {
                        Text("No saved presets")
                    }
                    Divider()
                    Button("Save Current as Preset…") {
                        openWindow(id: "save-preset")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    if !controller.namedPresets.isEmpty {
                        Menu("Delete Preset") {
                            ForEach(controller.namedPresets, id: \.name) { preset in
                                Button(preset.name, role: .destructive) {
                                    controller.deletePreset(named: preset.name)
                                }
                            }
                        }
                    }
                }
                Button("Import Preset…") { controller.importPresetFromFile() }
                Button("Export Preset…") { controller.exportPresetToFile() }
                Divider()
                if controller.isRunning {
                    Button("Stop Audio Engine") { controller.stop() }
                } else {
                    Button("Start Audio Engine") { controller.start() }
                }
                Divider()
                Toggle("Check for Updates Automatically", isOn: $controller.updateChecksEnabled)
                Button("Check for Updates Now") { controller.checkForUpdatesNow() }
                Button("About MacEQ") {
                    openWindow(id: "about")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Button("Quit MacEQ") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var addBandRow: some View {
        HStack(spacing: 8) {
            TextField("Frequency in Hz (20–20000)", text: $addBandText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(addBand)
            Button("Add") { addBand() }
                .controlSize(.small)
                .disabled(Double(addBandText) == nil)
            Text("Right-click a band to remove it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func beginBandEdit(at index: Int) {
        editingBandText = String(format: "%g", controller.bands[index].frequency)
        editingBandIndex = index
        bandFieldFocused = true
    }

    private func cancelBandEdit() {
        editingBandIndex = nil
        editingBandText = ""
    }

    /// Applies the retune. Keeps the field open on a rejected value so the
    /// number stays visible next to the error rather than silently reverting.
    private func commitBandFrequency(at index: Int) {
        guard let frequency = Double(editingBandText) else {
            cancelBandEdit()
            return
        }
        if controller.setGraphicBandFrequency(at: index, to: frequency) {
            cancelBandEdit()
        }
    }

    private func addBand() {
        guard let frequency = Double(addBandText) else { return }
        if controller.addGraphicBand(frequency: frequency) {
            addBandText = ""
            showAddBand = false
        }
    }

    private var bandSliders: some View {
        HStack(alignment: .top, spacing: 6) {
            dbScale
            ForEach(controller.bands.indices, id: \.self) { index in
                let band = controller.bands[index]
                // Positional, like the parametric table: right after a band is
                // removed SwiftUI can still read this row, so reads stay in
                // bounds and writes to a vanished band are dropped.
                let gain = controller.gains[index]
                VStack(spacing: 6) {
                    VerticalSlider(
                        value: Binding(
                            get: { controller.gains.indices.contains(index) ? controller.gains[index] : gain },
                            set: { newGain in
                                guard controller.gains.indices.contains(index) else { return }
                                controller.gains[index] = newGain
                            }
                        ),
                        range: EQController.gainRange
                    )
                    .frame(height: 140)
                    if editingBandIndex == index {
                        TextField("Hz", text: $editingBandText)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .focused($bandFieldFocused)
                            .onSubmit { commitBandFrequency(at: index) }
                            .onExitCommand { cancelBandEdit() }
                    } else {
                        Text(band.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            // Without an explicit shape a Text only accepts taps
                            // on its glyphs, which makes a 2-3 character label a
                            // needlessly precise target.
                            .contentShape(Rectangle())
                            .onTapGesture { beginBandEdit(at: index) }
                            .help("Click to change this band's frequency")
                    }
                    Text(gainLabel(controller.gains[index]))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .contextMenu {
                    Button("Remove \(band.label) Band", role: .destructive) {
                        controller.removeGraphicBand(at: index)
                    }
                    .disabled(controller.bands.count == 1)
                }
            }
        }
        // The frequency editor remembers a position. Once bands are added,
        // removed or re-sorted that position means a different band, and
        // pressing Return would retune it, so the edit is dropped instead.
        .onChange(of: controller.bands.map(\.frequency)) { _, _ in
            cancelBandEdit()
        }
    }

    private var dbScale: some View {
        VStack {
            Text("+12")
            Spacer()
            Text("0")
            Spacer()
            Text("−12")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(height: 140)
    }

    private var preampRow: some View {
        HStack(spacing: 10) {
            Text("Preamp")
                .font(.caption)
            Slider(
                value: $controller.manualPreampDB,
                in: EQController.gainRange
            )
            .controlSize(.small)
            .disabled(controller.autoPreampEnabled)
            Text(String(format: "%+.1f dB", controller.effectivePreampDB))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Toggle("Auto", isOn: $controller.autoPreampEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Automatically lower gain to prevent clipping from boosted bands")
        }
    }

    private var footer: some View {
        StatusFooterView(isRunning: controller.isRunning, statusModel: controller.statusModel)
    }

    private func gainLabel(_ gain: Double) -> String {
        gain == 0 ? "0" : String(format: "%+.0f", gain)
    }
}

/// Status line + diagnostics. A separate view on purpose: it alone observes
/// EngineStatusModel, so the twice-a-second poll updates redraw only this
/// footer instead of the whole popover.
struct StatusFooterView: View {
    let isRunning: Bool
    @ObservedObject var statusModel: EngineStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRunning ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(statusModel.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(statusModel.diagnosticLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Diagnostics")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Center-zero vertical slider: fill grows from the middle, gradient accent,
/// double-click resets to 0, drag snaps to 0.5 dB.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let trackWidth: CGFloat = 5
    private let knobSize: CGFloat = 13
    private static let accent = LinearGradient(
        colors: [Color.purple, Color.blue],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let knobY = yPosition(for: value, height: height)
            let centerY = height / 2

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: trackWidth)
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Self.accent)
                    .frame(width: trackWidth)
                    .frame(height: abs(centerY - knobY))
                    .offset(y: min(knobY, centerY))
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: trackWidth + 6, height: 1)
                    .offset(y: centerY)
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(y: knobY - knobSize / 2)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = valueFor(y: gesture.location.y, height: height)
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
            }
        }
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height * CGFloat(1 - fraction)
    }

    private func valueFor(y: CGFloat, height: CGFloat) -> Double {
        let fraction = 1 - Double(min(max(y, 0), height) / height)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return (raw * 2).rounded() / 2
    }
}
