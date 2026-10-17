#!/bin/bash
# Renders docs/marketing/xiaohongshu/slides.html (1080x1440 cards, picture in the middle, words underneath) to
#
#   dist/xhs-slides/01.jpg …           plain images (the finished card)
#   dist/xhs-slides/live/01.jpg + 01.mov …   Live Photo pairs (3 s of motion, cover = the finished card)
#
#   bash scripts/render-xiaohongshu-slides.sh            # everything
#   bash scripts/render-xiaohongshu-slides.sh stills     # only the plain images (fast)
#   bash scripts/render-xiaohongshu-slides.sh still 3 0.8   # card 3 at 0.8 s, to check motion
#
# Needs Google Chrome and ffmpeg. Live pairs go through the app's own Live Photo code (media-probe live),
# which also runs the system's pairing check.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
html="$root/docs/marketing/xiaohongshu/slides.html"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
fps="${FPS:-30}"; jobs="${JOBS:-6}"; seconds=3
[ -x "$chrome" ] || { echo "找不到 Chrome：$chrome（可用 CHROME=路径 指定）" >&2; exit 1; }
n="$(grep -c '^<div class="cell"><section' "$html")"
out="$root/dist/xhs-slides"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

source "$root/scripts/lib/render-frame.sh"
export CHROME_HEIGHT=1527                      # a 1440-high picture plus the height Chrome reserves
export chrome work html
card() { render_frame "file://$html?render=1&slide=$1&t=$2" "$3"; }   # <card> <seconds> <png>
export -f card

if [ "${1:-}" = "still" ]; then               # one card at one moment
  card "${2:?card number}" "${3:?seconds}" "$work/raw.png"
  ffmpeg -loglevel error -y -i "$work/raw.png" -vf "crop=1080:1440:0:0" "$out/check-$2-$3.png"; echo "$out/check-$2-$3.png"; exit 0
fi

echo "渲染 $n 张静态卡片…"
mkdir -p "$work/still"
seq 1 "$n" | xargs -P "$jobs" -I{} bash -c 'card {} 3 "'"$work"'/still/$(printf %02d {}).png"'
for f in "$work"/still/*.png; do
  ffmpeg -loglevel error -y -i "$f" -vf "crop=1080:1440:0:0" -q:v 2 "$out/$(basename "${f%.png}").jpg"
done
[ "${1:-}" = "stills" ] && { echo "$out"; exit 0; }

frames=$((seconds * fps))
echo "渲染 $n × $frames 帧动态（并行 $jobs）…"
mkdir -p "$work/frames"
for i in $(seq 1 "$n"); do for f in $(seq 0 $((frames - 1))); do echo "$i $f"; done; done |
  xargs -P "$jobs" -L1 bash -c 't=$(awk -v f="$2" -v r="'"$fps"'" "BEGIN{printf \"%.4f\", f/r}"); card "$1" "$t" "'"$work"'/frames/$(printf %02d "$1")-$(printf %03d "$2").png"' _
[ "$(ls "$work/frames" | wc -l | tr -d ' ')" = "$((n * frames))" ] || { echo "有帧没渲染出来" >&2; exit 1; }

echo "合成 Live Photo…"
mkdir -p "$out/live"; rm -f "$out/live"/*
(cd "$root" && swift build --product media-probe -q 2>/dev/null)
probe="$(cd "$root" && swift build --product media-probe --show-bin-path 2>/dev/null)/media-probe"
for i in $(seq -f %02g 1 "$n"); do
  ffmpeg -loglevel error -y -framerate "$fps" -i "$work/frames/$i-%03d.png" -vf "crop=1080:1440:0:0,format=yuv420p" \
    -c:v libx264 -crf 16 -preset medium "$work/motion-$i.mp4"
  "$probe" live "$work/motion-$i.mp4" "$work/live-$i" 2.8 >/dev/null
  mv "$work/live-$i/LivePhoto.jpg" "$out/live/$i.jpg"; mv "$work/live-$i/LivePhoto.mov" "$out/live/$i.mov"
done
echo "$out  （静态：*.jpg，实况：live/）"
