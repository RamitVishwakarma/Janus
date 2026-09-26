# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private reporting instead:
[Report a vulnerability](https://github.com/RamitVishwakarma/Janus/security/advisories/new).
If that is unavailable to you, open an issue saying only that you have a security
report and asking for a contact address, with no details.

Expect an acknowledgement within a week, and an estimate of a fix once the report
is confirmed. Credit in the release notes is offered unless you would rather not
have it.

## Supported versions

Fixes are made on the latest release. There are no long-term support branches.

## What Janus touches

Useful context for anyone assessing a report. The app:

- **Reads and writes the keychain entry `Claude Code-credentials`**, which holds
  the OAuth tokens for the signed-in Claude Code account. This is the entry being
  swapped, and is the whole point of the app.
- **Reaches every keychain entry by running `/usr/bin/security`** rather than by
  calling the Security framework directly. Entries carry a partition list naming
  the code that may open them without a prompt, and macOS fills it in with the
  signature of whichever program created the entry. Creating them from Janus
  would partition them to Janus, locking Claude Code out of its own tokens, and
  Janus out of them again after its next build, since it is signed ad-hoc and its
  signature changes each time. Going through `security` puts them in the
  `apple-tool:` partition, which is where Claude Code writes its own. The payload
  is passed to `security` as a hex argument, because it reads at most 128 bytes
  from standard input and a session is several times that; process arguments are
  visible to other processes of the same user, and to root, for as long as that
  one-shot call lives.
- **Reads and writes `~/.claude.json`** (or `~/.claude/.claude.json`, if that is
  where the installed Claude Code keeps it).
- **Stores saved sessions** as keychain entries under the service `Janus`,
  and files in `~/Library/Application Support/Janus/` created with mode
  `0600` inside a directory created with mode `0700`.
- **Moves cache directories to the Trash**, restricted to paths inside the user's
  home directory that pass `TrashPolicy` in
  `Sources/JanusCore/Reclaim.swift`. Nothing is deleted outright.
- **Runs two external commands**, `/usr/bin/security` and `/usr/bin/du`, both by
  absolute path and with no shell.

The app makes no network requests. There is no networking code in the repository,
and usage figures shown in the interface are read from the settings file Claude
Code writes rather than fetched from anywhere.

The app is deliberately not sandboxed, because the App Sandbox would block the
keychain entry and settings file it exists to move. It is signed ad-hoc rather
than with an Apple Developer certificate.

## Things that are known and are not bugs

- **Saved sessions are recoverable by anyone who can unlock your login keychain.**
  That is the same bar as the credentials Claude Code stores on its own, and for
  the same reason: they sit in the same partition, reachable by the same tool.
- **A saved settings snapshot contains whatever `~/.claude.json` contained**,
  including project paths and history. It is stored with owner-only permissions
  but is not separately encrypted.
- **Removing an account deletes its saved session immediately** and does not send
  it to the Trash. This is intentional, because leaving credentials in the Trash
  would be worse.
