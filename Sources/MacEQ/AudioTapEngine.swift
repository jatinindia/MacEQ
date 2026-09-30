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

/// Hands the active voice isolator to the audio thread; nil means the stage is
/// off (no processing, no added latency). Same lifetime rules as KernelHolder.
final class IsolatorHolder {
    var isolator: VoiceIsolator?
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
    /// Callbacks whose buffer layout differed from the route planned at start.
    var layoutMismatches: UInt64 = 0

    var lastPeak: Float { Float(bitPattern: lastPeakBits) }
    var lastRMS: Float { Float(bitPattern: lastRMSBits) }
}

/// Interleaved stereo working buffer for the audio thread. The whole chain
/// (compensation, convolution, EQ, spectrum capture) runs here, so it always
/// sees plain stereo no matter how the output device lays out its channels;
/// the result is then scattered to the device's stereo pair.
final class StereoScratch {
    /// Callbacks longer than this are processed in chunks.
    static let capacityFrames = 4096
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: StereoScratch.capacityFrames * 2)

    init() {
        samples.initialize(repeating: 0, count: Self.capacityFrames * 2)
    }

    deinit {
        samples.deallocate()
    }
}

/// Snapshot of the running audio path, for display and per-device profiles.
struct EngineStatus {
    let outputDeviceName: String
    let outputDeviceUID: String
    let sampleRate: Double
    let tapFormatDescription: String
    /// Which input buffer is the tap and where L/R land, for diagnostics.
    let routeDescription: String
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
    let isolatorHolder = IsolatorHolder()
    let captureRing = CaptureRing()
    private let scratch = StereoScratch()
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

            // 3. Plan the routing from the layouts Core Audio reports. The input
            //    list is the output device's own inputs (a headset mic, an
            //    interface's inputs) followed by the tap, and the output side
            //    can be any channel count or one buffer per channel. Copying
            //    input buffer i to output buffer i, as this used to, played the
            //    mic instead of the system mix on such devices, and scrambled
            //    stereo into multichannel layouts.
            guard tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            else {
                throw CoreAudioError(
                    call: "tap stream is not interleaved Float32 (\(describe(format: tapFormat)))",
                    status: noErr
                )
            }
            let outputChannels = try streamConfiguration(of: aggregateID, scope: kAudioObjectPropertyScopeOutput)
            let route = try planTapRoute(
                aggregateInputChannels: try streamConfiguration(of: aggregateID, scope: kAudioObjectPropertyScopeInput),
                deviceInputChannels: try streamConfiguration(of: outputDevice, scope: kAudioObjectPropertyScopeInput),
                tapChannelCount: Int(tapFormat.mChannelsPerFrame),
                outputChannels: outputChannels,
                preferredStereoChannels: try preferredStereoChannels(of: outputDevice)
            )

            // 4. The IOProc. Must stay real-time safe: no allocation, no locks,
            //    no Objective-C/Swift runtime calls that lock.
            // The process tap attenuates the captured mix by the sub-device count
            // when the default output is a multi-output device; restore the level.
            let compensationGain = Float(outputSubDeviceCount(of: outputDevice))
            let expectedInputBuffers = route.tapBufferIndex + 1
            let stats = self.stats
            let kernelHolder = self.kernelHolder
            let convolverHolder = self.convolverHolder
            let isolatorHolder = self.isolatorHolder
            let captureRing = self.captureRing
            let scratch = self.scratch.samples
            try checkOSStatus(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
                    _, inInputData, _, outOutputData, _ in
                    disableDenormalsOnCurrentThread()
                    let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
                    clear(outputBuffers)
                    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                    guard inputBuffers.count == expectedInputBuffers,
                          inputBuffers[route.tapBufferIndex].mNumberChannels == 2,
                          let tapData = inputBuffers[route.tapBufferIndex].mData
                    else {
                        // The layout changed since start() planned it. Play
                        // silence rather than whatever sits in the wrong buffer;
                        // counting it as a silent buffer lets the zero-buffer
                        // watchdog rebuild (and replan) the path.
                        stats.callbackCount &+= 1
                        stats.layoutMismatches &+= 1
                        stats.consecutiveZeroBuffers &+= 1
                        return
                    }
                    let tap = UnsafePointer(tapData.assumingMemoryBound(to: Float.self))
                    let frameCount = Int(inputBuffers[route.tapBufferIndex].mDataByteSize)
                        / (2 * MemoryLayout<Float>.size)
                    recordTapStats(tap, frameCount: frameCount, stats: stats)

                    let kernel = kernelHolder.kernel
                    if let kernel {
                        if kernel !== kernelHolder.lastProcessedKernel {
                            if let previous = kernelHolder.lastProcessedKernel {
                                kernel.adoptState(from: previous)
                            }
                            // Not the final release of the old kernel: the
                            // controller's retire list still holds it.
                            kernelHolder.lastProcessedKernel = kernel
                        }
                    } else if kernelHolder.lastProcessedKernel != nil {
                        // Bypassed: that state goes stale, so the kernel after
                        // bypass starts fresh rather than from old history.
                        kernelHolder.lastProcessedKernel = nil
                    }
                    let convolver = convolverHolder.convolver
                    let isolator = isolatorHolder.isolator

                    var offset = 0
                    while offset < frameCount {
                        let chunk = min(frameCount - offset, StereoScratch.capacityFrames)
                        scratch.update(from: tap + offset * 2, count: chunk * 2)
                        if compensationGain != 1 {
                            var gain = compensationGain
                            vDSP_vsmul(scratch, 1, &gain, scratch, 1, vDSP_Length(chunk * 2))
                        }
                        // Isolation first, so the model hears the mix as played
                        // rather than as EQ'd. Convolution before the EQ kernel so
                        // the kernel's limiter stays last in the chain and still
                        // catches IR-induced overs.
                        isolator?.process(interleavedStereo: scratch, frameCount: chunk)
                        convolver?.process(interleaved: scratch, frameCount: chunk, channelCount: 2)
                        kernel?.process(interleaved: scratch, frameCount: chunk, channelCount: 2)
                        if captureRing.captureEnabled {
                            captureRing.write(interleaved: scratch, frameCount: chunk, channelCount: 2)
                        }
                        scatterStereo(scratch, frameCount: chunk, atFrame: offset, to: route.output, in: outputBuffers)
                        offset += chunk
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
                routeDescription: describe(route: route, outputChannels: outputChannels),
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

/// Zeroes every output buffer, so channels the route doesn't write (everything
/// but the stereo pair) are silent. Real-time safe.
private func clear(_ buffers: UnsafeMutableAudioBufferListPointer) {
    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        memset(data, 0, Int(buffer.mDataByteSize))
    }
}

/// Level stats from the tap alone, not every input buffer: on a device with
/// inputs of its own, a microphone's noise floor would otherwise hide a silent
/// tap from the zero-buffer watchdog. Real-time safe.
private func recordTapStats(_ tap: UnsafePointer<Float>, frameCount: Int, stats: IOStats) {
    let sampleCount = frameCount * 2
    var peak: Float = 0
    var sumOfSquares: Float = 0
    if sampleCount > 0 {
        vDSP_maxmgv(tap, 1, &peak, vDSP_Length(sampleCount))
        vDSP_svesq(tap, 1, &sumOfSquares, vDSP_Length(sampleCount))
    }
    stats.callbackCount &+= 1
    stats.framesProcessed &+= UInt64(frameCount)
    stats.lastPeakBits = peak.bitPattern
    stats.lastRMSBits = (sampleCount > 0 ? (sumOfSquares / Float(sampleCount)).squareRoot() : 0).bitPattern
    if peak == 0 {
        stats.consecutiveZeroBuffers &+= 1
    } else {
        stats.consecutiveZeroBuffers = 0
    }
}

/// e.g. "tap = input buffer 2 of 2 · L → ch 3, R → ch 4 of 4".
private func describe(route: TapRoute, outputChannels: [Int]) -> String {
    let totalChannels = outputChannels.reduce(0, +)
    // 1-based channel number across all output buffers.
    func channelNumber(_ location: ChannelLocation) -> Int {
        outputChannels.prefix(location.buffer).reduce(0, +) + location.channel + 1
    }
    let output: String
    switch route.output {
    case .stereo(let left, let right):
        output = "L → ch \(channelNumber(left)), R → ch \(channelNumber(right)) of \(totalChannels)"
    case .mono(let location):
        output = "mono downmix → ch \(channelNumber(location)) of \(totalChannels)"
    }
    return "tap = input buffer \(route.tapBufferIndex + 1) of \(route.tapBufferIndex + 1) · \(output)"
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
