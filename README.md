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

## Configuration and authorization

`Config/Shared.xcconfig` contains safe defaults and optionally includes the
gitignored `Config/Local.xcconfig` for local build values. Access tokens must
never be placed in either configuration file.

### GitHub

Buddy uses a dedicated GitHub App and GitHub's device authorization flow. The
phone sends only the GitHub App's public client ID; there is no client secret,
embedded browser, loopback listener, or broad OAuth `repo` scope in the shipped
flow. GitHub App user tokens start with `ghu_` and are stored only in iOS Keychain.
Older OAuth tokens are rejected and their accounts are shown as needing a
one-time reconnect.

Register the GitHub App with these settings:

1. Enable Device Flow. Disable user-to-server token expiration until Buddy
   persists and rotates GitHub App refresh tokens.
2. Grant repository `Metadata: Read-only` and `Pull requests: Read-only` only.
   Do not request repository contents, issues, administration, or write access.
3. Allow installation on any account. Each user must install the app on the
   organizations or selected repositories whose private pull requests Buddy
   should display. Organization owners may need to approve the installation.
4. Set `BUDDY_GITHUB_CLIENT_ID` to the GitHub App client ID and
   `BUDDY_GITHUB_APP_SLUG` to its public slug in a local or CI build setting.
   Never use an OAuth App client ID here.

After device authorization, Buddy verifies `/user`, confirms that the user token
can see at least one installation through `/user/installations`, and only then
stores the account. Signing out removes the local token. The GitHub App
installation and GitHub-side authorization remain independently manageable in
GitHub settings.

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
