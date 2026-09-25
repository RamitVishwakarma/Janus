## What this changes

<!-- One or two sentences. The diff covers the detail. -->

## Why

<!-- The problem being solved, or the issue this closes: Closes #123 -->

## How it was tested

<!-- Which tests you added, and what you did by hand. "Built it and switched
     between two accounts" is a useful thing to write here. -->

- [ ] `swift test` passes
- [ ] `./build.sh` produces an app that launches

## Checklist

- [ ] One change, not several
- [ ] Logic that decides something lives in `JanusCore` and has a test
- [ ] No test touches the real keychain or the real `~/.claude.json`
- [ ] No new dependencies, or the reason for one is explained above
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` if this is user-visible
