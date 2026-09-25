# Contributing

Thanks for taking a look. Bug reports, cache-catalogue additions and pull
requests are all welcome.

## Getting set up

```sh
git clone https://github.com/RamitVishwakarma/Janus.git
cd Janus
swift build          # needs only the Xcode Command Line Tools
swift test           # needs Xcode, which is where XCTest comes from
./build.sh && open Janus.app
```

If `swift test` reports `no such module 'XCTest'`, your toolchain is the Command
Line Tools rather than Xcode. Either install Xcode and point at it with
`sudo xcode-select -s /Applications/Xcode.app`, or open the pull request and let
CI run the suite for you.

## Where things live

| Path | What belongs there |
| --- | --- |
| `Sources/JanusCore` | Sessions, storage, switching, the cache catalogue. No SwiftUI, and nothing that needs a window. |
| `Sources/Janus` | The SwiftUI app: window, menu bar item, view models. |
| `Tests/JanusCoreTests` | Tests for everything in `JanusCore`. |
| `scripts/` | Build-time helpers, called by `build.sh` and CI. |

Logic goes in `JanusCore` so it can be tested. If a change to the app
target contains a decision worth asserting, that decision probably belongs in
core.

## What a good pull request looks like

- **One change per pull request.** Easier to review and easier to revert.
- **Tests for anything that decides something.** Tests in this repository run
  against a temporary home directory and an in-memory keychain. See
  `Tests/JanusCoreTests/Support.swift`. No test should touch the real
  keychain or the real `~/.claude.json`.
- **Comments that explain why.** The code says what it does. Comments are for the
  reasoning that would otherwise be lost.
- **No new dependencies** without a reason in the pull request description.
  Janus depends on nothing but the system frameworks today, which is a
  large part of why it is auditable.

## Adding a cache target

This is the easiest useful contribution. Add an entry to
`Sources/JanusCore/CacheCatalog.swift`:

```swift
CacheEntry(id: "cargo", name: "Cargo registry",
           note: "Downloaded crate sources, refetched on the next build.",
           path: ".cargo/registry")
```

- `path` is relative to the home directory, always.
- `note` is read by someone who has never used the tool. Say what is lost.
- Set `ownerBundleID` and `clearableWhileRunning: false` if an app holds the
  directory open while it runs.
- The target must be something that regenerates itself. If losing it costs work
  rather than time, it does not belong in this list.

`CacheCatalogTests` asserts every entry passes `TrashPolicy`, so a mistyped path
fails CI rather than someone's afternoon.

## Releases

Versions follow [semantic versioning](https://semver.org). Releases are cut from
`main` by a maintainer:

1. Move the entries under `## [Unreleased]` in `CHANGELOG.md` into a new version
   heading with today's date.
2. Put the same version in `VERSION`.
3. Commit, then tag: `git tag v1.2.0 && git push origin main --tags`.

Pushing the tag runs `.github/workflows/release.yml`, which builds a universal
app, packages a `.dmg` and a `.zip`, and publishes them with checksums. CI
refuses a tag that does not match `VERSION`.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
