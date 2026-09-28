import AVFoundation
import Foundation
import MacEQCore

// Minimal test runner: the Command Line Tools toolchain ships neither XCTest nor
// swift-testing, so tests are a plain executable. Run with: swift run maceq-tests
// Exits 1 if any expectation fails.

var failureCount = 0
var expectationCount = 0

func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    expectationCount += 1
    if !condition {
        failureCount += 1
        let fileName = (file as NSString).lastPathComponent
        print("FAIL \(fileName):\(line): \(message)")
    }
}

func expectClose(
    _ actual: Double, _ expected: Double, tolerance: Double, _ label: String,
    file: String = #file, line: Int = #line
) {
    expect(
        abs(actual - expected) < tolerance,
        "\(label): \(actual) != \(expected) (tolerance \(tolerance))",
        file: file, line: line
    )
}

func expectCoefficients(
    _ actual: BiquadCoefficients, _ expected: [Double],
    file: String = #file, line: Int = #line
) {
    let tolerance = 1e-9
    expectClose(actual.b0, expected[0], tolerance: tolerance, "b0", file: file, line: line)
    expectClose(actual.b1, expected[1], tolerance: tolerance, "b1", file: file, line: line)
    expectClose(actual.b2, expected[2], tolerance: tolerance, "b2", file: file, line: line)
    expectClose(actual.a1, expected[3], tolerance: tolerance, "a1", file: file, line: line)
    expectClose(actual.a2, expected[4], tolerance: tolerance, "a2", file: file, line: line)
}

// MARK: - RBJ peaking coefficients vs independent Python-computed references

func testPeakingCoefficientReferences() {
    expectCoefficients(
        peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: 6.0),
        [1.043953086990, -1.895320723937, 0.867722284760, -1.895320723937, 0.911675371750]
    )
    expectCoefficients(
        peakingCoefficients(sampleRate: 48000, frequency: 31.5, q: 2.2, gainDB: -12.0),
        [0.998602485205, -1.996250408025, 0.997664893001, -1.996250408025, 0.996267378206]
    )
    expectCoefficients(
        peakingCoefficients(sampleRate: 44100, frequency: 16000, q: 2.2, gainDB: 12.0),
        [1.237257245133, 1.198259601429, 0.603566949272, 1.198259601429, 0.840824194405]
    )
    expectCoefficients(
        peakingCoefficients(sampleRate: 96000, frequency: 125, q: 0.5, gainDB: 3.0),
        [1.002820317669, -1.986260502412, 0.983506659325, -1.986260502412, 0.986326976994]
    )
}

// MARK: - Magnitude response

func testMagnitudeResponse() {
    let peak6 = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: 6.0)
    expectClose(
        magnitudeDB(of: [peak6], sampleRate: 48000, frequency: 1000),
        6.0, tolerance: 1e-6, "magnitude at Fc equals gain"
    )
    expectClose(
        magnitudeDB(of: [peak6], sampleRate: 48000, frequency: 8000),
        0.084432, tolerance: 1e-5, "magnitude far from Fc (Python reference)"
    )

    let flat = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 2.2, gainDB: 0.0)
    for frequency in [20.0, 100.0, 1000.0, 10000.0, 20000.0] {
        expectClose(
            magnitudeDB(of: [flat], sampleRate: 48000, frequency: frequency),
            0.0, tolerance: 1e-9, "zero-gain band is identity at \(frequency) Hz"
        )
    }

    let boost = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: 6.0)
    let cut = peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 1.0, gainDB: -6.0)
    expectClose(
        magnitudeDB(of: [boost, cut], sampleRate: 48000, frequency: 1000),
        0.0, tolerance: 1e-6, "opposite gains at same Fc cancel"
    )
}

// MARK: - Auto-preamp

func testAutoPreamp() {
    let bands = [
        peakingCoefficients(sampleRate: 48000, frequency: 63, q: 2.2, gainDB: 8.0),
        peakingCoefficients(sampleRate: 48000, frequency: 4000, q: 2.2, gainDB: 3.0),
    ]
    let preamp = autoPreampDB(of: bands, sampleRate: 48000)
    expect(preamp <= -8.0, "preamp \(preamp) must negate at least the largest band gain")
    expect(preamp > -12.0, "preamp \(preamp) unreasonably large for +8 dB max boost")

    let frequencies = logSpacedFrequencies(from: 20, to: 20000, count: 512)
    expect(frequencies.count == 512, "frequency grid has requested count")
    let maxAfter = frequencies
        .map { magnitudeDB(of: bands, sampleRate: 48000, frequency: $0) + preamp }
        .max()
    expect(maxAfter != nil && abs(maxAfter!) < 0.01, "preamp brings response peak to 0 dB, got \(String(describing: maxAfter))")

    let cutsOnly = [peakingCoefficients(sampleRate: 48000, frequency: 250, q: 2.2, gainDB: -6.0)]
    expectClose(
        autoPreampDB(of: cutsOnly, sampleRate: 48000),
        0.0, tolerance: 1e-9, "cuts-only chain needs no preamp"
    )
}

// MARK: - Frequency grid

func testLogSpacedFrequencies() {
    let grid = logSpacedFrequencies(from: 20, to: 20000, count: 4)
    expect(grid.count == 4, "grid count")
    if grid.count == 4 {
        expectClose(grid[0], 20, tolerance: 1e-9, "grid start")
        expectClose(grid[3], 20000, tolerance: 1e-6, "grid end")
        expectClose(grid[1] / grid[0], grid[2] / grid[1], tolerance: 1e-9, "log spacing has constant ratio")
    }
}

// MARK: - EQKernel end-to-end behavior

/// RMS of one channel of an interleaved stereo buffer, skipping a settle prefix.
private func channelRMS(_ samples: [Float], channel: Int, channelCount: Int, skipFrames: Int) -> Double {
    var sum = 0.0
    var count = 0
    var index = skipFrames * channelCount + channel
    while index < samples.count {
        sum += Double(samples[index]) * Double(samples[index])
        count += 1
        index += channelCount
    }
    return (sum / Double(count)).squareRoot()
}

func testKernelAppliesBandGainToSine() {
    let sampleRate = 48000.0
    let frameCount = 48000
    let frequency = 1000.0
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: frequency, q: 1.0, gainDB: 6.0)]
    guard let kernel = EQKernel(sections: sectionsNumbered(cascade), preampDB: 0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: false) else {
        expect(false, "kernel construction failed")
        return
    }

    var buffer = [Float](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let value = Float(sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.25
        buffer[frame * 2] = value
        buffer[frame * 2 + 1] = value
    }
    let inputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: 4800)

    buffer.withUnsafeMutableBufferPointer { pointer in
        kernel.process(interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: 2)
    }

    for channel in 0..<2 {
        let outputRMS = channelRMS(buffer, channel: channel, channelCount: 2, skipFrames: 4800)
        let gainDB = 20.0 * log10(outputRMS / inputRMS)
        expectClose(gainDB, 6.0, tolerance: 0.05, "sine at Fc gains +6 dB (channel \(channel))")
    }
}

/// Regression check for low-band audibility: Float32 biquad state at very low
/// Fc/48 kHz is numerically delicate, so measure the real kernel gain there.
func testKernelLowBandsApplyGain() {
    let sampleRate = 48000.0
    let frameCount = 144000  // 3 s, so even a 31.5 Hz filter fully settles
    let skip = 48000
    for (frequency, q) in [(31.5, 2.2), (63.0, 2.2), (125.0, 2.2)] {
        let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: frequency, q: q, gainDB: 12.0)]
        guard let kernel = EQKernel(sections: sectionsNumbered(cascade), preampDB: 0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: false) else {
            expect(false, "kernel construction failed for \(frequency) Hz")
            continue
        }
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let value = Float(sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.1
            buffer[frame * 2] = value
            buffer[frame * 2 + 1] = value
        }
        let inputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: skip)
        buffer.withUnsafeMutableBufferPointer { pointer in
            kernel.process(interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: 2)
        }
        let outputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: skip)
        let gainDB = 20.0 * log10(outputRMS / inputRMS)
        expectClose(gainDB, 12.0, tolerance: 0.1, "+12 dB band at \(frequency) Hz delivers +12 dB")
    }
}

func testKernelPreampScales() {
    let sampleRate = 48000.0
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 1.0, gainDB: 0.0)]
    guard let kernel = EQKernel(sections: sectionsNumbered(cascade), preampDB: -6.0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: false) else {
        expect(false, "kernel construction failed")
        return
    }
    var buffer = [Float](repeating: 0.5, count: 512 * 2)
    buffer.withUnsafeMutableBufferPointer { pointer in
        kernel.process(interleaved: pointer.baseAddress!, frameCount: 512, channelCount: 2)
    }
    // DC through a flat band settles fast; check the tail.
    let tail = Double(buffer[1000])
    expectClose(tail, 0.5 * pow(10.0, -6.0 / 20.0), tolerance: 0.001, "preamp -6 dB scales amplitude")
}

// MARK: - All filter types vs independent Python references

func testFilterTypeReferences() {
    func spec(_ type: FilterType, _ frequency: Double, gain: Double = 0, q: Double = 0) -> FilterSpec {
        FilterSpec(type: type, isEnabled: true, frequency: frequency, gainDB: gain, q: q)
    }
    expectCoefficients(
        coefficients(for: spec(.lowPass, 1000), sampleRate: 48000),
        [0.003916126661, 0.007832253321, 0.003916126661, -1.815341082705, 0.831005589347]
    )
    expectCoefficients(
        coefficients(for: spec(.highPassQ, 100, q: 1.2), sampleRate: 48000),
        [0.994532982734, -1.989065965469, 0.994532982734, -1.988980757765, 0.989151173172]
    )
    expectCoefficients(
        coefficients(for: spec(.bandPass, 1000, q: 2.0), sampleRate: 48000),
        [0.031600378776, 0.0, -0.031600378776, -1.920229656437, 0.936799242447]
    )
    expectCoefficients(
        coefficients(for: spec(.notch, 60, q: 10.0), sampleRate: 48000),
        [0.999607459104, -1.999153257712, 0.999607459104, -1.999153257712, 0.999214918209]
    )
    expectCoefficients(
        coefficients(for: spec(.allPass, 500, q: butterworthQ), sampleRate: 48000),
        [0.911594496600, -1.907501626046, 1.0, -1.907501626046, 0.911594496600]
    )
    expectCoefficients(
        coefficients(for: spec(.lowShelf, 100, gain: 6.0), sampleRate: 48000),
        [1.003217895737, -1.984364430777, 0.981386698749, -1.984424329139, 0.984544696124]
    )
    expectCoefficients(
        coefficients(for: spec(.highShelf, 8000, gain: 3.0), sampleRate: 44100),
        [1.241825000347, -0.746711627193, 0.293353733121, -0.413493777491, 0.201960883766]
    )
    expectCoefficients(
        coefficients(for: spec(.lowShelfC, 105, gain: -4.0, q: 0.9), sampleRate: 48000),
        [0.998231191310, -1.982818954816, 0.984736541566, -1.982775445178, 0.983011242514]
    )
    expectCoefficients(
        coefficients(for: spec(.highShelfC, 10000, gain: -4.0, q: 0.9), sampleRate: 48000),
        [0.764169852532, -0.146585687696, 0.222245829776, -0.477928081879, 0.317758076491]
    )
}

func testFilterTypeMagnitudeSanity() {
    func mag(_ spec: FilterSpec, at frequency: Double) -> Double {
        magnitudeDB(of: [coefficients(for: spec, sampleRate: 48000)], sampleRate: 48000, frequency: frequency)
    }
    let lowPass = FilterSpec(type: .lowPass, isEnabled: true, frequency: 1000, gainDB: 0, q: 0)
    expectClose(mag(lowPass, at: 1000), -3.0103, tolerance: 0.01, "Butterworth LP is -3 dB at Fc")
    expectClose(mag(lowPass, at: 20), 0.0, tolerance: 0.01, "LP passband is flat")
    expect(mag(lowPass, at: 16000) < -40, "LP stopband attenuates strongly")

    let notch = FilterSpec(type: .notch, isEnabled: true, frequency: 60, gainDB: 0, q: 10)
    expect(mag(notch, at: 60) < -40, "notch is deep at Fc")
    expectClose(mag(notch, at: 1000), 0.0, tolerance: 0.05, "notch is flat far from Fc")

    let allPass = FilterSpec(type: .allPass, isEnabled: true, frequency: 500, gainDB: 0, q: butterworthQ)
    for frequency in [50.0, 500.0, 5000.0] {
        expectClose(mag(allPass, at: frequency), 0.0, tolerance: 1e-6, "all-pass magnitude is flat at \(frequency)")
    }

    let lowShelf = FilterSpec(type: .lowShelf, isEnabled: true, frequency: 100, gainDB: 6, q: 0)
    expectClose(mag(lowShelf, at: 10), 6.0, tolerance: 0.05, "low shelf reaches gain below Fc")
    expectClose(mag(lowShelf, at: 10000), 0.0, tolerance: 0.05, "low shelf flat above Fc")
}

// MARK: - APO config.txt parse/serialize

func testAPOParse() {
    let text = """
    # AutoEQ export for some headphone
    Preamp: -6.8 dB
    Filter 1: ON PK Fc 105 Hz Gain -4.0 dB Q 0.90
    Filter 2: ON LSC Fc 105 Hz Gain 2.5 dB Q 0.64
    Filter 3: OFF HP Fc 40 Hz
    Filter 4: ON PK Fc 1500,5 Hz Gain 3,2 dB Q 2,00
    Device: some device to ignore
    Filter 5: ON HSC Fc 10000 Hz Gain -5.4 dB Q 0.70
    """
    do {
        let preset = try parseAPOConfig(text)
        expectClose(preset.preampDB, -6.8, tolerance: 1e-9, "preamp parsed")
        expect(preset.filters.count == 5, "5 filters parsed, got \(preset.filters.count)")
        guard preset.filters.count == 5 else { return }
        expect(preset.filters[0].type == .peaking, "filter 1 type")
        expectClose(preset.filters[0].frequency, 105, tolerance: 1e-9, "filter 1 Fc")
        expectClose(preset.filters[0].gainDB, -4.0, tolerance: 1e-9, "filter 1 gain")
        expectClose(preset.filters[0].q, 0.9, tolerance: 1e-9, "filter 1 Q")
        expect(preset.filters[1].type == .lowShelfC, "filter 2 type LSC")
        expect(!preset.filters[2].isEnabled, "filter 3 is OFF")
        expect(preset.filters[2].type == .highPass, "filter 3 type HP")
        expectClose(preset.filters[3].frequency, 1500.5, tolerance: 1e-9, "decimal-comma Fc")
        expectClose(preset.filters[3].gainDB, 3.2, tolerance: 1e-9, "decimal-comma gain")
        expect(preset.filters[4].type == .highShelfC, "filter 5 type HSC")
    } catch {
        expect(false, "parse threw: \(error)")
    }
}

func testAPOParseErrors() {
    do {
        _ = try parseAPOConfig("Filter 1: ON XYZ Fc 100 Hz")
        expect(false, "unknown filter type must throw")
    } catch let error as APOParseError {
        expect(error.line == 1, "error carries line number, got \(error.line)")
    } catch {
        expect(false, "wrong error type: \(error)")
    }
    do {
        _ = try parseAPOConfig("Preamp: loud dB")
        expect(false, "malformed preamp must throw")
    } catch is APOParseError {
        expect(true, "")
    } catch {
        expect(false, "wrong error type: \(error)")
    }
}

func testAPORoundTrip() {
    let original = EQPreset(preampDB: -5.5, filters: [
        FilterSpec(type: .peaking, isEnabled: true, frequency: 105.5, gainDB: -4.0, q: 0.9),
        FilterSpec(type: .lowPass, isEnabled: true, frequency: 18000, gainDB: 0, q: butterworthQ),
        FilterSpec(type: .highShelf, isEnabled: false, frequency: 8000, gainDB: 3.1, q: butterworthQ),
        FilterSpec(type: .notch, isEnabled: true, frequency: 50, gainDB: 0, q: 30),
    ])
    do {
        let reparsed = try parseAPOConfig(serializeAPOConfig(original))
        expectClose(reparsed.preampDB, original.preampDB, tolerance: 0.01, "round-trip preamp")
        expect(reparsed.filters.count == original.filters.count, "round-trip filter count")
        for (index, pair) in zip(reparsed.filters, original.filters).enumerated() {
            expect(pair.0.type == pair.1.type, "round-trip type at \(index)")
            expect(pair.0.isEnabled == pair.1.isEnabled, "round-trip enabled at \(index)")
            expectClose(pair.0.frequency, pair.1.frequency, tolerance: 0.01, "round-trip Fc at \(index)")
            if pair.1.type.usesGain {
                expectClose(pair.0.gainDB, pair.1.gainDB, tolerance: 0.01, "round-trip gain at \(index)")
            }
            if pair.1.type.usesQ {
                expectClose(pair.0.q, pair.1.q, tolerance: 0.01, "round-trip Q at \(index)")
            }
        }
    } catch {
        expect(false, "round-trip threw: \(error)")
    }
}

testPeakingCoefficientReferences()
testFilterTypeReferences()
testFilterTypeMagnitudeSanity()
testAPOParse()
testAPOParseErrors()
testAPORoundTrip()
testMagnitudeResponse()
testAutoPreamp()
testLogSpacedFrequencies()
// MARK: - Limiter

func testLimiterCatchesOvers() {
    let sampleRate = 48000.0
    let frameCount = 48000
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 1.0, gainDB: 0.0)]
    // +12 dB preamp on a 0.5-amplitude sine would peak at ~2.0 without a limiter.
    guard let kernel = EQKernel(
        sections: sectionsNumbered(cascade), preampDB: 12.0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: true
    ) else {
        expect(false, "kernel construction failed")
        return
    }
    var buffer = [Float](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let value = Float(sin(2.0 * Double.pi * 200.0 * Double(frame) / sampleRate)) * 0.5
        buffer[frame * 2] = value
        buffer[frame * 2 + 1] = value
    }
    buffer.withUnsafeMutableBufferPointer { pointer in
        kernel.process(interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: 2)
    }
    let maxSample = buffer.map { abs($0) }.max() ?? 0
    expect(maxSample <= 1.0, "limiter keeps output at or below full scale, got \(maxSample)")
    expect(maxSample > 0.9, "limiter should run near the ceiling, not crush the signal, got \(maxSample)")

    // Stereo linkage: both channels must receive identical gain reduction.
    var maxChannelDelta: Float = 0
    for frame in 0..<frameCount {
        maxChannelDelta = max(maxChannelDelta, abs(buffer[frame * 2] - buffer[frame * 2 + 1]))
    }
    expectClose(Double(maxChannelDelta), 0.0, tolerance: 1e-6, "stereo-linked limiter keeps channels identical")
}

func testLimiterTransparentBelowThreshold() {
    let sampleRate = 48000.0
    let frameCount = 48000
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 1.0, gainDB: 0.0)]
    guard let kernel = EQKernel(
        sections: sectionsNumbered(cascade), preampDB: 0.0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: true
    ) else {
        expect(false, "kernel construction failed")
        return
    }
    var buffer = [Float](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let value = Float(sin(2.0 * Double.pi * 200.0 * Double(frame) / sampleRate)) * 0.1
        buffer[frame * 2] = value
        buffer[frame * 2 + 1] = value
    }
    let inputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: 4800)
    buffer.withUnsafeMutableBufferPointer { pointer in
        kernel.process(interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: 2)
    }
    let outputRMS = channelRMS(buffer, channel: 0, channelCount: 2, skipFrames: 4800)
    expectClose(
        20 * log10(outputRMS / inputRMS), 0.0, tolerance: 0.05,
        "limiter is transparent for quiet signals"
    )
}

testKernelAppliesBandGainToSine()
testKernelLowBandsApplyGain()
testKernelPreampScales()
// MARK: - Spectrum analyzer

func testSpectrumAnalyzerFindsSine() {
    guard let analyzer = SpectrumAnalyzer(fftSize: 2048) else {
        expect(false, "analyzer construction failed")
        return
    }
    let sampleRate = 48000.0
    var samples = [Float](repeating: 0, count: 4096)
    for index in samples.indices {
        samples[index] = Float(sin(2.0 * Double.pi * 1000.0 * Double(index) / sampleRate))
    }
    let bands = logSpacedFrequencies(from: 20, to: 20000, count: 48)
    let spectrum = analyzer.bandMagnitudesDB(samples: samples, sampleRate: sampleRate, bandFrequencies: bands)
    expect(spectrum.count == bands.count, "one magnitude per band")

    guard let peakIndex = spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] }) else {
        expect(false, "no spectrum peak")
        return
    }
    let peakBandLow = bands[peakIndex]
    let peakBandHigh = peakIndex + 1 < bands.count ? bands[peakIndex + 1] : 24000
    expect(
        peakBandLow <= 1000 && 1000 <= peakBandHigh,
        "peak band [\(peakBandLow), \(peakBandHigh)] should contain 1 kHz"
    )
    expectClose(spectrum[peakIndex], 0.0, tolerance: 1.0, "full-scale sine reads ~0 dBFS")

    // Far away from the tone, the floor should be way down.
    expect(spectrum[5] < -60, "low bands near noise floor, got \(spectrum[5])")
    expect(spectrum[44] < -60, "high bands near noise floor, got \(spectrum[44])")
}

// MARK: - FIR convolver (uniform partitioned overlap-save)

/// Deterministic pseudo-random signal in [-1, 1] (LCG; tests must not flake).
func pseudoRandomSignal(count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Double(state >> 33) / Double(UInt32.max >> 1)) * 2 - 1
    }
}

/// O(N*L) time-domain reference convolution, accumulated in Double.
func directConvolution(input: [Float], impulseResponse: [Float]) -> [Float] {
    var output = [Float](repeating: 0, count: input.count)
    for n in input.indices {
        var sum = 0.0
        for k in 0...min(n, impulseResponse.count - 1) {
            sum += Double(impulseResponse[k]) * Double(input[n - k])
        }
        output[n] = Float(sum)
    }
    return output
}

/// Feeds an interleaved buffer through the convolver in uneven chunks, in place.
func convolveChunked(
    _ convolver: FIRConvolver, buffer: inout [Float], chunks: [Int], channelCount: Int
) {
    var offset = 0
    buffer.withUnsafeMutableBufferPointer { pointer in
        for chunk in chunks {
            convolver.process(
                interleaved: pointer.baseAddress! + offset * channelCount,
                frameCount: chunk,
                channelCount: channelCount
            )
            offset += chunk
        }
    }
}

func testConvolverDeltaIsDelayedIdentity() {
    let blockSize = 64
    guard let convolver = FIRConvolver(
        impulseResponse: [[1.0]], blockSize: blockSize, maxChannels: 1
    ) else {
        expect(false, "delta convolver construction failed")
        return
    }
    expect(convolver.latencyFrames == blockSize, "latency is one block")
    let original = (0..<400).map { Float($0 + 1) }
    var buffer = original
    convolveChunked(convolver, buffer: &buffer, chunks: [7, 64, 100, 129, 100], channelCount: 1)
    for index in 0..<blockSize {
        expectClose(Double(buffer[index]), 0, tolerance: 1e-3, "priming zeros at \(index)")
    }
    for index in blockSize..<400 {
        expectClose(
            Double(buffer[index]), Double(original[index - blockSize]),
            tolerance: 0.05, "delayed identity at \(index)"
        )
    }
}

func testConvolverMatchesDirectConvolution() {
    let blockSize = 64
    // IR longer than 3 partitions and not block-aligned, so the frequency-domain
    // delay line and zero-padding paths are all exercised.
    let impulseResponse = pseudoRandomSignal(count: 3 * blockSize + 7, seed: 12345)
    guard let convolver = FIRConvolver(
        impulseResponse: [impulseResponse], blockSize: blockSize, maxChannels: 1
    ) else {
        expect(false, "random-IR convolver construction failed")
        return
    }
    let input = pseudoRandomSignal(count: 1024, seed: 99)
    let expected = directConvolution(input: input, impulseResponse: impulseResponse)
    var buffer = input
    convolveChunked(convolver, buffer: &buffer, chunks: [1, 63, 64, 96, 300, 500], channelCount: 1)
    var maxError = 0.0
    for index in blockSize..<1024 {
        maxError = max(maxError, abs(Double(buffer[index]) - Double(expected[index - blockSize])))
    }
    expect(maxError < 5e-3, "partitioned convolution matches direct within 5e-3, max error \(maxError)")
}

func testConvolverStereoUsesPerChannelIR() {
    let blockSize = 64
    let extraDelay = 10
    var leftIR = [Float](repeating: 0, count: extraDelay + 1)
    leftIR[0] = 1
    var rightIR = [Float](repeating: 0, count: extraDelay + 1)
    rightIR[extraDelay] = 1
    guard let convolver = FIRConvolver(
        impulseResponse: [leftIR, rightIR], blockSize: blockSize, maxChannels: 2
    ) else {
        expect(false, "stereo convolver construction failed")
        return
    }
    let frames = 300
    let left = (0..<frames).map { Float($0 + 1) }
    let right = (0..<frames).map { Float(1000 - $0) }
    var buffer = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        buffer[frame * 2] = left[frame]
        buffer[frame * 2 + 1] = right[frame]
    }
    convolveChunked(convolver, buffer: &buffer, chunks: [128, 100, 72], channelCount: 2)
    for frame in blockSize..<frames {
        expectClose(
            Double(buffer[frame * 2]), Double(left[frame - blockSize]),
            tolerance: 0.05, "left channel delayed by block at \(frame)"
        )
    }
    for frame in (blockSize + extraDelay)..<frames {
        expectClose(
            Double(buffer[frame * 2 + 1]), Double(right[frame - blockSize - extraDelay]),
            tolerance: 0.05, "right channel delayed by block+IR at \(frame)"
        )
    }
}

func testConvolverRejectsInvalidConstruction() {
    expect(
        FIRConvolver(impulseResponse: [], blockSize: 64, maxChannels: 2) == nil,
        "empty IR rejected"
    )
    expect(
        FIRConvolver(impulseResponse: [[]], blockSize: 64, maxChannels: 2) == nil,
        "zero-length IR rejected"
    )
    expect(
        FIRConvolver(impulseResponse: [[1]], blockSize: 100, maxChannels: 2) == nil,
        "non-power-of-two block size rejected"
    )
    expect(
        FIRConvolver(impulseResponse: [[1], [1], [1]], blockSize: 64, maxChannels: 2) == nil,
        "IR channel count beyond maxChannels rejected"
    )
    expect(
        FIRConvolver(impulseResponse: [[1], [1, 0]], blockSize: 64, maxChannels: 2) == nil,
        "mismatched IR channel lengths rejected"
    )
}

// MARK: - Impulse response loading

func testImpulseResponseLoaderRoundTripAndResample() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("maceq-test-ir-\(ProcessInfo.processInfo.processIdentifier).wav")
    defer { try? FileManager.default.removeItem(at: url) }

    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false
    ), let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else {
        expect(false, "test WAV format construction failed")
        return
    }
    writeBuffer.frameLength = 480
    for index in 0..<480 {
        writeBuffer.floatChannelData![0][index] = Float(index) / 480
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: writeBuffer)
    } catch {
        expect(false, "test WAV write failed: \(error)")
        return
    }

    do {
        let sameRate = try loadImpulseResponse(url: url, sampleRate: 48000)
        expect(sameRate.count == 1, "mono file loads one channel")
        expect(sameRate[0].count == 480, "same-rate load keeps length, got \(sameRate[0].count)")
        expectClose(Double(sameRate[0][240]), 0.5, tolerance: 1e-4, "sample values survive round trip")

        let resampled = try loadImpulseResponse(url: url, sampleRate: 24000)
        expect(
            abs(resampled[0].count - 240) <= 32,
            "half-rate load halves length, got \(resampled[0].count)"
        )
    } catch {
        expect(false, "impulse response load failed: \(error)")
    }

    do {
        _ = try loadImpulseResponse(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("maceq-missing.wav"),
            sampleRate: 48000
        )
        expect(false, "missing file should throw")
    } catch {
        expect(true, "missing file throws")
    }
}

// MARK: - Graphic EQ band editing

func testGraphicBandDefaults() {
    expect(defaultGraphicBandFrequencies.count == 10, "10 default bands")
    expect(defaultGraphicBandFrequencies.first == 31.5, "first default band is 31.5 Hz")
    expect(defaultGraphicBandFrequencies.last == 16000, "last default band is 16 kHz")
    expect(
        defaultGraphicBandFrequencies == defaultGraphicBandFrequencies.sorted(),
        "default bands are sorted ascending"
    )
}

func testGraphicBandLabels() {
    expect(graphicBandLabel(frequency: 31.5) == "31", "31.5 -> 31, got \(graphicBandLabel(frequency: 31.5))")
    expect(graphicBandLabel(frequency: 63) == "63", "63 -> 63")
    expect(graphicBandLabel(frequency: 500) == "500", "500 -> 500")
    expect(graphicBandLabel(frequency: 1000) == "1k", "1000 -> 1k")
    expect(graphicBandLabel(frequency: 2500) == "2.5k", "2500 -> 2.5k, got \(graphicBandLabel(frequency: 2500))")
    expect(graphicBandLabel(frequency: 16000) == "16k", "16000 -> 16k")
}

func testGraphicBandInsertion() {
    do {
        let result = try insertGraphicBand(frequency: 750, into: defaultGraphicBandFrequencies)
        expect(result.frequencies.count == 11, "insertion grows list by one")
        expect(result.index == 5, "750 Hz lands between 500 and 1k, got index \(result.index)")
        expect(result.frequencies[result.index] == 750, "inserted frequency is at returned index")
        expect(
            result.frequencies == result.frequencies.sorted(),
            "list stays sorted after insertion"
        )
    } catch {
        expect(false, "valid insertion threw: \(error)")
    }

    do {
        _ = try insertGraphicBand(frequency: 10, into: defaultGraphicBandFrequencies)
        expect(false, "10 Hz is out of range and should throw")
    } catch {
        expect(true, "out-of-range frequency throws")
    }

    do {
        _ = try insertGraphicBand(frequency: 1010, into: defaultGraphicBandFrequencies)
        expect(false, "1010 Hz is within 5% of 1 kHz and should throw")
    } catch {
        expect(true, "near-duplicate frequency throws")
    }

    do {
        var frequencies = defaultGraphicBandFrequencies
        for f in [45.0, 90.0, 180.0, 350.0, 700.0, 1400.0] {
            frequencies = try insertGraphicBand(frequency: f, into: frequencies).frequencies
        }
        expect(frequencies.count == 16, "16 bands allowed")
        _ = try insertGraphicBand(frequency: 2800, into: frequencies)
        expect(false, "17th band should throw")
    } catch {
        expect(true, "band cap enforced")
    }
}

func testGraphicBandRemoval() {
    do {
        let result = try removeGraphicBand(at: 0, from: defaultGraphicBandFrequencies)
        expect(result.count == 9, "removal shrinks list by one")
        expect(result.first == 63, "removing index 0 leaves 63 first")
    } catch {
        expect(false, "valid removal threw: \(error)")
    }

    do {
        _ = try removeGraphicBand(at: 0, from: [1000])
        expect(false, "removing the last remaining band should throw")
    } catch {
        expect(true, "minimum of one band enforced")
    }

    do {
        _ = try removeGraphicBand(at: 42, from: defaultGraphicBandFrequencies)
        expect(false, "out-of-bounds index should throw")
    } catch {
        expect(true, "out-of-bounds removal throws")
    }
}

func testGraphicBandFrequencyUpdate() {
    // Editing in place, no reorder.
    do {
        let result = try updateGraphicBand(at: 0, to: 40, in: defaultGraphicBandFrequencies)
        expect(result.frequencies[0] == 40, "31.5 -> 40 in place")
        expect(result.index == 0, "no reorder keeps index 0, got \(result.index)")
        expect(result.frequencies.count == 10, "count unchanged")
    } catch {
        expect(false, "in-place edit threw: \(error)")
    }

    // Editing past neighbours must re-sort and report the new index.
    do {
        let result = try updateGraphicBand(at: 4, to: 3000, in: defaultGraphicBandFrequencies)
        expect(
            result.frequencies == result.frequencies.sorted(),
            "list stays sorted after a reordering edit"
        )
        expect(result.index == 6, "500 -> 3000 lands between 2k and 4k, got \(result.index)")
        expect(result.frequencies[result.index] == 3000, "moved band sits at reported index")
    } catch {
        expect(false, "reordering edit threw: \(error)")
    }

    // Setting a band to its own current value is a no-op, not a self-collision.
    do {
        let result = try updateGraphicBand(at: 3, to: 250, in: defaultGraphicBandFrequencies)
        expect(result.frequencies == defaultGraphicBandFrequencies, "same-value edit is a no-op")
        expect(result.index == 3, "same-value edit keeps index")
    } catch {
        expect(false, "same-value edit threw: \(error)")
    }

    do {
        _ = try updateGraphicBand(at: 0, to: 25000, in: defaultGraphicBandFrequencies)
        expect(false, "25 kHz is out of range and should throw")
    } catch {
        expect(true, "out-of-range edit throws")
    }

    do {
        _ = try updateGraphicBand(at: 0, to: 1020, in: defaultGraphicBandFrequencies)
        expect(false, "1020 Hz collides with the 1 kHz band and should throw")
    } catch {
        expect(true, "colliding edit throws")
    }

    do {
        _ = try updateGraphicBand(at: 99, to: 100, in: defaultGraphicBandFrequencies)
        expect(false, "out-of-bounds index should throw")
    } catch {
        expect(true, "out-of-bounds edit throws")
    }
}

// MARK: - Identity-section elimination

func testZeroGainPeakingIsExactlyIdentity() {
    // A 0 dB peaking/shelf section normalizes to b == a, i.e. H(z) = 1 exactly.
    // This is what makes dropping them from the cascade safe rather than lossy.
    for frequency in [31.5, 500.0, 1000.0, 16000.0] {
        let coefficients = peakingCoefficients(
            sampleRate: 48000, frequency: frequency, q: 2.2, gainDB: 0
        )
        expectClose(coefficients.b0, 1.0, tolerance: 1e-12, "b0 == 1 at \(frequency) Hz")
        expectClose(coefficients.b1, coefficients.a1, tolerance: 1e-12, "b1 == a1 at \(frequency) Hz")
        expectClose(coefficients.b2, coefficients.a2, tolerance: 1e-12, "b2 == a2 at \(frequency) Hz")
        expectClose(
            magnitudeDB(of: [coefficients], sampleRate: 48000, frequency: frequency),
            0.0, tolerance: 1e-9, "0 dB response at \(frequency) Hz"
        )
    }

    for type in [FilterType.lowShelf, .highShelf] {
        let spec = FilterSpec(type: type, isEnabled: true, frequency: 1000, gainDB: 0, q: 0.7)
        let coefficients = coefficients(for: spec, sampleRate: 48000)
        expectClose(coefficients.b0, 1.0, tolerance: 1e-12, "\(type) b0 == 1")
        expectClose(coefficients.b1, coefficients.a1, tolerance: 1e-12, "\(type) b1 == a1")
        expectClose(coefficients.b2, coefficients.a2, tolerance: 1e-12, "\(type) b2 == a2")
    }
}

func testIdentitySectionDetection() {
    expect(
        isIdentitySection(peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 2.2, gainDB: 0)),
        "0 dB peaking is identity"
    )
    expect(
        !isIdentitySection(peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 2.2, gainDB: 0.5)),
        "+0.5 dB peaking is not identity"
    )
    expect(
        !isIdentitySection(peakingCoefficients(sampleRate: 48000, frequency: 1000, q: 2.2, gainDB: -3)),
        "-3 dB peaking is not identity"
    )
    // A notch has no gain parameter but is emphatically not identity.
    expect(
        !isIdentitySection(
            coefficients(
                for: FilterSpec(type: .notch, isEnabled: true, frequency: 1000, gainDB: 0, q: 4),
                sampleRate: 48000
            )
        ),
        "a notch is not identity"
    )
}

func testKernelWithDroppedIdentitySectionsMatchesFullCascade() {
    // Dropping identity sections must be sample-for-sample equivalent, not merely close.
    let sampleRate = 48000.0
    let full = [
        peakingCoefficients(sampleRate: sampleRate, frequency: 125, q: 2.2, gainDB: 0),
        peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 2.2, gainDB: 6),
        peakingCoefficients(sampleRate: sampleRate, frequency: 8000, q: 2.2, gainDB: 0),
    ]
    let pruned = full.filter { !isIdentitySection($0) }
    expect(pruned.count == 1, "two identity sections dropped, got \(pruned.count)")

    guard let fullKernel = EQKernel(
            sections: sectionsNumbered(full), preampDB: 0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: false
        ),
        let prunedKernel = EQKernel(
            sections: sectionsNumbered(pruned), preampDB: 0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: false
        )
    else {
        expect(false, "kernel construction failed")
        return
    }

    var a = pseudoRandomSignal(count: 2048, seed: 99)
    var b = a
    a.withUnsafeMutableBufferPointer { buffer in
        fullKernel.process(interleaved: buffer.baseAddress!, frameCount: 1024, channelCount: 2)
    }
    b.withUnsafeMutableBufferPointer { buffer in
        prunedKernel.process(interleaved: buffer.baseAddress!, frameCount: 1024, channelCount: 2)
    }
    var maxDifference: Float = 0
    for index in a.indices {
        maxDifference = max(maxDifference, abs(a[index] - b[index]))
    }
    // Not bit-identical, and that is expected: the sections are exact identity
    // in real arithmetic (see testZeroGainPeakingIsExactlyIdentity), but vDSP
    // runs Float32, so each redundant section contributes rounding. The gap is
    // ~-83 dBFS on a full-scale signal — far below audibility.
    expect(
        maxDifference < 1e-4,
        "pruned cascade matches full cascade within Float32 rounding, max diff \(maxDifference)"
    )

    // And the pruning is not merely tolerable but strictly better: fewer
    // sections means less accumulated error, so the pruned output is closer to
    // a double-precision reference than the full cascade is.
    let reference = doublePrecisionBiquad(
        input: pseudoRandomSignal(count: 2048, seed: 99),
        section: full[1],
        channelCount: 2
    )
    var fullError = 0.0
    var prunedError = 0.0
    for index in reference.indices {
        fullError = max(fullError, abs(Double(a[index]) - reference[index]))
        prunedError = max(prunedError, abs(Double(b[index]) - reference[index]))
    }
    expect(
        prunedError <= fullError,
        "pruned cascade is at least as accurate: pruned \(prunedError) vs full \(fullError)"
    )
}

/// Direct Form I reference in Double, per channel — the ground truth the Float32
/// kernels are compared against.
func doublePrecisionBiquad(
    input: [Float], section: BiquadCoefficients, channelCount: Int
) -> [Double] {
    var output = [Double](repeating: 0, count: input.count)
    for channel in 0..<channelCount {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var index = channel
        while index < input.count {
            let x = Double(input[index])
            let y = section.b0 * x + section.b1 * x1 + section.b2 * x2
                - section.a1 * y1 - section.a2 * y2
            output[index] = y
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            index += channelCount
        }
    }
    return output
}

// MARK: - Denormal behaviour during silence

/// The mechanism behind steady idle CPU on Intel: a biquad's state decays
/// exponentially, so after audio stops the filter keeps producing ever-smaller
/// outputs that spend a long stretch in denormal range before reaching zero.
/// x86 handles denormal arithmetic with microcode assists that are orders of
/// magnitude slower than normal floating point; Apple silicon does not stall.
///
/// This test asserts the precondition (denormals really do occur), which holds
/// on every architecture, rather than the timing penalty, which does not.
func testBiquadStateReachesDenormalsDuringSilence() {
    let sampleRate = 48000.0
    let cascade = [peakingCoefficients(sampleRate: sampleRate, frequency: 125, q: 2.2, gainDB: 6)]
    guard let kernel = EQKernel(
        sections: sectionsNumbered(cascade), preampDB: 0, sampleRate: sampleRate,
        maxChannels: 2, limiterEnabled: false
    ) else {
        expect(false, "kernel construction failed")
        return
    }

    let frameCount = 512
    let channelCount = 2

    // Excite the filter, then feed pure silence and watch the tail decay.
    var burst = pseudoRandomSignal(count: frameCount * channelCount, seed: 7)
    burst.withUnsafeMutableBufferPointer { buffer in
        kernel.process(
            interleaved: buffer.baseAddress!, frameCount: frameCount, channelCount: channelCount
        )
    }

    var sawDenormal = false
    var silentBuffersUntilFullyZero = 0
    for buffer in 0..<4000 {
        var silence = [Float](repeating: 0, count: frameCount * channelCount)
        silence.withUnsafeMutableBufferPointer { pointer in
            kernel.process(
                interleaved: pointer.baseAddress!, frameCount: frameCount, channelCount: channelCount
            )
        }
        if silence.contains(where: { $0.isSubnormal }) {
            sawDenormal = true
        }
        if silence.contains(where: { $0 != 0 }) {
            silentBuffersUntilFullyZero = buffer + 1
        }
    }

    expect(sawDenormal, "the decaying tail passes through denormal values during silence")
    expect(
        silentBuffersUntilFullyZero > 0,
        "the tail takes \(silentBuffersUntilFullyZero) silent buffers to reach exact zero"
    )
}

testLimiterCatchesOvers()
testLimiterTransparentBelowThreshold()
testSpectrumAnalyzerFindsSine()
testConvolverDeltaIsDelayedIdentity()
testConvolverMatchesDirectConvolution()
testConvolverStereoUsesPerChannelIR()
testConvolverRejectsInvalidConstruction()
testImpulseResponseLoaderRoundTripAndResample()
testGraphicBandDefaults()
testGraphicBandLabels()
testGraphicBandInsertion()
testGraphicBandRemoval()
testGraphicBandFrequencyUpdate()
testZeroGainPeakingIsExactlyIdentity()
testIdentitySectionDetection()
testKernelWithDroppedIdentitySectionsMatchesFullCascade()
testBiquadStateReachesDenormalsDuringSilence()

// MARK: - Filters at or above Nyquist

/// Bluetooth headsets drop to 16/24 kHz while their mic is in use, which puts
/// the 16 kHz graphic band (and AutoEQ's 10 kHz shelves) at or above Nyquist.
/// There the RBJ formulas place a pole outside the unit circle, the output
/// grows without bound, and the audio turns to inf/NaN until the next rebuild.
/// Such a section must pass audio through instead.
func testFiltersAtOrAboveNyquistPassThroughStably() {
    for sampleRate in [16000.0, 22050.0, 24000.0, 32000.0] {
        let graphicBand = peakingCoefficients(sampleRate: sampleRate, frequency: 16000, q: 2.2, gainDB: 3)
        expect(
            isIdentitySection(graphicBand),
            "16 kHz graphic band at \(sampleRate) Hz should be identity, got \(graphicBand)"
        )
        for type in FilterType.allCases {
            let spec = FilterSpec(type: type, isEnabled: true, frequency: 16000, gainDB: 3, q: 0.7)
            let section = coefficients(for: spec, sampleRate: sampleRate)
            expect(
                isIdentitySection(section),
                "\(type.rawValue) at 16 kHz / \(sampleRate) Hz should be identity, got \(section)"
            )
        }

        guard let kernel = EQKernel(
            sections: sectionsNumbered([graphicBand]), preampDB: 0, sampleRate: sampleRate,
            maxChannels: 1, limiterEnabled: true
        ) else {
            expect(false, "kernel construction failed at \(sampleRate) Hz")
            continue
        }
        // Half scale, so the limiter never engages and any deviation is the filter's.
        let input = pseudoRandomSignal(count: Int(sampleRate), seed: 11).map { $0 * 0.5 }
        var output = input
        output.withUnsafeMutableBufferPointer { pointer in
            kernel.process(interleaved: pointer.baseAddress!, frameCount: pointer.count, channelCount: 1)
        }
        expect(output.allSatisfy(\.isFinite), "kernel output stays finite at \(sampleRate) Hz")
        let maxDeviation = zip(input, output).map { abs($0 - $1) }.max() ?? 0
        expect(
            maxDeviation < 1e-6,
            "above-Nyquist band passes audio through at \(sampleRate) Hz, deviation \(maxDeviation)"
        )
    }

    // Just below Nyquist the filter is still realizable and must stay active.
    let belowNyquist = peakingCoefficients(sampleRate: 24000, frequency: 11000, q: 2.2, gainDB: 3)
    expect(!isIdentitySection(belowNyquist), "11 kHz band at 24 kHz is still a real filter")
}

// MARK: - Spectrum analyzer below 40 kHz

/// The display bands run to 20 kHz. Below a 40 kHz sample rate the top bands
/// start above Nyquist, where there are no FFT bins at all.
func testSpectrumAnalyzerAtLowSampleRates() {
    guard let analyzer = SpectrumAnalyzer(fftSize: 2048) else {
        expect(false, "analyzer construction failed")
        return
    }
    let bands = logSpacedFrequencies(from: 20, to: 20000, count: 48)
    for sampleRate in [16000.0, 24000.0, 32000.0] {
        var samples = [Float](repeating: 0, count: 4096)
        for index in samples.indices {
            samples[index] = Float(sin(2.0 * Double.pi * 1000.0 * Double(index) / sampleRate))
        }
        let spectrum = analyzer.bandMagnitudesDB(samples: samples, sampleRate: sampleRate, bandFrequencies: bands)
        expect(spectrum.count == bands.count, "one magnitude per band at \(sampleRate) Hz")
        for (index, band) in bands.enumerated() where band >= sampleRate / 2 {
            expect(
                spectrum[index] == -100,
                "band \(band) Hz is above Nyquist at \(sampleRate) Hz and should read the floor, got \(spectrum[index])"
            )
        }
        guard let peakIndex = spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] }) else {
            expect(false, "no spectrum peak at \(sampleRate) Hz")
            continue
        }
        let peakBandHigh = peakIndex + 1 < bands.count ? bands[peakIndex + 1] : sampleRate / 2
        expect(
            bands[peakIndex] <= 1000 && 1000 <= peakBandHigh,
            "peak band [\(bands[peakIndex]), \(peakBandHigh)] should contain 1 kHz at \(sampleRate) Hz"
        )
    }
}

// MARK: - Engine recovery

func testEngineRestartDelayBacksOff() {
    let delays = (1...8).map { engineRestartDelay(afterConsecutiveFailures: $0) }
    expect(delays == [1, 2, 4, 8, 16, 30, 30, 30], "retry delays double from 1 s and cap at 30 s, got \(delays)")
    expect(
        engineRestartDelay(afterConsecutiveFailures: 10_000) == 30,
        "a device that stays broken for hours is still retried every 30 s"
    )
}

func testCallbackStallCounting() {
    expect(
        nextStalledTickCount(previousCallbackCount: nil, currentCallbackCount: 100, stalledTicks: 3) == 0,
        "no baseline yet (fresh start) is never a stall"
    )
    expect(
        nextStalledTickCount(previousCallbackCount: 100, currentCallbackCount: 100, stalledTicks: 0) == 1,
        "an unchanged callback count extends the streak"
    )
    expect(
        nextStalledTickCount(previousCallbackCount: 100, currentCallbackCount: 100, stalledTicks: 1) == 2,
        "the streak keeps growing while callbacks stay stopped"
    )
    expect(
        nextStalledTickCount(previousCallbackCount: 100, currentCallbackCount: 150, stalledTicks: 2) == 0,
        "any callback progress clears the streak"
    )
    expect(callbackStallTicksBeforeRestart == 2, "a stall needs two watchdog ticks (~4 s) without callbacks")
}

// MARK: - Kernel swaps (every slider tick builds a new kernel)

/// Sections numbered by position, for kernels that are never swapped.
func sectionsNumbered(_ cascade: [BiquadCoefficients]) -> [KernelSection] {
    cascade.enumerated().map { KernelSection(id: $0.offset, coefficients: $0.element) }
}

func processContinuously(_ input: [Float], kernel: EQKernel, channelCount: Int) -> [Float] {
    var output = input
    output.withUnsafeMutableBufferPointer { buffer in
        kernel.process(interleaved: buffer.baseAddress!, frameCount: buffer.count / channelCount, channelCount: channelCount)
    }
    return output
}

/// Runs `first` over the first half of `input`, then `second` over the rest
/// after adopting `first`'s state: what the audio thread does when a slider
/// tick swaps kernels mid-stream.
func processWithSwap(_ input: [Float], first: EQKernel, second: EQKernel, channelCount: Int) -> [Float] {
    var output = input
    let frameCount = input.count / channelCount
    let splitFrame = frameCount / 2
    output.withUnsafeMutableBufferPointer { buffer in
        first.process(interleaved: buffer.baseAddress!, frameCount: splitFrame, channelCount: channelCount)
        second.adoptState(from: first)
        second.process(
            interleaved: buffer.baseAddress! + splitFrame * channelCount,
            frameCount: frameCount - splitFrame,
            channelCount: channelCount
        )
    }
    return output
}

func maxAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).map { abs($0 - $1) }.max() ?? 0
}

/// A fresh kernel starts its filters and limiter from silence; swapped in
/// mid-song that is an audible click. Carrying state over must make a swap to
/// identical filters indistinguishable from never swapping at all, limiter
/// included.
func testKernelSwapWithSameFiltersIsSeamless() {
    let sampleRate = 48000.0
    let sections = [
        KernelSection(id: 0, coefficients: peakingCoefficients(sampleRate: sampleRate, frequency: 63, q: 2.2, gainDB: 9)),
        KernelSection(id: 1, coefficients: peakingCoefficients(sampleRate: sampleRate, frequency: 1000, q: 2.2, gainDB: -4)),
    ]
    // +6 dB preamp on a full-scale signal keeps the limiter busy at the swap.
    func makeKernel() -> EQKernel? {
        EQKernel(sections: sections, preampDB: 6, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: true)
    }
    guard let reference = makeKernel(), let first = makeKernel(), let second = makeKernel() else {
        expect(false, "kernel construction failed")
        return
    }
    let input = pseudoRandomSignal(count: 9600 * 2, seed: 5)
    let expected = processContinuously(input, kernel: reference, channelCount: 2)
    let swapped = processWithSwap(input, first: first, second: second, channelCount: 2)
    let difference = maxAbsoluteDifference(expected, swapped)
    expect(difference < 1e-6, "swap to identical filters is seamless, max deviation \(difference)")
}

/// A band at 0 dB is pruned from the cascade, so dragging a slider across 0 dB
/// adds or removes a section, and the other sections shift position. Carrying
/// state by section id (not position) must make both directions seamless.
func testKernelSwapAcrossPrunedSectionIsSeamless() {
    let sampleRate = 48000.0
    let low = KernelSection(id: 0, coefficients: peakingCoefficients(sampleRate: sampleRate, frequency: 125, q: 2.2, gainDB: 6))
    let passthrough = KernelSection(id: 1, coefficients: identityCoefficients)
    let high = KernelSection(id: 2, coefficients: peakingCoefficients(sampleRate: sampleRate, frequency: 4000, q: 2.2, gainDB: -3))
    let pruned = [low, high]
    let full = [low, passthrough, high]
    let input = pseudoRandomSignal(count: 9600 * 2, seed: 8).map { $0 * 0.5 }
    for (firstSections, secondSections, label) in [(pruned, full, "band leaving 0 dB"), (full, pruned, "band reaching 0 dB")] {
        func makeKernel(_ sections: [KernelSection]) -> EQKernel? {
            EQKernel(sections: sections, preampDB: 0, sampleRate: sampleRate, maxChannels: 2, limiterEnabled: false)
        }
        guard let reference = makeKernel(firstSections),
              let first = makeKernel(firstSections),
              let second = makeKernel(secondSections)
        else {
            expect(false, "kernel construction failed (\(label))")
            continue
        }
        let expected = processContinuously(input, kernel: reference, channelCount: 2)
        let swapped = processWithSwap(input, first: first, second: second, channelCount: 2)
        let difference = maxAbsoluteDifference(expected, swapped)
        expect(difference < 1e-6, "\(label): swap is seamless, max deviation \(difference)")
    }
}

/// With Auto preamp on, every slider tick can change the preamp too. A gain
/// step multiplies the waveform instantly, which ticks on loud material, so
/// the first buffer after a swap ramps from the old gain to the new one.
func testKernelSwapRampsPreampChange() {
    let sections = [KernelSection(id: 0, coefficients: identityCoefficients)]
    let halfGainDB = 20 * log10(0.5)
    guard let first = EQKernel(sections: sections, preampDB: 0, sampleRate: 48000, maxChannels: 2, limiterEnabled: false),
          let second = EQKernel(sections: sections, preampDB: halfGainDB, sampleRate: 48000, maxChannels: 2, limiterEnabled: false)
    else {
        expect(false, "kernel construction failed")
        return
    }
    let frameCount = 512
    var before = [Float](repeating: 0.5, count: frameCount * 2)
    var during = before
    var after = before
    before.withUnsafeMutableBufferPointer {
        first.process(interleaved: $0.baseAddress!, frameCount: frameCount, channelCount: 2)
    }
    second.adoptState(from: first)
    during.withUnsafeMutableBufferPointer {
        second.process(interleaved: $0.baseAddress!, frameCount: frameCount, channelCount: 2)
    }
    after.withUnsafeMutableBufferPointer {
        second.process(interleaved: $0.baseAddress!, frameCount: frameCount, channelCount: 2)
    }
    expect(during[0] > 0.49, "first sample after the swap is still at the old level, not a step: \(during[0])")
    var isMonotonic = true
    for frame in 1..<frameCount where during[frame * 2] > during[(frame - 1) * 2] {
        isMonotonic = false
    }
    expect(isMonotonic, "the ramp only moves toward the new gain")
    expectClose(Double(during[(frameCount - 1) * 2]), 0.25, tolerance: 0.002, "ramp arrives at the new gain")
    expect(
        (0..<frameCount).allSatisfy { during[$0 * 2] == during[$0 * 2 + 1] },
        "both channels ramp together"
    )
    expect(after.allSatisfy { abs($0 - 0.25) < 1e-4 }, "after the ramp the new gain holds steady")
}

// MARK: - Tap routing (which input buffer is the tap, where L/R go)

func expectRouteThrows(_ label: String, _ plan: () throws -> TapRoute) {
    do {
        let route = try plan()
        expect(false, "\(label): expected an error, got \(route)")
    } catch is TapRouteError {
        // expected
    } catch {
        expect(false, "\(label): expected TapRouteError, got \(error)")
    }
}

func testTapRoutePlanning() {
    do {
        // Built-in speakers / AirPods: no inputs of their own, one stereo stream.
        let speakers = try planTapRoute(
            aggregateInputChannels: [2], deviceInputChannels: [], tapChannelCount: 2,
            outputChannels: [2], preferredStereoChannels: (1, 2)
        )
        expect(speakers == TapRoute(
            tapBufferIndex: 0,
            output: .stereo(
                left: ChannelLocation(buffer: 0, channel: 0, channelsInBuffer: 2),
                right: ChannelLocation(buffer: 0, channel: 1, channelsInBuffer: 2)
            )
        ), "speakers: tap is buffer 0, L/R are channels 1-2, got \(speakers)")

        // USB headset: the device's own mic stream comes first; the tap follows it.
        let headset = try planTapRoute(
            aggregateInputChannels: [1, 2], deviceInputChannels: [1], tapChannelCount: 2,
            outputChannels: [2], preferredStereoChannels: (1, 2)
        )
        expect(headset.tapBufferIndex == 1, "headset: tap comes after the mic stream, got \(headset.tapBufferIndex)")

        // 4-out interface, speakers set to channels 3-4 in Audio MIDI Setup.
        let interface = try planTapRoute(
            aggregateInputChannels: [4, 2], deviceInputChannels: [4], tapChannelCount: 2,
            outputChannels: [4], preferredStereoChannels: (3, 4)
        )
        expect(interface == TapRoute(
            tapBufferIndex: 1,
            output: .stereo(
                left: ChannelLocation(buffer: 0, channel: 2, channelsInBuffer: 4),
                right: ChannelLocation(buffer: 0, channel: 3, channelsInBuffer: 4)
            )
        ), "interface: L/R land on the preferred channels 3-4, got \(interface)")

        // One buffer per channel (non-interleaved device).
        let perChannel = try planTapRoute(
            aggregateInputChannels: [2], deviceInputChannels: [], tapChannelCount: 2,
            outputChannels: [1, 1, 1, 1], preferredStereoChannels: (1, 2)
        )
        expect(perChannel.output == .stereo(
            left: ChannelLocation(buffer: 0, channel: 0, channelsInBuffer: 1),
            right: ChannelLocation(buffer: 1, channel: 0, channelsInBuffer: 1)
        ), "per-channel buffers: L/R are buffers 0 and 1, got \(perChannel.output)")

        let mono = try planTapRoute(
            aggregateInputChannels: [2], deviceInputChannels: [], tapChannelCount: 2,
            outputChannels: [1], preferredStereoChannels: (1, 2)
        )
        expect(
            mono.output == .mono(ChannelLocation(buffer: 0, channel: 0, channelsInBuffer: 1)),
            "a single-channel output gets a mono downmix, got \(mono.output)"
        )

        let unset = try planTapRoute(
            aggregateInputChannels: [2], deviceInputChannels: [], tapChannelCount: 2,
            outputChannels: [4], preferredStereoChannels: (7, 8)
        )
        expect(unset.output == .stereo(
            left: ChannelLocation(buffer: 0, channel: 0, channelsInBuffer: 4),
            right: ChannelLocation(buffer: 0, channel: 1, channelsInBuffer: 4)
        ), "preferred channels beyond the device fall back to 1-2, got \(unset.output)")
    } catch {
        expect(false, "route planning threw: \(error)")
    }

    expectRouteThrows("input buffers don't add up to device inputs + tap") {
        try planTapRoute(
            aggregateInputChannels: [2], deviceInputChannels: [2], tapChannelCount: 2,
            outputChannels: [2], preferredStereoChannels: (1, 2)
        )
    }
    expectRouteThrows("tap buffer has the wrong channel count") {
        try planTapRoute(
            aggregateInputChannels: [1, 1], deviceInputChannels: [1], tapChannelCount: 2,
            outputChannels: [2], preferredStereoChannels: (1, 2)
        )
    }
    expectRouteThrows("device inputs don't match the aggregate's leading buffers") {
        try planTapRoute(
            aggregateInputChannels: [1, 2], deviceInputChannels: [2], tapChannelCount: 2,
            outputChannels: [2], preferredStereoChannels: (1, 2)
        )
    }
    expectRouteThrows("no output channels") {
        try planTapRoute(
            aggregateInputChannels: [2], deviceInputChannels: [], tapChannelCount: 2,
            outputChannels: [], preferredStereoChannels: (1, 2)
        )
    }
}

/// An AudioBufferList with the given channels per buffer, zero-filled.
func makeBufferList(channelsPerBuffer: [Int], frameCount: Int) -> UnsafeMutableAudioBufferListPointer {
    let list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
    for (index, channels) in channelsPerBuffer.enumerated() {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * frameCount)
        samples.initialize(repeating: 0, count: channels * frameCount)
        list[index] = AudioBuffer(
            mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(channels * frameCount * MemoryLayout<Float>.size),
            mData: samples
        )
    }
    return list
}

func freeBufferList(_ list: UnsafeMutableAudioBufferListPointer) {
    for buffer in list {
        buffer.mData?.deallocate()
    }
    free(list.unsafeMutablePointer)
}

func bufferSamples(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> [Float] {
    let buffer = list[index]
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: count))
}

func testStereoScatter() {
    // Interleaved stereo source: L = 1 2 3 4, R = 10 20 30 40.
    let stereo: [Float] = [1, 10, 2, 20, 3, 30, 4, 40]

    // 4-channel interleaved device, L/R on channels 3-4; 1-2 must stay silent.
    let interleaved = makeBufferList(channelsPerBuffer: [4], frameCount: 4)
    scatterStereo(
        stereo, frameCount: 4, atFrame: 0,
        to: .stereo(
            left: ChannelLocation(buffer: 0, channel: 2, channelsInBuffer: 4),
            right: ChannelLocation(buffer: 0, channel: 3, channelsInBuffer: 4)
        ),
        in: interleaved
    )
    expect(
        bufferSamples(interleaved, 0) == [0, 0, 1, 10, 0, 0, 2, 20, 0, 0, 3, 30, 0, 0, 4, 40],
        "L/R written to channels 3-4 only, got \(bufferSamples(interleaved, 0))"
    )
    freeBufferList(interleaved)

    // One buffer per channel, written in two chunks (the IOProc processes in
    // scratch-sized chunks, so atFrame must offset correctly).
    let perChannel = makeBufferList(channelsPerBuffer: [1, 1, 1], frameCount: 4)
    let route = TapOutput.stereo(
        left: ChannelLocation(buffer: 0, channel: 0, channelsInBuffer: 1),
        right: ChannelLocation(buffer: 1, channel: 0, channelsInBuffer: 1)
    )
    scatterStereo(Array(stereo[0..<4]), frameCount: 2, atFrame: 0, to: route, in: perChannel)
    scatterStereo(Array(stereo[4..<8]), frameCount: 2, atFrame: 2, to: route, in: perChannel)
    expect(bufferSamples(perChannel, 0) == [1, 2, 3, 4], "left buffer, got \(bufferSamples(perChannel, 0))")
    expect(bufferSamples(perChannel, 1) == [10, 20, 30, 40], "right buffer, got \(bufferSamples(perChannel, 1))")
    expect(bufferSamples(perChannel, 2) == [0, 0, 0, 0], "unused channel stays silent")
    freeBufferList(perChannel)

    // Mono: averaged, so correlated material doesn't gain 6 dB.
    let mono = makeBufferList(channelsPerBuffer: [1], frameCount: 4)
    scatterStereo(
        stereo, frameCount: 4, atFrame: 0,
        to: .mono(ChannelLocation(buffer: 0, channel: 0, channelsInBuffer: 1)),
        in: mono
    )
    expect(bufferSamples(mono, 0) == [5.5, 11, 16.5, 22], "mono is (L+R)/2, got \(bufferSamples(mono, 0))")
    freeBufferList(mono)

    // A buffer laid out differently than planned (device reconfigured) must
    // not be written at the planned stride: silence, not scrambled audio. Eight
    // stereo frames hold as many samples as four 4-channel frames, so only the
    // channel-count check (not the size check) can catch this.
    let changed = makeBufferList(channelsPerBuffer: [2], frameCount: 8)
    scatterStereo(
        stereo, frameCount: 4, atFrame: 0,
        to: .stereo(
            left: ChannelLocation(buffer: 0, channel: 2, channelsInBuffer: 4),
            right: ChannelLocation(buffer: 0, channel: 3, channelsInBuffer: 4)
        ),
        in: changed
    )
    expect(bufferSamples(changed, 0).allSatisfy { $0 == 0 }, "mismatched layout stays silent, got \(bufferSamples(changed, 0))")
    freeBufferList(changed)
}

// MARK: - Invalid parametric values

/// Q = 0 divides by zero and a negative Q or Fc puts a pole outside the unit
/// circle: either way the audio turns to NaN. The band table and pasted
/// config text can both produce these, so they are refused at the door.
func testFilterValidation() {
    func spec(frequency: Double, gainDB: Double, q: Double) -> FilterSpec {
        FilterSpec(type: .peaking, isEnabled: true, frequency: frequency, gainDB: gainDB, q: q)
    }
    func expectInvalid(_ filter: FilterSpec, _ label: String) {
        do {
            try validateFilter(filter)
            expect(false, "\(label) should be rejected")
        } catch is FilterSpecError {
            // expected
        } catch {
            expect(false, "\(label): expected FilterSpecError, got \(error)")
        }
    }
    do {
        try validateFilter(spec(frequency: 1000, gainDB: -4, q: 0.7))
        try validateFilter(spec(frequency: 20, gainDB: 12, q: 0.1))
        try validateFilter(spec(frequency: 16000, gainDB: 0, q: 20))
    } catch {
        expect(false, "valid filters rejected: \(error)")
    }
    expectInvalid(spec(frequency: 0, gainDB: 0, q: 1), "Fc 0")
    expectInvalid(spec(frequency: -100, gainDB: 0, q: 1), "negative Fc")
    expectInvalid(spec(frequency: .nan, gainDB: 0, q: 1), "NaN Fc")
    expectInvalid(spec(frequency: .infinity, gainDB: 0, q: 1), "infinite Fc")
    expectInvalid(spec(frequency: 1000, gainDB: 0, q: 0), "Q 0")
    expectInvalid(spec(frequency: 1000, gainDB: 0, q: -1), "negative Q")
    expectInvalid(spec(frequency: 1000, gainDB: 0, q: .nan), "NaN Q")
    expectInvalid(spec(frequency: 1000, gainDB: 0, q: .infinity), "infinite Q")
    expectInvalid(spec(frequency: 1000, gainDB: .nan, q: 1), "NaN gain")
    expectInvalid(spec(frequency: 1000, gainDB: -.infinity, q: 1), "infinite gain")
}

/// The guarantee validation exists to give: anything it accepts produces
/// finite coefficients, for every filter type, including extreme but legal
/// values. (Fc at or above Nyquist is legal; it becomes identity.)
func testValidatedFiltersHaveFiniteCoefficients() {
    for type in FilterType.allCases {
        for frequency in [0.5, 20, 1000, 23999, 30000] {
            for q in [0.001, 0.7, 100] {
                for gainDB in [-60.0, 0, 60] {
                    let filter = FilterSpec(type: type, isEnabled: true, frequency: frequency, gainDB: gainDB, q: q)
                    guard (try? validateFilter(filter)) != nil else {
                        expect(false, "\(filter) should be valid")
                        continue
                    }
                    let c = coefficients(for: filter, sampleRate: 48000)
                    expect(
                        [c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite),
                        "\(type.rawValue) Fc \(frequency) Q \(q) gain \(gainDB) gives finite coefficients, got \(c)"
                    )
                }
            }
        }
    }
}

func testAPOParseRejectsInvalidValues() {
    let cases: [(text: String, line: Int, label: String)] = [
        ("Filter 1: ON PK Fc 0 Hz Gain 3 dB Q 1", 1, "Fc 0"),
        ("Filter 1: ON PK Fc -50 Hz Gain 3 dB Q 1", 1, "negative Fc"),
        ("Filter 1: ON PK Fc inf Hz Gain 3 dB Q 1", 1, "infinite Fc"),
        ("Filter 1: ON PK Fc 100 Hz Gain 3 dB Q 0", 1, "Q 0"),
        ("Filter 1: ON PK Fc 100 Hz Gain 3 dB Q -2", 1, "negative Q"),
        ("Filter 1: ON PK Fc 100 Hz Gain nan dB Q 1", 1, "NaN gain"),
        ("Filter 1: ON PK Fc 100 Hz Gain 3 dB BW Oct 0", 1, "zero bandwidth"),
        ("Preamp: nan dB", 1, "NaN preamp"),
        ("Preamp: -3 dB\nFilter 1: ON PK Fc 100 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc 200 Hz Gain 3 dB Q 0", 3, "bad filter on line 3"),
    ]
    for (text, line, label) in cases {
        do {
            let preset = try parseAPOConfig(text)
            expect(false, "\(label): should be rejected, parsed \(preset)")
        } catch let error as APOParseError {
            expect(error.line == line, "\(label): error names line \(line), got \(error.line) (\(error))")
        } catch {
            expect(false, "\(label): expected APOParseError, got \(error)")
        }
    }
}

testFilterValidation()
testValidatedFiltersHaveFiniteCoefficients()
testAPOParseRejectsInvalidValues()
testTapRoutePlanning()
testStereoScatter()
testFiltersAtOrAboveNyquistPassThroughStably()
testSpectrumAnalyzerAtLowSampleRates()
testEngineRestartDelayBacksOff()
testCallbackStallCounting()
testKernelSwapWithSameFiltersIsSeamless()
testKernelSwapAcrossPrunedSectionIsSeamless()
testKernelSwapRampsPreampChange()

if failureCount > 0 {
    print("\(failureCount) of \(expectationCount) expectations FAILED")
    exit(1)
}
print("All \(expectationCount) expectations passed")
