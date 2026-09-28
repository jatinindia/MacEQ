import Accelerate
import CoreAudio
import Foundation
import MacEQCore

// Denormal control lives in fenv.h. Guarded because the module name is an SDK
// detail: if it ever goes away the app still builds, just without the
// optimisation below.
#if canImport(fenv_h)
import fenv_h
#endif

/// Puts the calling thread into flush-to-zero / denormals-are-zero mode.
///
/// A biquad's state decays exponentially, so once audio stops the filters keep
/// producing ever smaller outputs — and they get stuck in denormal range rather
/// than reaching zero (measured: denormals appear 0.6 s into silence and are
/// still there minutes later). x86 evaluates denormal arithmetic through
/// microcode assists that are orders of magnitude slower than normal floating
/// point, so on Intel Macs this reads as steady idle CPU; Apple silicon handles
/// denormals in hardware and shows nothing.
///
/// Deliberately scoped to the audio thread. Apple's fenv.h warns that the math
/// and system libraries may return wrong results for edge cases in this mode,
/// so it must not leak into the rest of the app — and since it is per-thread
/// state and a dispatch queue does not promise the same thread every time, the
/// IOProc sets it on each callback. The cost is a control-register write.
private func disableDenormalsOnCurrentThread() {
    #if canImport(fenv_h)
    #if arch(x86_64)
    var environment = _FE_DFL_DISABLE_SSE_DENORMS_ENV
    #else
    var environment = _FE_DFL_DISABLE_DENORMS_ENV
    #endif
    _ = withUnsafePointer(to: &environment) { fesetenv($0) }
    #endif
}

/// Hands the current EQ kernel to the audio thread. The IOProc does a single
/// reference load per callback; `nil` means bypass (pure passthrough). The owner
/// must keep recently replaced kernels alive briefly (retire list) so the audio
/// thread's release can never be the final one.
final class KernelHolder {
    var kernel: EQKernel?
    /// Audio thread only (while IO runs): the kernel the last callback ran, so
    /// a newly swapped-in kernel can continue from its state (EQKernel.adoptState)
    /// instead of restarting its filters from silence. Cleared by the engine
    /// once IO has stopped.
    var lastProcessedKernel: EQKernel?
}

/// Hands the active FIR convolver to the audio thread; nil means no convolution.
/// Same lifetime rules as KernelHolder: the owner retires replaced convolvers so
/// the audio thread's reference release is never the final one.
final class ConvolverHolder {
    var convolver: FIRConvolver?
}

/// Single-writer ring of post-EQ mono samples for the spectrum display.
/// The audio thread writes, the UI thread snapshots; occasional torn reads are
/// harmless for visualization, so no synchronization is used.
final class CaptureRing {
    static let capacity = 8192  // power of two
    /// UI writes, audio thread reads (word-sized store, same rationale as
    /// IOStats): capture costs a per-sample loop, so it runs only while a
    /// spectrum view is actually visible.
    var captureEnabled = false
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: CaptureRing.capacity)
    private var writeIndex = 0

    init() {
        samples.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        samples.deallocate()
    }

    /// Averages interleaved channels to mono into the ring. Real-time safe.
    func write(interleaved data: UnsafePointer<Float>, frameCount: Int, channelCount: Int) {
        guard channelCount > 0 else { return }
        let scale = 1.0 / Float(channelCount)
        var index = writeIndex
        for frame in 0..<frameCount {
            var sum: Float = 0
            let base = frame * channelCount
            for channel in 0..<channelCount {
                sum += data[base + channel]
            }
            samples[index] = sum * scale
            index = (index + 1) & (Self.capacity - 1)
        }
        writeIndex = index
    }

    /// The most recent `count` samples in chronological order (UI thread).
    func latest(_ count: Int) -> [Float] {
        let clamped = min(count, Self.capacity)
        var result = [Float](repeating: 0, count: clamped)
        let end = writeIndex
        for offset in 0..<clamped {
            result[clamped - 1 - offset] = samples[(end - 1 - offset + Self.capacity) & (Self.capacity - 1)]
        }
        return result
    }
}

/// Stats written by the real-time IO thread and polled by the UI.
///
/// Real-time safety note: the IO thread does plain word-sized stores into these
/// fields and the UI timer reads them. On arm64 aligned 64-bit loads/stores do
/// not tear, and stale-by-one-callback values are harmless for a status display,
/// so no locking is used (locks are forbidden on the audio thread).
final class IOStats {
    var callbackCount: UInt64 = 0
    var framesProcessed: UInt64 = 0
    var lastPeakBits: UInt32 = 0
    var lastRMSBits: UInt32 = 0
    var consecutiveZeroBuffers: UInt64 = 0

    var lastPeak: Float { Float(bitPattern: lastPeakBits) }
    var lastRMS: Float { Float(bitPattern: lastRMSBits) }
}

/// Snapshot of the running audio path, for display and per-device profiles.
struct EngineStatus {
    let outputDeviceName: String
    let outputDeviceUID: String
    let sampleRate: Double
    let tapFormatDescription: String
    let bufferFrameSize: UInt32
    /// 1 for plain devices; the sub-device count for multi-output devices, where
    /// the tap attenuates the mix by that factor and the IOProc restores it.
    let tapCompensationGain: Float
}

/// Milestone 0 engine: muted global process tap + private aggregate device with a
/// straight passthrough IOProc. No DSP yet — the goal is to prove the audio path.
///
/// Interfaces Core Audio (external system), hence a class managing lifecycle state.
final class AudioTapEngine {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.jatingrewal.maceq.io", qos: .userInteractive)

    let stats = IOStats()
    let kernelHolder = KernelHolder()
    let convolverHolder = ConvolverHolder()
    let captureRing = CaptureRing()
    private(set) var status: EngineStatus?

    /// Called on the main queue when the system default output device changes.
    var onDefaultOutputDeviceChanged: (() -> Void)?
    /// Called on the main queue when Core Audio's process list changes (an app
    /// started/stopped doing audio). Owners re-check the exclude list on this.
    var onProcessListChanged: (() -> Void)?
    /// Called on the main queue when the active output device renegotiates its
    /// nominal sample rate while running (e.g. 44.1 <-> 48 kHz on Bluetooth).
    /// Filter coefficients are rate-dependent, so owners must restart on this.
    /// Fires only when the new rate actually differs from the rate at start.
    var onSampleRateChanged: (() -> Void)?
    /// Core Audio process objects to exclude from the tap (beyond our own process,
    /// always excluded). Set before start(). Owners resolve these from the exclude
    /// list and rebuild on onProcessListChanged when the set changes.
    var excludedProcessObjects: [AudioObjectID] = []
    /// IO buffer size to request on the aggregate at start; 0 keeps the device default.
    /// Smaller = lower latency, higher CPU wake rate.
    var preferredBufferFrames: UInt32 = 0
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)

    var isRunning: Bool { ioProcID != nil }

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultOutputDeviceChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            deviceListenerBlock = block
        } else {
            // Non-fatal: EQ still works, it just won't follow device switches.
            print("warning: default-output listener failed with OSStatus \(status)")
        }

        var processAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let processBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onProcessListChanged?()
        }
        let processStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &processAddress,
            DispatchQueue.main,
            processBlock
        )
        if processStatus == noErr {
            processListenerBlock = processBlock
        } else {
            // Non-fatal: exclude list won't self-heal when excluded apps launch.
            print("warning: process-list listener failed with OSStatus \(processStatus)")
        }
    }

    /// Builds the full path: tap -> private aggregate (real output as main sub-device
    /// + tap in the tap list) -> passthrough IOProc -> start.
    func start() throws {
        precondition(!isRunning, "AudioTapEngine.start() called while already running")

        // 1. Muted global tap: captures the entire system mix, silences the original
        //    so audio is heard exactly once (through our IOProc's output writes).
        //    Our own process MUST be excluded: a muted global tap that includes us
        //    mutes our EQ'd playback and feeds it back into the tap input.
        //    Do not touch isExclusive afterwards.
        let selfProcessObject = try processObjectID(forPID: getpid())
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [selfProcessObject] + excludedProcessObjects
        )
        tapDescription.name = "MacEQ System Tap"
        tapDescription.muteBehavior = .muted
        tapDescription.isPrivate = true

        try checkOSStatus(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            "AudioHardwareCreateProcessTap"
        )

        do {
            let outputDevice = try defaultOutputDeviceID()
            let outputUID = try deviceUID(of: outputDevice)
            let outputName = try deviceName(of: outputDevice)
            let sampleRate = try nominalSampleRate(of: outputDevice)

            // 2. Private aggregate: the real output device anchors the clock and
            //    receives our output; the tap feeds the input side. TapAutoStart is
            //    required or the tap delivers zero samples.
            let aggregateUID = UUID().uuidString
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacEQ Aggregate",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            try checkOSStatus(
                AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice"
            )

            if preferredBufferFrames > 0 {
                var frames = preferredBufferFrames
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyBufferFrameSize,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                try checkOSStatus(
                    AudioObjectSetPropertyData(
                        aggregateID, &address, 0, nil,
                        UInt32(MemoryLayout<UInt32>.size), &frames
                    ),
                    "AudioObjectSetPropertyData(kAudioDevicePropertyBufferFrameSize, \(preferredBufferFrames))"
                )
            }

            let tapFormat = try tapStreamFormat(of: tapID)
            let bufferFrames = try bufferFrameSize(of: aggregateID)

            // 3. Passthrough IOProc on the aggregate. Must stay real-time safe:
            //    no allocation, no locks, no Objective-C/Swift runtime calls that lock.
            // The process tap attenuates the captured mix by the sub-device count
            // when the default output is a multi-output device; restore the level.
            let compensationGain = Float(outputSubDeviceCount(of: outputDevice))
            let stats = self.stats
            let kernelHolder = self.kernelHolder
            let convolverHolder = self.convolverHolder
            let captureRing = self.captureRing
            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                    _, inInputData, _, outOutputData, _ in
                    disableDenormalsOnCurrentThread()
                    passthrough(input: inInputData, output: outOutputData, stats: stats)
                    if compensationGain != 1 {
                        applyOutputGain(compensationGain, output: outOutputData)
                    }
                    // Convolution before the EQ kernel so the kernel's limiter
                    // stays last in the chain and still catches IR-induced overs.
                    if let convolver = convolverHolder.convolver {
                        applyConvolver(convolver, output: outOutputData)
                    }
                    if let kernel = kernelHolder.kernel {
                        if kernel !== kernelHolder.lastProcessedKernel {
                            if let previous = kernelHolder.lastProcessedKernel {
                                kernel.adoptState(from: previous)
                            }
                            // Not the final release of the old kernel: the
                            // controller's retire list still holds it.
                            kernelHolder.lastProcessedKernel = kernel
                        }
                        applyKernel(kernel, output: outOutputData)
                    } else if kernelHolder.lastProcessedKernel != nil {
                        // Bypassed: that state goes stale, so the kernel after
                        // bypass starts fresh rather than from old history.
                        kernelHolder.lastProcessedKernel = nil
                    }
                    if captureRing.captureEnabled {
                        captureOutput(outOutputData, into: captureRing)
                    }
                },
                "AudioDeviceCreateIOProcIDWithBlock"
            )

            guard let ioProcID else {
                throw CoreAudioError(call: "AudioDeviceCreateIOProcIDWithBlock returned nil proc ID", status: noErr)
            }
            try checkOSStatus(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")

            status = EngineStatus(
                outputDeviceName: outputName,
                outputDeviceUID: outputUID,
                sampleRate: sampleRate,
                tapFormatDescription: describe(format: tapFormat),
                bufferFrameSize: bufferFrames,
                tapCompensationGain: compensationGain
            )
            stats.consecutiveZeroBuffers = 0
            addSampleRateListener(to: outputDevice, startedAt: sampleRate)
        } catch {
            // Unwind anything built before the failure so a retry starts clean.
            stop()
            throw error
        }
    }

    /// Introspects the live aggregate: which sub-devices actually activated, whether
    /// the aggregate exposes an output stream, and whether IO is really running.
    /// Any error is returned as a line rather than thrown — this is a diagnostic view.
    func diagnostics() -> [String] {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return [] }
        var lines: [String] = []
        do {
            let subDeviceIDs = try activeSubDeviceIDs(of: aggregateID)
            let names = try subDeviceIDs.map { try deviceName(of: $0) }
            lines.append("Active sub-devices: \(names.isEmpty ? "NONE" : names.joined(separator: ", "))")
            lines.append("Aggregate output streams: \(try outputStreamCount(of: aggregateID))")
            lines.append("Aggregate running: \(try deviceIsRunning(aggregateID))")
        } catch {
            lines.append("Diagnostics failed: \(error)")
        }
        return lines
    }

    private func sampleRateListenerAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func addSampleRateListener(to deviceID: AudioObjectID, startedAt startRate: Double) {
        var address = sampleRateListenerAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Property notifications can fire without an actual value change;
            // restarting the whole path on a no-op notification would loop.
            let newRate = (try? nominalSampleRate(of: deviceID)) ?? startRate
            if newRate != startRate {
                self.onSampleRateChanged?()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status == noErr {
            sampleRateListenerBlock = block
            sampleRateListenerDevice = deviceID
        } else {
            // Non-fatal: EQ still works, but a mid-session rate switch leaves
            // stale coefficients until the next restart.
            print("warning: sample-rate listener failed with OSStatus \(status)")
        }
    }

    private func removeSampleRateListener() {
        guard let sampleRateListenerBlock else { return }
        var address = sampleRateListenerAddress()
        AudioObjectRemovePropertyListenerBlock(
            sampleRateListenerDevice,
            &address,
            DispatchQueue.main,
            sampleRateListenerBlock
        )
        self.sampleRateListenerBlock = nil
        sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// Teardown in the required order: stop -> destroy IOProc -> destroy aggregate -> destroy tap.
    func stop() {
        removeSampleRateListener()
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        // IO has stopped, so the audio thread no longer touches this. The next
        // start may run at another sample rate; its kernel must not adopt
        // state from this session's.
        kernelHolder.lastProcessedKernel = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        status = nil
    }

    deinit {
        if let deviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                deviceListenerBlock
            )
        }
        if let processListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                processListenerBlock
            )
        }
        stop()
    }
}

/// Feeds the first output buffer (as heard, post-EQ) into the spectrum ring.
private func captureOutput(_ output: UnsafeMutablePointer<AudioBufferList>, into ring: CaptureRing) {
    let buffers = UnsafeMutableAudioBufferListPointer(output)
    guard let first = buffers.first, let data = first.mData else { return }
    let channels = Int(max(first.mNumberChannels, 1))
    let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
    ring.write(
        interleaved: data.assumingMemoryBound(to: Float.self),
        frameCount: sampleCount / channels,
        channelCount: channels
    )
}

/// Runs the FIR convolver in place on every output buffer. Real-time safe.
private func applyConvolver(_ convolver: FIRConvolver, output: UnsafeMutablePointer<AudioBufferList>) {
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputBuffers {
        guard let data = buffer.mData else { continue }
        let channels = Int(max(buffer.mNumberChannels, 1))
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        convolver.process(
            interleaved: data.assumingMemoryBound(to: Float.self),
            frameCount: sampleCount / channels,
            channelCount: channels
        )
    }
}

/// Runs the EQ kernel in place on every output buffer. Real-time safe.
private func applyKernel(_ kernel: EQKernel, output: UnsafeMutablePointer<AudioBufferList>) {
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputBuffers {
        guard let data = buffer.mData else { continue }
        let channels = Int(max(buffer.mNumberChannels, 1))
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        kernel.process(
            interleaved: data.assumingMemoryBound(to: Float.self),
            frameCount: sampleCount / channels,
            channelCount: channels
        )
    }
}

/// Copies tapped input buffers verbatim to the output buffers and updates stats.
/// Runs on the real-time audio thread — free function, no captures beyond `stats`.
private func passthrough(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    stats: IOStats
) {
    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

    var peak: Float = 0
    var sumOfSquares: Float = 0
    var sampleCount = 0
    var framesThisCallback: UInt64 = 0

    for bufferIndex in 0..<min(inputBuffers.count, outputBuffers.count) {
        let inBuffer = inputBuffers[bufferIndex]
        let outBuffer = outputBuffers[bufferIndex]
        guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

        let byteCount = Int(min(inBuffer.mDataByteSize, outBuffer.mDataByteSize))
        memcpy(outData, inData, byteCount)

        let samples = inData.assumingMemoryBound(to: Float.self)
        let count = byteCount / MemoryLayout<Float>.size
        var bufferPeak: Float = 0
        vDSP_maxmgv(samples, 1, &bufferPeak, vDSP_Length(count))
        if bufferPeak > peak { peak = bufferPeak }
        var bufferSumOfSquares: Float = 0
        vDSP_svesq(samples, 1, &bufferSumOfSquares, vDSP_Length(count))
        sumOfSquares += bufferSumOfSquares
        sampleCount += count
        let channels = max(inBuffer.mNumberChannels, 1)
        framesThisCallback += UInt64(count) / UInt64(channels)
    }

    stats.callbackCount &+= 1
    stats.framesProcessed &+= framesThisCallback
    stats.lastPeakBits = peak.bitPattern
    stats.lastRMSBits = (sampleCount > 0 ? (sumOfSquares / Float(sampleCount)).squareRoot() : 0).bitPattern
    if peak == 0 {
        stats.consecutiveZeroBuffers &+= 1
    } else {
        stats.consecutiveZeroBuffers = 0
    }
}

/// Multiplies every output buffer by a constant gain in place. Real-time safe.
/// Compensates the process tap's multi-output attenuation.
private func applyOutputGain(_ gain: Float, output: UnsafeMutablePointer<AudioBufferList>) {
    var gainValue = gain
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputBuffers {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        vDSP_vsmul(samples, 1, &gainValue, samples, 1, vDSP_Length(sampleCount))
    }
}

/// Current IO buffer size in frames, which dominates round-trip latency.
private func bufferFrameSize(of deviceID: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var frames: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try checkOSStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames),
        "AudioObjectGetPropertyData(kAudioDevicePropertyBufferFrameSize, device \(deviceID))"
    )
    return frames
}

private func describe(format: AudioStreamBasicDescription) -> String {
    let interleaving = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        ? "non-interleaved" : "interleaved"
    return String(
        format: "%.0f Hz, %u ch, %@, Float32: %@",
        format.mSampleRate,
        format.mChannelsPerFrame,
        interleaving,
        (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "yes" : "NO"
    )
}
