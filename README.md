# Buddy

[![Set it Free Loop](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FHemSoft%2Fbuddy-ios%2Fmain%2Fsfl.json&query=%24.version&prefix=v&label=Set%20it%20Free%20Loop&color=FFD700&style=flat&logo=githubactions&logoColor=white)](https://github.com/HemSoft/set-it-free-loop)
<!-- SFL_BADGE: auto-updated by deploy-workflow.ps1 -->
# Buddy

Buddy is a native iPhone productivity dashboard by HemSoft. It brings useful
information from services such as GitHub, Todoist, and email into one calm,
privacy-conscious home screen.

Buddy does not use AI and does not operate a backend. External accounts are
connected directly from the app with standards-based authorization, and
credentials are stored in the iOS Keychain.

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An Apple Developer team for device builds

## Getting started

1. Open `Buddy.xcodeproj` in Xcode.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`.
3. Add local integration identifiers to `Local.xcconfig` as features require
   them. Never commit secrets or access tokens.
4. Select the `Buddy` scheme and run on an iPhone simulator or device.

The project uses automatic signing with the HemSoft development team. If Xcode
cannot resolve the team on another Mac, select an available team under Buddy's
Signing & Capabilities settings.

## Architecture

Buddy is intentionally a single application target organized by responsibility:

- `App`: application entry point and navigation
- `Features`: user-facing dashboard areas
- `Core`: design, networking, persistence, security, logging, and routing
- `Integrations`: adapters for external services
- `Resources`: asset catalog, privacy manifest, and application metadata

Views use SwiftUI and lightweight observable feature models. SwiftData stores a
small cache for responsive and limited offline viewing. Authentication tokens
belong in Keychain, never SwiftData or source-controlled configuration.

## Configuration and OAuth

`Config/Shared.xcconfig` contains safe defaults, including public OAuth client
identifiers, and optionally includes the gitignored `Config/Local.xcconfig` for
local build values. Access tokens must never be placed in either configuration
file. OAuth integrations use an in-app system browser and PKCE whenever the
provider supports it.

### GitHub

Buddy uses GitHub's browser authorization-code flow with a loopback callback,
cryptographically random state, and PKCE `S256`. The authorization request uses
`prompt=select_account`, so initial connect, Add account, and reconnect all show
GitHub's account chooser. Buddy requests GitHub's `repo` OAuth scope so authored
and review-requested pull requests from private repositories appear alongside
public repositories. GitHub's OAuth App model grants broad read/write repository
access with this scope; Buddy uses it only for read-only identity and pull-request
API requests. Tokens are stored only in iOS Keychain. Existing accounts must be
reconnected once after this change so GitHub can grant the required scope.

GitHub currently requires `client_secret` during authorization-code exchange,
including when PKCE is supplied. A credential distributed in an iOS bundle is
not confidential. Buddy's backend-free strategy therefore requires a dedicated
Buddy OAuth app and explicitly treats its exchange credential as public/non-
confidential. Never reuse another application's OAuth credentials. If that
credential must remain confidential, route the code exchange through an owned
backend instead of putting it in the app or Keychain.

To test with a different GitHub OAuth app:

1. Register a dedicated Buddy GitHub OAuth app. Its callback URL must allow the
   loopback-literal redirect `http://127.0.0.1:<ephemeral-port>/callback`.
2. Pass both its client ID and public/non-confidential exchange credential as
   higher-precedence command-line build settings, for example
   `xcodebuild ... BUDDY_GITHUB_CLIENT_ID=... BUDDY_GITHUB_CLIENT_SECRET=...`.
   `Config/Local.xcconfig` may provide the exchange credential only when it
   belongs to the source-controlled client ID, because `Shared.xcconfig`
   intentionally restores that client ID after including local settings.
3. Do not commit a real credential, authorization code, PKCE verifier, or token.

The source-controlled client-ID assignment intentionally follows the optional
local include so an older blank local value cannot disable that safe public
identifier. No OAuth exchange credential is source-controlled. Command-line
build settings retain higher precedence for deliberate test configuration.

Buddy starts a listener bound only to `127.0.0.1` before presenting
`SFSafariViewController`, uses the listener's exact redirect URI during exchange,
and stops it on success, failure, timeout, or cancellation. The callback validates
the path, state, and non-empty code and rejects malformed or oversized requests.

## Verification

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project Buddy.xcodeproj \
  -scheme Buddy \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

For a physical Hemsoft iPhone deployment, keep the dedicated OAuth exchange
credential in the login Keychain with service `com.hemsoft.buddy.oauth` and
account `github-oauth-client-secret`, then run:

```sh
scripts/install-device-build.sh
```

The script refuses to install the app unless the signed bundle contains both
the configured GitHub client ID and the expected Keychain-backed exchange
credential.

## License

Buddy is available under the MIT License. See `LICENSE`.
