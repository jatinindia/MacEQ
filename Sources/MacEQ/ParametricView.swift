import MacEQCore
import SwiftUI

/// Parametric editor: response curve with draggable band points, a compact band
/// table, and a raw APO config text tab (which doubles as AutoEQ paste-import).
struct ParametricView: View {
    @ObservedObject var controller: EQController
    @State private var showConfigText = false
    /// Band under the pointer, in the table or on the curve; both highlight it.
    @State private var hoveredBand: Int?
    /// Whether band rows are hidden above/below the visible part of the list.
    @State private var moreAbove = false
    @State private var moreBelow = false
    @State private var configDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ResponseCurveView(controller: controller, hoveredBand: $hoveredBand)
                .frame(height: 168)

            HStack(spacing: 12) {
                Text(showConfigText ? "Config text" : bandCountLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !showConfigText {
                    IconButton(systemName: "plus", help: "Add a band") {
                        controller.addParametricBand()
                    }
                }
                IconButton(
                    systemName: showConfigText ? "list.bullet" : "text.alignleft",
                    help: showConfigText ? "Back to the band list" : "Edit as text, or paste an AutoEQ profile"
                ) {
                    showConfigText.toggle()
                }
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
        }
        .onChange(of: showConfigText) { _, shown in
            if shown { configDraft = controller.currentConfigText() }
        }
    }

    private var bandCountLabel: String {
        let count = controller.parametricFilters.count
        return count == 1 ? "1 band" : "\(count) bands"
    }

    private static let tableHeight: CGFloat = 140
    private static let fadeHeight: CGFloat = 18

    private var bandTable: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    if !controller.parametricFilters.isEmpty {
                        BandRow.header
                    }
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
                            isHighlighted: hoveredBand == index,
                            onDotHover: { inside in
                                if inside {
                                    hoveredBand = index
                                } else if hoveredBand == index {
                                    hoveredBand = nil
                                }
                            },
                            onDelete: {
                                // Commit any half-typed value now, while positions
                                // still point at the right bands. Committed after the
                                // deletion, it would land on whichever band moved
                                // into that row.
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                controller.removeParametricBand(at: index)
                            }
                        )
                        .id(index)
                    }
                    if controller.parametricFilters.isEmpty {
                        Text("No bands yet. Add one, or paste an AutoEQ profile as text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    }
                }
                // Room for the overlay scroll bar, so it never covers the delete
                // button at the end of a row.
                .padding(.trailing, 12)
                .background(
                    GeometryReader { content in
                        Color.clear.preference(
                            key: BandTableExtentKey.self,
                            value: content.frame(in: .named("bandTable"))
                        )
                    }
                )
            }
            .coordinateSpace(name: "bandTable")
            .frame(height: Self.tableHeight)
            .onPreferenceChange(BandTableExtentKey.self) { frame in
                moreAbove = frame.minY < -1
                moreBelow = frame.maxY > Self.tableHeight + 1
            }
            .mask(scrollFadeMask)
            // A new band is appended at the bottom: bring it into view.
            .onChange(of: controller.parametricFilters.count) { oldCount, newCount in
                guard newCount > oldCount else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    /// Fades the list's top/bottom edge only when there is more to scroll
    /// that way: a quiet hint that rows are hidden.
    private var scrollFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(moreAbove ? 0 : 1), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(moreBelow ? 0 : 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.fadeHeight)
        }
        .animation(.easeOut(duration: 0.15), value: moreAbove)
        .animation(.easeOut(duration: 0.15), value: moreBelow)
    }

    private var configEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $configDraft)
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 112)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if let parseError = controller.configParseError {
                    Text(parseError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    // The one place this tip is useful: where the profile is pasted.
                    Link(
                        "Find your headphones on AutoEQ",
                        destination: URL(string: "https://github.com/jaakkopasanen/AutoEq/tree/master/results")!
                    )
                    .font(.caption2)
                    .help("Free correction profiles for 5000+ headphones. Paste the ParametricEQ.txt here.")
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

private struct BandTableExtentKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

enum BandPalette {
    private static let colors: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .red]

    static func color(_ index: Int) -> Color {
        colors[index % colors.count]
    }
}

extension View {
    /// Soft halo used to tie a band's table dot to its point on the curve.
    func bandGlow(_ color: Color, active: Bool) -> some View {
        background(
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 18, height: 18)
                .blur(radius: 1.5)
                .opacity(active ? 1 : 0)
        )
        .scaleEffect(active ? 1.25 : 1)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

/// Small borderless symbol button used in the popover's toolbars.
struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(
                    Color.primary.opacity(hovering ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One row of the band table: the colored dot toggles the band, then type,
/// frequency, gain, Q, delete. Units live in the header row, once.
struct BandRow: View {
    @Binding var filter: FilterSpec
    let color: Color
    let isHighlighted: Bool
    let onDotHover: (Bool) -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    enum Column {
        /// Wide enough for the hover halo: the scroll view clips anything
        /// past its left edge, which pushed the glow off center.
        static let dot: CGFloat = 24
        static let type: CGFloat = 62
        static let delete: CGFloat = 18
    }

    /// Column titles with units, aligned to the row layout.
    static var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Column.dot, height: 1)
            Text("Type").frame(width: Column.type, alignment: .leading).padding(.leading, 4)
            Text("Freq (Hz)").frame(maxWidth: .infinity, alignment: .leading)
            Text("Gain (dB)").frame(maxWidth: .infinity, alignment: .leading)
            Text("Q").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: Column.delete, height: 1)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 2)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                filter.isEnabled.toggle()
            } label: {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .background(Circle().fill(filter.isEnabled ? color : .clear))
                    .frame(width: 9, height: 9)
                    .bandGlow(color, active: isHighlighted)
                    .frame(width: Column.dot, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover(perform: onDotHover)
            .help(filter.isEnabled ? "Turn this band off" : "Turn this band on")

            Picker("", selection: $filter.type) {
                ForEach(FilterType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: Column.type)

            numberField("Hz", value: $filter.frequency)
            numberField("dB", value: $filter.gainDB)
                .disabled(!filter.type.usesGain)
                .opacity(filter.type.usesGain ? 1 : 0.3)
            numberField("Q", value: $filter.q)
                .disabled(!filter.type.usesQ)
                .opacity(filter.type.usesQ ? 1 : 0.3)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: Column.delete, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Remove this band")
        }
        .padding(.vertical, 1)
        .opacity(filter.isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }

    private func numberField(_ placeholder: String, value: Binding<Double>) -> some View {
        TextField(placeholder, value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.plain)
            .font(.system(size: 11).monospacedDigit())
            .padding(.horizontal, 7)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Log-frequency / dB plot of the summed response, with draggable control points
/// (drag horizontally = Fc, vertically = gain for types that have one).
struct ResponseCurveView: View {
    @ObservedObject var controller: EQController
    @Binding var hoveredBand: Int?
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
                        let color = BandPalette.color(index)
                        Circle()
                            .fill(color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .shadow(color: color.opacity(0.5), radius: 2)
                            .bandGlow(color, active: draggedBandIndex == index || hoveredBand == index)
                            .position(pointPosition(for: filter, in: size))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredBand = nearestBand(to: location, in: size, within: 14)
                case .ended:
                    hoveredBand = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { gesture in
                        dragBand(at: gesture.location, in: size, startLocation: gesture.startLocation)
                    }
                    .onEnded { _ in draggedBandIndex = nil }
            )
        }
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

    /// Bands outside the plotted range (e.g. a 17 Hz AutoEQ band, or more
    /// than 15 dB of gain) are pinned to the plot edge so they stay visible
    /// and draggable instead of being drawn off the canvas.
    private func pointPosition(for filter: FilterSpec, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 6
        let x = xPosition(frequency: filter.frequency, width: size.width)
        let y = yPosition(db: filter.type.usesGain ? filter.gainDB : 0, height: size.height)
        return CGPoint(
            x: min(max(x, inset), size.width - inset),
            y: min(max(y, inset), size.height - inset)
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
        context.stroke(gridLines, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)

        var zeroLine = Path()
        let zeroY = yPosition(db: 0, height: size.height)
        zeroLine.move(to: CGPoint(x: 0, y: zeroY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(zeroLine, with: .color(.primary.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        for (label, frequency) in [("100", 100.0), ("1k", 1000.0), ("10k", 10000.0)] {
            context.draw(
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary),
                at: CGPoint(x: xPosition(frequency: frequency, width: size.width) + 4, y: size.height - 8),
                anchor: .leading
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
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [.purple, .blue]),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)
        )
        // Soft glow under a crisp line.
        var glow = context
        glow.addFilter(.blur(radius: 4))
        glow.opacity = 0.45
        glow.stroke(curve, with: shading, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        context.stroke(curve, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Interaction

    private func dragBand(at location: CGPoint, in size: CGSize, startLocation: CGPoint) {
        if draggedBandIndex == nil {
            // Lock onto the enabled band nearest to where the drag began.
            guard let nearest = nearestBand(to: startLocation, in: size, within: 25) else { return }
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

    /// The enabled band whose point is closest to `location`, if within `radius`.
    private func nearestBand(to location: CGPoint, in size: CGSize, within radius: CGFloat) -> Int? {
        let candidates = controller.parametricFilters.indices.filter {
            controller.parametricFilters[$0].isEnabled
        }
        let nearest = candidates.min { first, second in
            distance(from: location, to: pointPosition(for: controller.parametricFilters[first], in: size))
                < distance(from: location, to: pointPosition(for: controller.parametricFilters[second], in: size))
        }
        guard let nearest,
              distance(from: location, to: pointPosition(for: controller.parametricFilters[nearest], in: size)) < radius
        else { return nil }
        return nearest
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Live output spectrum, drawn as a soft filled curve behind the response
/// curve. Levels arrive smoothed (SpectrumSmoother) and auto-ranged to 0...1
/// of the plot height (SpectrumAutoRange), a different scale than the
/// response dB axis, purely for visualization. This draws them as a
/// Catmull-Rom spline rather than straight segments.
///
/// A separate view on purpose: it alone observes SpectrumModel, so the 30 fps
/// updates redraw only this canvas instead of the whole popover.
private struct SpectrumOverlay: View {
    @ObservedObject var spectrum: SpectrumModel

    private let freqRange: ClosedRange<Double> = 20...20000

    var body: some View {
        Canvas { context, size in
            let levels = spectrum.levels
            guard levels.count == EQController.spectrumBands.count, levels.count > 1 else { return }
            let logSpan = log(freqRange.upperBound / freqRange.lowerBound)
            let points = EQController.spectrumBands.enumerated().map { index, band in
                let fraction = max(0, min(1, levels[index]))
                return CGPoint(
                    x: CGFloat(log(band / freqRange.lowerBound) / logSpan) * size.width,
                    y: size.height * CGFloat(1 - fraction)
                )
            }

            let edge = Self.spline(through: points)
            var fill = edge
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [Color.blue.opacity(0.22), Color.purple.opacity(0.04)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(edge, with: .color(.blue.opacity(0.25)), lineWidth: 1)
        }
    }

    /// Uniform Catmull-Rom through the points, as cubic Beziers.
    private static func spline(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: 0, y: first.y))
        path.addLine(to: first)
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}
