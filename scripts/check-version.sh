#!/usr/bin/env bash
#
# Fails if VERSION, CHANGELOG.md and (when releasing) the git tag disagree.
# A release that ships one version while claiming another is worse than no release.
#
#   scripts/check-version.sh            check VERSION against the changelog
#   scripts/check-version.sh v1.2.0     also check the tag matches

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"

if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "VERSION is '${VERSION}', which is not a semantic version." >&2
    exit 1
fi

if ! grep -q "^## \[${VERSION}\] - " CHANGELOG.md; then
    echo "CHANGELOG.md has no released section for ${VERSION}." >&2
    echo "Add a '## [${VERSION}] - YYYY-MM-DD' heading before releasing." >&2
    exit 1
fi

if [[ -n "${1:-}" ]]; then
    TAG="${1#refs/tags/}"
    if [[ "${TAG}" != "v${VERSION}" ]]; then
        echo "Tag ${TAG} does not match VERSION ${VERSION} (expected v${VERSION})." >&2
        exit 1
    fi
fi

echo "Version ${VERSION} is consistent."
