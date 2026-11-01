import Foundation

/// What the tap's exclusion decision needs to know about one Core Audio client.
public struct AudioProcessSnapshot: Equatable {
    /// The app responsible for the process (helpers map to their app); nil when unknown.
    public let appBundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(appBundleID: String?, isRunningInput: Bool, isRunningOutput: Bool) {
        self.appBundleID = appBundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Whether the muted system tap must leave a process out, so its audio plays
/// directly to the output device instead of through MacEQ.
///
/// Apps the user excluded, always. And any process recording and playing at
/// once, which is what a call looks like (WhatsApp, FaceTime, Zoom, Meet): a
/// call app's voice processing makes macOS duck every *other* app's audio, and
/// with the call's own voice replayed by MacEQ, that includes the voice. The
/// call then sounds far too quiet until MacEQ quits. Played directly, the
/// voice is the call app's own audio again and is left alone.
public func shouldExcludeFromTap(_ process: AudioProcessSnapshot, userExcludedBundleIDs: Set<String>) -> Bool {
    if let appBundleID = process.appBundleID, userExcludedBundleIDs.contains(appBundleID) {
        return true
    }
    return process.isRunningInput && process.isRunningOutput
}
