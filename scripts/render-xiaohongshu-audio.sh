#!/bin/bash
# Adds sound to the Xiaohongshu video: original background music, and (optionally) a narration spoken by a TTS voice.
#
#   bash scripts/render-xiaohongshu-audio.sh                  # music-only cut + narrated cuts with two voices
#   bash scripts/render-xiaohongshu-audio.sh music            # only the music-only cut
#   bash scripts/render-xiaohongshu-audio.sh voice [VOICE…]   # narrated cuts (default: zh-CN-YunxiNeural zh-CN-XiaoxiaoNeural)
#   bash scripts/render-xiaohongshu-audio.sh mix [VOICE…]     # only redo the mixing (after voice/music/levels changed); reuses the picture
#   ENGINE=melo bash …                                         # speech engine: edge (default, cloud neural), melo (local), say (macOS)
#
# Outputs in dist/:  xiaohongshu-music.mp4, xiaohongshu-voice-<voice>.mp4, xiaohongshu-voice-<voice>.srt, and the loose tracks
# in dist/audio/ (music.wav, <voice>/voice.wav) if you would rather mix in an editor.
# The first run sets up .venv-audio (numpy, edge-tts, sherpa-onnx). Speech is checked with Whisper when
# ~/.cache/whisper-cpp/ggml-small.bin and whisper-cli are present (brew install whisper-cpp).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$root"
mode="${1:-all}"; shift || true
engine="${ENGINE:-edge}"
py="$root/.venv-audio/bin/python"
if [ ! -x "$py" ]; then
  python3 -m venv .venv-audio && .venv-audio/bin/pip install -q numpy edge-tts sherpa-onnx
fi
audio="$root/dist/audio"; mkdir -p "$audio"
slug() { echo "$1" | sed -E 's/^zh-CN-//; s/Neural$//' | tr 'A-Z' 'a-z'; }

# ---- music-only cut: the video as designed -----------------------------------------------------------------------
music_cut() {
  mkdir -p "$audio/design"
  "$py" scripts/audio/make-voiceover.py --design-only --out "$audio/design"
  "$py" scripts/audio/make-music.py "$audio/design/timeline.json" "$audio/music-design.wav"
  [ -f dist/xiaohongshu.mp4 ] || bash scripts/render-xiaohongshu-video.sh
  ffmpeg -loglevel error -y -i dist/xiaohongshu.mp4 -i "$audio/music-design.wav" -filter_complex \
    "[1:a]aformat=channel_layouts=stereo,loudnorm=I=-17:TP=-1.5:LRA=9[a]" -map 0:v -map "[a]" \
    -c:v copy -c:a aac -b:a 192k -ar 48000 -shortest dist/xiaohongshu-music.mp4
  echo "dist/xiaohongshu-music.mp4"
}

# ---- narrated cuts: one video render shared by every voice -----------------------------------------------------
voice_cuts() {
  local voices=("$@"); [ ${#voices[@]} -gt 0 ] || voices=(zh-CN-YunxiNeural zh-CN-XiaoxiaoNeural)
  [ "$engine" = edge ] || voices=("${voices[0]}")
  for v in "${voices[@]}"; do
    "$py" scripts/audio/make-voiceover.py --engine "$engine" --voice "$v" --out "$audio/$(slug "$v")" | tail -3
  done
  # every voice must fit the same picture: each scene is as long as the longest voice needs
  "$py" - "$audio" "${voices[@]}" <<'PY'
import json, sys, re
audio, voices = sys.argv[1], sys.argv[2:]
slug = lambda v: re.sub(r"Neural$", "", re.sub(r"^zh-CN-", "", v)).lower()
tls = [json.load(open(f"{audio}/{slug(v)}/timeline.json")) for v in voices]
merged = json.loads(json.dumps(tls[0])); t = 0.0
for i, s in enumerate(merged["scenes"]):
    s["dur"] = max(tl["scenes"][i]["dur"] for tl in tls); s["start"] = round(t, 3); t += s["dur"]
merged["total"] = round(t, 3); json.dump(merged, open(f"{audio}/merged.json", "w"), ensure_ascii=False, indent=1)
open(f"{audio}/durs.txt", "w").write(",".join(str(s["dur"]) for s in merged["scenes"]))
PY
  for v in "${voices[@]}"; do
    "$py" scripts/audio/make-voiceover.py --engine "$engine" --voice "$v" --reuse --min-durations "$audio/merged.json" --out "$audio/$(slug "$v")" | tail -1
  done
  DURS="$(cat "$audio/durs.txt")" OUT="$audio/picture.mp4" bash scripts/render-xiaohongshu-video.sh
  "$py" scripts/audio/make-music.py "$audio/$(slug "${voices[0]}")/timeline.json" "$audio/music.wav"
  mix_voices "${voices[@]}"
}

# ---- mix: music + voice -> finished files (fast; re-run after changing levels) --------------------------------
mix_voices() {
  local voices=("$@")
  for v in "${voices[@]}"; do
    local s; s="$(slug "$v")"
    # music sits under the voice and ducks while it speaks; the mix lands at a normal streaming loudness
    ffmpeg -loglevel error -y -i "$audio/picture.mp4" -i "$audio/music.wav" -i "$audio/$s/voice.wav" -filter_complex "
      [1:a]aformat=channel_layouts=stereo,loudnorm=I=-22:TP=-2:LRA=9[m];
      [2:a]aformat=channel_layouts=stereo,loudnorm=I=-16:TP=-1.5:LRA=8,asplit=2[vsc][vmix];
      [m][vsc]sidechaincompress=threshold=0.015:ratio=10:attack=15:release=450[duck];
      [duck][vmix]amix=inputs=2:normalize=0:duration=longest,loudnorm=I=-16:TP=-1.5:LRA=9[a]" \
      -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -ar 48000 -shortest "dist/xiaohongshu-voice-$s.mp4"
    cp "$audio/$s/captions.srt" "dist/xiaohongshu-voice-$s.srt"
    echo "dist/xiaohongshu-voice-$s.mp4  (+ .srt)"
  done
}

case "$mode" in
  music) music_cut ;;
  voice) voice_cuts "$@" ;;
  mix) v=("$@"); [ ${#v[@]} -gt 0 ] || v=(zh-CN-YunxiNeural zh-CN-XiaoxiaoNeural)
       for x in "${v[@]}"; do "$py" scripts/audio/make-voiceover.py --engine "$engine" --voice "$x" --reuse --min-durations "$audio/merged.json" --out "$audio/$(slug "$x")" | tail -1; done
       mix_voices "${v[@]}" ;;
  all) music_cut; voice_cuts "$@" ;;
  *) echo "用法：music | voice [声音…] | mix [声音…] | all" >&2; exit 2 ;;
esac
