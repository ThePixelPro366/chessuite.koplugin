#!/bin/sh
# Builds the companion app with the Android SDK tools only (no Gradle, no
# downloads): aapt2, javac, d8, zipalign, apksigner.
# Usage: ANDROID_HOME=/path/to/sdk ./build-apk.sh   -> build/chessuite-companion.apk
# (Android Studio / Gradle users can build the same sources with ./gradlew assembleRelease.)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
BT="$SDK/build-tools/${BUILD_TOOLS:-35.0.0}"
JAR="$SDK/platforms/android-${PLATFORM:-34}/android.jar"
SRC="$HERE/app/src/main"
OUT="$HERE/build"
rm -rf "$OUT"
mkdir -p "$OUT/res" "$OUT/classes" "$OUT/dex"

"$BT/aapt2" compile --dir "$SRC/res" -o "$OUT/res/res.zip"
# Gradle takes the package from build.gradle.kts (namespace); aapt2 wants it in the manifest
sed 's|<manifest |<manifest package="app.chessuite.companion" |' "$SRC/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"
"$BT/aapt2" link -o "$OUT/unsigned.apk" -I "$JAR" --manifest "$OUT/AndroidManifest.xml" \
    --min-sdk-version 24 --target-sdk-version 34 --version-code 1 --version-name 1.0 \
    --rename-manifest-package app.chessuite.companion \
    --java "$OUT/gen" "$OUT/res/res.zip"
javac --release 8 -nowarn -Xlint:-options -classpath "$JAR" -d "$OUT/classes" \
    $(find "$SRC/java" "$OUT/gen" -name '*.java')
(cd "$OUT/classes" && jar cf "$OUT/classes.jar" .)
"$BT/d8" --release --min-api 24 --lib "$JAR" --output "$OUT/dex" "$OUT/classes.jar"
cp "$OUT/unsigned.apk" "$OUT/with-dex.apk"
(cd "$OUT/dex" && zip -q -j "$OUT/with-dex.apk" classes.dex)
"$BT/zipalign" -f 4 "$OUT/with-dex.apk" "$OUT/aligned.apk"

KEY="${KEYSTORE:-$HERE/companion-debug.keystore}"
if [ ! -f "$KEY" ]; then
    keytool -genkeypair -keystore "$KEY" -storepass android -keypass android -alias companion \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Chessuite Companion" >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KEY" --ks-pass pass:android --key-pass pass:android \
    --out "$OUT/chessuite-companion.apk" "$OUT/aligned.apk"
echo "built $OUT/chessuite-companion.apk"
