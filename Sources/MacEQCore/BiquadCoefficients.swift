import Foundation

/// Normalized biquad coefficients (a0 divided out), Direct Form I convention:
/// y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]
///
/// Formulas from the RBJ Audio EQ Cookbook (W3C edition, adapted from
/// Robert Bristow-Johnson's Audio-EQ-Cookbook.txt).
public struct BiquadCoefficients: Equatable {
    public let b0: Double
    public let b1: Double
    public let b2: Double
    public let a1: Double
    public let a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
}

/// H(z) = 1: passes audio through unchanged.
public let identityCoefficients = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

/// Whether a filter at `frequency` can be realized at `sampleRate`.
///
/// At or above Nyquist the RBJ formulas put a pole on or outside the unit
/// circle, and the filter's output grows without bound. That happens in
/// practice: Bluetooth headsets drop to 16/24 kHz while their mic is in use,
/// which pushes the 16 kHz graphic band (and typical AutoEQ treble shelves)
/// past Nyquist. Such a filter could only act on content the stream cannot
/// carry, so the caller substitutes identity.
func isBelowNyquist(frequency: Double, sampleRate: Double) -> Bool {
    frequency < sampleRate / 2
}

/// RBJ Audio EQ Cookbook peaking filter. Identity at or above Nyquist.
public func peakingCoefficients(sampleRate: Double, frequency: Double, q: Double, gainDB: Double) -> BiquadCoefficients {
    guard isBelowNyquist(frequency: frequency, sampleRate: sampleRate) else {
        return identityCoefficients
    }
    let amplitude = pow(10.0, gainDB / 40.0)
    let omega = 2.0 * Double.pi * frequency / sampleRate
    let alpha = sin(omega) / (2.0 * q)
    let cosOmega = cos(omega)

    let b0 = 1.0 + alpha * amplitude
    let b1 = -2.0 * cosOmega
    let b2 = 1.0 - alpha * amplitude
    let a0 = 1.0 + alpha / amplitude
    let a1 = -2.0 * cosOmega
    let a2 = 1.0 - alpha / amplitude

    return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}

/// Whether a section passes its input through untouched, i.e. H(z) = 1.
///
/// A peaking or shelving filter at 0 dB gain normalizes to b == a exactly (not
/// approximately), so such sections can be dropped from a cascade without
/// changing a single output sample. Worth doing: a flat graphic EQ would
/// otherwise run a biquad per band, per channel, on every callback forever —
/// which is pure waste, and disproportionately expensive on Intel.
public func isIdentitySection(_ section: BiquadCoefficients) -> Bool {
    // Tolerance rather than == : coefficients arrive via transcendental math,
    // and a section this close to identity is inaudible either way.
    let epsilon = 1e-12
    return abs(section.b0 - 1.0) < epsilon
        && abs(section.b1 - section.a1) < epsilon
        && abs(section.b2 - section.a2) < epsilon
}

/// Magnitude response in dB of a cascade of biquads at one frequency:
/// |H(e^jω)| evaluated per section and summed in dB.
public func magnitudeDB(of cascade: [BiquadCoefficients], sampleRate: Double, frequency: Double) -> Double {
    let omega = 2.0 * Double.pi * frequency / sampleRate
    // z^-1 = e^{-jω}
    let zRe = cos(omega)
    let zIm = -sin(omega)
    // z^-2 = e^{-j2ω}
    let z2Re = cos(2.0 * omega)
    let z2Im = -sin(2.0 * omega)

    var totalDB = 0.0
    for section in cascade {
        let numRe = section.b0 + section.b1 * zRe + section.b2 * z2Re
        let numIm = section.b1 * zIm + section.b2 * z2Im
        let denRe = 1.0 + section.a1 * zRe + section.a2 * z2Re
        let denIm = section.a1 * zIm + section.a2 * z2Im
        let magnitudeSquared = (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm)
        totalDB += 10.0 * log10(magnitudeSquared)
    }
    return totalDB
}

/// Preamp (dB, <= 0) that exactly negates the cascade's maximum positive response,
/// scanned over a log-spaced 20 Hz - 20 kHz grid. Matches AutoEQ's convention.
public func autoPreampDB(of cascade: [BiquadCoefficients], sampleRate: Double) -> Double {
    let frequencies = logSpacedFrequencies(from: 20, to: min(20000, sampleRate / 2 * 0.95), count: 512)
    let responses = frequencies.map { magnitudeDB(of: cascade, sampleRate: sampleRate, frequency: $0) }
    guard let coarseIndex = responses.indices.max(by: { responses[$0] < responses[$1] }) else {
        return 0.0
    }

    // The grid can straddle a narrow peak; refine around the coarse maximum with a
    // golden-section search in log-frequency so the preamp negates the true peak.
    var low = log(frequencies[max(coarseIndex - 1, 0)])
    var high = log(frequencies[min(coarseIndex + 1, frequencies.count - 1)])
    let ratio = (sqrt(5.0) - 1.0) / 2.0
    let response = { (logF: Double) in
        magnitudeDB(of: cascade, sampleRate: sampleRate, frequency: exp(logF))
    }
    var x1 = high - ratio * (high - low)
    var x2 = low + ratio * (high - low)
    var f1 = response(x1)
    var f2 = response(x2)
    for _ in 0..<60 {
        if f1 < f2 {
            low = x1
            x1 = x2
            f1 = f2
            x2 = low + ratio * (high - low)
            f2 = response(x2)
        } else {
            high = x2
            x2 = x1
            f2 = f1
            x1 = high - ratio * (high - low)
            f1 = response(x1)
        }
    }
    let maxResponse = max(responses[coarseIndex], f1, f2)
    return maxResponse > 0.0 ? -maxResponse : 0.0
}

/// Log-spaced frequency grid, used for response scans and (later) curve drawing.
public func logSpacedFrequencies(from low: Double, to high: Double, count: Int) -> [Double] {
    precondition(count >= 2, "logSpacedFrequencies requires count >= 2, got \(count)")
    precondition(low > 0 && high > low, "invalid range \(low)...\(high)")
    let logLow = log(low)
    let step = (log(high) - logLow) / Double(count - 1)
    return (0..<count).map { exp(logLow + Double($0) * step) }
}
