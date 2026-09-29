#!/usr/bin/env bash
# Builds the NotePin S → YAMNet stream test on top of Plaud's own iOS template app.
# Usage: ./setup.sh [work-dir]      (default: ./build)
# Needs: git, curl, xcodegen (brew install xcodegen), CocoaPods (brew install cocoapods)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/build}"
REPO="$WORK/plaud-sdk-public"
IOS="$REPO/ios"
MODEL_URL="https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/audio_classification/android/lite-model_yamnet_classification_tflite_1.tflite"
MODEL_SHA="10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de"
CLASSMAP_URL="https://raw.githubusercontent.com/tensorflow/models/master/research/audioset/yamnet/yamnet_class_map.csv"

command -v xcodegen >/dev/null || { echo "xcodegen is missing. Install it with: brew install xcodegen"; exit 1; }
command -v pod >/dev/null || { echo "CocoaPods is missing. Install it with: brew install cocoapods"; exit 1; }

mkdir -p "$WORK"
if [ ! -d "$REPO" ]; then
  echo "→ Cloning Plaud SDK template app"
  git clone --depth 1 https://github.com/Plaud-AI/plaud-sdk-public.git "$REPO"
fi

echo "→ Copying Hush stream test sources"
mkdir -p "$IOS/PlaudTemplateApp/Hush" "$IOS/HushModel"
cp "$HERE"/HushStreamTest/*.swift "$IOS/PlaudTemplateApp/Hush/"

echo "→ Downloading YAMNet (TFLite, 4.1 MB) and its class map"
curl -fsSL -o "$IOS/HushModel/yamnet.tflite" "$MODEL_URL"
echo "$MODEL_SHA  $IOS/HushModel/yamnet.tflite" | shasum -a 256 -c - >/dev/null || { echo "yamnet.tflite checksum does not match"; exit 1; }
curl -fsSL -o "$IOS/HushModel/yamnet_class_map.csv" "$CLASSMAP_URL"

echo "→ Hooking blePcmData into HushAudioTap"
DM="$IOS/PlaudTemplateApp/Managers/DeviceManager.swift"
grep -q "HushAudioTap" "$DM" || perl -0pi -e 's|(\n(\s*)RecordingManager\.shared\.handlePcmData\(pcmData: pcmData\)[^\n]*)|$1\n$2HushAudioTap.shared.ingest(sessionId: sessionId, millsec: millsec, pcm: pcmData)|' "$DM"
grep -q "HushAudioTap" "$DM" || { echo "Could not patch DeviceManager.blePcmData. Add the line by hand (see README)."; exit 1; }

echo "→ Adding the Cry test button to the main screen"
TB="$IOS/PlaudTemplateApp/UI/Main/MainTabBarController.swift"
grep -q "CryStreamTestLauncher" "$TB" || perl -0pi -e 's|(\n(\s*)setupFloatingBar\(\)\n)|$1$2CryStreamTestLauncher.install(on: self)\n|' "$TB"
grep -q "CryStreamTestLauncher" "$TB" || { echo "Could not patch MainTabBarController. Add the line by hand (see README)."; exit 1; }

echo "→ Bundling the model"
grep -q "HushModel" "$IOS/project.yml" || perl -0pi -e 's|(\n(\s*)- path: \.\./sdk/ios/PlaudDeviceBasicSDK\.bundle\n)|$1$2- path: HushModel\n|' "$IOS/project.yml"
grep -q "HushModel" "$IOS/project.yml" || { echo "Could not add HushModel to project.yml resources."; exit 1; }

echo "→ Adding TensorFlow Lite"
cat > "$IOS/Podfile" <<'EOF'
platform :ios, '14.0'

target 'PlaudTemplateApp' do
  use_frameworks!
  pod 'TensorFlowLiteSwift', '~> 2.14'
end
EOF

cd "$IOS"
xcodegen generate
pod install

cat <<EOF

Done. Next:
  1. Put your Plaud User Access Token in $IOS/PartnerConfig.local.xcconfig
  2. Set your own DEVELOPMENT_TEAM in $IOS/project.yml, then run: cd "$IOS" && xcodegen generate && pod install
  3. open "$IOS/PlaudTemplateApp.xcworkspace" and run on a physical iPhone (the Plaud SDK has no simulator build)
  4. Pair the NotePin S in the app, then tap "Cry test" at the top right.
EOF
