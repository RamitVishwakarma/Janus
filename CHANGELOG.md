# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.1] - 2026-10-05

### Fixed

- A signed-in Claude Code account is no longer reported as signed out when a
  `~/.claude/.claude.json` exists. That file is not the live one on a default
  install; it is what Claude Code writes when started with
  `CLAUDE_CONFIG_DIR=~/.claude`, and other tools leave one behind holding only
  caches. Janus now finds the session the way Claude Code does: `~/.claude.json`
  (or `$CLAUDE_CONFIG_DIR/.claude.json`, or a pre-1.0 `.config.json`), with the
  keychain entry under `Claude Code-credentials`, suffixed with the hash of the
  configuration directory when `CLAUDE_CONFIG_DIR` moves it, and the keychain
  account taken from `$USER` as Claude Code takes it.

## [1.2.0] - 2026-09-28

### Added

- A Codex tab, for switching between OpenAI Codex accounts the way the Claude
  tab switches Claude Code ones. The window's tabs are now Claude, Codex and
  Storage. Codex keeps its whole sign-in in `~/.codex/auth.json`, so a switch
  saves that file under the account it belongs to and writes the other
  account's in its place; saved sign-ins live in the login keychain under
  `Janus Codex`. The displaced sign-in is saved again on every switch, because
  Codex rotates its single-use refresh tokens and an older copy stops working.
  The same email in two ChatGPT workspaces is kept as two accounts, and API-key
  sign-ins are supported. Refresh fetches each ChatGPT account's five-hour and
  weekly limits from OpenAI, and a switch made while Codex is running says so,
  since a running Codex can write its old account back. To add a second
  account, delete `~/.codex/auth.json` and run `codex login`. `codex logout`
  revokes the sign-in at OpenAI, which kills the copy Janus just saved.
- The menu bar lists the Codex account alongside the Claude Code one, with a
  one-click switch to the next.
- `~/.codex` is guarded from cache clearing, as `~/.claude` already was.

## [1.1.0] - 2026-09-27

### Added

- Refresh now asks Anthropic for each account's figures rather than only
  re-reading what Claude Code left on disk. A saved account's numbers used to be
  frozen at the moment it was last signed out, because that file is the only
  place they were written and nothing writes to it while the account is parked.
  One request per account, made with the tokens that account already has saved,
  and the line under each pair of bars says whether you are looking at a fetched
  figure or a remembered one. A fetched figure is kept, so it survives the app
  being quit and gives the account a current cache the next time it signs in.
  Expired tokens are renewed first, and what comes back is stored before it is
  used for anything else. The signed-in account is never renewed by Janus: a
  running Claude Code session is holding that token, and Claude Code keeps it
  fresh itself.
- The window keeps its own time. Countdowns run down and a limit that passes its
  reset empties itself while the window sits open, instead of waiting for
  something to force a redraw — a row drawn at nine used to still be claiming
  "resets in 2h 22m" at midnight. A window actually turning over also triggers a
  fetch, since that is the moment the old figure stops describing anything.

## [1.0.1] - 2026-09-26

### Fixed

- Repeated requests for the login keychain password, from Janus and from Claude
  Code alike. Keychain entries carry a partition list naming the code allowed to
  open them, and writing them through the Security framework quietly re-stamped
  that list with Janus's own signature, shutting Claude Code out of its own
  tokens and shutting Janus out again after every rebuild. Entries now go through
  `/usr/bin/security`, which is what Claude Code uses and what leaves them in a
  partition both can reopen. Saved accounts are mended the next time they are
  switched to.
- A switch no longer overwrites the live session when the keychain refuses to
  hand over its tokens. The refusal used to be indistinguishable from nobody
  being signed in, so the switch carried on and the displaced account was left
  needing a fresh sign-in.
- Refresh now folds the signed-in account's figures into its saved copy, so they
  are not lost when it is switched away from, and says what it could and could
  not bring up to date. Only the signed-in account's figures can move, which the
  button now explains rather than leaving people to press it again.
- A limit whose reset has passed no longer reads "resetting now" forever, and no
  longer shows the spend of the window that ended as though it were the current
  one. It is drawn empty with a dash and says "last reset 4h ago"; the weekly
  figure is left alone until its own reset comes round. Claude Code measures only
  while a session is running, so the signed-in account is now told to start one,
  and the help popover explains where the figures come from at all.
- The window comes forward before any operation that can raise a keychain prompt,
  so a prompt drawn behind another app no longer looks like a hung switch, and
  the busy state is cleared on every path out.

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

[Unreleased]: https://github.com/RamitVishwakarma/Janus/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/RamitVishwakarma/Janus/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/RamitVishwakarma/Janus/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/RamitVishwakarma/Janus/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/RamitVishwakarma/Janus/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/RamitVishwakarma/Janus/releases/tag/v1.0.0
