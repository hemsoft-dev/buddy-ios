import Foundation

struct AppConfiguration: Sendable {
    static let current = AppConfiguration()

    let githubClientID: String?
    let githubClientSecret: String?
    let versionDescription: String

    init(bundle: Bundle = .main) {
        let configuredClientID = bundle.object(forInfoDictionaryKey: "BuddyGitHubClientID") as? String
        githubClientID = configuredClientID?.nilIfEmptyOrBuildSetting
        let configuredClientSecret = bundle.object(forInfoDictionaryKey: "BuddyGitHubClientSecret") as? String
        githubClientSecret = configuredClientSecret?.nilIfEmptyOrBuildSetting

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        versionDescription = version
    }
}

private extension String {
    var nilIfEmptyOrBuildSetting: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
