#!/usr/bin/env python3
"""Builds the narration for the Xiaohongshu video: speech, timing, captions, and a speech-recognition check.

    .venv-audio/bin/python scripts/audio/make-voiceover.py [--engine melo|edge|say|files] [--voice NAME]

Reads docs/marketing/xiaohongshu/narration.json (one line per scene) and the scene lengths in video.html, then

  1. turns each line into speech (--engine):
       melo   open-source MeloTTS (Chinese + English), runs locally and offline        [default]
       edge   Microsoft's neural voices through the edge-tts package; needs internet, the text is sent to Microsoft
       say    the macOS system voice (Tingting): offline, but robotic
       files  your own recordings: put dist/audio/voice/01.wav, 02.wav ... in place and they are used as they are
  2. checks every line with Whisper (speech recognition) and reports how closely it matches the script,
  3. sets each scene as long as it needs to be: max(designed length, voice + a little breathing room),
  4. writes dist/audio/: voice/NN.wav, voice.wav (all lines placed on the timeline), timeline.json, captions.srt, asr-report.txt.
"""
import argparse
import asyncio
import difflib
import json
import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
XHS = ROOT / "docs/marketing/xiaohongshu"
OUT = ROOT / "dist/audio"
WHISPER_MODEL = Path.home() / ".cache/whisper-cpp/ggml-small.bin"
MELO_DIR = Path.home() / ".cache/sherpa-tts/vits-melo-tts-zh_en"
LEAD, TAIL = 0.45, 0.65          # seconds of picture before the voice starts and after it ends
SR = 44100

# Words a Chinese speech engine reads badly, respelled for the engine only (captions keep the original).
RESPELL = {
    "melo": {"DJI": "迪杰艾", "Mac": "麦克", "Mimo": "咪摩", "Lightroom": "莱特如姆", "Photoshop": "福托肖普",
             "Claude Code": "克劳德扣得", "ChatGPT": "查特G P T", "iPhone": "爱疯", "App": "阿普"},
    "say": {"DJI": "迪杰艾", "Mac": "麦克", "Mimo": "咪摩", "Lightroom": "莱特如姆", "Photoshop": "福托肖普",
            "Claude Code": "克劳德扣得", "ChatGPT": "查特G P T", "iPhone": "爱疯", "App": "阿普"},
    "edge": {},
}


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def wav_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def to_wav(src, dst):
    """44.1 kHz mono 16-bit, with leading/trailing silence trimmed."""
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-ar", str(SR), "-ac", "1",
         "-af", "silenceremove=start_periods=1:start_threshold=-48dB:start_silence=0.05,areverse,"
                "silenceremove=start_periods=1:start_threshold=-48dB:start_silence=0.05,areverse", str(dst)])


def respell(text, engine):
    for word, spoken in sorted(RESPELL.get(engine, {}).items(), key=lambda kv: -len(kv[0])):
        text = re.sub(re.escape(word), spoken, text)
    return text


# ---- speech engines -------------------------------------------------------------------------------------------

_melo = None


def speak_melo(text, dst, voice, speed):
    global _melo
    import numpy as np
    import sherpa_onnx
    if _melo is None:
        d = str(MELO_DIR)
        cfg = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                vits=sherpa_onnx.OfflineTtsVitsModelConfig(model=f"{d}/model.onnx", lexicon=f"{d}/lexicon.txt",
                                                           tokens=f"{d}/tokens.txt", dict_dir=f"{d}/dict"),
                num_threads=4),
            rule_fsts=",".join(f"{d}/{n}.fst" for n in ("date", "number", "phone", "new_heteronym")), max_num_sentences=1)
        _melo = sherpa_onnx.OfflineTts(cfg)
    audio = _melo.generate(text, sid=0, speed=speed)
    pcm = (np.clip(np.array(audio.samples), -1, 1) * 32767).astype("<i2")
    tmp = dst.with_suffix(".raw.wav")
    with wave.open(str(tmp), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(audio.sample_rate); w.writeframes(pcm.tobytes())
    to_wav(tmp, dst); tmp.unlink()


def speak_edge(text, dst, voice, speed):
    import edge_tts
    tmp = dst.with_suffix(".mp3")
    rate = f"{round((speed - 1) * 100):+d}%"
    asyncio.run(edge_tts.Communicate(text, voice or "zh-CN-YunxiNeural", rate=rate).save(str(tmp)))
    to_wav(tmp, dst); tmp.unlink()


def speak_say(text, dst, voice, speed):
    tmp = dst.with_suffix(".aiff")
    run(["say", "-v", voice or "Tingting", "-r", str(round(185 * speed)), "-o", str(tmp), text])
    to_wav(tmp, dst); tmp.unlink()


ENGINES = {"melo": speak_melo, "edge": speak_edge, "say": speak_say}


# ---- speech recognition ---------------------------------------------------------------------------------------

def transcribe(wav):
    if not (WHISPER_MODEL.exists() and shutil.which("whisper-cli")):
        return None
    tmp = wav.with_suffix(".16k.wav")
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(wav), "-ar", "16000", "-ac", "1", str(tmp)])
    out = run(["whisper-cli", "-m", str(WHISPER_MODEL), "-f", str(tmp), "-l", "zh", "-nt", "-np",
                "--prompt", "以下是普通话的句子，使用简体中文。"]).stdout
    tmp.unlink()
    return " ".join(out.split())


def normal(s):
    s = re.sub(r"[\s，。？！、,.?!：:；;“”「」\"'（）()\-—]", "", s).lower()
    return s.replace("麥", "麦").replace("機", "机")


def similarity(a, b):
    return difflib.SequenceMatcher(None, normal(a), normal(b)).ratio()


# ---- captions ---------------------------------------------------------------------------------------------------

def srt_time(t):
    ms = round(t * 1000)
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def caption_chunks(text):
    parts = [p for p in re.split(r"(?<=[，。？！、])", text) if p.strip()]
    merged, cur = [], ""
    for p in parts:                      # keep chunks readable: roughly 8-18 characters each
        if len(cur) + len(p) <= 18 or len(cur) < 6:
            cur += p
        else:
            merged.append(cur); cur = p
    return merged + ([cur] if cur else [])


# ---- main -------------------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", choices=[*ENGINES, "files"], default="melo")
    ap.add_argument("--voice", default=None, help="edge: e.g. zh-CN-YunxiNeural / zh-CN-XiaoxiaoNeural; say: Tingting")
    ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--reuse", action="store_true", help="keep voice/NN.wav files that already exist instead of speaking them again")
    ap.add_argument("--min-durations", help="a timeline.json whose scene lengths are the minimum here (so several voices can share one video render)")
    ap.add_argument("--design-only", action="store_true", help="no voice: write a timeline with the designed scene lengths (for a music-only cut)")
    args = ap.parse_args()
    out = Path(args.out); voice_dir = out / "voice"; voice_dir.mkdir(parents=True, exist_ok=True)

    narration = json.load(open(XHS / "narration.json"))["scenes"]
    html = (XHS / "video.html").read_text()
    designed = [(m.group(1), float(m.group(2))) for m in
                re.finditer(r'<section class="scene[^>]*?data-name="([^"]*)"[^>]*?data-dur="([\d.]+)"', html)]
    if len(designed) != len(narration):
        sys.exit(f"narration.json has {len(narration)} scenes but video.html has {len(designed)}")

    floor = [s["dur"] for s in json.load(open(args.min_durations))["scenes"]] if args.min_durations else [0] * len(narration)
    report, scenes, t = [], [], 0.0
    if args.design_only:
        for line, (name, design), minimum in zip(narration, designed, floor):
            dur = max(design, minimum)
            scenes.append({"id": line["id"], "name": name, "start": round(t, 3), "dur": dur, "designed": design,
                           "energy": line.get("energy", 0.6), "text": line["text"]})
            t += dur
        json.dump({"engine": None, "total": round(t, 3), "scenes": scenes}, open(out / "timeline.json", "w"), ensure_ascii=False, indent=1)
        print(f"design-only timeline: {t:.1f}s -> {out}")
        return
    for i, (line, (name, design), minimum) in enumerate(zip(narration, designed, floor), 1):
        wav = voice_dir / f"{i:02d}.wav"
        if args.reuse and wav.exists():
            pass
        elif args.engine != "files":
            ENGINES[args.engine](respell(line.get("speak", line["text"]), args.engine), wav, args.voice, args.speed)
        elif not wav.exists():
            sys.exit(f"missing {wav} (engine 'files' uses your own recordings)")
        voice = wav_seconds(wav)
        dur = max(design, LEAD + voice + TAIL, minimum)
        heard = transcribe(wav)
        score = similarity(line["text"], heard) if heard is not None else None
        scenes.append({"id": line["id"], "name": name, "start": round(t, 3), "dur": round(dur, 3), "designed": design,
                       "voice_start": round(t + LEAD, 3), "voice_dur": round(voice, 3), "energy": line.get("energy", 0.6),
                       "text": line["text"], "heard": heard, "match": None if score is None else round(score, 3)})
        report.append(f"{i:02d} {line['id']:<8} {voice:5.1f}s  match {('%.0f%%' % (score * 100)) if score is not None else 'n/a':>5}"
                      f"\n     said : {line['text']}\n     heard: {heard}")
        t += dur

    json.dump({"engine": args.engine, "voice": args.voice, "total": round(t, 3), "scenes": scenes},
              open(out / "timeline.json", "w"), ensure_ascii=False, indent=1)
    (out / "asr-report.txt").write_text("\n".join(report) + "\n")

    # captions
    cues, n = [], 1
    for s in scenes:
        chunks = caption_chunks(s["text"]); total = sum(len(c) for c in chunks); at = s["voice_start"]
        for c in chunks:
            d = s["voice_dur"] * len(c) / total
            cues.append(f"{n}\n{srt_time(at)} --> {srt_time(at + d)}\n{c.rstrip('，、')}\n"); n += 1; at += d
    (out / "captions.srt").write_text("\n".join(cues))

    # every line on the timeline, one voice track
    cmd = ["ffmpeg", "-loglevel", "error", "-y"]
    for s in scenes:
        cmd += ["-i", str(voice_dir / f"{scenes.index(s) + 1:02d}.wav")]
    delays = ";".join(f"[{i}:a]adelay={round(s['voice_start'] * 1000)}|{round(s['voice_start'] * 1000)}[a{i}]" for i, s in enumerate(scenes))
    # padded with silence to the full length of the picture, so later filters never end before the video does
    mix = "".join(f"[a{i}]" for i in range(len(scenes))) + f"amix=inputs={len(scenes)}:normalize=0:duration=longest[m];[m]apad=whole_dur={t:.3f}[v]"
    run(cmd + ["-filter_complex", f"{delays};{mix}", "-map", "[v]", "-ar", str(SR), "-ac", "1", str(out / "voice.wav")])

    print("\n".join(report))
    print(f"\nengine={args.engine}  total={t:.1f}s  (designed {sum(d for _, d in designed):.1f}s)  -> {out}")


if __name__ == "__main__":
    main()
