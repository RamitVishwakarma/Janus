#!/usr/bin/env bash
#
# Records the Janus window for a fixed number of seconds, then hands the
# recording to make-demo.sh. Open the Janus window first, run this, and click
# Switch when it says to.
#
#   scripts/record-demo.sh [seconds]
#
# Recording stops on its own, so nothing has to be done with the keyboard while
# the window is on camera.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="demo"
SECONDS_TO_RECORD="${1:-8}"
PAD=12   # points of breathing room around the window

mkdir -p "${OUT}"

pgrep -qf "Janus.app/Contents/MacOS/Janus" || {
    echo "Janus is not running. Start it, then open its window from the menu bar." >&2
    exit 1
}

# System Events reports the window in points, which is what -R wants. It only
# reports a window that is actually open, so this doubles as the check that
# there is something to film.
BOUNDS="$(osascript -e 'tell application "System Events" to tell process "Janus" to get {position, size} of window 1' 2>/dev/null || true)"
[[ -n "${BOUNDS}" ]] || {
    echo "No Janus window is open. Click the menu bar item to show it, then run this again." >&2
    exit 1
}

IFS=', ' read -r X Y W H <<< "${BOUNDS}"
X=$((X - PAD)); Y=$((Y - PAD)); W=$((W + PAD * 2)); H=$((H + PAD * 2))
(( X < 0 )) && X=0
(( Y < 0 )) && Y=0

RAW="${OUT}/recording.mov"
rm -f "${RAW}"

echo "==> Filming ${W}x${H} at ${X},${Y} for ${SECONDS_TO_RECORD}s"
echo
echo "    Move the pointer onto the window now."
for n in 3 2 1; do printf "\r    starting in %s " "${n}"; sleep 1; done
printf "\r    GO. Click Switch on the second account, then hold still.\n"

# -C keeps the pointer in frame, which is what makes the click legible.
screencapture -v -C -V "${SECONDS_TO_RECORD}" -R"${X},${Y},${W},${H}" "${RAW}"

echo
echo "==> ${RAW}"
scripts/make-demo.sh probe "${RAW}"
echo
echo "    Happy with the take? Blur the addresses and render both assets:"
echo "    scripts/make-demo.sh render ${RAW} <region> [region ...]"
echo "    Not happy? Run this again, it overwrites."
