import 'package:flutter/material.dart';
import '../core/quota_details.dart';

class QuotaPeriodView extends StatelessWidget {
  const QuotaPeriodView({
    super.key,
    required this.period,
    this.showPercent = true,
  });
  final QuotaPeriod period;
  final bool showPercent;
  String date(DateTime time) {
    final t = time.toLocal();
    String pad(int n) => '$n'.padLeft(2, '0');
    return '${t.year}-${pad(t.month)}-${pad(t.day)} ${pad(t.hour)}:${pad(t.minute)}';
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Text(period.label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (period.start != null)
          Text(
            '周期开始：${date(period.start!)}',
            style: const TextStyle(fontSize: 12),
          ),
        if (period.end != null)
          Text(
            '重置于 ${date(period.end!)}',
            style: const TextStyle(fontSize: 12),
          ),
        if (showPercent && period.remainingPercent != null)
          Text('该周期剩余 ${period.remainingPercent!.floor()}%'),
        if (period.tokens.hasData) ...[
          const SizedBox(height: 10),
          AmountsView(title: 'Token 额度', values: period.tokens),
        ],
        if (period.usd.hasData) ...[
          const SizedBox(height: 10),
          AmountsView(title: '美元额度（USD）', values: period.usd, dollars: true),
        ],
      ],
    ),
  );
}

class AmountsView extends StatelessWidget {
  const AmountsView({
    super.key,
    required this.title,
    required this.values,
    this.dollars = false,
  });
  final String title;
  final QuotaAmounts values;
  final bool dollars;
  String amount(double? value) {
    if (value == null) return '未提供';
    if (dollars) {
      if (value > 0 && value < 0.000001) return '< \$0.000001';
      final text = value == (value * 100).round() / 100
          ? value.toStringAsFixed(2)
          : value.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '');
      return '\$$text';
    }
    return value.round().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!values.hasData) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final field in [
              ('总额度', values.total),
              ('已用', values.used),
              ('剩余', values.remaining),
            ].where((field) => field.$2 != null))
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      field.$1,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        amount(field.$2),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
