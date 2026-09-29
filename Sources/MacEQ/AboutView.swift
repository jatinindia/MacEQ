import SwiftUI

/// About panel: version, author, project link, and the privacy claim the app
/// has to live up to (no recording; no network beyond the optional update
/// check — see README).
struct AboutView: View {
    static let repositoryURL = URL(string: "https://github.com/jatinindia/MacEQ")!

    private var version: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short else { return "development build" }
        guard let build else { return "Version \(short)" }
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("MacEQ")
                .font(.title2.weight(.semibold))
            Text("System-wide equalizer for macOS")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(version)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            VStack(spacing: 4) {
                Text("Made by Jatin Grewal")
                    .font(.caption)
                Link("github.com/jatinindia/MacEQ", destination: Self.repositoryURL)
                    .font(.caption)
                Text("Free and open source under the MIT license.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Audio is equalized on your Mac and played straight back out. "
                 + "MacEQ never records it or sends it anywhere. Its only network "
                 + "request is the optional daily update check, which sends nothing about you.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 280)
    }
}
