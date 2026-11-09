import Foundation

/// Auto-ranges smoothed spectrum levels (dBFS) for display. A fixed dBFS
/// scale leaves typical music in the bottom third of the plot, so this tracks
/// a reference level that jumps up to the loudest band at once and sinks back
/// slowly, then maps the `span` dB below that reference onto 0...(1 - headroom).
///
/// The reference never drops below `minimumReferenceDB`, so silence and the
/// noise floor stay at the bottom instead of being blown up to full height.
///
/// Pure value type so it can be tested without audio.
public struct SpectrumAutoRange {
    /// dB shown below the reference level.
    public var span: Double
    /// Fraction of the plot height left free above the loudest band.
    public var headroom: Double
    /// dB the reference may fall per frame when the music gets quieter.
    public var releasePerFrame: Double
    /// Lowest reference level, in dBFS.
    public var minimumReferenceDB: Double
    private var reference: Double?

    public init(span: Double = 50, headroom: Double = 0.12, releasePerFrame: Double = 0.15, minimumReferenceDB: Double = -40) {
        self.span = span
        self.headroom = headroom
        self.releasePerFrame = releasePerFrame
        self.minimumReferenceDB = minimumReferenceDB
    }

    /// Clears the tracked reference (e.g. when the display is hidden).
    public mutating func reset() {
        reference = nil
    }

    /// Maps one frame of dBFS levels to display heights in 0...1.
    public mutating func normalize(_ levelsDB: [Double]) -> [Double] {
        guard let peak = levelsDB.max() else { return [] }
        let target = max(peak, minimumReferenceDB)
        let top: Double
        if let current = reference, target < current {
            top = max(target, current - releasePerFrame)
        } else {
            top = target
        }
        reference = top
        let bottom = top - span
        let scale = 1 - headroom
        return levelsDB.map { max(0, min(1, ($0 - bottom) / span)) * scale }
    }
}
