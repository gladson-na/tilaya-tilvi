#!/usr/bin/env bash
# Run from the app folder after `flutter create`. Adds the typing service to the Android project.
set -euo pipefail
PKG=$(grep -hoE 'applicationId *= *"[^"]+"' android/app/build.gradle* | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "package: $PKG"
DIR=android/app/src/main/kotlin/$(echo "$PKG" | tr . /)
mkdir -p "$DIR" android/app/src/main/res/xml android/app/src/main/res/values
sed "s/PKG_NAME/$PKG/" native/MainActivity.kt > "$DIR/MainActivity.kt"
sed "s/PKG_NAME/$PKG/" native/TildaService.kt > "$DIR/TildaService.kt"
sed "s/PKG_NAME/$PKG/" native/NotesService.kt > "$DIR/NotesService.kt"
sed "s/PKG_NAME/$PKG/" native/WakeService.kt > "$DIR/WakeService.kt"
cp native/tilda_accessibility.xml android/app/src/main/res/xml/
cp native/tilda_strings.xml android/app/src/main/res/values/
M=android/app/src/main/AndroidManifest.xml
SVC="<service android:name=\"$PKG.TildaService\" android:exported=\"true\" android:label=\"Tilda typing\" android:permission=\"android.permission.BIND_ACCESSIBILITY_SERVICE\"><intent-filter><action android:name=\"android.accessibilityservice.AccessibilityService\"/></intent-filter><meta-data android:name=\"android.accessibilityservice\" android:resource=\"@xml/tilda_accessibility\"/></service>"
NS="<service android:name=\"$PKG.NotesService\" android:exported=\"false\" android:foregroundServiceType=\"microphone|mediaProjection\"/>"
WS="<service android:name=\"$PKG.WakeService\" android:exported=\"false\" android:foregroundServiceType=\"microphone\"/>"
sed -i "s#</application>#$SVC$NS$WS</application>#" "$M"
grep -c TildaService "$M"
grep -c NotesService "$M"
grep -c WakeService "$M"

# Launcher icon (the Tilda wave-T on teal) and the app name
RES=android/app/src/main/res
mkdir -p "$RES/mipmap-anydpi-v26"
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  mkdir -p "$RES/mipmap-$d"
  cp "native/icons/ic_launcher_$d.png" "$RES/mipmap-$d/ic_launcher.png"
  cp "native/icons/ic_launcher_$d.png" "$RES/mipmap-$d/ic_launcher_round.png"
  cp "native/icons/ic_launcher_foreground_$d.png" "$RES/mipmap-$d/ic_launcher_foreground.png"
done
cat > "$RES/values/tilda_colors.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><color name="tilda_icon_bg">#0B6B5A</color></resources>
XML
for n in ic_launcher ic_launcher_round; do
  cat > "$RES/mipmap-anydpi-v26/$n.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/tilda_icon_bg"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XML
done
sed -i '0,/android:label="[^"]*"/s##android:label="Tilda"#' "$M"
sed -i 's#android:icon="@mipmap/ic_launcher"#android:icon="@mipmap/ic_launcher" android:roundIcon="@mipmap/ic_launcher_round"#' "$M"
grep -c 'android:label="Tilda"' "$M"
