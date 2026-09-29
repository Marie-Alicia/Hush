# Hush

**Hush learns what your baby's cries tend to mean, and looks after you while you settle them.**

New parents lie awake wondering what their baby needs, and their own stress rises with every unexplained cry. Hush listens through a clip-on mic, an iPhone or the baby monitor a family already owns. It learns one baby's patterns from what actually settled each cry, and it supports the parent too: calm-down help at 3am, a safe way to take a break, fair night shifts, and support when things feel heavy.

Built for an AI conference hack day, September 2026.

## Try it

- **Interactive demo:** open [`docs/demo.html`](docs/demo.html) in a browser. It has 17 clickable screens, runs on sample data, and needs no install.
- **Website:** [`docs/index.html`](docs/index.html).
- **Run it locally:** `python3 -m http.server 8000 --directory docs`, then open http://localhost:8000.

## What's in the demo

| Area | Screens |
| --- | --- |
| **Listening** | Choose NotePin S, the iPhone's microphone and/or a baby monitor. With two sources, a cry has to be heard by both, which cuts false alarms. |
| **The baby** | Night mode; a live cry card with ranked guesses and the reasons behind them; one-tap "what settled her?"; a day timeline; the baby's cry profile; weekly insights; a flag for unusual cries |
| **The parent** | Calm Coach (breathing, grounding, kind words); Settle Guide with a 5-minute safe break (based on the NHS-backed ICON programme); daily check-in with a mood trend; tag-team nights with a partner; morning reflection; crisis support with UK and US helplines |
| **Health team** | Real PDF reports: a health visitor summary, an urgent summary for a doctor, and "my wellbeing" for the parent's GP |
| **Developer** | A simulation of the live NotePin S → YAMNet cry-detection stream test, with the real Swift source |

## How it works

```
NotePin S / iPhone mic / baby monitor
        │  live 16 kHz audio
        ▼
On the phone: YAMNet cry detection  ──  everything that isn't crying is deleted immediately
        │  cry clips + context (time since feed, sleep)
        ▼
Per-baby model: sound features (openSMILE, BEATs embeddings) + routine
        │  ranked guesses shown only when sound beats routine alone
        ▼
Parent taps what settled the cry  ──▶  the model learns this baby
        │
        ├─ Claude: weekly insights, morning reflection, tag-team messages (from logs, never audio)
        ├─ Fixed rules (not AI): red-flag cries and crisis words → NHS 111, 999, Samaritans
        └─ PDF reports for the health visitor or GP
```

## Repository

| Folder | What it is |
| --- | --- |
| [`docs/`](docs/) | The website and the interactive demo (static HTML, no build step). The folder is called `docs` so GitHub Pages can serve it. |
| [`ios-stream-test/`](ios-stream-test/) | Swift code that streams live audio from a Plaud NotePin S into YAMNet cry detection, built on Plaud's iOS template app. Includes a setup script and a Python tool for replaying a recorded night. See its [README](ios-stream-test/README.md). |
| [`plan/`](plan/) | The product plan, model choices and competitor research. |
| `netlify.toml` | Settings for deploying `docs/` on Netlify. |

## Status

This is a prototype. The demo runs on sample data, with an example baby called Isla and a parent called Sam. The stream-test code was compiled and run against a stand-in model; it hasn't yet run on an iPhone with a NotePin S.

## Safety

Hush is not a medical device and does not diagnose. It points parents to NHS advice. Calm-down scripts and crisis support would need review by a perinatal mental health clinician before real use.

If you're worried about a baby, call NHS 111, or 999 in an emergency. If you're struggling, Samaritans are free on 116 123, day or night.

## Rights

No licence is granted. All rights are reserved by the author. You're welcome to view the code and run the demo for the hack day.
