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
private local values. Client secrets and access tokens must never be placed in
either configuration file. OAuth integrations should use the system browser and
PKCE whenever the provider supports it. Buddy's callback route is:

```text
buddy://oauth/<provider>
```

Each provider's exact authorization requirements should be verified when its
integration is implemented.

### GitHub

Buddy uses GitHub's OAuth device flow because it is a native, backend-free app
and therefore cannot keep a client secret. The app requests no OAuth scopes for
the initial connection; this grants only the minimum access needed to validate
the signed-in user's public identity. Tokens are stored only in iOS Keychain.

Buddy's source-controlled build configuration includes the public client ID for
the HemSoft OAuth app, whose **Device Flow** setting is enabled. OAuth client IDs
identify an app but do not authenticate it, so distributable builds can safely
include this value without embedding a client secret.

To test with a different GitHub OAuth app:

1. Register a GitHub OAuth app and enable **Device Flow** in its settings.
2. Pass its public client ID as a command-line build setting, for example
   `xcodebuild ... BUDDY_GITHUB_CLIENT_ID=your-public-client-id`.
3. Do not add a client secret.

The shared client-ID assignment intentionally follows the optional local include
so an older `Local.xcconfig` containing a blank value cannot disable connection
in a current build. Command-line build settings retain higher precedence when a
developer deliberately tests another OAuth app.

The device flow opens GitHub in the system browser, observes GitHub's polling
interval and expiration, and handles `slow_down` responses. The existing
`buddy://oauth/github` route remains available for future providers that use a
redirect-based authorization flow.

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

## License

Buddy is available under the MIT License. See `LICENSE`.
