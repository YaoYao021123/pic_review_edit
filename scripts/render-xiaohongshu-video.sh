#!/bin/bash
# Renders docs/marketing/xiaohongshu/video.html to a silent 1080x1920 MP4 (add your voice and clips in an editor),
# or to still frames for checking a scene:
#
#   bash scripts/render-xiaohongshu-video.sh                 # dist/xiaohongshu.mp4, 30 fps
#   bash scripts/render-xiaohongshu-video.sh still 2 8.5 20  # dist/xhs-stills/t-*.png at those seconds
#   FPS=24 JOBS=4 bash scripts/render-xiaohongshu-video.sh
#
# Needs Google Chrome and ffmpeg (brew install ffmpeg). Chrome runs headless, one process per frame.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
html="$root/docs/marketing/xiaohongshu/video.html"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
fps="${FPS:-30}"; jobs="${JOBS:-6}"
[ -x "$chrome" ] || { echo "找不到 Chrome：$chrome（可用 CHROME=路径 指定）" >&2; exit 1; }
# DURS="4,5.2,..." overrides the scene lengths (the audio script passes lengths that fit the narration);
# OUT=path chooses the output file.
total="$(DURS="${DURS:-}" python3 - "$html" <<'EOF'
import os,re,sys
if os.environ.get("DURS"):
    print(sum(float(x) for x in os.environ["DURS"].split(",")))
else:
    print(sum(float(x) for x in re.findall(r'<section class="scene[^>]*data-dur="([\d.]+)"', open(sys.argv[1]).read())))
EOF
)"
out_file="${OUT:-$root/dist/xiaohongshu.mp4}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$root/dist"

source "$root/scripts/lib/render-frame.sh"
export chrome work
render_at() { render_frame "file://$html?render=1&t=$1${DURS:+&dur=$DURS}" "$2"; }   # <time seconds> <output png>
export -f render_at; export html DURS

if [ "${1:-}" = "still" ]; then
  shift; mkdir -p "$root/dist/xhs-stills"
  for t in "$@"; do
    render_at "$t" "$work/raw.png"
    ffmpeg -loglevel error -y -i "$work/raw.png" -vf "crop=1080:1920:0:0" "$root/dist/xhs-stills/t-$t.png"
    echo "dist/xhs-stills/t-$t.png"
  done
  exit 0
fi

frames="$(python3 -c "import math;print(math.ceil($total*$fps))")"
mkdir -p "$work/raw"
echo "渲染 $frames 帧（${total}s × ${fps}fps，并行 $jobs）…"
seq 0 $((frames - 1)) | xargs -P "$jobs" -I{} bash -c 'render_at "$(python3 -c "print(round({}/'"$fps"',4))")" "'"$work"'/raw/$(printf %05d {}).png"'
count="$(ls "$work/raw" | wc -l | tr -d ' ')"
[ "$count" = "$frames" ] || { echo "只渲染了 $count / $frames 帧" >&2; exit 1; }
ffmpeg -loglevel error -y -framerate "$fps" -i "$work/raw/%05d.png" -vf "crop=1080:1920:0:0,format=yuv420p" \
  -c:v libx264 -crf 17 -preset medium -movflags +faststart "$out_file"
ls -la "$out_file" | awk -v f="$out_file" '{print $5/1048576 " MB  " f}'
