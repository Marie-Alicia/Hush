# Hush: NotePin S → YAMNet stream test

Checks the first technical question in the Hush plan: **can a phone reliably spot a baby's
cry, live, from the NotePin S audio stream?** It adds a "Cry test" screen to Plaud's own iOS
template app ([Plaud-AI/plaud-sdk-public](https://github.com/Plaud-AI/plaud-sdk-public), Apache 2.0).

## How the audio flows

```
NotePin S ──BLE──▶ PlaudDeviceAgent.blePcmData(sessionId:millsec:pcmData:isMusic:)
                   640-byte chunks · 16 kHz · mono · Int16 · ~20 ms each
                        │  (one line added to the template's DeviceManager)
                        ▼
                  HushAudioTap ──▶ CryDetector
                                     • 15,600-sample window (0.975 s), scored every 0.48 s
                                     • YAMNet TFLite → max("Baby cry, infant cry", "Crying, sobbing")
                                     • 3-frame moving average
                                     • opens an episode at ≥ 0.35, closes after 8 s below 0.20
                                     • saves cry + 10 s pre-roll as WAV; other audio is never stored
                        ▼
                  frames.csv (every frame + your "crying / false alarm" taps) → Export
```

## Files

| File | What it does |
|---|---|
| `HushStreamTest/CryDetector.swift` | Sliding window, YAMNet inference, smoothing, episode logic, WAV clips, BLE gap detection |
| `HushStreamTest/HushAudioTap.swift` | Receives PCM from `DeviceManager`, runs a test session, writes `frames.csv` |
| `HushStreamTest/CryStreamTestViewController.swift` | Test screen: live score, score chart, stream health, ground-truth buttons, CSV export |
| `setup.sh` | Clones the Plaud template, copies these files in, adds the two hook lines, downloads YAMNet, adds TensorFlow Lite |
| `tools/offline_yamnet.py` | Runs the same logic over a whole exported night on your Mac, for tuning thresholds |

## Setup

You need a Mac with Xcode 16+, a physical iPhone (the Plaud SDK has no simulator build), a
**NotePin S** (the original NotePin isn't supported by the SDK) and a Plaud Developer Platform
User Access Token.

```bash
brew install xcodegen cocoapods
./setup.sh
```

Then:
1. Put your token in `build/plaud-sdk-public/ios/PartnerConfig.local.xcconfig` as `USER_ACCESS_TOKEN = …`
2. Change `DEVELOPMENT_TEAM` in `build/plaud-sdk-public/ios/project.yml` to your Apple team, then
   `cd build/plaud-sdk-public/ios && xcodegen generate && pod install`
3. Open `PlaudTemplateApp.xcworkspace`, run it on the iPhone, pair the NotePin S, and tap **Cry test**.

If `setup.sh` can't find where to add the hooks (Plaud may change the template), add them by hand:

```swift
// DeviceManager.swift, inside blePcmData(sessionId:millsec:pcmData:isMusic:)
HushAudioTap.shared.ingest(sessionId: sessionId, millsec: millsec, pcm: pcmData)

// MainTabBarController.swift, in viewDidLoad() after setupFloatingBar()
CryStreamTestLauncher.install(on: self)
```

## Field test protocol (one night per family)

1. Clip the NotePin S about 1 m from the cot. Put the phone on a charger with the test screen open.
   The screen stays awake so iOS doesn't pause Bluetooth.
2. Tap **Start test**. Whenever the baby really cries, tap **Baby is crying**. If the screen shows
   "Crying detected" when the baby isn't crying, tap **False alarm**.
3. In the morning, tap **Export CSV** and save the recording from the Plaud app as WAV.
4. On your Mac, rerun with different thresholds:
   ```bash
   pip install numpy ai-edge-litert
   python tools/offline_yamnet.py night.wav --model yamnet.tflite --classes yamnet_class_map.csv --start 0.30
   ```

**Pass criteria for moving on to the classifier work**

| Measure | Target |
|---|---|
| Real cries detected (recall) | ≥ 95% of the cries you tapped |
| False alarms | ≤ 1 per night |
| Time to detect | ≤ 3 s after crying starts |
| Stream health | gaps under 1% of audio; average inference under 30 ms |

## Known limits

- **Checked so far:** `CryDetector` was compiled and run on macOS with a stand-in model. It detected one simulated cry, flagged a simulated 200 ms Bluetooth gap, and saved a 24.9 s WAV (10 s pre-roll + 6 s cry + 8 s tail).
- **Not checked yet:** the UIKit test screen and the real TensorFlow Lite model haven't been built. That needs Xcode with the iOS SDK, which the machine I wrote this on doesn't have.
- The `millsec` gap check assumes `millsec` is the recording's running position in milliseconds. Confirm that on the first device run.
- The SDK streams audio while the NotePin S is recording, and this test starts a recording. That recording also stays on the pin, so delete it or sync it afterwards.
- YAMNet is a general sound model. Expect confusion with TV babies, siblings and some pets. The server-side PANNs check in the plan is there to catch these.
