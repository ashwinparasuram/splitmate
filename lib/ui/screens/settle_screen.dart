import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../sync/change_log.dart';
import '../widgets/common.dart';

/// Records a payment that happened outside the app. Nothing is transferred.
class SettleScreen extends ConsumerStatefulWidget {
  const SettleScreen({super.key, this.groupId, this.fromUserId, this.toUserId, this.amountMinor, this.currency});
  final String? groupId;
  final String? fromUserId;
  final String? toUserId;
  final int? amountMinor;
  final String? currency;

  @override
  ConsumerState<SettleScreen> createState() => _SettleScreenState();
}

class _SettleScreenState extends ConsumerState<SettleScreen> {
  /// One id per screen: retries and double taps record a single settlement.
  final _settlementId = const Uuid().v4();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _groupId;
  String? _from;
  String? _to;
  String _currency = 'INR';
  String _method = 'cash';
  bool _saving = false;
  List<Member> _members = const [];

  @override
  void initState() {
    super.initState();
    _currency = widget.currency ?? 'INR';
    _from = widget.fromUserId;
    _to = widget.toUserId;
    if (widget.amountMinor != null) {
      _amount.text = formatDecimal(widget.amountMinor!, Currency.of(_currency)).replaceAll(',', '');
    }
    if (widget.groupId != null) _selectGroup(widget.groupId!, keepParties: true);
  }

  Future<void> _selectGroup(String id, {bool keepParties = false}) async {
    final repo = ref.read(repoProvider);
    final members = await repo.members(id);
    final g = await repo.group(id);
    final b = await repo.balances(groupId: id);
    setState(() {
      _groupId = id;
      _members = members;
      if (!keepParties) {
        // Default to the biggest thing the user owes, else is owed.
        final me = repo.me;
        final mine = b.suggestedTransfers().where((t) => t.fromUserId == me || t.toUserId == me).toList();
        if (mine.isNotEmpty) {
          _from = mine.first.fromUserId;
          _to = mine.first.toUserId;
          _currency = mine.first.currency;
          _amount.text = formatDecimal(mine.first.amountMinor, Currency.of(_currency)).replaceAll(',', '');
        } else {
          _from = me;
          _to = null;
          _currency = g?.defaultCurrency ?? _currency;
        }
      }
    });
  }

  Future<void> _save() async {
    final cur = Currency.of(_currency);
    int amount;
    try {
      amount = parseMinor(_amount.text, cur);
    } on MoneyFormatException catch (e) {
      return showSnack(context, e.message);
    }
    if (_groupId == null || _from == null || _to == null) return showSnack(context, 'Choose who paid whom');
    if (_from == _to) return showSnack(context, 'Choose two different people');
    if (amount <= 0) return showSnack(context, 'Enter an amount');
    setState(() => _saving = true);
    try {
      await ref.read(repoProvider).recordSettlement(
            id: _settlementId,
            groupId: _groupId!,
            fromUserId: _from!,
            toUserId: _to!,
            amountMinor: amount,
            currency: _currency,
            method: _method,
            note: _note.text,
          );
      if (mounted) {
        showSnack(context, 'Payment recorded');
        context.pop();
      }
    } on AuthorizationException catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(selectableGroupsProvider);
    final me = ref.watch(meProvider);
    final active = _members.where((m) => m.isActive || m.person.id == _from || m.person.id == _to).toList();
    String n(Member m) => m.person.id == me ? 'You' : m.person.name;
    final cur = Currency.of(_currency);

    return Scaffold(
      appBar: AppBar(title: const Text('Settle up')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const InfoBanner(
          icon: Icons.info_outline,
          text: 'SplitMate only records that a payment happened. It never moves money — '
              'pay with cash, UPI, your bank app, etc., then record it here.',
        ),
        const SizedBox(height: 8),
        AsyncView(
          value: groups,
          builder: (list) => DropdownButtonFormField<String>(
            initialValue: list.any((g) => g.id == _groupId) ? _groupId : null,
            decoration: const InputDecoration(labelText: 'Group or friend'),
            items: [
              for (final g in list.where((g) => g.localStatus == 'active'))
                DropdownMenuItem(value: g.id, child: Text(g.name)),
            ],
            onChanged: (v) => _selectGroup(v!),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: active.any((m) => m.person.id == _from) ? _from : null,
              decoration: const InputDecoration(labelText: 'Who paid'),
              items: [for (final m in active) DropdownMenuItem(value: m.person.id, child: Text(n(m)))],
              onChanged: (v) => setState(() => _from = v),
            ),
          ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward)),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: active.any((m) => m.person.id == _to) ? _to : null,
              decoration: const InputDecoration(labelText: 'Paid to'),
              items: [for (final m in active) DropdownMenuItem(value: m.person.id, child: Text(n(m)))],
              onChanged: (v) => setState(() => _to = v),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<String>(
              initialValue: _currency,
              decoration: const InputDecoration(labelText: 'Currency'),
              items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text(c.code))],
              onChanged: (v) => setState(() => _currency = v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _amount,
              keyboardType: TextInputType.numberWithOptions(decimal: cur.exponent > 0),
              decoration: InputDecoration(labelText: 'Amount', prefixText: cur.symbol),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'cash', label: Text('Cash')),
            ButtonSegment(value: 'upi', label: Text('UPI')),
            ButtonSegment(value: 'bank', label: Text('Bank')),
            ButtonSegment(value: 'other', label: Text('Other')),
          ],
          selected: {_method},
          onSelectionChanged: (s) => setState(() => _method = s.first),
        ),
        const SizedBox(height: 12),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
        const SizedBox(height: 20),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Record payment')),
      ]),
    );
  }
}
