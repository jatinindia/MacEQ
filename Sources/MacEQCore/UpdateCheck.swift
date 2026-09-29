import Foundation

/// A release version as MacEQ tags them: vMAJOR.MINOR.PATCH.
public struct ReleaseVersion: Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Numeric, component by component, so 1.10.0 is newer than 1.9.0.
    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public enum UpdateCheckError: Error, CustomStringConvertible {
    case unparseableVersion(String)
    case unreadableReply(String)
    case badStatus(Int, String)
    case notHTTP

    public var description: String {
        switch self {
        case .unparseableVersion(let text):
            return "'\(text)' is not a version like 1.3.0"
        case .unreadableReply(let snippet):
            return "GitHub's reply has no release tag: \(snippet)"
        case .badStatus(let status, let snippet):
            return "GitHub answered HTTP \(status): \(snippet)"
        case .notHTTP:
            return "the reply was not an HTTP response"
        }
    }
}

/// Parses "v1.3.0" or "1.3.0". Anything else (pre-release suffixes, two or
/// four components, signs) is not a release this checker compares against.
public func parseReleaseVersion(_ text: String) -> ReleaseVersion? {
    let body = text.hasPrefix("v") ? String(text.dropFirst()) : text
    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
          let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
    else { return nil }
    return ReleaseVersion(major: major, minor: minor, patch: patch)
}

/// The latest release if it is newer than the running app, nil if the app is
/// current. An older latest release (e.g. a pulled one) is never offered.
public func newerRelease(latestTag: String, currentVersion: String) throws -> ReleaseVersion? {
    guard let latest = parseReleaseVersion(latestTag) else {
        throw UpdateCheckError.unparseableVersion(latestTag)
    }
    guard let current = parseReleaseVersion(currentVersion) else {
        throw UpdateCheckError.unparseableVersion(currentVersion)
    }
    return current < latest ? latest : nil
}

/// The tag of the release in a GitHub /releases/latest reply. Only the tag is
/// read: the download link the app shows is fixed, never taken from the reply.
public func decodeLatestReleaseTag(_ data: Data) throws -> String {
    struct LatestRelease: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }
    do {
        return try JSONDecoder().decode(LatestRelease.self, from: data).tagName
    } catch {
        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw UpdateCheckError.unreadableReply(snippet)
    }
}

/// How often the automatic check contacts GitHub.
public let updateCheckInterval: TimeInterval = 24 * 3600

/// Whether an automatic check is due. A last check dated in the future means
/// the clock was set back; waiting for it to catch up could skip checks for
/// days, so that counts as due.
public func isUpdateCheckDue(lastCheck: Date?, now: Date) -> Bool {
    guard let lastCheck else { return true }
    let elapsed = now.timeIntervalSince(lastCheck)
    return elapsed < 0 || elapsed >= updateCheckInterval
}
