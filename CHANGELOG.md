# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Regression tests pinning down that reordering the rotation never alters, drops
  or duplicates a saved account. Accounts are keyed by UUID rather than by
  position, so their place in the list is not part of how they are stored.

## [1.0.0] - 2026-09-25

First public release.

### Added

- Switch between saved Claude Code accounts from a window or the menu bar, with
  the live session swapped in place and the displaced one saved automatically.
- Save the signed-in account with one press; an account signed in outside the app
  is adopted rather than overwritten when switching away from it.
- Per-account five-hour and weekly limit usage, read from the settings file
  Claude Code writes, with saved accounts labelled by when their figures were
  taken.
- A reorderable rotation, so `⌘S` from the menu bar moves through accounts in the
  order you choose.
- A storage tab that measures a catalogue of developer and application caches and
  moves the selected ones to the Trash, refusing anything outside the home
  directory and anything held open by a running app.
- Universal builds published as a `.dmg` and a `.zip` with SHA-256 checksums.

[Unreleased]: https://github.com/RamitVishwakarma/Janus/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/RamitVishwakarma/Janus/releases/tag/v1.0.0
