import 'dart:async';

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../data/ledger_repository.dart';
import '../sync/pairing.dart';
import '../sync/secure_channel.dart';
import '../sync/sync_session.dart';
import '../sync/change_log.dart' show readMeta, writeMeta;
import '../sync/transport/endpoints.dart';
import '../sync/transport/frame_channel.dart';
import '../sync/transport/port_mapping.dart';

/// A pairing waiting for the local user to compare the code and approve.
class PendingApproval {
  PendingApproval(this.peer, this.sas, this.isInviter);
  final PeerIdentity peer;
  final String sas;
  final bool isInviter;
  final decision = Completer<bool>();

  void approve() {
    if (!decision.isCompleted) decision.complete(true);
  }

  void reject() {
    if (!decision.isCompleted) decision.complete(false);
  }
}

/// Whether peers off this network can reach the listener.
enum Reachability { off, checking, internet, lanOnly }

class SyncState {
  const SyncState({
    this.hosting = false,
    this.endpoints = const [],
    this.reach = Reachability.off,
    this.reachDetail,
    this.busy = false,
    this.phase,
    this.progress,
    this.lastMessage,
    this.lastError,
    this.approval,
  });

  final bool hosting;
  final List<String> endpoints;
  final Reachability reach;

  /// e.g. "IPv6" or "router port (UPnP)".
  final String? reachDetail;
  final bool busy;
  final String? phase;
  final SyncProgress? progress;
  final String? lastMessage;
  final String? lastError;
  final PendingApproval? approval;

  SyncState copyWith({
    bool? hosting,
    List<String>? endpoints,
    Reachability? reach,
    String? reachDetail,
    bool? busy,
    String? phase,
    SyncProgress? progress,
    String? lastMessage,
    String? lastError,
    PendingApproval? approval,
    bool clearApproval = false,
    bool clearError = false,
  }) =>
      SyncState(
        hosting: hosting ?? this.hosting,
        endpoints: endpoints ?? this.endpoints,
        reach: reach ?? this.reach,
        reachDetail: reachDetail ?? this.reachDetail,
        busy: busy ?? this.busy,
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        lastMessage: lastMessage ?? this.lastMessage,
        lastError: clearError ? null : (lastError ?? this.lastError),
        approval: clearApproval ? null : (approval ?? this.approval),
      );

  /// Keeps hosting info, drops per-operation state.
  SyncState idle({String? lastMessage, String? lastError}) => SyncState(
        hosting: hosting,
        endpoints: endpoints,
        reach: reach,
        reachDetail: reachDetail,
        lastMessage: lastMessage,
        lastError: lastError,
      );
}

/// Runs the LAN listener and outgoing connections, and turns protocol
/// events into UI state. Only active while a sync/pairing screen is open:
/// mobile OSes suspend sockets in the background.
class SyncController extends ValueNotifier<SyncState> {
  SyncController({required this.repo, required this.pairing}) : super(const SyncState());

  final LedgerRepository repo;
  final PairingService pairing;
  TcpListener? _listener;
  StreamSubscription<TcpFrameChannel>? _sub;
  int _hostRefs = 0;

  /// Whether to advertise internet endpoints (IPv6 / router port mapping).
  static const internetKey = 'sync.internet';
  PortMapping? _mapping;

  Future<bool> internetAllowed() async => await readMeta(repo.db, internetKey) != '0';

  Future<void> setInternetAllowed(bool on) async {
    await writeMeta(repo.db, internetKey, on ? '1' : '0');
    if (_listener != null) {
      // Re-advertise with the new setting.
      final refs = _hostRefs;
      _hostRefs = 1;
      await stopHosting();
      await startHosting();
      _hostRefs = refs;
    }
  }

  Future<List<String>> startHosting() async {
    _hostRefs++;
    if (_listener == null) {
      final listener = await TcpListener.bind();
      _listener = listener;
      _sub = listener.connections.listen(_onIncoming);
      final internet = await internetAllowed();
      final local = await localEndpoints(listener.port, includeIPv6: internet);
      final hasV6 = local.any((e) => e.kind == EndpointKind.ipv6);
      value = value.copyWith(
        hosting: true,
        endpoints: [for (final e in local) e.encode()],
        reach: !internet ? Reachability.lanOnly : Reachability.checking,
        reachDetail: hasV6 ? 'IPv6' : null,
        clearError: true,
      );
      if (internet) unawaited(_mapPort(listener, local, hasV6));
    }
    return value.endpoints;
  }

  /// Asks the home router (UPnP / NAT-PMP) to forward a public port. Runs
  /// after the code is first shown; the endpoints update when it succeeds.
  Future<void> _mapPort(TcpListener listener, List<Endpoint> local, bool hasV6) async {
    final lanIp = local.where((e) => e.kind == EndpointKind.lan).firstOrNull?.host;
    String? gateway;
    try {
      gateway = await NetworkInfo().getWifiGatewayIP();
    } catch (_) {}
    final mapping = await PortMapper.map(
      internalPort: listener.port,
      gatewayIp: gateway,
      lanIp: lanIp,
      // iOS needs a special Apple entitlement to send SSDP multicast.
      useUpnp: Platform.isAndroid,
    );
    if (_listener != listener) {
      await mapping?.release();
      return;
    }
    _mapping = mapping;
    final details = [if (hasV6) 'IPv6', if (mapping != null) 'router port (${mapping.method})'];
    value = value.copyWith(
      endpoints: [...value.endpoints, if (mapping != null) mapping.endpoint.encode()],
      reach: details.isEmpty ? Reachability.lanOnly : Reachability.internet,
      reachDetail: details.join(' + '),
    );
  }

  Future<void> stopHosting() async {
    _hostRefs = (_hostRefs - 1).clamp(0, 1 << 30);
    if (_hostRefs > 0) return;
    await _sub?.cancel();
    await _listener?.close();
    await _mapping?.release();
    _mapping = null;
    _sub = null;
    _listener = null;
    value = SyncState(lastMessage: value.lastMessage, lastError: value.lastError);
  }

  Future<void> _onIncoming(TcpFrameChannel raw) async {
    if (value.busy) {
      await raw.close();
      return;
    }
    _setBusy('Authenticating');
    try {
      final hs = await Handshake.respond(
        raw: raw,
        me: repo.log.identity,
        inviteSecretFor: pairing.secretFor,
        isKnownPeer: pairing.isKnownPeer,
        allowedModes: {HandshakeMode.pair, HandshakeMode.sync},
      );
      if (hs.mode == HandshakeMode.pair) {
        await _approveAndPair(hs, inviteId: hs.inviteId);
      }
      await _runSession(hs, raw.description);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _approveAndPair(HandshakeResult hs,
      {String? inviteId, Invitation? scanned, String? endpoint}) async {
    final approval = PendingApproval(hs.peer, hs.sas, inviteId != null);
    value = value.copyWith(approval: approval, phase: 'Compare the code with ${hs.peer.displayName}');
    try {
      await pairing.confirm(
        hs: hs,
        localApproval: approval.decision.future,
        inviteId: inviteId,
        scannedInvitation: scanned,
        endpoint: endpoint,
      );
    } finally {
      value = value.copyWith(clearApproval: true);
    }
  }

  /// Scanner side of pairing.
  Future<void> joinWithInvitation(Invitation inv) async {
    if (inv.isExpired(repo.log.now())) {
      _fail(PairingException('This code has expired. Ask for a new one.'));
      return;
    }
    _setBusy('Connecting');
    try {
      final (raw, endpoint) = await PairingService.dial(inv.endpoints);
      _setBusy('Authenticating');
      final hs = await Handshake.initiate(
        raw: raw,
        me: repo.log.identity,
        mode: HandshakeMode.pair,
        expectedPeerKey: inv.ed25519Pub,
        inviteId: inv.id,
        inviteSecret: inv.secret,
      );
      await _approveAndPair(hs, scanned: inv, endpoint: endpoint);
      await _runSession(hs, endpoint);
    } catch (e) {
      _fail(e);
    }
  }

  /// Re-sync with an already paired device.
  Future<void> syncWith(String deviceId, List<String> endpoints) async {
    final key = await pairing.pinnedKeyFor(deviceId);
    if (key == null) {
      _fail(PairingException('That device is not paired with this one.'));
      return;
    }
    _setBusy('Connecting');
    try {
      final (raw, endpoint) = await PairingService.dial(endpoints);
      _setBusy('Authenticating');
      final hs = await Handshake.initiate(
          raw: raw, me: repo.log.identity, mode: HandshakeMode.sync, expectedPeerKey: key);
      await repo.db.update('sync_devices', {'last_endpoint': endpoint},
          where: 'device_id = ?', whereArgs: [deviceId]);
      await _runSession(hs, endpoint);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _runSession(HandshakeResult hs, String where) async {
    final result = await SyncSession(
      channel: hs.channel,
      peer: hs.peer,
      log: repo.log,
      onProgress: (p) => value = value.copyWith(phase: p.phase, progress: p),
    ).run();
    repo.notifyChanged();
    final r = result.received;
    value = value.idle(
      lastMessage: 'Synced with ${hs.peer.displayName}: sent ${result.sent}, '
          'received ${r.applied}${r.pending > 0 ? ', ${r.pending} waiting' : ''}'
          '${r.rejected > 0 ? ', ${r.rejected} rejected' : ''}.',
    );
  }

  void _setBusy(String phase) =>
      value = value.copyWith(busy: true, phase: phase, clearError: true);

  void _fail(Object e) {
    value = value.idle(
      lastError: switch (e) {
        PairingException(:final message) => message,
        HandshakeException(:final message) => 'Could not connect securely: $message',
        SyncException(:final message) => '$message. Already received changes are kept; try again.',
        TransportException(:final message) => 'Connection lost: $message. Try again.',
        _ => 'Something went wrong: $e',
      },
    );
  }

  void clearMessages() => value = value.copyWith(clearError: true);
}
