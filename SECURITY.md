# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private reporting instead:
[Report a vulnerability](https://github.com/RamitVishwakarma/Switchboard/security/advisories/new).
If that is unavailable to you, open an issue saying only that you have a security
report and asking for a contact address — no details.

Expect an acknowledgement within a week, and an estimate of a fix once the report
is confirmed. Credit in the release notes is offered unless you would rather not
have it.

## Supported versions

Fixes are made on the latest release. There are no long-term support branches.

## What Switchboard touches

Useful context for anyone assessing a report. The app:

- **Reads and writes the keychain entry `Claude Code-credentials`**, which holds
  the OAuth tokens for the signed-in Claude Code account. This is the entry being
  swapped, and is the whole point of the app.
- **Reads and writes `~/.claude.json`** (or `~/.claude/.claude.json`, if that is
  where the installed Claude Code keeps it).
- **Stores saved sessions** as keychain entries under the service `Switchboard`,
  and files in `~/Library/Application Support/Switchboard/` created with mode
  `0600` inside a directory created with mode `0700`.
- **Moves cache directories to the Trash**, restricted to paths inside the user's
  home directory that pass `TrashPolicy` in
  `Sources/SwitchboardCore/Reclaim.swift`. Nothing is deleted outright.
- **Runs one external command**, `/usr/bin/du`, by absolute path and with no
  shell, to measure directory sizes.

The app makes no network requests. There is no networking code in the repository,
and usage figures shown in the interface are read from the settings file Claude
Code writes rather than fetched from anywhere.

The app is deliberately not sandboxed — the App Sandbox would block the keychain
entry and settings file it exists to move — and is signed ad-hoc rather than with
an Apple Developer certificate.

## Things that are known and are not bugs

- **Saved sessions are recoverable by anyone who can unlock your login keychain.**
  That is the same bar as the credentials Claude Code stores on its own.
- **A saved settings snapshot contains whatever `~/.claude.json` contained**,
  including project paths and history. It is stored with owner-only permissions
  but is not separately encrypted.
- **Removing an account deletes its saved session immediately** and does not send
  it to the Trash. This is intentional — leaving credentials in the Trash would be
  worse.
