#!/usr/bin/env python3
"""Synthesizes an original, royalty-free background track that follows the video's scenes.

    .venv-audio/bin/python scripts/audio/make-music.py <timeline.json> <out.wav>

The timeline lists each scene's start and length; how full the music sounds per scene comes from the
scene's "energy" (0..1). Everything is generated from scratch with numpy (warm pad, soft plucked
arpeggio, bass, a light pulse, a short reverb), so there is no sample, no licence and no copyright claim.
It is a calm, modern synth bed — good under a voice. For a richer, professionally produced sound,
use a track from Xiaohongshu's / CapCut's licensed library instead.
"""
import json
import sys
import wave

import numpy as np

SR = 44100
BPM = 84
BEAT = 60 / BPM
BAR = 4 * BEAT
# One chord per bar, as MIDI notes: Cmaj7 - Am7 - Fmaj7 - G6.
CHORDS = [
    (48, [60, 64, 67, 71]),   # C  : C4 E4 G4 B4
    (45, [57, 60, 64, 67]),   # Am : A3 C4 E4 G4
    (41, [57, 60, 64, 65]),   # F  : A3 C4 E4 F4
    (43, [55, 59, 62, 64]),   # G6 : G3 B3 D4 E4
]


def midi(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def envelope(n, attack, release, sustain=1.0):
    e = np.ones(n) * sustain
    a, r = min(int(attack * SR), n), min(int(release * SR), n)
    if a:
        e[:a] = np.linspace(0, sustain, a) ** 2
    if r:
        e[-r:] *= np.linspace(1, 0, r) ** 2
    return e


def one_pole_lowpass(x, cutoff):
    a = 1 - np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):          # fine for a minute of audio; keeps the script dependency-free
        acc += a * (v - acc)
        y[i] = acc
    return y


def pad(chord_notes, length, detune):
    t = np.arange(int(length * SR)) / SR
    out = np.zeros_like(t)
    for note in chord_notes:
        f = midi(note) * (1 + detune)
        out += np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 2 * f * t) + 0.12 * np.sin(2 * np.pi * 3 * f * t)
    return out / max(1, len(chord_notes)) * envelope(len(t), 1.1, 1.4)


def pluck(note, length=0.9, bright=1.0):
    t = np.arange(int(length * SR)) / SR
    f = midi(note)
    decay = np.exp(-t / 0.32)
    tone = np.sin(2 * np.pi * f * t) + 0.45 * bright * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t / 0.18) \
        + 0.18 * bright * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t / 0.1)
    return tone * decay * envelope(len(t), 0.004, 0.08)


def thump(length=0.28):
    t = np.arange(int(length * SR)) / SR
    f = 110 * np.exp(-t * 14) + 42
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.09)


def shaker(rng, length=0.09):
    n = int(length * SR)
    noise = rng.standard_normal(n)
    noise = one_pole_lowpass(noise, 7000) - one_pole_lowpass(noise, 2500)     # a soft band, not white hiss
    return noise * np.exp(-np.arange(n) / SR / 0.025) * envelope(n, 0.002, 0.03) * 2.2


def add(track, sound, start, gain, pan=0.0):
    i = int(start * SR)
    if i >= track.shape[1]:
        return
    n = min(len(sound), track.shape[1] - i)
    track[0, i:i + n] += sound[:n] * gain * (1 - max(0, pan))
    track[1, i:i + n] += sound[:n] * gain * (1 + min(0, pan))


def reverb(track, rng, seconds=1.9, mix=0.28):
    n = int(seconds * SR)
    ir = rng.standard_normal((2, n)) * np.exp(-np.arange(n) / SR / 0.55)
    size = 1 << int(np.ceil(np.log2(track.shape[1] + n)))
    wet = np.stack([np.fft.irfft(np.fft.rfft(track[c], size) * np.fft.rfft(ir[c], size), size)[:track.shape[1]] for c in range(2)])
    wet /= max(1e-6, np.abs(wet).max()) / max(1e-6, np.abs(track).max())
    return track * (1 - mix) + wet * mix


def main(timeline_path, out_path):
    timeline = json.load(open(timeline_path))
    scenes = timeline["scenes"]
    total = scenes[-1]["start"] + scenes[-1]["dur"] + float(timeline.get("tail", 0))   # ends with the picture; its fade-out lands on the last frame
    rng = np.random.default_rng(7)
    track = np.zeros((2, int(total * SR)))

    def energy_at(t):
        for s in scenes:
            if s["start"] <= t < s["start"] + s["dur"]:
                return s.get("energy", 0.6)
        return 0.3

    bars = int(np.ceil(total / BAR))
    for b in range(bars):
        t0 = b * BAR
        e = energy_at(t0 + BAR / 2)
        root, notes = CHORDS[b % 4]
        # pad: always, a touch wider when the music is fuller
        for pan, det in ((-0.35, -0.0015), (0.35, 0.0015)):
            add(track, pad(notes, BAR + 1.6, det), t0, 0.16 + 0.05 * e, pan)
        if e >= 0.5:                                           # bass
            t = np.arange(int(BAR * SR)) / SR
            add(track, np.sin(2 * np.pi * midi(root) * t) * envelope(len(t), 0.05, 0.4), t0, 0.22 * min(1, e + 0.2))
        if e >= 0.45:                                          # arpeggio, eighth notes
            pattern = [0, 2, 1, 3, 2, 1, 3, 2]
            for k, idx in enumerate(pattern):
                note = notes[idx] + (12 if k % 4 == 3 else 0)
                vel = (0.5 + 0.5 * ((k % 2) == 0)) * (0.55 + 0.45 * e)
                add(track, pluck(note, bright=0.6 + 0.6 * e), t0 + k * BEAT / 2 + rng.uniform(-0.004, 0.004), 0.12 * vel,
                    pan=-0.3 + 0.6 * (k / 7))
        if e >= 0.65:                                          # a soft pulse
            for beat in (0, 2):
                add(track, thump(), t0 + beat * BEAT, 0.16 * e)
            for k in range(8):
                if k % 2:
                    add(track, shaker(rng), t0 + k * BEAT / 2, 0.035 * e, pan=0.3)

    track = reverb(track, rng)
    # gentle low cut and fades
    for c in range(2):
        track[c] -= one_pole_lowpass(track[c], 35)
    fade_in, fade_out = int(1.2 * SR), int(3.2 * SR)
    track[:, :fade_in] *= np.linspace(0, 1, fade_in)
    track[:, -fade_out:] *= np.linspace(1, 0, fade_out) ** 1.5
    # leave headroom: the mix step normalises loudness and ducks this under the voice
    track *= 0.89 / max(1e-6, np.abs(track).max())
    pcm = (np.clip(track.T, -1, 1) * 32767).astype("<i2")
    with wave.open(out_path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    print(f"{out_path}  {total:.1f}s")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
