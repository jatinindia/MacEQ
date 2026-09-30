import Accelerate
import AudioToolbox
import Foundation

public struct VoiceIsolatorError: Error, CustomStringConvertible {
    public let call: String
    public let status: OSStatus

    public var description: String { "\(call) failed with OSStatus \(status)" }
}

/// Input staged for one render: the render callback copies from here. A plain
/// struct behind a pointer so the callback needs no reference to the isolator.
private struct RenderInput {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    var frameCount: Int
    var readOffset: Int
}

/// Apple's AUSoundIsolation (the standard "Voice" model) run on interleaved
/// stereo. Adds `latencyFrames` of delay (~76 ms in stereo at any rate).
///
/// The mix is the unit's Wet/Dry parameter: 100 keeps only the voice, 0 is the
/// dry (latency-aligned) signal. It is a linear blend, so 50 attenuates the
/// background by only ~6 dB. The unit also accepts down to -100 (everything
/// but the voice), which MacEQ doesn't use: as a karaoke effect it barely
/// touched sung vocals on real songs.
///
/// Only the standard model is used: the HighQualityVoice model was measured
/// allocating on the render thread and overrunning 512-frame deadlines, so it
/// is not safe in an IOProc.
///
/// Real-time safety: `process` allocates nothing and takes no locks (measured
/// for the standard model with a malloc interposer: zero render-thread
/// allocations across fixed and varying slice sizes). Every buffer is created
/// in `init`. `setMix` may be called from another thread while `process` runs;
/// Apple's units take parameter changes atomically.
///
/// Interfaces an Audio Unit (external system) with manual lifetime, hence a class.
public final class VoiceIsolator {
    public let latencyFrames: Int
    public let maxFrames: Int
    /// Renders that failed or consumed a different frame count than staged; the
    /// chunk is output as silence. Audio thread writes, UI reads (word-sized
    /// stores; stale-by-one values are harmless for an error display).
    public private(set) var renderFailureCount: UInt64 = 0
    public private(set) var lastRenderFailureStatus: OSStatus = noErr

    private let unit: AudioUnit
    private let input: UnsafeMutablePointer<RenderInput>
    private let outputLeft: UnsafeMutablePointer<Float>
    private let outputRight: UnsafeMutablePointer<Float>
    private let outputList: UnsafeMutableAudioBufferListPointer
    private var timeStamp = AudioTimeStamp()

    /// - Parameters:
    ///   - sampleRate: the engine's rate; the unit accepts 16–96 kHz.
    ///   - maxFrames: the largest `frameCount` `process` will be given.
    ///   - mix: initial Wet/Dry value, 0–100 (see the type comment).
    public init(sampleRate: Double, maxFrames: Int, mix: Float) throws {
        precondition(maxFrames > 0, "maxFrames must be positive")
        let input = UnsafeMutablePointer<RenderInput>.allocate(capacity: 1)
        input.initialize(to: RenderInput(
            left: .allocate(capacity: maxFrames),
            right: .allocate(capacity: maxFrames),
            frameCount: 0,
            readOffset: 0
        ))
        do {
            let (unit, latencySeconds) = try makeSoundIsolationUnit(
                sampleRate: sampleRate, maxFrames: maxFrames, mix: mix, input: input
            )
            self.unit = unit
            self.latencyFrames = Int((latencySeconds * sampleRate).rounded())
        } catch {
            input.pointee.left.deallocate()
            input.pointee.right.deallocate()
            input.deallocate()
            throw error
        }
        self.maxFrames = maxFrames
        self.input = input
        self.outputLeft = .allocate(capacity: maxFrames)
        self.outputRight = .allocate(capacity: maxFrames)
        self.outputList = AudioBufferList.allocate(maximumBuffers: 2)
        timeStamp.mFlags = .sampleTimeValid
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        input.pointee.left.deallocate()
        input.pointee.right.deallocate()
        input.deallocate()
        outputLeft.deallocate()
        outputRight.deallocate()
        outputList.unsafeMutablePointer.deallocate()
    }

    /// Changes the Wet/Dry mix without rebuilding, so the delay line and the
    /// model's state carry on.
    public func setMix(_ mix: Float) throws {
        let status = AudioUnitSetParameter(
            unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, mix, 0
        )
        guard status == noErr else {
            throw VoiceIsolatorError(call: "AudioUnitSetParameter(WetDryMixPercent, \(mix))", status: status)
        }
    }

    /// Isolates interleaved stereo Float32 in place. Real-time safe.
    public func process(interleavedStereo samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        precondition(frameCount <= maxFrames, "frameCount \(frameCount) exceeds maxFrames \(maxFrames)")
        guard frameCount > 0 else { return }
        let length = vDSP_Length(frameCount)

        var inputSplit = DSPSplitComplex(realp: input.pointee.left, imagp: input.pointee.right)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) {
            vDSP_ctoz($0, 2, &inputSplit, 1, length)
        }
        input.pointee.frameCount = frameCount
        input.pointee.readOffset = 0

        let byteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: outputLeft)
        outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: outputRight)
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(frameCount), outputList.unsafeMutablePointer)
        timeStamp.mSampleTime += Double(frameCount)

        guard status == noErr,
              input.pointee.readOffset == frameCount,
              let left = outputList[0].mData?.assumingMemoryBound(to: Float.self),
              let right = outputList[1].mData?.assumingMemoryBound(to: Float.self)
        else {
            renderFailureCount &+= 1
            lastRenderFailureStatus = status
            // Silence rather than the dry chunk: dry audio here would be out of
            // step with the delayed audio around it.
            memset(samples, 0, frameCount * 2 * MemoryLayout<Float>.size)
            return
        }
        var outputSplit = DSPSplitComplex(realp: left, imagp: right)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) {
            vDSP_ztoc(&outputSplit, 1, $0, 2, length)
        }
    }
}

/// Supplies the staged input. Copies what is left and zero-fills any excess
/// request; `process` detects the mismatch through `readOffset`.
private func renderInputCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timeStamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frameCount: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let input = refCon.assumingMemoryBound(to: RenderInput.self)
    guard let ioData else { return kAudio_ParamError }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let requested = Int(frameCount)
    let available = max(0, min(requested, input.pointee.frameCount - input.pointee.readOffset))
    for (index, buffer) in buffers.enumerated() {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let source = index == 0 ? input.pointee.left : input.pointee.right
        data.update(from: source + input.pointee.readOffset, count: available)
        if available < requested {
            (data + available).update(repeating: 0, count: requested - available)
        }
    }
    input.pointee.readOffset += requested
    return noErr
}

/// Creates, configures and initializes the unit; disposes it on any failure.
/// Returns the unit and its reported latency in seconds.
private func makeSoundIsolationUnit(
    sampleRate: Double, maxFrames: Int, mix: Float, input: UnsafeMutablePointer<RenderInput>
) throws -> (AudioUnit, Double) {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    guard let component = AudioComponentFindNext(nil, &description) else {
        throw VoiceIsolatorError(call: "AudioComponentFindNext(AUSoundIsolation)", status: noErr)
    }
    var created: AudioUnit?
    let createStatus = AudioComponentInstanceNew(component, &created)
    guard createStatus == noErr, let unit = created else {
        throw VoiceIsolatorError(call: "AudioComponentInstanceNew(AUSoundIsolation)", status: createStatus)
    }

    func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else { throw VoiceIsolatorError(call: call, status: status) }
    }

    do {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        for (scope, name) in [(kAudioUnitScope_Input, "input"), (kAudioUnitScope_Output, "output")] {
            try check(
                AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, formatSize),
                "AudioUnitSetProperty(StreamFormat, \(name), \(sampleRate) Hz stereo)"
            )
        }
        // The default (1156 frames) is smaller than the engine's chunks.
        var maximumFrames = UInt32(maxFrames)
        try check(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &maximumFrames, UInt32(MemoryLayout<UInt32>.size)
            ),
            "AudioUnitSetProperty(MaximumFramesPerSlice, \(maxFrames))"
        )
        var callback = AURenderCallbackStruct(inputProc: renderInputCallback, inputProcRefCon: input)
        try check(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            "AudioUnitSetProperty(SetRenderCallback)"
        )
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize(AUSoundIsolation, \(sampleRate) Hz)")
        try check(
            AudioUnitSetParameter(
                unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice), 0
            ),
            "AudioUnitSetParameter(SoundToIsolate, Voice)"
        )
        try check(
            AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, mix, 0),
            "AudioUnitSetParameter(WetDryMixPercent, \(mix))"
        )
        var latency: Float64 = 0
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        try check(
            AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &latencySize),
            "AudioUnitGetProperty(Latency)"
        )
        return (unit, latency)
    } catch {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        throw error
    }
}
