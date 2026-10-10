import 'models.dart';

num? usageNumber(dynamic value) {
  final parsed = value is num ? value : num.tryParse('$value');
  return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
}

String compactUsage(dynamic value) {
  final number = usageNumber(value);
  if (number == null) return '—';
  const suffix = ['', 'K', 'M', 'B'];
  var scaled = number.toDouble(), index = 0;
  while (scaled >= 1000 && index < 3) {
    scaled /= 1000;
    index++;
  }
  if (double.parse(scaled.toStringAsFixed(2)) >= 1000 && index < 3) {
    scaled /= 1000;
    index++;
  }
  final digits = scaled
      .toStringAsFixed(index == 0 ? 0 : 2)
      .replaceFirst(RegExp(r'\.0+$'), '')
      .replaceFirstMapped(RegExp(r'(\.\d*?)0+$'), (m) => m[1]!);
  return '$digits${suffix[index]}';
}

String exactUsage(dynamic value) {
  final number = usageNumber(value);
  if (number == null) return '未提供';
  return number
      .toStringAsFixed(0)
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}

String usageCost(Map row, {String field = 'cost_usd'}) {
  final amount = usageNumber(row[field]);
  if (!row.containsKey(field)) return '未返回费用';
  if (amount == null) return '费用数据异常';
  if (amount == 0 && row['cost_available'] == false) return '未完整计价';
  final suffix = row['cost_available'] == false
      ? '（部分）'
      : row['cost_available'] == null
      ? '（完整性未知）'
      : '';
  if (amount == 0) return '\$0$suffix';
  if (amount < 0.001) return '<\$0.001$suffix';
  return '\$${amount.toStringAsFixed(3)}$suffix';
}

List<Json> dailyUsage(dynamic value) {
  if (value is! List) return [];
  final days = <String, Json>{};
  const metrics = [
    'total_tokens',
    'requests',
    'input_tokens',
    'output_tokens',
    'cache_read_tokens',
    'cache_creation_tokens',
    'reasoning_tokens',
  ];
  for (final raw in value.whereType<Map>()) {
    final bucket = '${raw['bucket'] ?? ''}';
    if (bucket.length < 10 || !RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(bucket)) {
      continue;
    }
    final date = bucket.substring(
      0,
      10,
    ); // Retain the server bucket's calendar day, never device timezone.
    final row = days.putIfAbsent(
      date,
      () => {'label': date, 'day': date, 'cost_available': true},
    );
    for (final key in metrics) {
      final n = usageNumber(raw[key]);
      if (n != null) row[key] = (row[key] as num? ?? 0) + n;
    }
    final cost = usageNumber(raw['cost_usd']);
    if (cost != null) row['cost_usd'] = (row['cost_usd'] as num? ?? 0) + cost;
    if (raw['cost_available'] != true || cost == null) {
      row['cost_available'] = false;
    }
  }
  final keys = days.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final k in keys) days[k]!];
}
