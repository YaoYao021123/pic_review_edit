#!/usr/bin/env python3
"""Turns a recording of YOU talking to the camera into a finished Xiaohongshu video, with whiteboard sketches.

    .venv-audio/bin/python scripts/audio/build-talking-video.py MY-TAKE.mov [--out dist/talking] [options]

Your face and your own voice stay the main thing. The tool only does the editing chores:

  1. frames the take as 1080x1920 (9:16, 30 fps; a landscape take is centre-cropped),
  2. cleans the voice: low rumble and steady background noise out, even volume, normal streaming loudness,
  3. trims dead air: leading/trailing silence and long pauses are shortened (jump cuts), so it keeps moving,
  4. recognises what you said (Whisper, on this Mac) and writes captions (captions.srt; fix it and run with --captions),
  5. draws hand-made whiteboard sketches (Excalidraw style, 15 pages, docs/marketing/xiaohongshu/sketches.html) while
     you tell the story: each shape appears at the moment you say its word; a page you never mention is skipped. Your face moves to the lower half while a sketch is
     up, and fills the screen at the start and the end,
  6. burns the captions in and puts a quiet original music bed under your voice (it ducks while you speak).

Needs: ffmpeg, Google Chrome (sketches and captions are drawn by it), whisper-cli + ~/.cache/whisper-cpp/ggml-small.bin,
and the .venv-audio environment. Nothing leaves your Mac.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from sketch_pics import BOARDS, MAX_SPAN, find_pics, pics_param
XHS = ROOT / "docs/marketing/xiaohongshu"
WHISPER_MODEL = Path.home() / ".cache/whisper-cpp/ggml-small.bin"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROMPT = "以下是普通话的句子，使用简体中文。光集，DJI，Mimo，Mac，Claude Code，ChatGPT，Lightroom，Photoshop，iPhone，实况照片。"
# Whisper's usual mis-hearings of the product's words (edit freely).
FIXES = {"光极": "光集", "路塞特": "Lucet", "Lucid": "Lucet", "露塞特": "Lucet", "光景": "光集", "光级": "光集", "克劳德扣得": "Claude Code", "克劳德 Code": "Claude Code",
         "cloud code": "Claude Code", "Cloud Code": "Claude Code", "查特GPT": "ChatGPT", "check gpt": "ChatGPT",
         "Check GPT": "ChatGPT", "API": "App", "MIMO": "Mimo", "mimo": "Mimo", "Memo": "Mimo"}
# Trimming: pauses longer than PAUSE_MAX are cut down to 2 * KEEP; the very start and end get LEAD / TAIL.
SILENCE_DB, SILENCE_MIN, PAUSE_MAX, KEEP, LEAD, TAIL = "-40dB", 0.5, 0.65, 0.16, 0.12, 0.45

# Layout (1080x1920). With a sketch up: sketch on top (1080x1080), your face below (1080x840).
SKETCH_H, FACE_H = 1080, 840
CAPTION_Y = 1450          # top of the 300 px caption strip (its text sits at the bottom of the strip, clear of the app's buttons)
INTRO, OUTRO = 3.5, 4.0   # seconds of full-screen face at the start / the end
HOLD = 3.5                # a sketch stays up this long after its last word
BOARD_FPS = 10            # sketches are drawn at 10 pictures a second (hand-drawn look, and quick to render)


def run(cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, capture_output=True, text=True, **kw)


def ffprobe_duration(path):
    return float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]).stdout)


def log(msg):
    print(f"· {msg}", flush=True)


# ---- 1-3: frame, clean, trim -------------------------------------------------------------------------------------

def silences(wav, total):
    err = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(wav), "-af", f"silencedetect=noise={SILENCE_DB}:d={SILENCE_MIN}",
                          "-f", "null", "-"], capture_output=True, text=True).stderr
    found, start = [], None
    for line in err.splitlines():
        if m := re.search(r"silence_start: ([\d.]+)", line):
            start = float(m.group(1))
        elif m := re.search(r"silence_end: ([\d.]+)", line):
            found.append((start if start is not None else 0.0, float(m.group(1)))); start = None
    if start is not None:
        found.append((start, total))
    return found


def keep_intervals(total, sil):
    cuts = []
    for s, e in sil:
        if s < 0.05:
            cuts.append((0.0, max(0.0, e - LEAD)))
        elif e >= total - 0.05:
            cuts.append((s + TAIL, total))
        elif e - s > PAUSE_MAX:
            cuts.append((s + KEEP, e - KEEP))
    keep, at = [], 0.0
    for a, b in sorted(c for c in cuts if c[1] - c[0] > 0.05):
        if a - at > 0.2:
            keep.append((at, a))
        at = max(at, b)
    if total - at > 0.2:
        keep.append((at, total))
    return keep or [(0.0, total)]


def build_tight(face, work, trim):
    log("framing the video as 1080x1920 and cleaning the voice")
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", face, "-vf",
         "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p",
         "-an", "-c:v", "libx264", "-crf", "15", "-preset", "fast", work / "face.mp4"])
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", face, "-vn", "-ac", "1", "-ar", "48000",
         "-af", "highpass=f=80,afftdn=nr=12:nf=-45,acompressor=threshold=-21dB:ratio=3:attack=8:release=140:makeup=2,"
                "loudnorm=I=-16:TP=-1.5:LRA=8", work / "voice.wav"])
    total = ffprobe_duration(work / "voice.wav")
    keep = keep_intervals(total, silences(work / "voice.wav", total)) if trim else [(0.0, total)]
    cut = total - sum(b - a for a, b in keep)
    log(f"{total:.1f}s recorded -> {total - cut:.1f}s after trimming ({cut:.1f}s of dead air and long pauses removed, {len(keep)} segments)")
    parts, concat = [], []
    for i, (a, b) in enumerate(keep):
        fade = min(0.015, (b - a) / 3)
        parts.append(f"[0:v]trim=start={a:.3f}:end={b:.3f},setpts=PTS-STARTPTS[v{i}];"
                     f"[1:a]atrim=start={a:.3f}:end={b:.3f},asetpts=PTS-STARTPTS,afade=t=in:d={fade},"
                     f"afade=t=out:st={b - a - fade:.3f}:d={fade}[a{i}]")
        concat.append(f"[v{i}][a{i}]")
    graph = ";".join(parts) + ";" + "".join(concat) + f"concat=n={len(keep)}:v=1:a=1[v][a]"
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", work / "face.mp4", "-i", work / "voice.wav", "-filter_complex", graph,
         "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-crf", "15", "-preset", "fast", "-c:a", "aac", "-b:a", "192k",
         "-ar", "48000", work / "tight.mp4"])
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", work / "tight.mp4", "-vn", "-ac", "1", "-ar", "48000", work / "tight.wav"])
    return ffprobe_duration(work / "tight.mp4")


# ---- 4: captions --------------------------------------------------------------------------------------------------

def srt_time(t):
    ms = round(t * 1000)
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def parse_srt_time(s):
    h, m, rest = s.split(":"); sec, ms = rest.replace(".", ",").split(",")
    return int(h) * 3600 + int(m) * 60 + int(sec) + int(ms) / 1000


def read_srt(path):
    cues = []
    for block in re.split(r"\n\s*\n", Path(path).read_text().strip()):
        lines = block.strip().splitlines()
        if len(lines) >= 3 and "-->" in lines[1]:
            a, b = (parse_srt_time(x.strip()) for x in lines[1].split("-->"))
            cues.append({"start": a, "end": b, "text": " ".join(lines[2:]).strip()})
    return cues


MAX_CAPTION = 16          # characters on one caption line


def split_long(cue):
    """Whisper sometimes returns one long cue for several seconds of speech; cut it at commas, timed by character count."""
    text = cue["text"]
    if len(text) <= MAX_CAPTION:
        return [cue]
    chunks, cur = [], ""
    for part in re.split(r"(?<=[，。？！、,.?!])", text):
        while len(part) > MAX_CAPTION:              # no punctuation to cut at: cut by length
            if cur:
                chunks.append(cur); cur = ""
            cut = MAX_CAPTION - 2
            while cut < len(part) and part[cut - 1].isascii() and part[cut].isascii() and part[cut - 1].isalnum() and part[cut].isalnum():
                cut += 1                            # never cut inside an English word
            chunks.append(part[:cut]); part = part[cut:]
        if len(cur) + len(part) > MAX_CAPTION and cur:
            chunks.append(cur); cur = ""
        cur += part
    if cur:
        chunks.append(cur)
    span, at, out = cue["end"] - cue["start"], cue["start"], []
    for ch in chunks:
        d = span * len(ch) / len(text)
        out.append({"start": at, "end": at + d, "text": ch.strip("，。,.、")}); at += d
    return [c for c in out if c["text"]]


def transcribe(work, total):
    if not (WHISPER_MODEL.exists() and shutil.which("whisper-cli")):
        sys.exit("speech recognition needs whisper-cli and ~/.cache/whisper-cpp/ggml-small.bin (brew install whisper-cpp)")
    log("recognising what you said (Whisper, on this Mac)")
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", work / "tight.wav", "-ar", "16000", "-ac", "1", work / "asr16.wav"])
    run(["whisper-cli", "-m", WHISPER_MODEL, "-f", work / "asr16.wav", "-l", "zh", "-ml", "14", "-sow", "-oj", "-of", work / "asr",
         "-np", "--prompt", PROMPT])
    raw = json.load(open(work / "asr.json"))["transcription"]
    cues = []
    for seg in raw:
        text = seg["text"].strip()
        for bad, good in FIXES.items():
            text = text.replace(bad, good)
        text = text.strip(" ，。,.、")
        if text:
            cues.append({"start": seg["offsets"]["from"] / 1000, "end": seg["offsets"]["to"] / 1000, "text": text})
    cues = [piece for c in cues for piece in split_long(c)]
    merged = []                                     # very short bits read better joined to their neighbour
    for c in cues:
        if merged and (len(c["text"]) < 4 or len(merged[-1]["text"]) < 4) and c["start"] - merged[-1]["end"] < 0.5 \
                and len(merged[-1]["text"]) + len(c["text"]) <= 16:
            merged[-1]["text"] += c["text"]; merged[-1]["end"] = c["end"]
        else:
            merged.append(c)
    for i, c in enumerate(merged):                  # never overlap, never linger long after the words
        nxt = merged[i + 1]["start"] if i + 1 < len(merged) else total
        c["end"] = min(max(c["end"], c["start"] + 0.5), nxt - 0.02 if nxt > c["start"] + 0.55 else c["end"], total)
    return merged


def write_srt(cues, path):
    path.write_text("\n".join(f"{i}\n{srt_time(c['start'])} --> {srt_time(c['end'])}\n{c['text']}\n" for i, c in enumerate(cues, 1)))


# ---- 5: sketches --------------------------------------------------------------------------------------------------

def plan_sketches(cues, total):
    """For each board: when it appears, when it goes, and when each of its elements is drawn (seconds on the video)."""
    text, times = "", []
    for c in cues:                                  # the time of every character, spread evenly across its cue
        n = max(1, len(c["text"]))
        for i, _ in enumerate(c["text"]):
            times.append(c["start"] + (c["end"] - c["start"]) * i / n)
        text += c["text"]
    def search(anchors, pos):
        hits = {}
        for key, pattern in anchors:
            m = re.compile(pattern, re.I).search(text, pos)
            if m and (not hits or times[m.start()] - min(hits.values()) <= MAX_SPAN):
                hits[key] = times[m.start()]; pos = m.start() + 1
        return hits, pos

    found, pos, retry = [], 0, []
    for name, anchors in BOARDS:                    # pages are matched in story order ...
        hits, after = search(anchors, pos)
        if hits:
            found.append((name, anchors, hits)); pos = after
        else:
            retry.append((name, anchors))
    for name, anchors in retry:                     # ... and a page whose words came earlier in a shorter script is looked for from the start
        hits, _ = search(anchors, 0)
        if hits and not any(min(hits.values()) < max(o.values()) and max(hits.values()) > min(o.values()) for _, _, o in found):
            found.append((name, anchors, hits))
    found.sort(key=lambda f: min(f[2].values()))

    plan = []
    for k, (name, anchors, hits) in enumerate(found):
        if not hits:
            continue
        start = max(min(hits.values()) - 0.3, INTRO)
        later = [min(h.values()) - 0.3 for _, _, h in found[k + 1:] if h]
        end = min(max(hits.values()) + HOLD, min(later) if later else total, total - OUTRO)
        if end - start < 2.0:
            continue
        cue, prev = {}, -1.5
        for key, _ in anchors:                      # an element you never said is drawn just after the one before it
            cue[key] = max(0.0, hits[key] - start) if key in hits else prev + 1.5
            prev = cue[key]
        plan.append({"name": name, "at": round(start, 2), "len": round(end - start, 2), "cues": {a: round(t, 2) for a, t in cue.items()},
                     "missing": [key for key, _ in anchors if key not in hits]})
    return plan


def render_sketches(plan, work, pics):
    """Each board is drawn frame by frame by headless Chrome, then turned into a short clip. Returns the clip paths."""
    env_lib = ROOT / "scripts/lib/render-frame.sh"
    clips = []
    for p in plan:
        folder = work / f"board-{p['name']}"
        shutil.rmtree(folder, ignore_errors=True); folder.mkdir(parents=True)
        drawn = min(p["len"], max(p["cues"].values()) + 3.2)          # after this the board no longer changes
        n = int(drawn * BOARD_FPS) + 1
        log(f"drawing the '{p['name']}' sketch ({n} pictures)")
        cues = ",".join(f"{k}:{v}" for k, v in p["cues"].items())

        def one(i):
            raw = folder / f"{i:04d}.raw.png"
            url = f"file://{XHS}/sketches.html?board={p['name']}&render=1&t={i / BOARD_FPS:.3f}&cues={cues}&pics={pics_param(pics)}"
            run(["bash", "-c", f'chrome="{CHROME}"; work="{folder}"; source "{env_lib}"; CHROME_HEIGHT=1167 render_frame "{url}" "{raw}"'])
            run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-vf", f"crop=1080:{SKETCH_H}:0:0", folder / f"{i:04d}.png"])
            raw.unlink()
        with ThreadPoolExecutor(6) as pool:
            list(pool.map(one, range(n)))
        clip = work / f"board-{p['name']}.mp4"
        run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", BOARD_FPS, "-i", folder / "%04d.png", "-vf",
             f"fps=30,format=yuv420p", "-c:v", "libx264", "-crf", "14", clip])
        clips.append(clip)
    return clips


# ---- 6: captions as pictures, music, final mix ------------------------------------------------------------------

def render_captions(cues, work):
    log(f"drawing {len(cues)} captions")
    env_lib = ROOT / "scripts/lib/render-frame.sh"
    html = XHS / "caption.html"

    def one(item):
        i, c = item
        out = work / f"cap-{i:03d}.png"; raw = work / f"cap-{i:03d}.raw.png"
        run(["bash", "-c", f'chrome="{CHROME}"; work="{work}"; source "{env_lib}"; '
                           f'CHROME_TRANSPARENT=1 CHROME_HEIGHT=387 render_frame "file://{html}?text={quote(c["text"])}" "{raw}"'])
        run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-vf", "crop=1080:300:0:0", out]); raw.unlink()
        return out
    with ThreadPoolExecutor(6) as pool:
        return list(pool.map(one, enumerate(cues)))


def make_music(total, work):
    tl = {"scenes": [{"start": 0, "dur": 4, "energy": 0.3}, {"start": 4, "dur": max(1, total - 9), "energy": 0.55},
                     {"start": max(5, total - 5), "dur": min(5, total - 5), "energy": 0.35}], "tail": 0}
    json.dump(tl, open(work / "music-timeline.json", "w"))
    py = ROOT / ".venv-audio/bin/python"
    run([py, ROOT / "scripts/audio/make-music.py", work / "music-timeline.json", work / "music.wav"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("take", help="your recording (.mov / .mp4 …)")
    ap.add_argument("--out", default=str(ROOT / "dist/talking"))
    ap.add_argument("--name", help="output name (default: the recording's name)")
    ap.add_argument("--face-y", type=float, default=0.38,
                    help="where your face is in the frame, 0 = top, 1 = bottom (default 0.38); sets the crop while a sketch is up")
    ap.add_argument("--no-trim", action="store_true", help="keep every pause")
    ap.add_argument("--no-music", action="store_true")
    ap.add_argument("--no-pics", action="store_true", help="hand-drawn icons only, no screenshots in the sketches")
    ap.add_argument("--no-sketches", action="store_true", help="face and captions only")
    ap.add_argument("--captions", help="use this (edited) captions.srt instead of recognising speech again")
    ap.add_argument("--plan-only", action="store_true", help="stop after recognising speech and planning the sketches")
    args = ap.parse_args()
    take = Path(args.take).expanduser().resolve()
    out = Path(args.out); work = out / "work"; work.mkdir(parents=True, exist_ok=True)
    name = args.name or take.stem

    total = build_tight(take, work, not args.no_trim)
    cues = read_srt(args.captions) if args.captions else transcribe(work, total)
    write_srt(cues, out / f"{name}.srt")
    (out / f"{name}-transcript.txt").write_text("\n".join(c["text"] for c in cues) + "\n")

    plan = [] if args.no_sketches else plan_sketches(cues, total)
    sheet = ["Sketches (your face moves to the lower half while one is up):"] + \
            [f"  {p['at']:6.1f}s - {p['at'] + p['len']:5.1f}s  {p['name']:<8} drawn at "
             + " ".join(f"{k}@{p['at'] + v:.1f}" for k, v in p["cues"].items())
             + (f"   (not heard: {', '.join(p['missing'])})" if p["missing"] else "") for p in plan] \
        if plan else ["No sketches."]
    (out / f"{name}-cues.txt").write_text("\n".join(sheet) + "\n")
    print("\n".join(sheet))
    if args.plan_only:
        return

    clips = render_sketches(plan, work, {} if args.no_pics else find_pics())
    cap_files = render_captions(cues, work)
    if not args.no_music:
        make_music(total, work)

    # ---- the final graph: face full-screen; while a sketch is up, the sketch on top and the face cropped below it
    crop_y = round(min(max(args.face_y * 1920 - FACE_H * 0.42, 0), 1920 - FACE_H))
    cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", work / "tight.mp4"]
    chains, last, idx = [], "[0:v]", 1
    if plan:
        chains.append(f"[0:v]split={len(plan) + 1}[base]" + "".join(f"[f{k}]" for k in range(len(plan))))
        last = "[base]"
    for k, (p, clip) in enumerate(zip(plan, clips)):
        a, b = p["at"], p["at"] + p["len"]
        cmd += ["-i", clip]
        chains.append(f"[f{k}]crop=1080:{FACE_H}:0:{crop_y}[c{k}]")
        chains.append(f"{last}[c{k}]overlay=0:{SKETCH_H}:enable='between(t,{a},{b})'[h{k}]")
        chains.append(f"[{idx}:v]setpts=PTS-STARTPTS,fps=30,format=yuva420p,fade=t=in:st=0:d=0.12:alpha=1,setpts=PTS+{a}/TB[b{k}]")
        chains.append(f"[h{k}][b{k}]overlay=0:0:enable='between(t,{a},{b})':eof_action=repeat[o{k}]")
        last = f"[o{k}]"; idx += 1
    for i, (c, png) in enumerate(zip(cues, cap_files)):
        cmd += ["-i", png]
        chains.append(f"{last}[{idx}:v]overlay=0:{CAPTION_Y}:enable='between(t,{c['start']:.3f},{c['end']:.3f})'[c{i}]")
        last = f"[c{i}]"; idx += 1
    music = idx
    if not args.no_music:
        cmd += ["-i", work / "music.wav"]
        audio = ("[0:a]aformat=channel_layouts=stereo,asplit=2[vsc][vmix];"
                 f"[{music}:a]aformat=channel_layouts=stereo,loudnorm=I=-25:TP=-2:LRA=9[m];"
                 "[m][vsc]sidechaincompress=threshold=0.02:ratio=8:attack=15:release=500[duck];"
                 "[duck][vmix]amix=inputs=2:normalize=0:duration=first,loudnorm=I=-16:TP=-1.5:LRA=9[a]")
    else:
        audio = "[0:a]aformat=channel_layouts=stereo[a]"
    graph = ";".join(chains + [f"{last}format=yuv420p[vout]", audio])
    dest = out / f"{name}.mp4"
    log("putting it together")
    run([*cmd, "-filter_complex", graph, "-map", "[vout]", "-map", "[a]", "-c:v", "libx264", "-crf", "18", "-preset", "medium",
         "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", "-t", f"{total:.3f}", dest])

    # a few stills to check the layout without watching the whole video
    prev = out / f"{name}-preview"; shutil.rmtree(prev, ignore_errors=True); prev.mkdir()
    moments = [("1-start", 1.5)] + [(f"{k + 2}-{p['name']}", p["at"] + p["len"] - 0.6) for k, p in enumerate(plan)] + [("end", total - 1.5)]
    for label, t in moments:
        run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{max(0, t):.2f}", "-i", dest, "-frames:v", "1", prev / f"{label}.png"])
    print(f"\n{dest}  ({total:.1f}s)\n{prev}/  <- stills of the layout\n{out / (name + '.srt')}  <- fix any wrong word, then run again with --captions")


if __name__ == "__main__":
    main()
