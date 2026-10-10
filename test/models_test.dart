import 'package:flutter_test/flutter_test.dart';
import 'package:cliproxy_quota/core/models.dart';

void main() {
  test('API-key OpenAI accounts are not assumed to have Codex quota', () {
    final account = AccountQuota.fromApi({'provider': 'openai'});
    expect(account.provider, 'GPT');
    expect(account.supported, false);
    expect(account.reason, '暂不支持');
  });
  test('empty plugin response preserves known passive quota', () {
    final account = const AccountQuota(
      provider: 'GPT',
      name: 'a',
      remaining: 20,
    ).withProbe(data: {'groups': []});
    expect(account.remaining, 20);
  });
  test('Codex prefers five-hour window even when secondary appears first', () {
    final account = AccountQuota.fromApi({
      'provider': 'codex',
      'name': 'a.json',
      'quota': {
        'observed_at': '2026-10-02T12:00:00Z',
        'signals': {
          'X-Codex-Primary-Used-Percent': '80',
          'X-Codex-Primary-Window-Minutes': '10080',
          'X-Codex-Secondary-Used-Percent': '12.5',
          'X-Codex-Secondary-Window-Minutes': '300',
          'X-Codex-Secondary-Reset-After-Seconds': '60',
        },
      },
    });
    expect(account.provider, 'GPT');
    expect(account.remaining, 87.5);
    expect(account.resetAt, DateTime.utc(2026, 10, 2, 12, 1));
  });
  test('Claude unified signals use fractions and five-hour reset', () {
    final account = AccountQuota.fromApi({
      'provider': 'claude',
      'quota': {
        'signals': {
          'anthropic-ratelimit-unified-5h-utilization': '0.4',
          'anthropic-ratelimit-unified-5h-reset': '1790942400',
          'anthropic-ratelimit-unified-7d-utilization': '0.8',
        },
      },
    });
    expect(account.remaining, 60);
    expect(account.windowMinutes, 300);
    expect(account.resetAt, isNotNull);
  });
  test('pool uses minimum, never average', () {
    final pool = ProviderQuota('GPT', [
      const AccountQuota(provider: 'GPT', name: 'a', remaining: 85),
      const AccountQuota(provider: 'GPT', name: 'b', remaining: 5),
    ]);
    expect(pool.remaining, 5);
    expect(pool.accounts.length, 2);
  });
  test(
    'unknown accounts do not hide healthy accounts; availability is explicit',
    () {
      final pool = ProviderQuota('GPT', [
        const AccountQuota(provider: 'GPT', name: 'a', remaining: 85),
        const AccountQuota(provider: 'GPT', name: 'b', reason: '已禁用'),
      ]);
      expect(pool.remaining, 85);
      expect(pool.availableCount, 1);
      expect(pool.issues, 1);
    },
  );
  test('disabled account does not become artificial zero', () {
    final account = AccountQuota.fromApi({
      'provider': 'codex',
      'disabled': true,
    });
    expect(account.reason, '已禁用');
    expect(account.remaining, isNull);
  });
  test('unknown quota signals and cooldown never become a percentage', () {
    final account = AccountQuota.fromApi({
      'provider': 'grok',
      'quota': {
        'exceeded': true,
        'signals': {'Retry-After': '60'},
      },
    });
    expect(account.remaining, isNull);
    expect(account.reason, '暂不支持');
  });
  test('plugin groups support Grok, prefer 5h and preserve zero', () {
    final account = AccountQuota.fromApi({'provider': 'grok'}).withProbe(
      data: {
        'groups': [
          {
            'displayName': 'Grok quota',
            'buckets': [
              {'window': 'weekly', 'remainingFraction': 0.8},
              {
                'window': '5h',
                'remainingFraction': 0,
                'remaining_fraction': 0.6,
                'resetTime': '2026-10-02T14:00:00Z',
              },
            ],
          },
        ],
      },
    );
    expect(account.remaining, 0);
    expect(account.supported, true);
    expect(account.windowMinutes, 300);
    expect(account.reason, isNull);
  });
  test(
    'snake case normalized groups and non-five-hour primary window work',
    () {
      final account = AccountQuota.fromApi({'provider': 'grok'}).withProbe(
        data: {
          'groups': [
            {
              'display_name': 'Grok',
              'buckets': [
                {
                  'window': 'daily',
                  'remaining_fraction': 0.5,
                  'reset_time': '2026-10-03T00:00:00Z',
                },
              ],
            },
          ],
        },
      );
      expect(account.remaining, 50);
      expect(account.windowMinutes, 1440);
      expect(account.resetAt, DateTime.utc(2026, 10, 3));
    },
  );
  test('malformed fractions do not become exhausted quota', () {
    for (final fraction in [null, 'NaN', 'Infinity', -1, 1.5]) {
      final account = AccountQuota.fromApi({'provider': 'grok'}).withProbe(
        data: {
          'groups': [
            {
              'buckets': [
                {'remainingFraction': fraction},
              ],
            },
          ],
        },
      );
      expect(account.remaining, isNull);
    }
  });
  test('widget omits unsupported providers and all account identifiers', () {
    final snapshot = QuotaSnapshot(DateTime.utc(2026, 10, 2), [
      const AccountQuota(
        provider: 'GPT',
        name: 'private@example.com',
        remaining: 30,
      ),
      const AccountQuota(
        provider: 'Other',
        name: 'secret.json',
        supported: false,
        reason: '暂不支持',
      ),
    ]);
    expect((snapshot.toWidgetJson()['providers'] as List).length, 1);
    expect(
      snapshot.toWidgetJson().toString(),
      isNot(contains('private@example.com')),
    );
    expect(snapshot.toWidgetJson().toString(), isNot(contains('secret.json')));
    expect(snapshot.providers.length, 2);
  });
  test('snapshot round trip preserves unsupported state', () {
    final snapshot = QuotaSnapshot(DateTime.utc(2026, 10, 2), [
      const AccountQuota(
        provider: 'Other',
        name: 'test',
        supported: false,
        reason: '暂不支持',
      ),
    ]);
    final restored = QuotaSnapshot.fromJson(snapshot.toJson());
    expect(restored.accounts.single.supported, false);
    expect(restored.updatedAt, snapshot.updatedAt);
  });
  test('upstream errors are reduced to safe reasons', () {
    final account = AccountQuota.fromApi({
      'provider': 'claude',
      'status': 'error',
      'status_message': '401 Bearer secret-token example',
    });
    expect(account.reason, '401 · 认证失效');
    expect(account.toJson().toString(), isNot(contains('secret-token')));
  });
}
