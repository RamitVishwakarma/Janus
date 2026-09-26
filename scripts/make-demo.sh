#!/usr/bin/env bash
#
# Turns a screen recording of Janus into the two assets a launch needs: an
# optimised GIF for the README, and an H.264 video for everywhere that would
# rather have one. Regions can be blurred on the way through, which is how the
# account addresses stay out of the published version.
#
# Find the regions to blur, reading them off the 100px grid:
#
#   scripts/make-demo.sh probe recording.mov
#
# Then render, passing any number of regions as WxH+X+Y:
#
#   scripts/make-demo.sh render recording.mov 320x40+193+205 360x40+193+398

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="demo"
WIDTH="${JANUS_DEMO_WIDTH:-900}"   # GIF width; 900 reads well on GitHub and X
FPS="${JANUS_DEMO_FPS:-15}"
BLUR="${JANUS_DEMO_BLUR:-24}"

usage() { sed -n '3,14p' "$0" | sed 's|^#\{1,\} \{0,1\}||'; exit 1; }

command -v ffmpeg >/dev/null || { echo "ffmpeg is not installed: brew install ffmpeg" >&2; exit 1; }

MODE="${1:-}"
INPUT="${2:-}"
[[ -n "${MODE}" && -n "${INPUT}" ]] || usage
[[ -f "${INPUT}" ]] || { echo "No such recording: ${INPUT}" >&2; exit 1; }

mkdir -p "${OUT}"

# A frame with a grid over it, so the blur regions can be read off by eye
# rather than guessed at.
if [[ "${MODE}" == "probe" ]]; then
    ffmpeg -v error -y -i "${INPUT}" \
        -vf "drawgrid=w=100:h=100:t=1:c=red@0.5,drawgrid=w=500:h=500:t=2:c=yellow@0.8" \
        -frames:v 1 "${OUT}/probe.png"
    ffprobe -v error -show_entries stream=width,height -of csv=p=0 "${INPUT}" \
        | awk -F, '{print "==> recording is " $1 "x" $2 "; thin grid 100px, thick 500px"}'
    echo "    open ${OUT}/probe.png, read off each region to hide as WxH+X+Y, then:"
    echo "    scripts/make-demo.sh render ${INPUT} <region> [region ...]"
    exit 0
fi

[[ "${MODE}" == "render" ]] || { echo "Unknown mode: ${MODE} (expected probe or render)" >&2; exit 1; }

shift 2
REGIONS=("$@")

# Each region is cropped out of a copy of the frame, blurred, and laid back
# over the top, as one filter graph so the video is only decoded once. The
# last overlay is left unlabelled: that makes it the graph's output, so the
# scale and palette stages can be appended with a comma.
build_hide_chain() {
    local n=${#REGIONS[@]} i chain prev="base"
    if [[ ${n} -eq 0 ]]; then echo "null"; return; fi

    chain="split=$((n + 1))[base]"
    for ((i = 0; i < n; i++)); do chain+="[r${i}]"; done
    chain+=";"

    for ((i = 0; i < n; i++)); do
        local spec="${REGIONS[$i]}" w h x y
        [[ "${spec}" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] || {
            echo "Bad region '${spec}', expected WxH+X+Y" >&2; exit 1; }
        w="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}"
        x="${BASH_REMATCH[3]}" y="${BASH_REMATCH[4]}"
        # boxblur's radius has to stay inside the plane, and the chroma
        # planes are half-size, so both are clamped to the region.
        local short=$(( w < h ? w : h )) lr cr
        lr=$(( short / 2 - 2 )); (( lr > BLUR )) && lr=${BLUR}; (( lr < 1 )) && lr=1
        cr=$(( short / 4 - 2 )); (( cr > BLUR )) && cr=${BLUR}; (( cr < 1 )) && cr=1
        chain+="[r${i}]crop=${w}:${h}:${x}:${y},"
        chain+="boxblur=luma_radius=${lr}:luma_power=2:chroma_radius=${cr}:chroma_power=2[b${i}];"
        chain+="[${prev}][b${i}]overlay=${x}:${y}"
        if ((i < n - 1)); then chain+="[o${i}];"; prev="o${i}"; fi
    done
    echo "${chain}"
}

HIDE="$(build_hide_chain)"

echo "==> Video"
ffmpeg -v error -y -i "${INPUT}" \
    -vf "${HIDE},scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos" \
    -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -an \
    -movflags +faststart "${OUT}/demo.mp4"

echo "==> GIF"
# Two passes: one to pick a palette from the frames that actually change, one
# to apply it. A single pass bands visibly across the usage bars.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
ffmpeg -v error -y -i "${INPUT}" \
    -vf "${HIDE},fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=192" \
    "${TMP}/palette.png"
ffmpeg -v error -y -i "${INPUT}" -i "${TMP}/palette.png" \
    -lavfi "${HIDE},fps=${FPS},scale=${WIDTH}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 "${OUT}/demo.gif"

echo
ls -lh "${OUT}"/demo.* | awk '{print "    " $9 "  " $5}'
if [[ $(stat -f%z "${OUT}/demo.gif") -gt 10485760 ]]; then
    echo "    Over 10MB; GitHub stalls on those. Try JANUS_DEMO_WIDTH=700 or a shorter take."
fi
