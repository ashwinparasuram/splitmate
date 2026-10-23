# SplitMate — design

SplitMate is an offline-first, peer-to-peer expense-sharing app for Android and iOS.
There is no application server and no cloud database. Each device keeps its own
SQLite database. Devices exchange signed change records directly with each other.
Google Drive is optional and is used only for encrypted backups.

This document is the source of truth for the data model, the sync protocol, the
conflict rules and the backup format. `docs/LIMITATIONS.md` lists what is not done,
and `docs/OPERATIONS.md` covers installation and recovery.

## 1. Research notes (REA and Splitwise workflows)

REA (`mcp__rea__*`, from github.com/morluto/rea) was installed and connected for this
work. Its capabilities were checked:

| REA capability | Status on this machine |
| --- | --- |
| MCP server and static-analysis tools | available |
| `inspect_adb_client` (pull/inspect the Splitwise Android app) | **unavailable**: no `adb` binary |
| `inspect_apktool_client` (decode an APK) | **unavailable**: no `apktool` |
| browser/CDP tools (inspect splitwise.com in a page) | **unavailable**: no loopback CDP endpoint was running |
| Splitwise APK/IPA artifact to open | **none present** |

So no Splitwise artifact or live page was inspected with REA. The workflows below come
from the public, documented behaviour of expense-sharing apps, not from reverse
engineering. No Splitwise code, branding or assets are used.

Workflows that informed the implementation:

* **Add expense:** description, amount, currency, "paid by", "split" (equally, exact
  amounts, percentages, shares), date, category, notes and receipt. The form validates
  that the allocations add up to the total before saving.
* **Group view:** expenses newest first, a per-member balance summary, "Settle up" and
  "Balances".
* **Friends view:** the pairwise "X owes you" / "you owe X" for each friend across all
  groups.
* **Settle up:** record a cash or external payment between two people. It is a record
  only; no money moves.
* **Simplify debts:** suggest the fewest transfers that clear the group's net balances.
* **Activity:** a timeline of who added, edited or deleted what.
* **Leftover cents:** one participant absorbs the remainder. SplitMate does this
  deterministically (see §5) so every device gets identical splits.

## 2. Architecture

```
UI (Flutter widgets, GoRouter)  ──>  Riverpod providers
                                       │
                ┌──────────────────────┼─────────────────────────┐
         LedgerRepository        SyncEngine/SyncSession      BackupService
         (commands + queries)    (protocol state machine)    (format + storage)
                │                      │                         │
           ChangeLog  <────────────────┘                         │
      (append/ingest signed changes, authorise, materialise)     │
                │                                                │
          SQLite (sqflite)  <────────────────────────────────────┘
                │
     IdentityService (Ed25519/X25519 keys in platform secure storage)

Transports: FrameChannel  ← TcpTransport (LAN / hotspot)
                          ← MemoryTransport (tests)
             SyncBundle   (sealed file exchange for devices on different networks)
```

### Event-sourced core

Every user-visible financial or group record is **materialised from a log of signed,
content-addressed changes** (`sync_changes`):

* A local edit appends a change and re-materialises the affected entity, in one SQLite
  transaction.
* A remote change is checked (hash, signature, authorisation, causal readiness),
  stored, and the entity is re-materialised the same way.
* The entity tables (`groups`, `group_members`, `expenses`, `expense_participants`,
  `expense_splits`, `settlements`) are a deterministic function of the set of accepted
  changes. Two devices with the same set of changes compute **identical** rows and
  balances, whatever order the changes arrived in.
* The log doubles as the audit history ("Expense history" screen).
* Balances are never synchronised. They are always derived from expenses and
  settlements.

## 3. Identity

On first launch the app creates:

* `user_id`: a random UUIDv4, stable for life and carried across backups.
* `device_id`: a random UUIDv4 for each installation. After a restore the app makes a
  new one.
* An **Ed25519 signing key pair** (it signs changes and handshakes) and an **X25519
  key-agreement key pair** (it seals offline sync bundles). The private keys are stored
  through `flutter_secure_storage` (Android Keystore-backed EncryptedSharedPreferences;
  iOS Keychain, `first_unlock_this_device`).

No online account is involved. Google Sign-In is used only by the Backup screen.

## 4. SQLite schema (v1)

All IDs are UUID strings. Money is `INTEGER` minor units plus an explicit ISO-4217
`currency`. Timestamps are UTC epoch milliseconds. Foreign keys are on
(`PRAGMA foreign_keys = ON`), the journal is in WAL mode, and migrations live in
`lib/data/db/migrations.dart` with `PRAGMA user_version`.

| Table | Purpose | Synced? |
| --- | --- | --- |
| `app_meta` | key/value: local user id, device id, HLC state, sequence counter, settings | local |
| `users` | people this device knows: display name, public keys, `is_local` | derived from member changes |
| `friends` | the local friend list (can exist before the friend has a device) | local |
| `groups` | groups and hidden two-person "direct" groups; `local_status` = active/invited/declined | materialised |
| `group_members` | role (admin/member), status (active/removed); historical rows are kept | materialised |
| `group_invitations` | invitations created here: token **hash**, scope, expiry, status | local |
| `expenses` | the current state of each expense, plus `conflicted` and `head_change_id` | materialised |
| `expense_participants` | split inputs (exact minor units / basis points / shares) | materialised |
| `expense_splits` | computed owed amount for each participant | materialised |
| `settlements` | recorded payments, voidable but otherwise immutable | materialised |
| `activity_logs` | timeline entries, one per accepted change | derived |
| `sync_devices` | paired peers: keys, last endpoint, last sync, the peer's last-known version vector | local |
| `sync_changes` | **the authoritative log**: signed changes with status applied/pending/rejected | synced |
| `sync_conflicts` | open and resolved conflicts for each entity | derived plus local resolution state |
| `backup_metadata` | backups created and restored: location, remote id, checksum, versions | local |

Soft deletion: an expense has `deleted_at`, and a settlement has `voided_at` plus
`void_reason`. Both are ordinary changes in the log, so the deletion itself is the
tombstone and is replicated and auditable.

Indexes cover `sync_changes(entity_type, entity_id)`, `sync_changes(group_id,
origin_device_id, origin_seq)`, `sync_changes(status)`, `expenses(group_id,
expense_date)`, `settlements(group_id)`, `group_members(user_id)` and
`activity_logs(created_at)`.

## 5. Money and splits

* `Currency` carries its ISO-4217 exponent (JPY 0, INR/USD/EUR 2, KWD/BHD/OMR 3, …).
  Amounts are parsed from user text with exactly that precision. No floating point is
  used anywhere in the money path.
* **Equal:** `base = total ~/ n`. The remainder `r` is given +1 minor unit each to the
  first `r` participants in **ascending `user_id` order**.
* **Exact:** each input is in minor units, and they must add up to the total exactly.
* **Percentage:** inputs in basis points (100.00% = 10000) must add up to 10000.
  Each share is `floor(total * bp / 10000)` and the remainder is assigned by
  **largest fractional remainder**, ties broken by ascending `user_id`.
* **Shares:** positive integer weights, allocated by the same largest-remainder rule.
* Every split is checked: participants are unique group members, there is at least one,
  the inputs are non-negative and the result adds up exactly to the total.
* Balances are computed **per currency**. Different currencies are never added
  together, because there is no conversion policy. The UI shows one line for each
  currency.
* Pairwise debt: for each expense, every participant other than the payer owes the
  payer their split. A settlement from A to B reduces what A owes B. A group's net
  balance for each person is the sum of their pairwise positions.
* Suggested settlements ("simplify debts") use a greedy max-creditor/max-debtor match
  for each currency, with deterministic tie-breaks by user id.

## 6. Sync change record

```jsonc
{
  "v": 1,                       // change format version
  "type": "group|member|expense|settlement",
  "entity": "<uuid>",           // member entity = uuidv5(group_id + user_id)
  "group": "<uuid>",            // the sharing scope; used for authorisation
  "parents": ["<change_id>"],  // heads this edit was based on (sorted)
  "author": "<user_id>",
  "device": "<device_id>",
  "seq": 42,                    // per-origin-device counter (monotonic)
  "hlc": "001730000000000-00000-<device_id>",  // hybrid logical clock
  "data": { ... full entity snapshot ... }
}
```

* `change_id = hex(SHA-256(canonical JSON))`. Canonical JSON sorts keys, has no
  whitespace and allows integers only. The ID verifies integrity and makes processing
  idempotent.
* `sig = Ed25519(author key, change_id bytes)`.
* Checks on receipt: the recomputed hash matches, the signature is valid for the
  author's key, the schema is valid, the size is within limits, the HLC is no more than
  24 h in the future, and the authorisation rules (§8) pass. Parents must already be
  present (causal readiness). A change that is not ready yet is stored as `pending` and
  retried after every batch and every sync. A change that fails a check is stored as
  `rejected`, with a reason, and is never applied.

## 7. Conflict rules

For each entity the accepted changes form a DAG through `parents`. The **heads** are
the changes that no other change lists as a parent.

* **One head:** the state is that head's snapshot.
* **Several heads (concurrent offline edits):** the base is the latest common ancestor
  (highest HLC, ties broken by id; empty if there is none). The fields are grouped into
  *components*:
  * Expense, financial component (`amount_minor`, `currency`, `payer_id`, `split_type`,
    `participants`, `deleted`) as one unit; each metadata field (`description`,
    `category`, `notes`, `expense_date`) separately.
  * Settlement, financial component (`from`, `to`, `amount_minor`, `currency`,
    `voided`) as one unit; `note` and `void_reason` separately.
  * Group and member: each field separately (ordinary metadata).
* For each component, look at the heads whose value differs from the base:
  * none: keep the base value;
  * exactly one distinct new value: take it (a safe three-way merge, for example one
    person edits the notes while the other edits the amount);
  * more than one distinct new value: **metadata** takes the head with the highest
    `(hlc, change_id)`, which is deterministic. **Financial** components use the same
    deterministic pick **and** open a `sync_conflicts` row. The expense is flagged
    `conflicted` and the UI asks the user to choose. It is never silently
    last-write-wins.
* **Resolving:** the user picks a version or edits it. The app writes a new change whose
  `parents` are *all* the current heads. The DAG then has one head again and the
  conflict closes everywhere once that change propagates.
* Settlements are immutable after creation except for `voided`, `void_reason` and
  `note`. A change that alters a settlement's amount, parties or currency is rejected.
  Corrections are made by voiding the settlement and recording a new one, which keeps
  the audit trail. Settlement IDs are client UUIDs, so redelivery is idempotent. Two
  *different* settlements with the same group, parties, amount and currency within 48 h
  from different devices raise a `possible_duplicate_settlement` conflict so a person
  can void one.
* Every device runs the same deterministic algorithm on the same set of changes, so all
  devices show the same balances, including while a conflict is open.

## 8. Authorisation (deterministic replay)

Authorisation depends on group membership, and membership itself changes through
synced changes. To keep every device's verdict identical regardless of arrival
order, **each remote batch replays the whole group**: all stored changes of the group
are sorted by `(hlc, change_id)` and evaluated in that order against the membership
state *as of that point in the timeline* (`ChangeLog.replayGroup`). Statuses
(applied/pending/rejected) and the materialised rows are therefore a pure function of
the set of stored changes. A local edit is always the newest HLC, so it is evaluated
incrementally against the current state, which gives the same result.

* **Group root change:** `data.creator` carries the creator's id, name and public keys.
  The author must be that creator, and the signature must verify with that key. If the
  creator's key is already pinned through pairing it must match. The creator is an
  **implicit admin member** from the root onwards, so no separate self-member change is
  needed.
* **Group edits:** only active admins. `type` and `creator` are immutable.
* **Member changes:** only active admins. The one exception is a member removing
  *themselves* (leave). The member entity id must equal `uuidv5(group:user)`. Binding a
  public key to a user who already has a different pinned or bound key is rejected.
  `merged_into` links a placeholder (someone added before they had the app) to the real
  identity, and balances then alias the placeholder to that identity.
* **Expense/settlement:** the author must be an *active* member at that point in the
  timeline, so a member removed earlier cannot add expenses. A new expense's payer and
  participants, and a new settlement's parties, must be active members. Edits may still
  reference removed members, which keeps history intact.
* **Keys:** the author's key comes from their membership state in the group (written by
  an admin who verified it during pairing, or by the creator's root). A relaying peer
  cannot forge or alter anyone's changes.
* **Sending:** a device sends a peer only changes of groups in which the peer is an
  active member. Requests for any other group id are ignored.
* **Receiving:** the receiver ingests only groups it asked for. A group that someone
  else added you to appears as an *invitation* (`local_status = invited`) until you
  accept it. Scanning a group invitation QR counts as acceptance. Declined groups are
  not requested again and are excluded from balances.
* **Clock skew:** a change whose HLC is more than 24 h ahead of the receiver's clock is
  rejected, so a bad clock cannot win every deterministic tie.

## 9. Transport and session protocol

`FrameChannel` is a full-duplex stream of length-prefixed frames (at most 4 MiB). It
has these implementations:

1. **TcpTransport:** the device showing a code listens on one ephemeral TCP port bound
   **dual-stack** (IPv4 + IPv6). The code lists every candidate endpoint
   (`lib/sync/transport/endpoints.dart`), and the dialling phone connects to all of them
   at once and keeps the first that answers. LAN addresses get a 250 ms head start.
   Candidates:
   * **LAN IPv4**: the same Wi-Fi, or one phone tethered to the other's hotspot.
   * **Global IPv6** (2000::/3, up to two): reachable over the internet when neither
     network firewalls incoming IPv6.
   * **Router-mapped public IPv4** (`lib/sync/transport/port_mapping.dart`). This asks
     the home router through **NAT-PMP** (RFC 6886, unicast to the gateway) and then
     **UPnP IGD** (SSDP discovery plus SOAP `AddPortMapping`, Android only, because iOS
     needs a restricted multicast entitlement). The lease is one hour, and the mapping is
     deleted when the screen closes. A router whose "external" address is private or in
     100.64/10 (carrier-grade NAT) is ignored, because a mapping there would be useless.

   No relay, STUN, TURN or rendezvous server is involved. The only network services
   contacted are the user's own router and the peer. Codes are exchanged in person (QR
   scan) or over any messenger, as a shared QR image (decoded from the gallery with
   `MobileScannerController.analyzeImage`) or as pasted text. Internet endpoints can be
   switched off (Sync → "Allow connections over the internet", `app_meta`
   `sync.internet`).
2. **MemoryTransport:** in-process, with fault injection, for tests.
3. **Sync bundles (`.smsync`):** used when no direct path exists, for example both phones
   behind carrier-grade NAT without IPv6. The sender seals the changes for one paired peer
   (ephemeral X25519 → HKDF → AES-256-GCM, Ed25519-signed). The file can be shared over
   any channel, and the receiver imports it through the normal ingest checks. Processing
   is idempotent.

Wi-Fi Direct (Android only), Multipeer Connectivity (iOS only), BLE and TCP hole punching
are not implemented. See LIMITATIONS.

### Handshake (SIGMA-I style, using the `cryptography` package; no new cipher)

```
I → R  HELLO  {protocols:[1], mode: pair|sync, eph: X25519_pub_I, nonce_I, invite_id?}
R → I  HELLO  {protocol: 1, eph: X25519_pub_R, nonce_R}
        th = SHA-256(hello_I ‖ hello_R);  s = X25519(eph_I, eph_R)
        keys = HKDF-SHA256(s, salt = th) → hs_i2r, hs_r2i, app_i2r, app_r2i, sas
R → I  AUTH(hs_r2i) {identity, ed_pub, x_pub, schema, sig = Ed25519_R("R" ‖ th)}
I → R  AUTH(hs_i2r) {identity, ed_pub, x_pub, schema, sig = Ed25519_I("I" ‖ th),
                     invite_proof = HMAC-SHA256(invite_secret, th)}   // pairing only
```

* In **sync mode** both keys must match `sync_devices` (they are pinned). A new
  `device_id` with an already-paired identity key is the same person after a backup
  restore. It is recorded as an additional device, unless that device id was revoked.
* In **pair mode** the scanner checks the responder's `ed_pub` against the QR. The
  responder checks `invite_proof` against the stored invitation (unexpired, unused,
  hash-matched). Both screens then show a 6-digit **SAS** derived from the transcript,
  and **both users must approve**. A QR code on its own is not treated as proof of
  identity.
* Records are AES-256-GCM. The nonce is a direction byte plus a 64-bit counter. The
  receiver requires counters to increase strictly (no replay or reordering). The
  ephemeral keys give forward secrecy.

### Sync messages (inside the secure channel)

```
INVENTORY {groups:[{id,name}]}            // groups where the peer is an active member
REQUEST   {vectors:{group_id:{origin_device:max_seq}}}
BATCH     {no, changes:[...], final}      // ≤ 200 changes, ascending (group, origin, seq)
ACK       {no, applied, pending, rejected}
DONE      {}
ERROR     {code, message}
```

* Both directions run at the same time. Each batch is applied in **one SQLite
  transaction** and acknowledged. The sender waits for the ACK before sending the next
  batch, and after an interruption it resumes from the receiver's vector. Senders
  stream changes in ascending sequence order for each (group, origin). Receivers store
  every received change, even pending or rejected ones, so each `max_seq` describes a
  gap-free prefix.
* Re-delivered changes are recognised by `change_id` and ignored.
* "Full resync" sends empty vectors. This always converges because ingest is
  idempotent.

## 10. Backup format (`.smbk`, format v1)

```
"SMBK" | u8 format_version=1 | u32 header_len | header JSON | ciphertext
header = {format_version, schema_version, app_version, created_at, user_id, device_id,
          kdf:{alg:"argon2id", m, t, p, salt}, cipher:"aes-256-gcm", nonce,
          payload_sha256, payload_length}
ciphertext = AES-256-GCM(key = Argon2id(passphrase), aad = header bytes,
                         gzip(JSON payload))
payload = {sync_changes (all statuses), friends, sync_devices, group local_status,
           conflict resolution state, identity:{user_id, display_name, ed25519 & x25519
           private keys}}
```

* **Consistent snapshot:** the export reads every table inside **one SQLite read
  transaction**. Under WAL that is a consistent point-in-time view, and the live
  database file is never copied.
* **Integrity:** the GCM tag (keyed) and the payload SHA-256 are both checked. A wrong
  passphrase, any flipped bit, or a truncated download is rejected before any data is
  touched.
* **Restore is a merge, never an overwrite.** Changes are ingested idempotently through
  the same checks as sync, and then everything is re-materialised.
  * Fresh install: adopt the identity from the backup, generate a new `device_id`,
    import.
  * Same identity with newer local data: merge. Changes that exist only locally are
    kept.
  * Different identity: refuse, and tell the user to reset the app first.
* The passphrase is never stored next to the backup. Scheduled backups are opt-in. The
  derived key is then kept in secure storage on that device only.
* Drive storage is `appDataFolder` (scope `drive.appdata`), so the app cannot see the
  user's other files.
