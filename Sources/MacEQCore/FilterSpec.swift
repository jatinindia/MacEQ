import Foundation

/// The filter types Equalizer APO supports, keyed by their config.txt type codes.
public enum FilterType: String, CaseIterable, Equatable {
    case peaking = "PK"
    case lowPass = "LP"
    case highPass = "HP"
    case lowPassQ = "LPQ"
    case highPassQ = "HPQ"
    case lowShelf = "LS"
    case highShelf = "HS"
    case lowShelfC = "LSC"
    case highShelfC = "HSC"
    case notch = "NO"
    case bandPass = "BP"
    case allPass = "AP"

    /// Whether this type has a user-set gain.
    public var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf, .lowShelfC, .highShelfC: return true
        case .lowPass, .highPass, .lowPassQ, .highPassQ, .notch, .bandPass, .allPass: return false
        }
    }

    /// Whether this type has a user-set Q.
    public var usesQ: Bool {
        switch self {
        case .peaking, .lowPassQ, .highPassQ, .lowShelfC, .highShelfC, .notch, .bandPass, .allPass: return true
        case .lowPass, .highPass, .lowShelf, .highShelf: return false
        }
    }
}

/// One filter line of an APO config: type, on/off, and parameters.
/// `q` and `gainDB` are stored even for types that ignore them, so switching a
/// band's type in the UI round-trips the values.
public struct FilterSpec: Equatable {
    public var type: FilterType
    public var isEnabled: Bool
    public var frequency: Double
    public var gainDB: Double
    public var q: Double

    public init(type: FilterType, isEnabled: Bool, frequency: Double, gainDB: Double, q: Double) {
        self.type = type
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
    }
}

/// Fixed Q used by types without a user Q (LP, HP; and shelves at slope S=1,
/// where the RBJ slope formula reduces to exactly 1/sqrt(2) for any gain).
public let butterworthQ = 1.0 / 2.0.squareRoot()

/// RBJ Audio EQ Cookbook coefficients for any supported filter type.
/// Identity at or above Nyquist, where no type is realizable (see isBelowNyquist).
public func coefficients(for spec: FilterSpec, sampleRate: Double) -> BiquadCoefficients {
    guard isBelowNyquist(frequency: spec.frequency, sampleRate: sampleRate) else {
        return identityCoefficients
    }
    let omega = 2.0 * Double.pi * spec.frequency / sampleRate
    let cosOmega = cos(omega)
    let sinOmega = sin(omega)
    let q = spec.type.usesQ ? spec.q : butterworthQ
    let alpha = sinOmega / (2.0 * q)

    let b0: Double, b1: Double, b2: Double
    let a0: Double, a1: Double, a2: Double

    switch spec.type {
    case .peaking:
        let amplitude = pow(10.0, spec.gainDB / 40.0)
        b0 = 1.0 + alpha * amplitude
        b1 = -2.0 * cosOmega
        b2 = 1.0 - alpha * amplitude
        a0 = 1.0 + alpha / amplitude
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha / amplitude

    case .lowPass, .lowPassQ:
        b0 = (1.0 - cosOmega) / 2.0
        b1 = 1.0 - cosOmega
        b2 = (1.0 - cosOmega) / 2.0
        a0 = 1.0 + alpha
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha

    case .highPass, .highPassQ:
        b0 = (1.0 + cosOmega) / 2.0
        b1 = -(1.0 + cosOmega)
        b2 = (1.0 + cosOmega) / 2.0
        a0 = 1.0 + alpha
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha

    case .bandPass:
        // Constant 0 dB peak gain variant.
        b0 = alpha
        b1 = 0.0
        b2 = -alpha
        a0 = 1.0 + alpha
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha

    case .notch:
        b0 = 1.0
        b1 = -2.0 * cosOmega
        b2 = 1.0
        a0 = 1.0 + alpha
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha

    case .allPass:
        b0 = 1.0 - alpha
        b1 = -2.0 * cosOmega
        b2 = 1.0 + alpha
        a0 = 1.0 + alpha
        a1 = -2.0 * cosOmega
        a2 = 1.0 - alpha

    case .lowShelf, .lowShelfC:
        let amplitude = pow(10.0, spec.gainDB / 40.0)
        let beta = 2.0 * amplitude.squareRoot() * alpha
        b0 = amplitude * ((amplitude + 1.0) - (amplitude - 1.0) * cosOmega + beta)
        b1 = 2.0 * amplitude * ((amplitude - 1.0) - (amplitude + 1.0) * cosOmega)
        b2 = amplitude * ((amplitude + 1.0) - (amplitude - 1.0) * cosOmega - beta)
        a0 = (amplitude + 1.0) + (amplitude - 1.0) * cosOmega + beta
        a1 = -2.0 * ((amplitude - 1.0) + (amplitude + 1.0) * cosOmega)
        a2 = (amplitude + 1.0) + (amplitude - 1.0) * cosOmega - beta

    case .highShelf, .highShelfC:
        let amplitude = pow(10.0, spec.gainDB / 40.0)
        let beta = 2.0 * amplitude.squareRoot() * alpha
        b0 = amplitude * ((amplitude + 1.0) + (amplitude - 1.0) * cosOmega + beta)
        b1 = -2.0 * amplitude * ((amplitude - 1.0) + (amplitude + 1.0) * cosOmega)
        b2 = amplitude * ((amplitude + 1.0) + (amplitude - 1.0) * cosOmega - beta)
        a0 = (amplitude + 1.0) - (amplitude - 1.0) * cosOmega + beta
        a1 = 2.0 * ((amplitude - 1.0) - (amplitude + 1.0) * cosOmega)
        a2 = (amplitude + 1.0) - (amplitude - 1.0) * cosOmega - beta
    }

    return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
}
