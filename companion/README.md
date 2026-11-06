# Chessuite Companion (Android)

The Lichess API cannot request a server analysis ("Request computer analysis"
on the website), and the Lichess login page is meant to be used in a real
browser. This tiny, optional app opens lichess.org in a browser view on your
phone, where you log in yourself, and hands that website login to Chessuite
on your e-reader over your Wi-Fi.

This is an unofficial helper, not affiliated with Lichess, and not an official
Lichess API. Use it at your own discretion.

1. On the e-reader: Chessuite → Lichess account → Connect phone for Lichess analysis.
2. Scan the QR code with the phone camera, tap "Open in Chessuite Companion"
   (the page also offers the app for download, served by the e-reader).
3. Log in to Lichess in the app; it sends the login to the e-reader, which
   checks the one-time code and stops listening.

The login is a full Lichess website session. It only travels over your local
network, to the e-reader that showed the one-time code, and is stored in
Chessuite's settings; "Forget phone login" removes it.

Build: `ANDROID_HOME=/path/to/sdk ./build-apk.sh` (SDK tools only, no
downloads), or `gradle assembleRelease`. `companion-debug.keystore` is a
throwaway signing key kept in the repo so that rebuilt APKs install as updates.
Because that key is public, anyone can sign an APK with it: only install the
APK from this repository or from your own e-reader.
