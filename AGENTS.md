# MeetingDesk / Toplantı

Native personal macOS meeting app. SwiftPM target is MeetingDesk; app bundle is Toplanti.app and bundle ID stays com.altugegesari.meetingdesk.

## Working rules

- Keep meeting archives, recordings, exported notes, API tokens and private signing keys out of Git and release assets. The user archive is ~/Library/Application Support/MeetingDesk; do not modify it for tests.
- Preserve local Turkish transcription, microphone/system source separation, gain, pause timestamps, recovery receipts, and backward compatibility of saved meetings.
- Updates use Sparkle 2.10.0. Keep the embedded Ed25519 public key stable; the private signing key stays in the local Keychain unless the user explicitly authorizes a CI secret.
- Update checks and relaunch must wait for recording, recovery, transcription, summary and file persistence to finish. Never cancel work to install an update.
- Public/private release visibility is a user choice. Do not expose a private repository or meeting data while changing release delivery.
- Increase both CFBundleShortVersionString and CFBundleVersion for a new release. Published release assets are immutable. Use Packaging/release.py and docs/RELEASING.md.
- Do not report tests or generated-audio probes as proof of live microphone capture or successful in-app installation. State those verification boundaries separately.

## Checks

Run swift test --disable-sandbox --disable-keychain --cache-path .build/cache --scratch-path .build with CLANG_MODULE_CACHE_PATH and SWIFT_MODULECACHE_PATH under .build/ModuleCache. Run python3 -m unittest discover -s Packaging -p test_*.py. Package using zsh Packaging/build.sh into a fresh dist directory. Verify the package signature and update configuration before publishing.
