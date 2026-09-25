#!/usr/bin/env bash
#
# Prints the CHANGELOG section for one version, for use as release notes.
#
#   scripts/release-notes.sh 1.0.0

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-notes.sh <version>}"

awk -v version="${VERSION}" '
    $0 ~ "^## \\[" version "\\]" { collecting = 1; next }
    collecting && /^## \[/       { exit }
    collecting                   { print }
' CHANGELOG.md | sed '/./,$!d'
