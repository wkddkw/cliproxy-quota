import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cliproxy_quota/core/models.dart';
import 'package:cliproxy_quota/ui/app.dart';

void main() {
  testWidgets(
    'GPT Claude and Grok cards use image marks instead of text initials',
    (tester) async {
      for (final name in ['GPT', 'Claude', 'Grok']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProviderCard(
                provider: ProviderQuota(name, [
                  AccountQuota(provider: name, name: 'fixture', remaining: 50),
                ]),
                onTap: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        final image =
            tester.widget<Image>(find.byType(Image)).image as AssetImage;
        expect(image.assetName, 'assets/providers/${name.toLowerCase()}.png');
      }
    },
  );
}
