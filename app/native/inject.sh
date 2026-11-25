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
cp native/tilda_accessibility.xml android/app/src/main/res/xml/
cp native/tilda_strings.xml android/app/src/main/res/values/
M=android/app/src/main/AndroidManifest.xml
SVC="<service android:name=\"$PKG.TildaService\" android:exported=\"true\" android:label=\"Tilda typing\" android:permission=\"android.permission.BIND_ACCESSIBILITY_SERVICE\"><intent-filter><action android:name=\"android.accessibilityservice.AccessibilityService\"/></intent-filter><meta-data android:name=\"android.accessibilityservice\" android:resource=\"@xml/tilda_accessibility\"/></service>"
NS="<service android:name=\"$PKG.NotesService\" android:exported=\"false\" android:foregroundServiceType=\"microphone\"/>"
sed -i "s#</application>#$SVC$NS</application>#" "$M"
grep -c TildaService "$M"
grep -c NotesService "$M"
