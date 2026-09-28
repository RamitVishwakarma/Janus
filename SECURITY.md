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
- **Reads and writes `~/.codex/auth.json`** (or `$CODEX_HOME/auth.json`), which
  holds the signed-in Codex account's tokens or API key. Written to a new file
  created with mode `0600` and renamed into place.
- **Stores saved Codex sign-ins** as keychain entries under the service
  `Janus Codex`, each holding one account's whole `auth.json`, with the list of
  accounts in `~/Library/Application Support/Janus/Codex/roster.json`.
- **Stores saved sessions** as keychain entries under the service `Janus`,
  and files in `~/Library/Application Support/Janus/` created with mode
  `0600` inside a directory created with mode `0700`.
- **Moves cache directories to the Trash**, restricted to paths inside the user's
  home directory that pass `TrashPolicy` in
  `Sources/JanusCore/Reclaim.swift`. Nothing is deleted outright.
- **Runs three external commands**, `/usr/bin/security`, `/usr/bin/du` and
  `/usr/bin/pgrep` (to tell whether Codex is running), all by absolute path and
  with no shell.

The only network requests are the usage fetches: to `api.anthropic.com` and
`platform.claude.com` for Claude Code accounts, and to `chatgpt.com` and
`auth.openai.com` for Codex accounts, each made with that account's own tokens.
The Codex request carries a browser `User-Agent`, as codex-switcher's does,
because `chatgpt.com` challenges anything else.

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
