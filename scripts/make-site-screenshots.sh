#!/bin/bash
# Regenerates the website's screenshots from the app's own snapshot mode (no screen-recording
# permission needed).
#
#   bash scripts/make-site-screenshots.sh <folder-of-demo-photos> <hero-photo> [video] [before-after-photo]
#
# Optional settings (environment):
#   SHOT_LANG=en         English interface; pictures go to website/assets/en (Chinese: website/assets)
#   SKY_PHOTO=<photo>    a photo with sky, for the local-gradient screenshot and before / after pair
#   MATCH_REFERENCE=<photo>  the reference for the "match colors" pair (default: SKY_PHOTO); the hero is matched to it
#   SIMILAR_DIR=<folder> near-duplicate shots, for the "Similar & Bursts" view
#   COMPARE_FILES=a.jpg,b.jpg,c.jpg  photos for the side-by-side compare sheet
#   REMOVE_RECIPE=<recipe.json>  a Remove layer for SKY_PHOTO, for the "Remove" before / after pair
#                        (scripts/site-remove.json paints out the sign in the published sunset photo)
# The before / after pairs and the README GIFs (no text in them) are shared by both languages.
#
# The demo photos are shown publicly, so use pictures you have the right to publish (landscapes,
# not portraits). Snapshots draw Liquid Glass with its flat fallback and cannot capture video frames;
# replace website/assets/shot-edit.jpg with a real screen capture if you want the glass look.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
demo="${1:?demo photo folder}"; hero="${2:?hero photo}"; video="${3:-}"; compare_photo="${4:-$hero}"
# Fail before touching anything: a missing photo must never overwrite the website's pictures with empty ones.
[ -n "$(ls "$demo"/*.jpg 2>/dev/null)" ] || { echo "示例照片文件夹里没有 .jpg：$demo" >&2; exit 1; }
for f in "$hero" "$compare_photo" ${video:+"$video"}; do [ -f "$f" ] || { echo "找不到文件：$f" >&2; exit 1; }; done
lang="${SHOT_LANG:-zh}"
shared="$root/website/assets"; site="$shared"; [ "$lang" = en ] && site="$shared/en"
# Section titles are localized, and the snapshot "collapse:" command takes the visible title.
if [ "$lang" = en ]; then t_file="File"; t_presets="Presets"; t_adjust="Adjustments"; lang_args=(-AppleLanguages "(en)")
else t_file="文件"; t_presets="预设"; t_adjust="调整"; lang_args=(-AppleLanguages "(zh-Hans)"); fi
for f in ${SKY_PHOTO:+"$SKY_PHOTO"} ${MATCH_REFERENCE:+"$MATCH_REFERENCE"}; do [ -f "$f" ] || { echo "找不到文件：$f" >&2; exit 1; }; done
work="$(mktemp -d)"; out="$work/out"; shots="$work/shots"; crops="$work/crops"
mkdir -p "$out" "$shots" "$crops"
bin="$(bash scripts/dev-build.sh | tail -1)"
# The app restores its last window and split-view sizes; start from the defaults so the layout (and so the crops
# below) is the same every time.
for key in "NSWindow Frame workbench" "NSSplitView Subview Frames workbench, SidebarNavigationSplitView"; do
  defaults delete media-workbench "$key" 2>/dev/null || true
done
# Collapsed inspector sections are remembered too; start with everything open.
defaults export media-workbench - 2>/dev/null | python3 -c "
import plistlib, subprocess, sys
data = sys.stdin.buffer.read()
for key in (plistlib.loads(data) if data else {}):
    if key.startswith('section.collapsed.'): subprocess.run(['defaults', 'delete', 'media-workbench', key])
" || true
imports="$demo${video:+,$video}"

run() { # steps
  GUANGJI_DATA_DIR="${2:-$work/data}" GUANGJI_SNAPSHOT_DIR="$shots" GUANGJI_SNAPSHOT_STEPS="$1" "$bin" "${lang_args[@]}" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 120); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
}

# Browse grid, then the hero photo after 自动, presets, the 构图 tab with a square crop, the 学习 tab. Each window shot
# is paired with a panel render of the same inspector state (see with_panel below).
run "size:1470x836;import:$imports;wait:12;shot:browse;open:$hero;tab:color;colormode:simple;wait:4;auto;wait:8;shot:edit;\
panel:presets@800;crop:0.9,30,0,1;tab:geometry;wait:3;panel:geometry@800;shot:crop;tab:learn;wait:2;panel:learn@1150;quit"
[ -n "$video" ] && run "open:$video;tab:info;collapse:$t_file;wait:6;panel:info@1100;quit"
run "open:$hero;wait:3;sheet:export;wait:2;shot:export;quit"
# Local adjustments: a gradient that darkens the sky (the same values as the sky before / after pair below).
sky_layer="start=0.5,0|end=0.5,0.52|exposure=-0.7|highlights=-45|saturation=18|contrast=12"
[ -n "${SKY_PHOTO:-}" ] && run "size:1470x836;open:$SKY_PHOTO;tab:color;colormode:simple;collapse:$t_presets;collapse:$t_adjust;wait:4;\
local:linear;localset:$sky_layer;wait:5;shot:local;panel:local-panel@1100;quit" "$work/data-local"
# A project: every demo photo in one project sharing one look, evened out.
if [ "$lang" = en ]; then project_name="Grassland trip"; else project_name="草原之行"; fi
run "size:1470x836;import:$demo;wait:8;open:$hero;wait:3;adjust:vibrance=18;adjust:contrast=8;wait:2;mode:browse;selectall;\
newproject:$project_name;wait:4;evenout;wait:15;select:$hero;wait:2;shot:project;quit" "$work/data-project"
# Similar shots and bursts, and the side-by-side compare sheet.
[ -n "${SIMILAR_DIR:-}" ] && run "size:1470x836;import:$SIMILAR_DIR;wait:8;groups:on;wait:10;shot:similar;\
${COMPARE_FILES:+compare:$COMPARE_FILES;wait:6;shot:compare;}quit" "$work/data-similar"

# The crops below assume a 1470 x 836 pt window (2940 x 1672 px). Stop here rather than crop the wrong thing.
for f in edit crop browse ${SKY_PHOTO:+local} ${SIMILAR_DIR:+similar}; do
  got="$(sips -g pixelWidth -g pixelHeight "$shots/$f.png" | awk '/pixel/{printf "%sx", $2}')"
  [ "$got" = "2940x1672x" ] || { echo "$f.png 的尺寸是 ${got%x}，应为 2940x1672（窗口大小没有生效）" >&2; exit 1; }
done
jpg() { sips -s format jpeg -s formatOptions 90 "$1" --out "$2" >/dev/null 2>&1; }
# Crops keep full widths and cut panels at section boundaries (a cut through a list looks broken).
# Note: sips treats "--cropOffset 0 0" as "no offset" and crops from the CENTER, so top-aligned crops use 1 0.
# Window shots lose the title bar (its glass controls can't be captured) and the status bar.
# The window capture can't draw the secondary text on the inspector's translucent material in every build (the labels
# come out near-black), so the inspector column is replaced by the same panel rendered in its own window, where the text
# is drawn correctly. Where the column starts is measured in each capture (the canvas background is darker than the
# inspector's) and the panel render is scaled to the column's real width, so nothing is guessed.
PANEL_DY=16
inspector_x() { # <window.png> -> x where the inspector column starts
  ffmpeg -loglevel error -y -i "$1" -vf "crop=2940:1200:0:300,format=gray" -f rawvideo -pix_fmt gray - |
    python3 -c "
import sys
data = sys.stdin.buffer.read()
rows = [data[y * 2940:(y + 1) * 2940] for y in range(0, 1200, 25)]
# In each row the inspector starts just after the last dark (canvas) pixel. A dark control inside the
# inspector (a slider track, a histogram) can only push that further right, so the leftmost answer
# over many rows is the column's real edge.
edges = [max(i for i in range(2000, 2940) if row[i] < 24) + 1 for row in rows if any(row[i] < 24 for i in range(2000, 2940))]
print(min(edges) if edges else '')"
}
with_panel() { # <window.png> <panel.png> <window x offset kept on the left> <out.png>
  local x; x="$(inspector_x "$1")"
  [ -n "$x" ] && [ "$x" -gt 2100 ] && [ "$x" -lt 2700 ] || { echo "找不到检查器的左边界：$1（x=$x）" >&2; return 1; }
  local width=$((2940 - x)) left=$((x - $3))
  ffmpeg -loglevel error -y -i "$1" -i "$2" -filter_complex \
    "[0:v]crop=${left}:1514:$3:104[l];[1:v]scale=${width}:-2,crop=${width}:1514:0:${PANEL_DY}[r];[l][r]hstack" "$4"
}
with_panel "$shots/edit.png" "$shots/presets.png" 0 "$crops/edit.png"; jpg "$crops/edit.png" "$out/shot-edit.jpg"
# Without the sidebar the picture and the inspector can be shown larger on the page.
with_panel "$shots/crop.png" "$shots/geometry.png" 525 "$crops/crop.png"; jpg "$crops/crop.png" "$out/shot-crop.jpg"
sips -c 960 2415 --cropOffset 104 525 "$shots/browse.png" --out "$crops/browse.png" >/dev/null; jpg "$crops/browse.png" "$out/shot-browse.jpg"
sips -c 880 660 --cropOffset 1 0 "$shots/presets.png" --out "$crops/presets.png" >/dev/null; jpg "$crops/presets.png" "$out/panel-presets.jpg"
sips -c 870 660 --cropOffset 1 0 "$shots/learn.png" --out "$crops/learn.png" >/dev/null; jpg "$crops/learn.png" "$out/panel-learn.jpg"
[ -f "$shots/info.png" ] && { sips -c 1330 660 --cropOffset 1 0 "$shots/info.png" --out "$crops/info.png" >/dev/null; jpg "$crops/info.png" "$out/panel-info.jpg"; }
jpg "$shots/export.png" "$out/sheet-export.jpg"
if [ -n "${SKY_PHOTO:-}" ]; then
  with_panel "$shots/local.png" "$shots/local-panel.png" 525 "$crops/local.png"; jpg "$crops/local.png" "$out/shot-local.jpg"
fi
# The project view keeps the sidebar, where the projects are listed.
[ -f "$shots/project.png" ] && { sips -c 1100 2938 --cropOffset 104 1 "$shots/project.png" --out "$crops/project.png" >/dev/null; jpg "$crops/project.png" "$out/shot-project.jpg"; }
[ -f "$shots/similar.png" ] && { sips -c 960 2415 --cropOffset 104 525 "$shots/similar.png" --out "$crops/similar.png" >/dev/null; jpg "$crops/similar.png" "$out/shot-similar.jpg"; }
[ -f "$shots/compare.png" ] && jpg "$shots/compare.png" "$out/sheet-compare.jpg"

# The before / after pair is the engine's real 自动 result (left = before).
cmp="$work/cmp.jpg"
swift run --quiet media-probe auto "$compare_photo" "$cmp" >/dev/null
w=$(sips -g pixelWidth "$cmp" | awk '/pixelWidth/{print $2}'); h=$(sips -g pixelHeight "$cmp" | awk '/pixelHeight/{print $2}')
half=$(( (w - 8) / 2 ))
sips -c "$h" "$half" --cropOffset 0 1 "$cmp" --out "$out/before.jpg" >/dev/null
sips -c "$h" "$half" --cropOffset 0 $((half + 8)) "$cmp" --out "$out/after.jpg" >/dev/null

# More before / after pairs, rendered by the engine at full quality: a sky gradient and "match colors".
pairs="$work/pairs"; mkdir -p "$pairs"
if [ -n "${SKY_PHOTO:-}" ]; then
  printf '{"version": 2, "locals": [{"shape": "linear", "start": [0.5, 0], "end": [0.5, 0.52], "adjustments": {"exposure": -0.7, "highlights": -45, "saturation": 18, "contrast": 12}}]}' > "$work/sky.json"
  swift run --quiet media-probe render "$SKY_PHOTO" - "$pairs/sky-before.jpg" 1280 >/dev/null
  swift run --quiet media-probe render "$SKY_PHOTO" "$work/sky.json" "$pairs/sky-after.jpg" 1280 >/dev/null
  swift run --quiet media-probe render "$hero" - "$pairs/match-before.jpg" 1280 >/dev/null
  swift run --quiet media-probe match "$hero" "${MATCH_REFERENCE:-$SKY_PHOTO}" "$pairs/match-after.jpg" 1280 >/dev/null
  sips -Z 640 "${MATCH_REFERENCE:-$SKY_PHOTO}" --out "$pairs/match-reference.jpg" >/dev/null
  [ -n "${REMOVE_RECIPE:-}" ] && swift run --quiet media-probe render "$SKY_PHOTO" "$REMOVE_RECIPE" "$pairs/remove-after.jpg" 1280 >/dev/null
fi
# README GIFs: GitHub can't run the website's drag slider, so the divider sweeps by itself.
sweep() { # <before> <after> <out.gif>
  # Ordered (Bayer) dithering keeps each GIF around 0.5 MB instead of 3–4 MB.
  # The white divider is drawn by the same expression (drawbox's "t" is its border thickness, not time).
  ffmpeg -loglevel error -y -loop 1 -t 6 -framerate 12 -i "$1" -loop 1 -t 6 -framerate 12 -i "$2" -filter_complex \
    "[0]scale=640:-2,format=gbrp[a];[1]scale=640:-2,format=gbrp[b];\
     [a][b]blend=all_expr='if(lt(abs(X-W*(0.5-0.4*cos(2*PI*T/6))),1.5),245,if(lt(X,W*(0.5-0.4*cos(2*PI*T/6))),A,B))',\
     split[s0][s1];[s0]palettegen=max_colors=128:stats_mode=full[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" "$3"
}
cp "$out/before.jpg" "$out/after.jpg" "$pairs/" 2>/dev/null || true
[ -s "$pairs/before.jpg" ] && sweep "$pairs/before.jpg" "$pairs/after.jpg" "$pairs/compare-auto.gif"
[ -s "$pairs/sky-after.jpg" ] && sweep "$pairs/sky-before.jpg" "$pairs/sky-after.jpg" "$pairs/compare-sky.gif"
[ -s "$pairs/match-after.jpg" ] && sweep "$pairs/match-before.jpg" "$pairs/match-after.jpg" "$pairs/compare-match.gif"
[ -s "$pairs/remove-after.jpg" ] && sweep "$pairs/sky-before.jpg" "$pairs/remove-after.jpg" "$pairs/compare-remove.gif"

# Only now replace the website's images, and only if every one was produced.
for f in shot-edit shot-crop shot-browse; do [ -s "$out/$f.jpg" ] || { echo "没有生成 $f.jpg，网站图片保持不变" >&2; exit 1; }; done
mkdir -p "$site"
# The Auto pair is language-independent: it lives once in website/assets.
for f in "$out"/*.jpg; do case "$(basename "$f")" in before.jpg|after.jpg) cp -f "$f" "$shared"/ ;; *) cp -f "$f" "$site"/ ;; esac; done
cp -f "$pairs"/*.jpg "$pairs"/*.gif "$shared"/ 2>/dev/null || true
echo "Updated website/assets (working files in $work)"
