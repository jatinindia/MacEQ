import Foundation

/// Turns raw per-frame spectrum bands (dBFS) into a calm display curve:
/// a small Gaussian blur across neighboring bands removes the jagged
/// bin-to-bin peaks, and attack/release ballistics remove frame-to-frame
/// flicker (rises fast so transients still register, falls slowly).
///
/// Pure value type so it can be tested without audio.
public struct SpectrumSmoother {
    /// Fraction of the gap closed per frame when the level rises.
    public var attack: Double
    /// Fraction of the gap closed per frame when the level falls.
    public var release: Double
    /// Gaussian kernel weights, centered (odd count).
    private let kernel: [Double]
    private var state: [Double] = []

    public init(attack: Double = 0.6, release: Double = 0.18, blurRadius: Int = 2, sigma: Double = 1.2) {
        self.attack = attack
        self.release = release
        let radius = max(blurRadius, 0)
        let weights = (-radius...radius).map { offset in
            exp(-Double(offset * offset) / (2 * sigma * sigma))
        }
        let total = weights.reduce(0, +)
        self.kernel = weights.map { $0 / total }
    }

    /// Clears the ballistics state (e.g. when the display is hidden).
    public mutating func reset() {
        state = []
    }

    /// Feeds one raw frame and returns the smoothed frame.
    public mutating func process(_ frame: [Double]) -> [Double] {
        let blurred = Self.blur(frame, kernel: kernel)
        guard state.count == blurred.count else {
            state = blurred
            return state
        }
        for index in blurred.indices {
            let target = blurred[index]
            let coefficient = target > state[index] ? attack : release
            state[index] += (target - state[index]) * coefficient
        }
        return state
    }

    /// Edge-clamped convolution with a normalized kernel.
    static func blur(_ values: [Double], kernel: [Double]) -> [Double] {
        guard values.count > 1, kernel.count > 1 else { return values }
        let radius = kernel.count / 2
        let last = values.count - 1
        return values.indices.map { index in
            var sum = 0.0
            for (offset, weight) in kernel.enumerated() {
                let source = min(max(index + offset - radius, 0), last)
                sum += values[source] * weight
            }
            return sum
        }
    }
}
