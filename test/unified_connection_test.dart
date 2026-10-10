import 'package:flutter_test/flutter_test.dart';
import 'package:cliproxy_quota/core/connection.dart';

void main() {
  test('one host derives independent CPA and Keeper endpoints', () {
    const s = ConnectionSettings(
      server: '74.82.192.138',
      port: 8443,
      unified: true,
      backend: 'keeper',
    );
    expect(s.keeperUri.toString(), 'https://74.82.192.138:8443/keeper');
    expect(s.cpaUri.toString(), 'https://74.82.192.138:8443');
    expect(s.baseUri, s.keeperUri);
    expect(ConnectionSettings.fromJson(s.toJson()).keeperUri, s.keeperUri);
  });
  test('pasted management and Keeper page URLs share the same origin', () {
    for (final path in ['/management.html#/', '/keeper/ranking']) {
      final s = ConnectionSettings(
        server: 'https://example.invalid:8443$path',
        unified: true,
        backend: 'keeper',
      );
      expect(s.keeperUri.toString(), 'https://example.invalid:8443/keeper');
      expect(s.cpaUri.toString(), 'https://example.invalid:8443');
    }
  });
  test('advanced overrides and legacy paths remain intact', () {
    const s = ConnectionSettings(
      server: 'shared.invalid',
      unified: true,
      keeperAddress: 'https://keeper.invalid/custom/',
      cpaAddress: 'https://cpa.invalid:8443',
    );
    expect(s.keeperUri.toString(), 'https://keeper.invalid/custom');
    expect(s.cpaUri.toString(), 'https://cpa.invalid:8443');
    const old = ConnectionSettings(
      server: '',
      backend: 'keeper',
      fullAddress: 'https://old.invalid/custom',
    );
    expect(ConnectionSettings.fromJson(old.toJson()).baseUri, old.baseUri);
  });
  test('unified address rejects embedded credentials and invalid port', () {
    expect(
      () => const ConnectionSettings(
        server: 'https://user:pass@example.invalid',
        unified: true,
      ).baseUri,
      throwsA(isA<AppError>()),
    );
    expect(
      () => const ConnectionSettings(
        server: 'host',
        port: 0,
        unified: true,
      ).baseUri,
      throwsA(isA<AppError>()),
    );
  });
}
