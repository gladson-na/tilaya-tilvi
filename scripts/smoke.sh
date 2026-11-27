#!/usr/bin/env bash
# Installs the APK on the running emulator, opens it, waits, and fails if it crashed or died.
set -u
APK="$1"
AAPT=$(ls "$ANDROID_HOME"/build-tools/*/aapt | sort -V | tail -1)
PKG=$("$AAPT" dump badging "$APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
echo "package: $PKG"
echo "phone: Android $(adb shell getprop ro.build.version.release) (API $(adb shell getprop ro.build.version.sdk)), $(adb shell getprop ro.product.cpu.abi)"
echo "app needs: $("$AAPT" dump badging "$APK" | grep -E "^(minSdkVersion|sdkVersion):" | head -1)"
OUT=$(adb install -r "$APK" 2>&1); echo "$OUT"
echo "$OUT" | grep -q "Success" || { echo "INSTALL FAILED"; exit 1; }
adb shell pm grant "$PKG" android.permission.RECORD_AUDIO >/dev/null 2>&1 || true
adb shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 25
PID=$(adb shell "ps | grep $PKG" | tr -d '\r' | awk '{print $2}' | head -1)
adb logcat -d > /tmp/log.txt
adb exec-out screencap -p > "${SCREENSHOT:-/tmp/shot.png}" || true
if grep -q "FATAL EXCEPTION" /tmp/log.txt && grep -A12 "FATAL EXCEPTION" /tmp/log.txt | grep -q "$PKG"; then
  echo "CRASH:"; grep -A14 "FATAL EXCEPTION" /tmp/log.txt | head -40; exit 1
fi
if [ -z "$PID" ]; then echo "APP IS NOT RUNNING after 25 seconds"; tail -40 /tmp/log.txt; exit 1
fi
echo "OK: the app opened and stayed running (pid $PID)"
