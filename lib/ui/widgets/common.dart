import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../domain/models.dart';
import '../theme.dart';

/// Renders an AsyncValue with consistent loading and error states.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.builder});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const Center(child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        )),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load: $e', textAlign: TextAlign.center),
          ),
        ),
      );
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.imagePath, this.radius = 20});
  final String name;
  final String? imagePath;
  final double radius;

  static const _palette = [
    Color(0xFF14866D), Color(0xFF3563E9), Color(0xFFB4508A), Color(0xFFCA7A12),
    Color(0xFF6B4FD8), Color(0xFF0E7490), Color(0xFFB93838), Color(0xFF4D7C0F),
  ];

  @override
  Widget build(BuildContext context) {
    if (imagePath != null && File(imagePath!).existsSync()) {
      return CircleAvatar(radius: radius, backgroundImage: FileImage(File(imagePath!)));
    }
    final trimmed = name.trim();
    final initials = trimmed.isEmpty
        ? '?'
        : trimmed.split(RegExp(r'\s+')).take(2).map((w) => w.characters.first.toUpperCase()).join();
    final color = _palette[trimmed.hashCode.abs() % _palette.length];
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Text(initials,
          style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: radius * 0.75)),
    );
  }
}

/// "you are owed ₹800.00" / "you owe ₹400.00" / "settled up".
class BalanceText extends StatelessWidget {
  const BalanceText({super.key, required this.byCurrency, this.style, this.prefixOwed = 'you are owed', this.prefixOwe = 'you owe'});
  final Map<String, int> byCurrency;
  final TextStyle? style;
  final String prefixOwed;
  final String prefixOwe;

  @override
  Widget build(BuildContext context) {
    final entries = byCurrency.entries.where((e) => e.value != 0).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final base = style ?? Theme.of(context).textTheme.bodyMedium!;
    if (entries.isEmpty) {
      return Text('settled up', style: base.copyWith(color: context.money.settled));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in entries)
          Text(
            '${e.value > 0 ? prefixOwed : prefixOwe} ${formatMoney(e.value.abs(), e.key)}',
            style: base.copyWith(
                color: e.value > 0 ? context.money.owed : context.money.owe, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
        child: Row(children: [
          Expanded(
            child: Text(title.toUpperCase(),
                style: Theme.of(context).textTheme.labelMedium!.copyWith(
                    letterSpacing: 0.8,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700)),
          ),
          ?trailing,
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(message,
              style: Theme.of(context).textTheme.bodyMedium!
                  .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      );
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.icon, required this.text, this.color, this.action});
  final IconData icon;
  final String text;
  final Color? color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Icon(icon, color: c, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ?action,
      ]),
    );
  }
}

IconData categoryIcon(String category) => switch (category) {
      'food' => Icons.restaurant,
      'groceries' => Icons.local_grocery_store,
      'transport' => Icons.directions_car,
      'travel' => Icons.flight,
      'lodging' => Icons.hotel,
      'rent' => Icons.home,
      'utilities' => Icons.bolt,
      'entertainment' => Icons.movie,
      'shopping' => Icons.shopping_bag,
      'health' => Icons.local_hospital,
      _ => Icons.receipt_long,
    };

class ExpenseTile extends StatelessWidget {
  const ExpenseTile({super.key, required this.expense, required this.people, required this.me, this.onTap, this.showGroup});
  final Expense expense;
  final Map<String, Person> people;
  final String me;
  final VoidCallback? onTap;
  final String? showGroup;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    final payer = e.payerId == me ? 'You' : (people[e.payerId]?.name ?? 'Someone');
    final myShare = e.splits[me] ?? 0;
    final lent = e.payerId == me ? e.amountMinor - myShare : -myShare;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
        child: Icon(categoryIcon(e.category), color: scheme.onPrimaryContainer),
      ),
      title: Row(children: [
        Flexible(child: Text(e.description, overflow: TextOverflow.ellipsis)),
        if (e.conflicted) ...[
          const SizedBox(width: 6),
          Icon(Icons.warning_amber_rounded, size: 16, color: context.money.owe),
        ],
      ]),
      subtitle: Text(
        [
          '$payer paid ${formatMoney(e.amountMinor, e.currency)}',
          DateFormat.MMMd().format(DateTime.fromMillisecondsSinceEpoch(e.expenseDate)),
          ?showGroup,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: lent == 0
          ? Text('not involved', style: TextStyle(color: context.money.settled, fontSize: 12))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(lent > 0 ? 'you lent' : 'you borrowed',
                    style: TextStyle(fontSize: 11, color: lent > 0 ? context.money.owed : context.money.owe)),
                Text(formatMoney(lent.abs(), e.currency),
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: lent > 0 ? context.money.owed : context.money.owe)),
              ],
            ),
    );
  }
}

void showSnack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String timeAgo(int millis) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(millis));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(millis));
}
