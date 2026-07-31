import Foundation

enum AppRoute: Equatable, Sendable {
    case oauthCallback(provider: String)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "buddy",
              url.host?.lowercased() == "oauth"
        else {
            return nil
        }

        let provider = url.pathComponents
            .filter { $0 != "/" }
            .first?
            .lowercased()

        guard let provider, !provider.isEmpty else { return nil }
        self = .oauthCallback(provider: provider)
    }

    var provider: String {
        switch self {
        case let .oauthCallback(provider): provider
        }
    }
}
