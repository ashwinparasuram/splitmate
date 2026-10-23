import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/providers.dart';
import '../../app/sync_controller.dart';
import '../../sync/pairing.dart';
import '../theme.dart';
import '../widgets/code_share.dart';
import '../widgets/common.dart';

/// Pulls a SplitMate code out of scanned or pasted text (a pasted message
/// may contain extra words around it).
String? extractCode(String raw) =>
    RegExp(r'splitmate:(?:pair|connect):v1:[A-Za-z0-9_-]+').firstMatch(raw)?.group(0);

/// QR pairing: show an invitation, or scan / upload / paste someone else's.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key, this.groupId, this.placeholderUserId, this.scan = false});
  final String? groupId;
  final String? placeholderUserId;
  final bool scan;

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 2, vsync: this, initialIndex: widget.scan ? 1 : 0);
  late final SyncController _sync = ref.read(servicesProvider).sync;
  late final PairingService _pairing = ref.read(servicesProvider).pairing;
  Invitation? _invitation;

  /// Every invitation shown on this screen stays valid until it closes, so
  /// a friend who scanned an earlier code (before the router port was
  /// mapped) can still connect.
  final List<String> _issued = [];
  String? _hostError;
  Timer? _ticker;
  bool _dialogOpen = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_onSync);
    _startHosting();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  Future<void> _startHosting() async {
    try {
      await _sync.startHosting();
      await _refreshInvitation();
    } catch (e) {
      if (mounted) setState(() => _hostError = 'Could not start listening: $e');
    }
  }

  Future<void> _refreshInvitation() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final endpoints = _sync.value.endpoints;
      setState(() => _hostError = endpoints.isEmpty
          ? 'No network connection. Connect to Wi-Fi or mobile data.'
          : null);
      final inv = await _pairing.createInvitation(
        endpoints: endpoints,
        groupId: widget.groupId,
        placeholderUserId: widget.placeholderUserId,
      );
      _issued.add(inv.id);
      if (mounted) setState(() => _invitation = inv);
    } finally {
      _refreshing = false;
    }
  }

  void _onSync() {
    final state = _sync.value;
    final approval = state.approval;
    if (approval != null && !_dialogOpen && mounted) {
      _dialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ApprovalDialog(approval: approval),
      ).whenComplete(() => _dialogOpen = false);
    }
    // The router port mapping finishes after the first code is shown.
    final inv = _invitation;
    if (inv != null && state.hosting && !listEquals(inv.endpoints, state.endpoints)) {
      unawaited(_refreshInvitation());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sync.removeListener(_onSync);
    for (final id in _issued) {
      unawaited(_pairing.revokeInvitation(id));
    }
    unawaited(_sync.stopHosting());
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _sync.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect phones'),
        bottom: TabBar(controller: _tabs, tabs: const [Tab(text: 'My code'), Tab(text: 'Scan')]),
      ),
      body: Column(children: [
        if (state.busy)
          LinearProgressIndicator(
            value: state.progress == null || state.progress!.toSend == 0
                ? null
                : state.progress!.sent / state.progress!.toSend,
          ),
        if (state.busy && state.phase != null) InfoBanner(icon: Icons.sync, text: state.phase!),
        if (state.lastError != null)
          InfoBanner(icon: Icons.error_outline, color: context.money.owe, text: state.lastError!),
        if (state.lastMessage != null && !state.busy)
          InfoBanner(icon: Icons.check_circle_outline, color: context.money.owed, text: state.lastMessage!),
        Expanded(
          child: TabBarView(controller: _tabs, children: [
            _ShowCode(
              invitation: _invitation,
              error: _hostError,
              reach: state.reach,
              reachDetail: state.reachDetail,
              onRefresh: _refreshInvitation,
            ),
            _Scanner(onCode: _onScanned),
          ]),
        ),
      ]),
    );
  }

  bool _handlingScan = false;

  Future<void> _onScanned(String raw) async {
    if (_handlingScan || _sync.value.busy) return;
    final code = extractCode(raw);
    if (code == null) {
      showSnack(context, 'That is not a SplitMate code.');
      return;
    }
    _handlingScan = true;
    try {
      final connect = ConnectCode.tryDecode(code);
      if (connect != null) {
        await _sync.syncWith(connect.deviceId, connect.endpoints);
        return;
      }
      final inv = Invitation.decode(code);
      if (inv.userId == ref.read(meProvider)) {
        showSnack(context, 'That is your own code.');
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Connect with ${inv.displayName}?'),
          content: Text(inv.groupName == null
              ? 'You will be able to share groups with each other.'
              : '${inv.displayName} invited you to "${inv.groupName}". Its expenses and member names '
                  'will be copied to this phone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
          ],
        ),
      );
      if (ok == true) await _sync.joinWithInvitation(inv);
    } on PairingException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      _handlingScan = false;
    }
  }
}

class _ShowCode extends StatelessWidget {
  const _ShowCode({
    required this.invitation,
    required this.error,
    required this.reach,
    required this.reachDetail,
    required this.onRefresh,
  });
  final Invitation? invitation;
  final String? error;
  final Reachability reach;
  final String? reachDetail;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final inv = invitation;
    if (inv == null) {
      return error != null
          ? EmptyState(icon: Icons.wifi_off, title: 'Cannot show a code', message: error!)
          : const Center(child: CircularProgressIndicator());
    }
    final left = Duration(milliseconds: inv.expiresAt - DateTime.now().millisecondsSinceEpoch);
    final expired = left.isNegative;
    final code = inv.encode();
    return ListView(padding: const EdgeInsets.all(24), children: [
      if (error != null) InfoBanner(icon: Icons.wifi_off, text: error!),
      _ReachBanner(reach: reach, detail: reachDetail),
      Text(inv.groupName == null ? 'Let your friend scan this code' : 'Invite to "${inv.groupName}"',
          style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
      const SizedBox(height: 16),
      Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: expired
              ? const SizedBox(width: 240, height: 240, child: Center(child: Text('Code expired')))
              : QrImageView(data: code, size: 240, backgroundColor: Colors.white),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        expired ? 'This code expired.' : 'Valid for ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
        textAlign: TextAlign.center,
      ),
      if (expired) TextButton(onPressed: onRefresh, child: const Text('New code')),
      if (!expired)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => shareCode(code,
                    message: 'Connect with me on SplitMate: in the app, open Connect → Scan → '
                        'Upload QR image (or Paste code). Valid for 10 minutes.'),
                icon: const Icon(Icons.share),
                label: const Text('Share code'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => copyCode(context, code),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 16),
      _Steps(steps: [
        'Together: your friend opens SplitMate → Connect → Scan.',
        'Apart: tap Share code and send it. They choose Upload QR image or Paste code.',
        'You will both see a 6-digit code. Approve only if they match — when apart, compare it on a phone call.',
        'Keep this screen open until the sync finishes.',
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'The code contains your phone\'s network addresses. Share it only with the person you are connecting to.',
          style: TextStyle(fontSize: 12),
        ),
      ),
    ]);
  }
}

class _ReachBanner extends StatelessWidget {
  const _ReachBanner({required this.reach, required this.detail});
  final Reachability reach;
  final String? detail;

  @override
  Widget build(BuildContext context) => switch (reach) {
        Reachability.checking => InfoBanner(
            icon: Icons.travel_explore,
            text: 'Same network ready${detail == null ? '' : ' · $detail'}. Checking internet reachability…',
          ),
        Reachability.internet => InfoBanner(
            icon: Icons.public,
            color: context.money.owed,
            text: 'Reachable over the internet ($detail) and on this network.',
          ),
        Reachability.lanOnly => InfoBanner(
            icon: Icons.wifi,
            color: context.money.owe,
            text: 'Only reachable on this network. This network blocks incoming connections '
                '(no IPv6, router port opening unavailable). Ask your friend to show their code instead, '
                'use one Wi-Fi/hotspot, or send a sync file.',
          ),
        Reachability.off => const SizedBox.shrink(),
      };
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});
  final List<String> steps;

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final (i, s) in steps.indexed)
          ListTile(
            dense: true,
            leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
            title: Text(s),
          ),
      ]);
}

class _Scanner extends StatefulWidget {
  const _Scanner({required this.onCode});
  final Future<void> Function(String) onCode;

  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    final value = await pickQrFromGallery(context, _controller);
    if (value != null) await widget.onCode(value);
  }

  Future<void> _paste() async {
    final value = await pasteCodeDialog(context);
    if (value != null && value.isNotEmpty) await widget.onCode(value);
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value != null) widget.onCode(value);
          },
          errorBuilder: (context, error) => EmptyState(
            icon: Icons.no_photography_outlined,
            title: 'Camera unavailable',
            message: 'Allow camera access to scan, or use Upload QR image / Paste code below. '
                '(${error.errorCode.name})',
          ),
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _upload,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Upload QR image'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste),
                label: const Text('Paste code'),
              ),
            ),
          ]),
        ),
      ]);
}

class _ApprovalDialog extends StatelessWidget {
  const _ApprovalDialog({required this.approval});
  final PendingApproval approval;

  @override
  Widget build(BuildContext context) {
    final sas = approval.sas;
    return AlertDialog(
      icon: const Icon(Icons.verified_user_outlined),
      title: Text('Connect with ${approval.peer.displayName}?'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Check that the other phone shows the same code:'),
        const SizedBox(height: 16),
        Text('${sas.substring(0, 3)} ${sas.substring(3)}',
            style: Theme.of(context).textTheme.displaySmall!.copyWith(
                fontWeight: FontWeight.w800, letterSpacing: 4, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 16),
        const Text(
            'Not together? Compare it on a voice call — not in the chat where you sent the code. '
            'If the codes differ, someone may be intercepting the connection: tap Reject.',
            style: TextStyle(fontSize: 13),
            textAlign: TextAlign.center),
      ]),
      actions: [
        TextButton(
            onPressed: () {
              approval.reject();
              Navigator.pop(context);
            },
            child: const Text('Reject')),
        FilledButton(
            onPressed: () {
              approval.approve();
              Navigator.pop(context);
            },
            child: const Text('Codes match')),
      ],
    );
  }
}
