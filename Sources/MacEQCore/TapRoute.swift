import CoreAudio
import Foundation

/// One channel of a device's IOProc buffer list.
public struct ChannelLocation: Equatable {
    public let buffer: Int
    public let channel: Int
    /// Interleaving stride of that buffer.
    public let channelsInBuffer: Int

    public init(buffer: Int, channel: Int, channelsInBuffer: Int) {
        self.buffer = buffer
        self.channel = channel
        self.channelsInBuffer = channelsInBuffer
    }
}

/// Where the processed stereo signal goes in the output device's buffers.
public enum TapOutput: Equatable {
    case stereo(left: ChannelLocation, right: ChannelLocation)
    /// Single-channel device: (L + R) / 2.
    case mono(ChannelLocation)
}

/// The IOProc's view of the aggregate: which input buffer carries the tap, and
/// where its left/right channels land on the output device.
public struct TapRoute: Equatable {
    public let tapBufferIndex: Int
    public let output: TapOutput

    public init(tapBufferIndex: Int, output: TapOutput) {
        self.tapBufferIndex = tapBufferIndex
        self.output = output
    }
}

public struct TapRouteError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { "TapRouteError: \(message)" }
}

/// Plans the IOProc routing from the buffer layouts Core Audio reports, before
/// IO starts.
///
/// The aggregate's input buffer list holds the output device's own input
/// streams (a USB headset's mic, an interface's inputs) followed by the tap:
/// sub-device streams come first, in sub-device order, and taps are appended.
/// The whole layout is checked against that, and a layout that doesn't match is
/// refused rather than guessed at: guessing wrong plays the microphone instead
/// of the system mix.
///
/// Left and right go to the device's preferred stereo pair (Audio MIDI Setup >
/// Configure Speakers), the same channels macOS itself sends stereo to; every
/// other channel stays silent. A pair outside the device's channels falls back
/// to channels 1-2, macOS's own default.
///
/// - Parameters:
///   - aggregateInputChannels: channels per buffer, aggregate input scope.
///   - deviceInputChannels: channels per buffer of the output device's own inputs.
///   - tapChannelCount: channels in the tap's stream (MacEQ requests stereo).
///   - outputChannels: channels per buffer, aggregate output scope.
///   - preferredStereoChannels: 1-based (left, right) channel numbers.
public func planTapRoute(
    aggregateInputChannels: [Int],
    deviceInputChannels: [Int],
    tapChannelCount: Int,
    outputChannels: [Int],
    preferredStereoChannels: (Int, Int)
) throws -> TapRoute {
    let context = "aggregate inputs \(aggregateInputChannels), device inputs \(deviceInputChannels), "
        + "tap \(tapChannelCount) ch, outputs \(outputChannels)"
    guard tapChannelCount == 2 else {
        throw TapRouteError(message: "expected a stereo tap (\(context))")
    }
    let tapIndex = deviceInputChannels.count
    guard aggregateInputChannels.count == tapIndex + 1,
          Array(aggregateInputChannels.prefix(tapIndex)) == deviceInputChannels,
          aggregateInputChannels[tapIndex] == tapChannelCount
    else {
        throw TapRouteError(
            message: "input buffers are not the output device's own inputs followed by the tap (\(context))"
        )
    }

    let locations = outputChannels.enumerated().flatMap { buffer, channels in
        (0..<channels).map { ChannelLocation(buffer: buffer, channel: $0, channelsInBuffer: channels) }
    }
    guard !locations.isEmpty else {
        throw TapRouteError(message: "the output device has no output channels (\(context))")
    }
    if locations.count == 1 {
        return TapRoute(tapBufferIndex: tapIndex, output: .mono(locations[0]))
    }
    let (preferredLeft, preferredRight) = preferredStereoChannels
    let channelNumbers = 1...locations.count
    let preferredIsUsable = preferredLeft != preferredRight
        && channelNumbers.contains(preferredLeft)
        && channelNumbers.contains(preferredRight)
    let (left, right) = preferredIsUsable ? (preferredLeft, preferredRight) : (1, 2)
    return TapRoute(
        tapBufferIndex: tapIndex,
        output: .stereo(left: locations[left - 1], right: locations[right - 1])
    )
}

/// Writes `frameCount` frames of interleaved stereo into the output buffers,
/// starting at frame `frameOffset`, per `output`. Writes only the routed
/// channels: callers zero the buffers first so every other channel is silent.
/// Real-time safe.
public func scatterStereo(
    _ stereo: UnsafePointer<Float>,
    frameCount: Int,
    atFrame frameOffset: Int,
    to output: TapOutput,
    in buffers: UnsafeMutableAudioBufferListPointer
) {
    switch output {
    case .stereo(let left, let right):
        // Two direct calls, not a loop over [(0, left), (1, right)]: that array
        // literal could allocate on the audio thread.
        copyChannel(stereo, sourceChannel: 0, frameCount: frameCount, atFrame: frameOffset, to: left, in: buffers)
        copyChannel(stereo, sourceChannel: 1, frameCount: frameCount, atFrame: frameOffset, to: right, in: buffers)
    case .mono(let location):
        guard let destination = channelStart(location, atFrame: frameOffset, frameCount: frameCount, in: buffers)
        else { return }
        for frame in 0..<frameCount {
            destination[frame * location.channelsInBuffer] = (stereo[frame * 2] + stereo[frame * 2 + 1]) * 0.5
        }
    }
}

private func copyChannel(
    _ stereo: UnsafePointer<Float>, sourceChannel: Int, frameCount: Int, atFrame frameOffset: Int,
    to location: ChannelLocation, in buffers: UnsafeMutableAudioBufferListPointer
) {
    guard let destination = channelStart(location, atFrame: frameOffset, frameCount: frameCount, in: buffers)
    else { return }
    for frame in 0..<frameCount {
        destination[frame * location.channelsInBuffer] = stereo[frame * 2 + sourceChannel]
    }
}

/// First sample of `location` at `frameOffset`, or nil if the buffer is
/// missing, laid out differently than planned, or too short for the write.
/// Writing nothing leaves that channel silent, which beats writing at the
/// wrong stride. A guard, not a path taken in practice.
private func channelStart(
    _ location: ChannelLocation, atFrame frameOffset: Int, frameCount: Int,
    in buffers: UnsafeMutableAudioBufferListPointer
) -> UnsafeMutablePointer<Float>? {
    guard location.buffer < buffers.count,
          Int(buffers[location.buffer].mNumberChannels) == location.channelsInBuffer,
          let data = buffers[location.buffer].mData
    else { return nil }
    let bufferFrames = Int(buffers[location.buffer].mDataByteSize)
        / (MemoryLayout<Float>.size * location.channelsInBuffer)
    guard frameOffset + frameCount <= bufferFrames else { return nil }
    return data.assumingMemoryBound(to: Float.self) + frameOffset * location.channelsInBuffer + location.channel
}
