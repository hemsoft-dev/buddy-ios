# Changelog

Notable changes included in Buddy device deployments are recorded here.

## 0.1.0 (6) - 2026-08-08

- Match CodexBar's GitHub CLI-compatible browser authorization so private organization accounts do not depend on a newly registered HemSoft OAuth app.
- Dismiss the in-app GitHub browser only after authorization succeeds or fails.
- Disconnect by revoking only Buddy's token, without revoking shared GitHub CLI-compatible sessions used by other apps.

## 0.1.0 (3) - 2026-08-07

- Revoke Buddy's server-side GitHub grant when an account is disconnected, ensuring the next connection requires fresh approval.
- Keep the GitHub callback confirmation visible until the user returns to Buddy.

## 0.1.0 (2) - 2026-08-06

- Show pull requests authored by the signed-in GitHub user on the dashboard.
- Move GitHub account setup and management into Settings.
- Show only the public app version in Settings, without the internal build number.
