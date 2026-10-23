# Installation, deployment and recovery

## Requirements

* Flutter stable 3.47+ (Dart 3.13+).
* Android: SDK with API 36 build tools, minSdk 23.
* iOS: Xcode 16+, iOS 13+.

## Build and test

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release        # Android
flutter build ipa --release        # iOS (on macOS)
```

Host tests use `sqflite_common_ffi`, so no device or emulator is needed.

## Production release (Android)

1. **Create a release key once and back it up.** If it is lost, you can never publish
   updates to the same app.
   ```
   "C:\Program Files\Java\jdk-22in\keytool.exe" -genkeypair -v -keystore D:\keys\splitmate-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias splitmate
   ```
2. Copy `android/key.properties.example` to `android/key.properties` and fill in the
   passwords. The file is git-ignored. Without it, release builds are signed with the
   debug key and Gradle prints a warning.
3. Set the version in `pubspec.yaml` (`version: 1.2.0+3` means name 1.2.0 and code 3; the
   code must increase with every release), or pass it on the command line:
   ```
   flutter build apk --release --build-name=1.0.0 --build-number=1
   ```
4. The output is `build/app/outputs/flutter-apk/app-release.apk`. Rename it, e.g. to
   `splitmate-1.0.0.apk`. For Google Play, upload an App Bundle instead:
   `flutter build appbundle --release` → `build/app/outputs/bundle/release/app-release.aab`.

## Optional: Google Drive backup setup

SplitMate never requires Google. To enable the optional Drive backup:

1. Create a Google Cloud project and enable the **Google Drive API**.
2. Configure the OAuth consent screen with the scope
   `https://www.googleapis.com/auth/drive.appdata` (the app's private folder only).
3. Create OAuth clients:
   * **Android:** package `app.splitmate.splitmate` plus the SHA-1 of your signing key.
   * **iOS:** bundle id `app.splitmate.splitmate`. Put the client id into
     `ios/Runner/Info.plist` (`GIDClientID`) and the reversed client id into
     `CFBundleURLSchemes`. Both currently hold `YOUR_IOS_CLIENT_ID` placeholders.
4. No server, database or API key of your own is needed.

## Permissions

| Platform | Permission | Why |
| --- | --- | --- |
| Android | `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE` | TCP sync on the LAN, optional Drive |
| Android | `CAMERA` | QR scanning, receipt photos |
| iOS | `NSLocalNetworkUsageDescription` | Connecting to phones on the same network |
| iOS | `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` | QR, receipts |

Android Auto Backup is disabled and iOS Documents is excluded from device backup, so
the ledger is never copied to the cloud without the user's explicit, encrypted backup.

## What happens if…

| Situation | Result | What to do |
| --- | --- | --- |
| **Phone lost, have a backup** | Restoring the `.smbk` backup recreates the identity (same user id and keys) under a new device id. Paired friends accept the new device automatically, because the key is the same. | Install, choose *Restore from a backup file* (or get started, then Account → Backup → Drive), enter the passphrase, then sync with a friend for anything newer. |
| **Phone lost, no backup** | The identity's private key is gone. Shared groups still exist on friends' phones. | Start fresh, then ask a group admin to invite you again by QR. Your old member entry remains in history. An admin opens the group's Members tab, chooses "Replace with a new phone" on your old entry, and you scan that code; your old balances are linked to the new identity. |
| **App reinstalled on the same phone** | Android: the database and keys are removed. iOS: Keychain items marked *this device only* can survive a reinstall, but the database does not. | Same as "phone lost". If the app finds keys but no database, it shows an empty ledger with the old identity: sync with friends, or restore a backup (it merges). |
| **Private key lost or corrupted** | You cannot sign new changes as that identity. | Restore a backup, or start fresh and be re-invited. |
| **Restore onto a phone that already has newer data** | Restoring the same identity **merges**: nothing local is deleted or overwritten, missing records are added, and concurrent edits show up as conflicts. | Nothing extra. |
| **Restore someone else's backup over existing data** | Refused. | Delete all data first (Privacy → Delete), then restore. |
| **Wrong passphrase / corrupted / truncated file** | Rejected before anything is written (AES-GCM tag, header AAD and payload SHA-256 are all checked). | Use the right passphrase, or another backup. |
| **Backup from a newer app version** | Refused with "update the app". | Update SplitMate. |
| **Database schema upgrade** | Migrations run in a transaction on open. An older app refuses a newer database. | None. |

## Recovery passphrase

The passphrase is stretched with Argon2id (19 MiB, 2 passes) into an AES-256-GCM key.
It is never stored next to the backup. It is stored on the phone only if the user turns
on automatic backups, and then only in the Keychain/Keystore. There is no way to recover
a lost passphrase.
