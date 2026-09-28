import Accelerate
import Foundation

/// One biquad section of a kernel, tagged with the identity of the filter it
/// came from (e.g. its band index). When one kernel replaces another mid-stream,
/// filter state carries over between sections with equal ids.
public struct KernelSection: Equatable {
    public let id: Int
    public let coefficients: BiquadCoefficients

    public init(id: Int, coefficients: BiquadCoefficients) {
        self.id = id
        self.coefficients = coefficients
    }
}

/// A built, immutable EQ processing chain: one vDSP biquad cascade applied per
/// channel (stereo-linked coefficients, independent filter state) plus a preamp.
///
/// Build on a non-real-time thread; `process` is real-time safe (no allocation,
/// no locks — the delay buffers are preallocated and owned by the kernel).
/// Wraps vDSP (external system interface), hence a class with managed lifetime.
public final class EQKernel {
    private let setup: vDSP_biquad_Setup
    private let sectionCount: Int
    private let sectionIDs: [Int]
    private let preampLinear: Float
    /// Gain the next `process` ramps from. Equal to preampLinear except for the
    /// first buffer after adoptState(from:) picked up a different preamp.
    private var preampRampStart: Float
    /// vDSP delay state: 2 * sections + 2 floats per channel.
    private let delays: [UnsafeMutablePointer<Float>]
    private let maxChannels: Int

    // Stereo-linked hard-knee peak limiter (safety net after the preamp).
    // Instant attack guarantees no sample exceeds the threshold; the release
    // recovers smoothly. State is touched only by the audio thread.
    private let limiterEnabled: Bool
    private var limiterGain: Float = 1.0
    private let limiterThreshold: Float = 0.9886  // -0.1 dBFS
    private let limiterReleasePerFrame: Float

    public let sampleRate: Double

    /// - Parameters:
    ///   - sections: biquad sections applied in series (identical for all
    ///     channels), each tagged with a stable id for adoptState(from:).
    ///   - preampDB: gain applied after filtering, in dB.
    ///   - sampleRate: rate the coefficients were computed for.
    ///   - maxChannels: number of independent channel states to allocate.
    ///   - limiterEnabled: apply the stereo-linked safety limiter after the preamp.
    public init?(sections: [KernelSection], preampDB: Double, sampleRate: Double, maxChannels: Int, limiterEnabled: Bool) {
        guard !sections.isEmpty, maxChannels > 0 else { return nil }
        self.limiterEnabled = limiterEnabled
        // ~150 ms release time constant, computed per frame.
        self.limiterReleasePerFrame = Float(1.0 - exp(-1.0 / (0.15 * sampleRate)))
        var flattened: [Double] = []
        flattened.reserveCapacity(sections.count * 5)
        for section in sections.map(\.coefficients) {
            flattened.append(contentsOf: [section.b0, section.b1, section.b2, section.a1, section.a2])
        }
        guard let setup = vDSP_biquad_CreateSetup(flattened, vDSP_Length(sections.count)) else {
            return nil
        }
        self.setup = setup
        self.sectionCount = sections.count
        self.sectionIDs = sections.map(\.id)
        self.preampLinear = Float(pow(10.0, preampDB / 20.0))
        self.preampRampStart = preampLinear
        self.sampleRate = sampleRate
        self.maxChannels = maxChannels
        let delayLength = 2 * sections.count + 2
        self.delays = (0..<maxChannels).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: delayLength)
            pointer.initialize(repeating: 0, count: delayLength)
            return pointer
        }
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
        for pointer in delays {
            pointer.deallocate()
        }
    }

    /// Continues from `previous`'s state instead of from silence. A slider tick
    /// builds a new kernel while music plays; starting its filters and limiter
    /// from zero is an audible click. Call on the audio thread, once, before
    /// this kernel's first `process`, with the kernel that ran last. Real-time
    /// safe: copies preallocated state, allocates nothing.
    ///
    /// vDSP's delay layout (verified against a Direct Form I reference) is one
    /// pair per stage: the input history, then each section's output history.
    /// A section's input history is simply the previous pair. So:
    /// - a section whose id also exists in `previous` keeps its output history;
    /// - a section with no match (a band just leaving 0 dB, where it was pruned)
    ///   takes its input history as output history, which is exactly what the
    ///   identity section it replaces would have produced. Seamless both ways.
    public func adoptState(from previous: EQKernel) {
        for channel in 0..<min(maxChannels, previous.maxChannels) {
            let source = previous.delays[channel]
            let destination = delays[channel]
            destination.update(from: source, count: 2)
            for section in 0..<sectionCount {
                let pair = destination + 2 * (section + 1)
                if let match = previous.sectionIDs.firstIndex(of: sectionIDs[section]) {
                    pair.update(from: source + 2 * (match + 1), count: 2)
                } else {
                    pair.update(from: pair - 2, count: 2)
                }
            }
        }
        limiterGain = previous.limiterGain
        preampRampStart = previous.preampLinear
    }

    /// Filters interleaved Float32 audio in place. Real-time safe.
    public func process(interleaved samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        guard frameCount > 0, channelCount > 0 else { return }
        let channels = min(channelCount, maxChannels)
        for channel in 0..<channels {
            vDSP_biquad(
                setup,
                delays[channel],
                samples + channel,
                vDSP_Stride(channelCount),
                samples + channel,
                vDSP_Stride(channelCount),
                vDSP_Length(frameCount)
            )
        }
        if preampRampStart == preampLinear {
            var gain = preampLinear
            let totalSamples = vDSP_Length(frameCount * channelCount)
            vDSP_vsmul(samples, 1, &gain, samples, 1, totalSamples)
        } else {
            // A gain step multiplies the waveform instantly, which ticks on loud
            // material; ramp across this buffer instead, per frame so every
            // channel moves together.
            let step = (preampLinear - preampRampStart) / Float(frameCount)
            for channel in 0..<channelCount {
                var gain = preampRampStart
                var increment = step
                vDSP_vrampmul(
                    samples + channel, vDSP_Stride(channelCount),
                    &gain, &increment,
                    samples + channel, vDSP_Stride(channelCount),
                    vDSP_Length(frameCount)
                )
            }
            preampRampStart = preampLinear
        }

        if limiterEnabled {
            applyLimiter(samples: samples, frameCount: frameCount, channelCount: channelCount)
        }
    }

    private func applyLimiter(samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        // Fast path: fully released, and no sample can reach the threshold, so
        // the loop below would multiply everything by exactly 1.0. This is the
        // common case (audio that never clips), and the loop it skips is scalar
        // and branchy — the most expensive thing in the chain on Intel.
        var bufferPeak: Float = 0
        vDSP_maxmgv(samples, 1, &bufferPeak, vDSP_Length(frameCount * channelCount))
        if limiterGain >= 1.0 && bufferPeak <= limiterThreshold {
            return
        }

        var gain = limiterGain
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var framePeak: Float = 0
            for channel in 0..<channelCount {
                let magnitude = abs(samples[base + channel])
                if magnitude > framePeak { framePeak = magnitude }
            }
            if framePeak * gain > limiterThreshold {
                gain = limiterThreshold / framePeak
            } else {
                gain += (1.0 - gain) * limiterReleasePerFrame
            }
            for channel in 0..<channelCount {
                samples[base + channel] *= gain
            }
        }
        // The release curve approaches 1.0 asymptotically and could otherwise
        // sit a hair below it forever, which would keep the fast path above
        // permanently unreachable. Snapping costs at most -0.0001 dB.
        limiterGain = gain > 0.9999 ? 1.0 : gain
    }
}
