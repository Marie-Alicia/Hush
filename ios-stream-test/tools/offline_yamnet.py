"""Replays a NotePin S recording through the same YAMNet cry logic as the iPhone test.

Use it to tune thresholds on a whole night at once: export the night's recording from the
Plaud app as WAV (16 kHz mono), run this, and compare the episodes with what you noted.

    pip install numpy ai-edge-litert
    python offline_yamnet.py night.wav --model yamnet.tflite --classes yamnet_class_map.csv
    python offline_yamnet.py night.wav --start 0.30 --stop 0.15 --csv frames.csv
"""
import argparse
import csv
import wave

import numpy as np

try:
    from ai_edge_litert.interpreter import Interpreter
except ImportError:  # older installs
    from tflite_runtime.interpreter import Interpreter

SR, WINDOW, HOP = 16_000, 15_600, 7_680


def load_wav(path):
    with wave.open(path, "rb") as w:
        if w.getframerate() != SR or w.getsampwidth() != 2:
            raise SystemExit(f"{path}: needs 16 kHz 16-bit WAV (got {w.getframerate()} Hz, {8 * w.getsampwidth()}-bit)")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        if w.getnchannels() > 1:
            pcm = pcm.reshape(-1, w.getnchannels()).mean(axis=1)
    return pcm.astype(np.float32) / 32768.0


def load_labels(path):
    with open(path, newline="") as f:
        return [row["display_name"] for row in csv.DictReader(f)]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("wav")
    p.add_argument("--model", default="yamnet.tflite")
    p.add_argument("--classes", default="yamnet_class_map.csv")
    p.add_argument("--start", type=float, default=0.35, help="smoothed score that opens an episode")
    p.add_argument("--stop", type=float, default=0.20, help="score that keeps an episode alive")
    p.add_argument("--smooth", type=int, default=3)
    p.add_argument("--end-after", type=float, default=8.0)
    p.add_argument("--csv", help="write every frame here")
    a = p.parse_args()

    audio = load_wav(a.wav)
    labels = load_labels(a.classes)
    cry_idx = [labels.index(n) for n in ("Baby cry, infant cry", "Crying, sobbing")]

    interp = Interpreter(model_path=a.model)
    interp.allocate_tensors()
    inp, out = interp.get_input_details()[0], interp.get_output_details()[0]

    recent, episodes, frames = [], [], []
    open_at = last_loud = None
    peak = 0.0
    for start in range(0, len(audio) - WINDOW + 1, HOP):
        interp.set_tensor(inp["index"], audio[start:start + WINDOW].reshape(inp["shape"]))
        interp.invoke()
        scores = interp.get_tensor(out["index"]).reshape(-1)
        t = (start + WINDOW) / SR
        cry = float(max(scores[i] for i in cry_idx))
        recent = (recent + [cry])[-a.smooth:]
        smoothed = sum(recent) / len(recent)

        if open_at is not None:
            if smoothed >= a.stop:
                last_loud, peak = t, max(peak, smoothed)
            if t - last_loud >= a.end_after:
                episodes.append((open_at, last_loud, peak))
                open_at = None
        elif smoothed >= a.start:
            open_at, last_loud, peak = t, t, smoothed

        top = int(scores.argmax())
        frames.append((round(t, 2), round(cry, 4), round(smoothed, 4), labels[top], round(float(scores[top]), 4), int(open_at is not None)))

    if open_at is not None:
        episodes.append((open_at, last_loud, peak))

    hms = lambda s: f"{int(s // 3600):02d}:{int(s % 3600 // 60):02d}:{int(s % 60):02d}"
    print(f"{len(audio) / SR / 60:.1f} min of audio · {len(frames)} frames · {len(episodes)} cry episodes")
    for s, e, pk in episodes:
        print(f"  {hms(s)} → {hms(e)}  ({e - s:4.0f} s)  peak {pk:.2f}")

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["stream_s", "cry_score", "smoothed", "top_label", "top_score", "in_episode"])
            w.writerows(frames)
        print(f"frames written to {a.csv}")


if __name__ == "__main__":
    main()
