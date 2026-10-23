# Known limitations

This list is honest about what is not implemented or not verified. Items marked
**unverified** are implemented but have not been exercised on real hardware.

## Verification status

* **No device builds were run.** The development machine (Windows) has no Android SDK
  and cannot build for iOS. The Dart code passes `flutter analyze` with no errors or
  warnings, and 66 automated tests pass on the host, including widget smoke tests of
  the main screens. `flutter build apk`/`ipa` and a run on physical phones have **not**
  been done. **Unverified:** camera scanning, the LAN socket between two phones, Google
  Sign-In, and file sharing and picking.
* **Two-device sync over real Wi-Fi is unverified.** The full protocol (pairing, SAS,
  approvals, sync, interruption, resume) is tested over an in-memory transport. The TCP
  transport shares the same code path but has not been run phone-to-phone.

## Connectivity

* **Direct internet sync is best-effort.** There is no relay server, by design. Phones on
  different networks can connect only if the phone **showing** the code is reachable:
  * through **public IPv6**, if both networks have IPv6 and neither firewall blocks
    incoming connections (many home routers do by default; some mobile carriers allow
    it), or
  * through a **router port mapping**. This needs a home router with NAT-PMP or UPnP
    enabled, and a router that is not itself behind carrier-grade NAT. UPnP is used on
    Android only, because iOS requires an Apple-approved multicast entitlement;
    NAT-PMP works on both.

  It **will not work** when both phones are on mobile data behind carrier-grade NAT
  without usable IPv6, or on guest or corporate Wi-Fi. Swapping which phone shows the
  code sometimes helps. Otherwise, use one Wi-Fi or hotspot, or send an encrypted sync
  file.
* **Not implemented:** TCP or UDP hole punching. It would need both phones to exchange
  fresh addresses at the same moment, which a one-way QR or message cannot do without a
  rendezvous server.
* **Open port while hosting:** with internet connections allowed and the Connect or Sync
  screen open, the listening port may be exposed to the internet through IPv6 or the
  router mapping. Only authenticated peers get past the handshake (a valid invitation
  secret, or a pinned paired key). The mapping is removed when the screen closes, and it
  can be switched off in Sync.
* **The code contains network addresses,** including the public IPv6 and IPv4, so share
  it only with the intended person.
* **When apart, compare the SAS on a voice call.** The pairing code sent through a
  messenger is only as trustworthy as that messenger, and the 6-digit comparison over an
  independent channel is what defeats interception.
* **Not implemented:** Wi-Fi Direct, Multipeer Connectivity, BLE and mDNS discovery.
* **Foreground only.** iOS and Android suspend sockets in the background, so sync runs
  only while the Sync or Connect screen is open.
* **Unverified on hardware:** the port-mapping and IPv6 paths are tested against fake
  routers and real loopback sockets on the host, not against real routers or carriers.

## Data and sync

* **Receipt photos are not synced.** They stay on the device that attached them, and they
  are not included in backups.
* **Profile renames do not propagate.** Other members see the name that was recorded in
  the group membership. An admin can re-add or edit the member to update it.
* **Revoking a device is local.** It stops this phone from syncing with that device. It
  does not remove the person from groups (use "Remove from group") and does not revoke
  their key for other members.
* **Removing a member stops what they can author, not what they can read.** They keep
  the history they already synced.
* **Replay cost.** Each received batch replays its group (O(changes in the group)). This
  is fine for hundreds to low thousands of changes per group. Very large groups would
  need incremental replay.
* **The 24-hour clock-skew guard** rejects changes from a device whose clock is more than
  a day fast. Fixing the clock and editing again resolves it.
* **One identity on two phones at once:** restoring a backup onto a second phone while the
  first is still in use works (each phone has its own device id), but both act as the
  same person.

## Security

* **The SQLite database is not encrypted at the application level.** It sits in the
  app's private sandbox, protected by Android file-based encryption and iOS Data
  Protection, and it is excluded from Android Auto Backup and from iCloud device
  backups. SQLCipher (`sqflite_sqlcipher`) was not added because it would replace the
  sqflite engine and could not be built or verified on this machine. It is the
  recommended next step if threat models include forensic access to an unlocked device.
* **The handshake** is a SIGMA-I/TLS-1.3-style composition of standard primitives
  (X25519, Ed25519, HKDF-SHA256, AES-256-GCM from `package:cryptography`). It is not a
  formally verified protocol such as Noise, because no maintained Noise implementation
  exists for Dart. It should get an external review before production use.
* **The SAS is 6 digits** (about 20 bits). That is adequate for an in-person comparison
  only; do not read it over an untrusted channel.
* **Scheduled backups** store the backup passphrase in platform secure storage when the
  user opts in.

## Backup

* **Scheduled backup** runs when the app is opened and the last backup is more than 24 h
  old. There is no OS background job (WorkManager/BGTaskScheduler).
* **Google Sign-In needs OAuth clients** created in Google Cloud for each platform (see
  OPERATIONS.md). Without them the Drive option fails, and every other feature keeps
  working.
* **A forgotten backup passphrase cannot be recovered.**
