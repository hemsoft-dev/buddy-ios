import Foundation

struct AppConfiguration: Sendable {
    static let current = AppConfiguration()

    let githubClientID: String?
    let versionDescription: String

    init(bundle: Bundle = .main) {
        let configuredClientID = bundle.object(forInfoDictionaryKey: "BuddyGitHubClientID") as? String
        githubClientID = configuredClientID?.nilIfEmptyOrBuildSetting

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        versionDescription = "\(version) (\(build))"
    }
}

private extension String {
    var nilIfEmptyOrBuildSetting: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
