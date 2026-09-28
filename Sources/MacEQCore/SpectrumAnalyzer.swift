import Accelerate
import Foundation

/// Real-input FFT analyzer for the live spectrum display: Hann window, vDSP DFT,
/// magnitudes calibrated so a full-scale sine reads 0 dBFS, peak-picked onto an
/// arbitrary (log-spaced) display band grid.
///
/// Not real-time safe (allocates at init); call from the UI/main thread.
/// Wraps a vDSP DFT setup (external resource), hence a class.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private var windowed: [Float]
    private var realInput: [Float]
    private var imagInput: [Float]
    private var realOutput: [Float]
    private var imagOutput: [Float]
    private var magnitudes: [Float]

    /// - Parameter fftSize: power of two, e.g. 2048 (~23 Hz resolution at 48 kHz).
    public init?(fftSize: Int) {
        guard fftSize > 0, (fftSize & (fftSize - 1)) == 0 else { return nil }
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            return nil
        }
        self.fftSize = fftSize
        self.setup = setup
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        self.window = hann
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realInput = [Float](repeating: 0, count: fftSize / 2)
        self.imagInput = [Float](repeating: 0, count: fftSize / 2)
        self.realOutput = [Float](repeating: 0, count: fftSize / 2)
        self.imagOutput = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    /// dBFS per display band: for each band, the loudest FFT bin between it and
    /// the next band (peak-pick reads better than averaging for music).
    /// - Parameters:
    ///   - samples: at least `fftSize` mono samples; the last `fftSize` are used.
    ///   - sampleRate: rate the samples were captured at.
    ///   - bandFrequencies: ascending display-band center frequencies.
    /// - Returns: dBFS value per band, floored at -100.
    public func bandMagnitudesDB(samples: [Float], sampleRate: Double, bandFrequencies: [Double]) -> [Double] {
        let floorDB = -100.0
        guard samples.count >= fftSize, !bandFrequencies.isEmpty else {
            return Array(repeating: floorDB, count: bandFrequencies.count)
        }

        let offset = samples.count - fftSize
        samples.withUnsafeBufferPointer { pointer in
            vDSP_vmul(pointer.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        }
        // Pack real signal into split-complex (even -> real, odd -> imag) for zrop.
        // The split-complex pointers must stay valid for the whole vDSP call, so
        // they come from scoped buffer pointers rather than inout-to-pointer
        // conversions (which are only valid during the DSPSplitComplex init).
        let halfLength = vDSP_Length(fftSize / 2)
        realInput.withUnsafeMutableBufferPointer { real in
            imagInput.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, halfLength)
                    }
                }
            }
        }
        vDSP_DFT_Execute(setup, realInput, imagInput, &realOutput, &imagOutput)
        realOutput.withUnsafeMutableBufferPointer { real in
            imagOutput.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, halfLength)
            }
        }

        // Calibration: sine of amplitude A at bin k gives |X_k| = A * N/2 * CG * 2
        // (zrop scales by 2), with Hann coherent gain CG = 0.5 -> |X_k| = A * N/2.
        // amplitude = 2 * sqrt(|X_k|^2) / N.
        let amplitudeScale = 2.0 / Double(fftSize)
        let binWidth = sampleRate / Double(fftSize)
        let binCount = fftSize / 2

        return bandFrequencies.indices.map { bandIndex in
            let bandLow = bandFrequencies[bandIndex]
            let bandHigh = bandIndex + 1 < bandFrequencies.count
                ? bandFrequencies[bandIndex + 1]
                : sampleRate / 2
            let firstBin = max(Int(bandLow / binWidth), 1)
            // A band starting at or above Nyquist has no bins at all. The
            // display bands run to 20 kHz, so this is every sample rate below
            // 40 kHz, e.g. Bluetooth headsets at 16/24 kHz during calls.
            guard firstBin < binCount else { return floorDB }
            let lastBin = min(max(Int(bandHigh / binWidth), firstBin), binCount - 1)
            var peak: Float = 0
            for bin in firstBin...lastBin where magnitudes[bin] > peak {
                peak = magnitudes[bin]
            }
            let amplitude = amplitudeScale * Double(peak).squareRoot()
            return amplitude > 0 ? max(20.0 * log10(amplitude), floorDB) : floorDB
        }
    }
}
