import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../domain/split_calculator.dart';
import '../../sync/change_log.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Create and edit expense, with equal / exact / percentage / shares splits.
class ExpenseFormScreen extends ConsumerStatefulWidget {
  const ExpenseFormScreen({super.key, this.groupId, this.expenseId});
  final String? groupId;
  final String? expenseId;

  @override
  ConsumerState<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends ConsumerState<ExpenseFormScreen> {
  /// Generated once per form so a double tap on Save cannot create two expenses.
  final _newId = const Uuid().v4();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  final Map<String, TextEditingController> _values = {};

  bool _loaded = false;
  bool _saving = false;
  String? _groupId;
  String _currency = 'INR';
  String? _payer;
  SplitType _type = SplitType.equal;
  final Set<String> _included = {};
  DateTime _date = DateTime.now();
  String _category = 'general';
  String? _receipt;
  List<Member> _members = const [];

  bool get _editing => widget.expenseId != null;

  @override
  void initState() {
    super.initState();
    _groupId = widget.groupId;
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    if (_editing) {
      final e = await repo.expense(widget.expenseId!);
      if (e == null) return;
      _groupId = e.groupId;
      _description.text = e.description;
      _currency = e.currency;
      _amount.text = formatDecimal(e.amountMinor, Currency.of(e.currency)).replaceAll(',', '');
      _payer = e.payerId;
      _type = e.splitType;
      _date = DateTime.fromMillisecondsSinceEpoch(e.expenseDate);
      _category = e.category;
      _notes.text = e.notes ?? '';
      _receipt = e.receiptPath;
      for (final part in e.participants) {
        _included.add(part.userId);
        _values[part.userId] = TextEditingController(text: _formatInput(part.value));
      }
    }
    if (_groupId != null) await _selectGroup(_groupId!, initial: true);
    setState(() => _loaded = true);
  }

  Future<void> _selectGroup(String id, {bool initial = false}) async {
    final repo = ref.read(repoProvider);
    final g = await repo.group(id);
    final members = await repo.members(id);
    setState(() {
      _groupId = id;
      _members = members;
      if (!initial || !_editing) {
        _currency = g?.defaultCurrency ?? _currency;
        _payer = repo.me;
        _included
          ..clear()
          ..addAll(members.where((m) => m.isActive).map((m) => m.person.id));
      }
    });
  }

  String _formatInput(int value) => switch (_type) {
        SplitType.exact => formatDecimal(value, Currency.of(_currency)).replaceAll(',', ''),
        SplitType.percentage => formatBasisPoints(value),
        _ => value.toString(),
      };

  TextEditingController _valueFor(String userId) =>
      _values.putIfAbsent(userId, () => TextEditingController());

  /// Parses the form into split inputs, or returns a user-facing error.
  (List<SplitInput>?, String?) _inputs(int? total) {
    final ids = _included.toList()..sort();
    if (ids.isEmpty) return (null, 'Choose at least one person');
    try {
      final inputs = [
        for (final id in ids)
          SplitInput(id, switch (_type) {
            SplitType.equal => 0,
            SplitType.exact => parseMinor(_valueFor(id).text.isEmpty ? '0' : _valueFor(id).text, Currency.of(_currency)),
            SplitType.percentage => parseBasisPoints(_valueFor(id).text.isEmpty ? '0' : _valueFor(id).text),
            SplitType.shares => int.tryParse(_valueFor(id).text.isEmpty ? '1' : _valueFor(id).text) ??
                (throw MoneyFormatException('Shares must be whole numbers')),
          }),
      ];
      if (total != null) SplitCalculator.allocate(total: total, type: _type, inputs: inputs);
      return (inputs, null);
    } on MoneyFormatException catch (e) {
      return (null, e.message);
    } on SplitValidationException catch (e) {
      return (null, e.message);
    }
  }

  int? get _total {
    try {
      return parseMinor(_amount.text, Currency.of(_currency));
    } on MoneyFormatException {
      return null;
    }
  }

  Future<void> _save() async {
    final total = _total;
    if (_groupId == null) return showSnack(context, 'Choose a group or friend');
    if (_description.text.trim().isEmpty) return showSnack(context, 'Add a description');
    if (total == null || total <= 0) return showSnack(context, 'Enter a valid amount');
    final (inputs, error) = _inputs(total);
    if (error != null) return showSnack(context, error);
    setState(() => _saving = true);
    final repo = ref.read(repoProvider);
    final draft = ExpenseDraft(
      groupId: _groupId!,
      description: _description.text,
      amountMinor: total,
      currency: _currency,
      payerId: _payer ?? repo.me,
      splitType: _type,
      participants: inputs!,
      expenseDate: DateTime(_date.year, _date.month, _date.day, 12).millisecondsSinceEpoch,
      category: _category,
      notes: _notes.text,
    );
    try {
      final id = _editing ? widget.expenseId! : _newId;
      if (_editing) {
        await repo.editExpense(id, draft);
      } else {
        await repo.addExpense(draft, id: id);
      }
      await _storeReceipt(id);
      if (mounted) context.pop();
    } on AuthorizationException catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _storeReceipt(String expenseId) async {
    final repo = ref.read(repoProvider);
    final current = (await repo.expense(expenseId))?.receiptPath;
    if (_receipt == current) return;
    if (_receipt == null) {
      if (current != null && await File(current).exists()) await File(current).delete();
      await repo.setReceipt(expenseId, null);
      return;
    }
    final dir = ref.read(servicesProvider).receiptsDir;
    await dir.create(recursive: true);
    final dest = p.join(dir.path, '$expenseId${p.extension(_receipt!).toLowerCase()}');
    await File(_receipt!).copy(dest);
    await repo.setReceipt(expenseId, dest);
  }

  Future<void> _pickReceipt(ImageSource source) async {
    final x = await ImagePicker().pickImage(source: source, maxWidth: 2000, imageQuality: 80);
    if (x != null) setState(() => _receipt = x.path);
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(selectableGroupsProvider);
    final total = _total;
    final (inputs, error) = _inputs(total);
    Map<String, int>? preview;
    if (total != null && total > 0 && inputs != null) {
      preview = SplitCalculator.allocate(total: total, type: _type, inputs: inputs);
    }
    final cur = Currency.of(_currency);

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Edit expense' : 'Add expense'),
        actions: [
          TextButton(onPressed: _saving || !_loaded ? null : _save, child: const Text('Save')),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              if (!_editing)
                AsyncView(
                  value: groups,
                  builder: (list) => DropdownButtonFormField<String>(
                    initialValue: list.any((g) => g.id == _groupId) ? _groupId : null,
                    decoration: const InputDecoration(labelText: 'With group or friend'),
                    items: [
                      for (final g in list.where((g) => g.localStatus == 'active'))
                        DropdownMenuItem(
                          value: g.id,
                          child: Row(children: [
                            Icon(g.isDirect ? Icons.person : Icons.groups, size: 18),
                            const SizedBox(width: 8),
                            Text(g.name),
                          ]),
                        ),
                    ],
                    onChanged: (v) => _selectGroup(v!),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Description', prefixIcon: Icon(Icons.edit_note)),
              ),
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
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _members.any((m) => m.person.id == _payer) ? _payer : null,
                decoration: const InputDecoration(labelText: 'Paid by', prefixIcon: Icon(Icons.account_circle_outlined)),
                items: [
                  for (final m in _members.where((m) => m.isActive || m.person.id == _payer))
                    DropdownMenuItem(
                        value: m.person.id,
                        child: Text(m.person.id == ref.read(meProvider) ? 'You' : m.person.name)),
                ],
                onChanged: (v) => setState(() => _payer = v),
              ),
              const SizedBox(height: 16),
              SegmentedButton<SplitType>(
                segments: const [
                  ButtonSegment(value: SplitType.equal, label: Text('Equal')),
                  ButtonSegment(value: SplitType.exact, label: Text('Exact')),
                  ButtonSegment(value: SplitType.percentage, label: Text('%')),
                  ButtonSegment(value: SplitType.shares, label: Text('Shares')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() {
                  _type = s.first;
                  for (final c in _values.values) {
                    c.clear();
                  }
                }),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(children: [
                  for (final m in _members.where((m) => m.isActive || _included.contains(m.person.id)))
                    _ParticipantRow(
                      name: m.person.id == ref.read(meProvider) ? 'You' : m.person.name,
                      included: _included.contains(m.person.id),
                      type: _type,
                      controller: _valueFor(m.person.id),
                      currency: cur,
                      share: preview?[m.person.id],
                      onToggle: (v) => setState(() => v ? _included.add(m.person.id) : _included.remove(m.person.id)),
                      onChanged: () => setState(() {}),
                    ),
                ]),
              ),
              if (error != null && total != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error, style: TextStyle(color: context.money.owe)),
                ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(DateFormat.yMMMd().format(_date)),
                    onPressed: () async {
                      final d = await showDatePicker(
                          context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime(2100));
                      if (d != null) setState(() => _date = d);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      for (final e in expenseCategories.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => _category = v!),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                maxLines: 3,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
              _ReceiptPicker(
                path: _receipt,
                onPick: _pickReceipt,
                onRemove: () => setState(() => _receipt = null),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_editing ? 'Save changes' : 'Add expense'),
              ),
            ]),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.name,
    required this.included,
    required this.type,
    required this.controller,
    required this.currency,
    required this.share,
    required this.onToggle,
    required this.onChanged,
  });

  final String name;
  final bool included;
  final SplitType type;
  final TextEditingController controller;
  final Currency currency;
  final int? share;
  final ValueChanged<bool> onToggle;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Checkbox(value: included, onChanged: (v) => onToggle(v ?? false)),
          PersonAvatar(name: name, radius: 14),
          const SizedBox(width: 10),
          Expanded(child: Text(name)),
          if (included && type != SplitType.equal)
            SizedBox(
              width: 90,
              child: TextField(
                controller: controller,
                textAlign: TextAlign.end,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: switch (type) {
                    SplitType.exact => '0',
                    SplitType.percentage => '0.00',
                    _ => '1',
                  },
                  suffixText: switch (type) {
                    SplitType.percentage => '%',
                    SplitType.shares => '×',
                    _ => null,
                  },
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
          SizedBox(
            width: 92,
            child: Text(
              included && share != null ? formatMoney(share!, currency.code) : '',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
        ]),
      );
}

class _ReceiptPicker extends StatelessWidget {
  const _ReceiptPicker({required this.path, required this.onPick, required this.onRemove});
  final String? path;
  final void Function(ImageSource) onPick;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    if (path != null && File(path!).existsSync()) {
      return Card(
        child: ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(path!), width: 48, height: 48, fit: BoxFit.cover),
          ),
          title: const Text('Receipt attached'),
          subtitle: const Text('Stored only on this device'),
          trailing: IconButton(icon: const Icon(Icons.close), onPressed: onRemove),
        ),
      );
    }
    return Row(children: [
      Expanded(
        child: OutlinedButton.icon(
            onPressed: () => onPick(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Receipt photo')),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: OutlinedButton.icon(
            onPressed: () => onPick(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('From gallery')),
      ),
    ]);
  }
}
