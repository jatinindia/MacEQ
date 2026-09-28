import Foundation

/// Delay before retrying a failed audio-engine start: 1 s, doubling, capped at
/// 30 s. A Bluetooth device still negotiating its connection usually starts
/// within a second or two; one that stays broken is retried indefinitely, but
/// not hammered.
public func engineRestartDelay(afterConsecutiveFailures failures: Int) -> TimeInterval {
    precondition(failures >= 1, "engineRestartDelay needs at least one failure, got \(failures)")
    return min(pow(2.0, Double(failures - 1)), 30)
}

/// Watchdog ticks in a row without a single IOProc callback before the audio
/// path counts as dead. Two ticks (~4 s at the 2 s watchdog interval) rather
/// than one, so the moment IO takes to resume after wake isn't mistaken for a
/// stall.
public let callbackStallTicksBeforeRestart = 2

/// Advances the stalled-tick streak from one watchdog observation of the IOProc
/// callback counter.
///
/// A running aggregate calls its IOProc continuously, silence included, so a
/// counter that stops moving means the path is dead (sleep/wake, a coreaudiod
/// restart). The silent-buffer watchdog cannot see that state: it only counts
/// buffers that actually arrive.
/// - Parameter previousCallbackCount: nil when there is no baseline yet (fresh start).
public func nextStalledTickCount(
    previousCallbackCount: UInt64?, currentCallbackCount: UInt64, stalledTicks: Int
) -> Int {
    guard let previousCallbackCount else { return 0 }
    return currentCallbackCount == previousCallbackCount ? stalledTicks + 1 : 0
}
