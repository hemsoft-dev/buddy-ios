# Buddy

[![SFL Upstream](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FHemSoft%2Fbuddy-ios%2Fmain%2Fsfl.json&query=%24.version&prefix=v&label=SFL%20Upstream&color=FFD700&style=flat&logo=githubactions&logoColor=white)](https://github.com/HemSoft/set-it-free-loop)
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

`Config/Shared.xcconfig` contains safe defaults, including the public GitHub CLI
OAuth client identifiers used by CodexBar, and optionally includes the
gitignored `Config/Local.xcconfig` for local build values. These static values
identify the OAuth application but do not grant GitHub account access. Access
tokens must never be placed in either configuration file.

### GitHub

Buddy uses GitHub's browser authorization-code flow with a loopback callback,
cryptographically random state, and PKCE `S256`. The authorization request uses
`prompt=select_account`, so initial connect, Add account, and reconnect ask
GitHub to show its account chooser. Buddy requests `repo read:org`; the
repository scope lets authored and review-requested pull requests from private
repositories appear alongside public repositories, while organization identity
supports established organization authorization. GitHub's OAuth scope grants
broad read/write repository access; Buddy uses it only for read-only identity
and pull-request API requests. Tokens are stored only in iOS Keychain.

Buddy follows CodexBar's backend-free strategy and bundles the public OAuth
client ID and client secret used by GitHub CLI-compatible clients. Static
credentials shipped in an app cannot be confidential. Browser authorization
and PKCE protect each account sign-in, and the bundled values alone provide no
account access. GitHub may identify the authorization as GitHub CLI because the
shared public OAuth client is the application receiving the grant.

To test deliberately with a different GitHub OAuth app:

1. Ensure its callback configuration allows the loopback-literal redirect
   `http://127.0.0.1:<ephemeral-port>/callback`.
2. Pass both its client ID and exchange credential as
   higher-precedence command-line build settings, for example
   `xcodebuild ... BUDDY_GITHUB_CLIENT_ID=... BUDDY_GITHUB_CLIENT_SECRET=...`.
3. Do not commit a real credential, authorization code, PKCE verifier, or token.

The source-controlled public client assignments intentionally follow the
optional local include so older blank local values cannot make distributable
builds incomplete. Command-line build settings retain higher precedence for
deliberate test configuration.

Buddy starts a listener bound only to `127.0.0.1` before presenting
`SFSafariViewController`, uses the listener's exact redirect URI during exchange,
and stops it on success, failure, timeout, or cancellation. The callback validates
the path, state, and non-empty code and rejects malformed or oversized requests.
Disconnect revokes only Buddy's exact access token, then removes its local
Keychain item. It does not revoke the shared GitHub CLI application grant, so
unrelated GitHub CLI and CodexBar sessions remain valid.

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

For a physical Hemsoft iPhone deployment, run:

```sh
scripts/install-device-build.sh
```

The script refuses to install unless the signed app contains the exact public
GitHub CLI-compatible OAuth configuration declared in `Config/Shared.xcconfig`.

## License

Buddy is available under the MIT License. See `LICENSE`.
