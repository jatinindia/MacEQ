import MacEQCore
import SwiftUI

/// Parametric editor: response curve with draggable band points, a compact band
/// table, and a raw APO config text tab (which doubles as AutoEQ paste-import).
struct ParametricView: View {
    @ObservedObject var controller: EQController
    @State private var showConfigText = false
    @State private var configDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResponseCurveView(controller: controller)
                .frame(height: 150)

            HStack {
                Button {
                    controller.addParametricBand()
                } label: {
                    Label("Add Band", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
                Toggle("Edit as text", isOn: $showConfigText)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }

            if showConfigText {
                configEditor
            } else {
                bandTable
            }

            // Shown under both views: a file import lands on the band table.
            if let notice = controller.configImportNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(spacing: 4) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Free correction profiles for 5000+ headphones:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Link("AutoEQ", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq/tree/master/results")!)
                    .font(.caption2)
                Text("— import the ParametricEQ.txt for your model.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .onChange(of: showConfigText) { _, shown in
            if shown { configDraft = controller.currentConfigText() }
        }
    }

    private var bandTable: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(controller.parametricFilters.indices, id: \.self) { index in
                    // Rows are keyed by position. Right after a deletion SwiftUI
                    // can still read a row that no longer exists; the snapshot
                    // keeps that read in bounds instead of crashing.
                    let snapshot = controller.parametricFilters[index]
                    BandRow(
                        filter: Binding(
                            get: {
                                controller.parametricFilters.indices.contains(index)
                                    ? controller.parametricFilters[index] : snapshot
                            },
                            set: { controller.updateParametricFilter(at: index, to: $0) }
                        ),
                        color: BandPalette.color(index),
                        onDelete: {
                            // Commit any half-typed value now, while positions
                            // still point at the right bands. Committed after the
                            // deletion, it would land on whichever band moved
                            // into that row.
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            controller.removeParametricBand(at: index)
                        }
                    )
                }
                if controller.parametricFilters.isEmpty {
                    Text("No bands. Add one, or paste an AutoEQ profile via “Edit as text”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
        .frame(height: 130)
    }

    private var configEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $configDraft)
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 104)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            HStack {
                if let parseError = controller.configParseError {
                    Text(parseError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Apply") {
                    controller.applyConfigText(configDraft)
                    if controller.configParseError == nil {
                        configDraft = controller.currentConfigText()
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

enum BandPalette {
    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red]

    static func color(_ index: Int) -> Color {
        colors[index % colors.count]
    }
}

/// One row of the band table: enable, type, Fc, gain, Q, delete.
struct BandRow: View {
    @Binding var filter: FilterSpec
    let color: Color
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $filter.isEnabled)
                .toggleStyle(.checkbox)
                .controlSize(.mini)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Picker("", selection: $filter.type) {
                ForEach(FilterType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 64)

            numberField("Fc", value: $filter.frequency, width: 58)
            numberField("dB", value: $filter.gainDB, width: 44)
                .disabled(!filter.type.usesGain)
                .opacity(filter.type.usesGain ? 1 : 0.35)
            numberField("Q", value: $filter.q, width: 44)
                .disabled(!filter.type.usesQ)
                .opacity(filter.type.usesQ ? 1 : 0.35)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
        }
        .opacity(filter.isEnabled ? 1 : 0.5)
    }

    private func numberField(_ label: String, value: Binding<Double>, width: CGFloat) -> some View {
        HStack(spacing: 2) {
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: width)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Log-frequency / dB plot of the summed response, with draggable control points
/// (drag horizontally = Fc, vertically = gain for types that have one).
struct ResponseCurveView: View {
    @ObservedObject var controller: EQController
    @State private var draggedBandIndex: Int?

    private let dbRange: ClosedRange<Double> = -15...15
    private let freqRange: ClosedRange<Double> = 20...20000

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas { context, canvasSize in
                    drawGrid(context: context, size: canvasSize)
                }
                SpectrumOverlay(spectrum: controller.spectrum)
                    .allowsHitTesting(false)
                Canvas { context, canvasSize in
                    drawCurve(context: context, size: canvasSize)
                }
                ForEach(controller.parametricFilters.indices, id: \.self) { index in
                    let filter = controller.parametricFilters[index]
                    if filter.isEnabled {
                        Circle()
                            .fill(BandPalette.color(index))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                            .position(pointPosition(for: filter, in: size))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { gesture in
                        dragBand(at: gesture.location, in: size, startLocation: gesture.startLocation)
                    }
                    .onEnded { _ in draggedBandIndex = nil }
            )
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { controller.startSpectrum() }
        .onDisappear { controller.stopSpectrum() }
    }

    // MARK: - Coordinate mapping

    private func xPosition(frequency: Double, width: CGFloat) -> CGFloat {
        let fraction = log(frequency / freqRange.lowerBound) / log(freqRange.upperBound / freqRange.lowerBound)
        return CGFloat(fraction) * width
    }

    private func frequency(atX x: CGFloat, width: CGFloat) -> Double {
        let fraction = Double(min(max(x, 0), width) / width)
        return freqRange.lowerBound * pow(freqRange.upperBound / freqRange.lowerBound, fraction)
    }

    private func yPosition(db: Double, height: CGFloat) -> CGFloat {
        let fraction = (db - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound)
        return height * CGFloat(1 - fraction)
    }

    private func db(atY y: CGFloat, height: CGFloat) -> Double {
        let fraction = 1 - Double(min(max(y, 0), height) / height)
        return dbRange.lowerBound + fraction * (dbRange.upperBound - dbRange.lowerBound)
    }

    private func pointPosition(for filter: FilterSpec, in size: CGSize) -> CGPoint {
        CGPoint(
            x: xPosition(frequency: filter.frequency, width: size.width),
            y: yPosition(db: filter.type.usesGain ? filter.gainDB : 0, height: size.height)
        )
    }

    // MARK: - Drawing

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var gridLines = Path()
        for decade in [100.0, 1000.0, 10000.0] {
            let x = xPosition(frequency: decade, width: size.width)
            gridLines.move(to: CGPoint(x: x, y: 0))
            gridLines.addLine(to: CGPoint(x: x, y: size.height))
        }
        for db in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = yPosition(db: db, height: size.height)
            gridLines.move(to: CGPoint(x: 0, y: y))
            gridLines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(gridLines, with: .color(.primary.opacity(0.08)), lineWidth: 1)

        var zeroLine = Path()
        let zeroY = yPosition(db: 0, height: size.height)
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(zeroLine, with: .color(.primary.opacity(0.25)), lineWidth: 1)

        for (label, frequency) in [("100", 100.0), ("1k", 1000.0), ("10k", 10000.0)] {
            context.draw(
                Text(label).font(.system(size: 8)).foregroundStyle(.tertiary),
                at: CGPoint(x: xPosition(frequency: frequency, width: size.width) + 10, y: size.height - 7)
            )
        }
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        let sampleRate = controller.currentSampleRate
        let cascade = controller.parametricFilters
            .filter(\.isEnabled)
            .map { coefficients(for: $0, sampleRate: sampleRate) }
        guard !cascade.isEmpty else { return }

        let frequencies = logSpacedFrequencies(from: freqRange.lowerBound, to: freqRange.upperBound, count: 160)
        var curve = Path()
        for (index, frequency) in frequencies.enumerated() {
            let response = magnitudeDB(of: cascade, sampleRate: sampleRate, frequency: frequency)
            let point = CGPoint(
                x: xPosition(frequency: frequency, width: size.width),
                y: yPosition(db: min(max(response, dbRange.lowerBound), dbRange.upperBound), height: size.height)
            )
            if index == 0 {
                curve.move(to: point)
            } else {
                curve.addLine(to: point)
            }
        }
        context.stroke(
            curve,
            with: .linearGradient(
                Gradient(colors: [.purple, .blue]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ),
            lineWidth: 2
        )
    }

    // MARK: - Interaction

    private func dragBand(at location: CGPoint, in size: CGSize, startLocation: CGPoint) {
        if draggedBandIndex == nil {
            // Lock onto the enabled band nearest to where the drag began.
            let candidates = controller.parametricFilters.indices.filter {
                controller.parametricFilters[$0].isEnabled
            }
            let nearest = candidates.min { first, second in
                distance(from: startLocation, to: pointPosition(for: controller.parametricFilters[first], in: size))
                    < distance(from: startLocation, to: pointPosition(for: controller.parametricFilters[second], in: size))
            }
            guard let nearest,
                  distance(from: startLocation, to: pointPosition(for: controller.parametricFilters[nearest], in: size)) < 25
            else { return }
            draggedBandIndex = nearest
        }
        guard let index = draggedBandIndex, controller.parametricFilters.indices.contains(index) else { return }
        var filter = controller.parametricFilters[index]
        filter.frequency = (frequency(atX: location.x, width: size.width) * 10).rounded() / 10
        if filter.type.usesGain {
            filter.gainDB = (db(atY: location.y, height: size.height) * 10).rounded() / 10
        }
        controller.parametricFilters[index] = filter
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Live output spectrum, drawn as a translucent filled skyline behind the
/// response curve. Spectrum dBFS (-80..0) maps onto the full plot height —
/// a different scale than the response dB axis, purely for visualization.
///
/// A separate view on purpose: it alone observes SpectrumModel, so the 20 fps
/// updates redraw only this canvas instead of the whole popover.
private struct SpectrumOverlay: View {
    @ObservedObject var spectrum: SpectrumModel

    private let freqRange: ClosedRange<Double> = 20...20000

    var body: some View {
        Canvas { context, size in
            let levels = spectrum.levelsDB
            guard levels.count == EQController.spectrumBands.count else { return }
            let floorDB = -80.0
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, band) in EQController.spectrumBands.enumerated() {
                let fraction = max(0, min(1, (levels[index] - floorDB) / -floorDB))
                let logSpan = log(freqRange.upperBound / freqRange.lowerBound)
                let point = CGPoint(
                    x: CGFloat(log(band / freqRange.lowerBound) / logSpan) * size.width,
                    y: size.height * CGFloat(1 - fraction)
                )
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.blue.opacity(0.15)))
        }
    }
}
