#!/usr/bin/env bash
set -e

echo "=========================================================="
echo "  Offline SOS Bridge - Android APK Automated Build Script"
echo "=========================================================="

# Check for Flutter in PATH or common directories
if ! command -v flutter &> /dev/null; then
  if [ -f "$HOME/tools/flutter/bin/flutter" ]; then
    export PATH="$HOME/tools/flutter/bin:$PATH"
  elif [ -f "$HOME/flutter/bin/flutter" ]; then
    export PATH="$HOME/flutter/bin:$PATH"
  else
    echo "❌ Error: Flutter SDK not found in PATH."
    echo "Please ensure Flutter is installed and added to your PATH."
    echo "Visit: https://docs.flutter.dev/get-started/install"
    exit 1
  fi
fi

echo "🔹 Flutter SDK: $(flutter --version | head -n 1)"

# Check for Java
if ! command -v java &> /dev/null; then
  echo "⚠️ Warning: 'java' not found in PATH. Ensure OpenJDK 17 is installed."
fi

echo "📦 Resolving project dependencies..."
flutter pub get

echo "🔨 Building Release APK (Signed with standard debug release config)..."
flutter build apk --release

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

if [ -f "$APK_PATH" ]; then
  echo "=========================================================="
  echo "🎉 SUCCESS! APK successfully generated at:"
  echo "   $(pwd)/$APK_PATH"
  echo "   File Size: $(du -h "$APK_PATH" | cut -f1)"
  echo "=========================================================="
  echo "📲 You can now transfer and install this APK on any Android phone!"
else
  echo "❌ Build finished but APK was not found at $APK_PATH"
  exit 1
fi
