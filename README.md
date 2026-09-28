# Janus

A small macOS app for people who keep more than one Claude Code or Codex
account, and who have noticed how much disk the tools they use every day quietly
hold onto.

[![CI](https://github.com/RamitVishwakarma/Janus/actions/workflows/ci.yml/badge.svg)](https://github.com/RamitVishwakarma/Janus/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RamitVishwakarma/Janus?sort=semver)](https://github.com/RamitVishwakarma/Janus/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey)

![Janus switching between two saved Claude Code accounts](demo/demo.gif)

One click moves the live session, and the account it displaces is saved first.

It does three things, one tab each:

- **Switches Claude Code accounts.** Signing in as another account normally means
  signing out first and typing the whole thing again. Janus saves each
  account's session and puts it back on demand, so the second account is one click
  away instead of one login away.
- **Switches Codex accounts.** The same, for OpenAI's Codex, in a tab of its own.
  See [Codex](#codex).
- **Clears developer caches.** A list of directories that are safe to delete,
  measured and shown with what each one costs to lose. Everything goes to the
  Trash rather than being deleted, so any decision can be taken back.

## Install

With Homebrew:

```sh
brew install --cask --no-quarantine ramitvishwakarma/tap/janus
```

Or download the latest `.dmg` from
[Releases](https://github.com/RamitVishwakarma/Janus/releases/latest), open it,
and drag Janus to Applications. The build is universal, covering Apple silicon
and Intel.

The app is signed ad-hoc rather than with a paid Apple Developer certificate, so
macOS quarantines it on first launch and says the developer cannot be verified.
`--no-quarantine` tells Homebrew to skip that flag. After a download by hand,
clear it once:

```sh
xattr -dr com.apple.quarantine /Applications/Janus.app
open /Applications/Janus.app
```

To have it start with the Mac, add it under System Settings → General → Login
Items, or:

```sh
osascript -e 'tell application "System Events" to make login item \
  at end with properties {path:"/Applications/Janus.app", hidden:true}'
```

### Build it yourself

Needs the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is
not required.

```sh
git clone https://github.com/RamitVishwakarma/Janus.git
cd Janus
./build.sh
open Janus.app
```

## Using it

Janus cannot sign in for you, so the first account has to be signed in
already. Press **Save current account** and it is captured.

For the second: sign out of Claude Code, sign in as the other account, come back,
and press **Save current account** again. From then on both are in the list and
switching between them is one click, or `⌘S` from the menu bar.

![The Janus window, with both accounts and how much of each limit they have spent](demo/screenshot.png)

The menu bar item shows which account is live. The window shows both accounts
with how much of their five-hour and weekly limits each has spent. That is the
number to look at when the decision you are making is *which account has room
left*.

## Where the usage figures come from

Claude Code asks Anthropic for your limits while a session is running and writes
the answer into its own settings file. Janus reads that file for nothing, which
is what every row shows to begin with. For the account that is signed in, those
figures are as current as your last session. For an account that is not, they
are whatever it had spent at the moment you switched away — frozen, and
increasingly wrong the longer it sits there.

**Refresh** goes and asks. It calls Anthropic's usage endpoint once per account,
with the tokens that account already has saved, and shows what comes back. That
is the only network request Janus makes for Claude, it goes nowhere but
`api.anthropic.com` and `platform.claude.com`, and nothing is sent that is not
the account's own credentials. The Codex tab's equivalent is described under
[Codex](#codex). The line under each pair of bars says which of the two you are
looking at, so a fetched figure and a three-day-old one are never confusable.

Two things happen on their own, without the button:

- **The window keeps its own time.** Countdowns tick down and a limit that
  passes its reset empties itself while you are looking at it, rather than
  waiting for the next time something forces a redraw.
- **A window turning over is fetched.** That is the one moment the old figure
  becomes actively misleading — it is the spend of a window that has ended — so
  it is the one moment Janus spends a request without being asked.

A limit past its reset shows a dash until it has been fetched. Guessing at the
replacement would be worse than admitting there isn't one yet.

Saved accounts are renewed as needed: an access token that has expired is
refreshed before the usage request, and the tokens that come back are written
into the vault before anything else is attempted with them. The signed-in
account's token is never renewed by Janus, because a running Claude Code session
is holding it, and rotating it underneath that session is how a sign-in that was
working stops working. Claude Code keeps that one fresh itself.

## How switching works

A signed-in Claude Code session is two things on disk:

| Part | Where it lives |
| --- | --- |
| OAuth tokens | Keychain entry `Claude Code-credentials` |
| Everything else | `~/.claude.json` |

Switching is just moving that pair. Janus copies the live pair into storage
under the account it belongs to, then writes the other account's saved pair into
place. Saved tokens go into the login keychain under the service `Janus`;
saved settings go to `~/Library/Application Support/Janus/`, readable only
by you.

Three things follow from that, and are worth knowing before you trust it:

- **Nothing leaves the Mac except a usage request you asked for.** There is no
  server and no telemetry. The one thing that goes out is Refresh asking
  Anthropic, or OpenAI on the Codex tab, for your own figures with your own
  tokens, described above.
- **The settings file is written back whole.** It belongs to another program and
  gains keys between releases, so Janus parses what it needs and preserves
  everything else byte for byte.
- **Switching does not affect a running session.** Claude Code reads credentials
  at startup, so restart it to pick up the new account.

### If something goes wrong halfway

Every switch fetches the replacement session before it touches anything live, and
saves the session it is about to displace before overwriting it. If a step fails,
say a declined keychain prompt or a missing saved session, the Mac is left signed
into the account it was already signed into.

Signing in outside the app is handled too. If the live account is not one
Janus knows about, it is saved as a new account rather than overwritten,
because those credentials exist nowhere else.

## Codex

The **Codex** tab does for Codex what the Claude tab does for Claude Code. It
works the way [codex-switcher](https://github.com/Lampese/codex-switcher) does,
by swapping one file:

| Part | Where it lives |
| --- | --- |
| The whole sign-in, tokens included | `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) |

Saved sign-ins go into the login keychain under the service `Janus Codex`, one
entry per account holding that account's entire `auth.json`; the list of accounts
is `~/Library/Application Support/Janus/Codex/roster.json`. The live file is
written owner-only (`0600`) and renamed into place, so Codex never reads half of
one.

To add accounts: save the one Codex is signed into, delete `~/.codex/auth.json`,
run `codex login` as the next one, and save that too. Do not use `codex logout`
for this. It revokes the sign-in at OpenAI, so the copy Janus just saved stops
working with it. Deleting the file tells OpenAI nothing. ChatGPT sign-ins are listed by
email with their plan beside it, and the same email in two workspaces, a
personal plan and a team plan say, is two accounts. API-key sign-ins work too,
listed by the key's last four characters.

Things specific to Codex:

- **Quit Codex before switching.** Codex renews its own sign-in every few days
  and writes the result back to `auth.json`. One that is still running keeps the
  account it started with, and can write it back over the one you switched to.
  Janus says so after a switch when it can see Codex running.
- **The displaced sign-in is saved again on every switch.** ChatGPT refresh
  tokens are single-use, and the copy saved when an account was added stops
  working once Codex has renewed it. Saving the live file at the moment it is
  switched away from is what keeps switching back working.
- **Usage comes from Refresh only.** Codex does not write its limits anywhere
  Janus can read them for free, so figures appear when you press Refresh and
  last as long as the app is open. Refresh asks `chatgpt.com` for each
  account's five-hour and weekly limits, the request Codex makes for `/status`,
  renewing a saved account's tokens at `auth.openai.com` first if they have run
  out. The signed-in account is never renewed, for the same reason as on the
  Claude side.
- **Only file-based sign-ins.** If Codex is configured to keep its credentials
  in the keychain (`cli_auth_credentials_store = "keychain"`), there is no
  `auth.json` to swap, and the tab will say nobody is signed in.

## Clearing caches

The Storage tab measures a fixed list of cache directories: package managers,
build caches, browser and editor caches. Two rules keep it boring:

- **Nothing is deleted.** `FileManager.trashItem` moves things to the Trash.
- **Only caches inside your home directory can be touched.** Anything outside it
  is refused, as are the directories everything else lives inside, among them
  `~/Desktop`, `~/Library`, `~/.ssh`, `~/.claude` and `~/.codex`. This is enforced in code,
  not by being careful when editing the list, and there is a test asserting every
  entry in the catalogue passes it.

Caches belonging to a running app are shown greyed out with a **Quit it** link
rather than cleared underneath it. Clearing an editor's cache while the editor
holds files open in it is a good way to confuse the editor.

Some paths, `~/Downloads` and `~/.Trash` among them, are behind macOS privacy
controls. Grant Full Disk Access in System Settings → Privacy & Security if you
want them covered.

### Adding a cache to the list

Add an entry to `CacheEntry.developerTools` or `CacheEntry.applications` in
[`Sources/JanusCore/CacheCatalog.swift`](Sources/JanusCore/CacheCatalog.swift):

```swift
CacheEntry(id: "cargo", name: "Cargo registry",
           note: "Downloaded crate sources, refetched on the next build.",
           path: ".cargo/registry")
```

Paths are relative to the home directory. Entries that do not exist on a given
Mac are filtered out when scanning, so listing something niche costs nothing.

## Known limitations

- **Ad-hoc signed.** Every build produces a different signature, so macOS treats
  each new version as a new app and may ask for keychain permission again after
  an update. Signing with a self-signed certificate from Keychain Access gives a
  stable identity if that becomes annoying.
- **Not sandboxed.** The App Sandbox would cut the app off from the keychain entry
  and settings file it exists to move, which also means it cannot ship on the App
  Store.
- **macOS only.** Both halves of a session are stored in macOS-specific places.

## Development

```sh
swift build          # build
swift test           # run the tests (needs Xcode for XCTest)
./build.sh           # assemble Janus.app
```

The code is split so the interesting half can be tested without a window on
screen:

| Target | What is in it |
| --- | --- |
| `JanusCore` | Sessions, storage, the switch itself, the cache catalogue and its safety rules. No SwiftUI. |
| `Janus` | The SwiftUI window, the menu bar item, and the models behind them. |
| `JanusCoreTests` | Everything in `JanusCore`, against a temporary home directory and an in-memory keychain. |

`swift build` needs only the Command Line Tools; `swift test` needs XCTest, which
ships with Xcode. CI runs the tests on every push and pull request.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
Security reports have their own route in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).

Janus is not affiliated with, endorsed by, or supported by Anthropic. It
reads and writes files and keychain entries belonging to Claude Code, which is a
product of Anthropic.
