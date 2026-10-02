typedef Json = Map<String, dynamic>;

double? number(dynamic value) {
  final result = value is num ? value.toDouble() : double.tryParse('$value');
  return result != null && result.isFinite ? result : null;
}

DateTime? timestamp(dynamic value) {
  if (value == null) return null;
  final numeric = number(value);
  if (numeric != null) {
    return DateTime.fromMillisecondsSinceEpoch(
      (numeric > 100000000000 ? numeric : numeric * 1000).round(),
      isUtc: true,
    );
  }
  return DateTime.tryParse('$value')?.toUtc();
}
