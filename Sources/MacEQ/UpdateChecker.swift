import Foundation
import MacEQCore

/// The one network request MacEQ makes, and only with the user's consent:
/// ask GitHub's public API which MacEQ release is the latest. Nothing about
/// the user or their audio is sent; GitHub sees an ordinary HTTPS request
/// from this IP address with a "MacEQ/<version>" user agent.
///
/// The download link shown to the user is `releasesPageURL`, fixed here, never
/// a link taken from the reply.
enum UpdateChecker {
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/jatinindia/MacEQ/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/jatinindia/MacEQ/releases/latest")!
    private static let attempts = 3

    /// The latest release's tag, e.g. "v1.3.0". Retries twice with a warning
    /// (the first attempt after waking often hits a network that isn't up
    /// yet), then throws the last error.
    static func fetchLatestReleaseTag(appVersion: String) async throws -> String {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacEQ/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        var lastError: Error = UpdateCheckError.notHTTP
        for attempt in 1...attempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UpdateCheckError.notHTTP
                }
                guard http.statusCode == 200 else {
                    throw UpdateCheckError.badStatus(
                        http.statusCode, String(decoding: data.prefix(200), as: UTF8.self)
                    )
                }
                return try decodeLatestReleaseTag(data)
            } catch {
                lastError = error
                print("warning: update check attempt \(attempt) of \(attempts) (\(latestReleaseAPIURL)) failed: \(error)")
                if attempt < attempts {
                    try await Task.sleep(for: .seconds(2 * attempt))
                }
            }
        }
        throw lastError
    }
}
