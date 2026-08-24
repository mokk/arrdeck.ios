# arrdeck-ios

Native iOS client for [arrdeck](https://github.com/mokk/arrdeck). Works against
**any** arrdeck backend over its HTTP API — the backend repo is pinned as a
submodule for the committed OpenAPI spec, locale strings and contract tests, not
because the app assumes that deployment.

The plan lives in `arrdeck/IOS-PLAN.md`. This repo currently implements
**phase A (server profiles)**: the profile model, the three-outcome `/about`
probe, Keychain storage, and the onboarding/list views.

## Layout

- `Sources/ArrdeckKit` — everything that is not a screen: profiles, the probe,
  capability handling, storage. Platform-neutral on purpose so it builds and
  tests on a Mac with only Command Line Tools.
- `Sources/ArrdeckUI` — SwiftUI views. Also compile on macOS, so type errors
  surface from `swift build` without Xcode; iOS-only API stays out.
- `App/` — the Xcode app target, generated with
  [xcodegen](https://github.com/yonaskolb/XcodeGen). This is the only part that
  needs Xcode. It also owns the two Info.plist keys a LAN profile cannot work
  without: the `NSAllowsLocalNetworking` ATS exception (plain-HTTP LAN URLs are
  refused by default) and `NSLocalNetworkUsageDescription` (the local-network
  permission prompt).
- `arrdeck/` — the backend, pinned. `Tests/…/AboutContractTests` reads its
  `FEATURE_ROUTES` table so the `Feature` enum cannot drift from the backend
  silently.

## Building

```sh
swift build     # package + views, Command Line Tools suffice
./test.sh       # swift test with the CLT framework paths (see script header)
```

The app itself:

```sh
brew install xcodegen
cd App && xcodegen && open Arrdeck.xcodeproj
```

## Decisions carried in code

- **A profile's URL is immutable.** Sessions are cookies and passkeys are
  rp_id-scoped, so a different URL is a different identity; editing one in
  place would silently invalidate both. Delete and re-add instead.
- **Bare IPs and localhost normalise to `http://`, hostnames to `https://`.**
  LAN deployments run plain HTTP; a TLS error against a LAN IP is not something
  a user can act on.
- **A 401 from the probe is progress, not failure** — it is how an arrdeck that
  wants pairing answers. 200 HTML during onboarding is "not an API"; the same
  bytes *after* pairing mean a backend from before `/about` existed.
- **Unknown feature names are kept**, so a newer backend's capabilities survive
  a round-trip through this app's storage.
