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

`Config/Shared.xcconfig` contains safe defaults and optionally includes the
gitignored `Config/Local.xcconfig`. OAuth integrations should use the system
browser and PKCE whenever the provider supports it. Buddy's callback route is:

```text
buddy://oauth/<provider>
```

Each provider's exact authorization requirements should be verified when its
integration is implemented.

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
