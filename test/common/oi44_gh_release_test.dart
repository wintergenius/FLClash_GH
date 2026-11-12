import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/subscription_info_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    hwidManager.resetForTesting();
  });

  group('OI-44 HwidManager & ASCII sanitization', () {
    test('computeGhostHopHwid normalizes GUID/ANDROID_ID and hashes SHA-256', () {
      final lower = computeGhostHopHwid(
        platformTag: 'win',
        rawId: 'd1a2b3c4-e5f6-4789-abcd-0123456789ef',
      );
      final upperPadded = computeGhostHopHwid(
        platformTag: 'win',
        rawId: '  D1A2B3C4-E5F6-4789-ABCD-0123456789EF \n',
      );
      final android = computeGhostHopHwid(
        platformTag: 'and',
        rawId: 'd1a2b3c4-e5f6-4789-abcd-0123456789ef',
      );

      expect(lower, hasLength(64));
      expect(lower, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(upperPadded, lower);
      expect(android, isNot(equals(lower)));
    });

    test('sanitizeDeviceHeaderValue enforces printable ASCII <= 64 chars', () {
      expect(
        sanitizeDeviceHeaderValue(
          'ПК-Николая\r\n\tдом',
          fallback: 'Windows PC',
        ),
        'Windows PC',
      );
      expect(
        sanitizeDeviceHeaderValue(
          '  Samsung\tSM-S928B (Ультра)  ',
          fallback: 'Android Device',
        ),
        'Samsung SM-S928B ()',
      );
      final overlong = 'Model-${'X' * 90}';
      final trimmed = sanitizeDeviceHeaderValue(
        overlong,
        fallback: 'Windows PC',
      );
      expect(trimmed.length, lessThanOrEqualTo(64));
      expect(trimmed.startsWith('Model-XXXX'), isTrue);
    });

    test(
      'HwidManager resolves deterministic Windows headers when on Windows',
      () async {
        if (!Platform.isWindows) {
          return;
        }
        hwidManager.windowsMachineGuidReader =
            () => '11223344-5566-7788-99AA-BBCCDDEEFF00';
        hwidManager.deviceInfoReader = () async =>
            BaseDeviceInfo({'computerName': 'ПК-Тест'});

        final headers = await hwidManager.getHeaders();
        expect(
          headers['x-hwid'],
          computeGhostHopHwid(
            platformTag: 'win',
            rawId: '11223344-5566-7788-99aa-bbccddeeff00',
          ),
        );
        expect(headers['x-device-os'], 'Windows');
        expect(headers['x-device-model'], 'Windows PC');
        for (final entry in headers.entries) {
          expect(
            entry.value.codeUnits.every((u) => u >= 0x20 && u <= 0x7E),
            isTrue,
            reason: 'Header ${entry.key} must be printable ASCII',
          );
          expect(entry.value.length, lessThanOrEqualTo(64));
        }
      },
    );
  });

  group('OI-44 Subscription headers & Profile-Title', () {
    test('SubscriptionInfo.formHString tolerates trailing semicolons', () {
      final clean = SubscriptionInfo.formHString(
        'upload=0; download=0; total=0; expire=1794430800',
      );
      final trailing = SubscriptionInfo.formHString(
        'upload=12; download=34; total=0; expire=1794430800; ; malformed',
      );
      expect(clean.total, 0);
      expect(clean.expire, 1794430800);
      expect(trailing.upload, 12);
      expect(trailing.download, 34);
      expect(trailing.total, 0);
      expect(trailing.expire, 1794430800);
    });

    test('parseProfileUpdateInterval clamps valid 1..168 hour window', () {
      expect(parseProfileUpdateInterval('12'), const Duration(hours: 12));
      expect(parseProfileUpdateInterval(' 1 '), const Duration(hours: 1));
      expect(parseProfileUpdateInterval('168'), const Duration(hours: 168));
      expect(parseProfileUpdateInterval('0'), isNull);
      expect(parseProfileUpdateInterval('169'), isNull);
      expect(parseProfileUpdateInterval('abc'), isNull);
      expect(parseProfileUpdateInterval(null), isNull);
    });

    test('decodeProfileTitle decodes base64: prefix and plain strings', () {
      expect(
        decodeProfileTitle('base64:R2hvc3RIb3AgVlBO'),
        'GhostHop VPN',
      );
      expect(decodeProfileTitle('GhostHop Mobile'), 'GhostHop Mobile');
      expect(decodeProfileTitle('base64:%%%invalid%%%'), isNull);
      expect(decodeProfileTitle('   '), isNull);
      expect(
        ''.takeFirstValid([
          decodeProfileTitle('base64:R2hvc3RIb3AgKDMg0YPRgdGC0YAuKQ=='),
          getFileNameForDisposition('attachment; filename="GhostHop.yaml"'),
        ]),
        'GhostHop (3 устр.)',
      );
    });

    testWidgets(
      'SubscriptionInfoView shows expire without 0 B / 0 B progress bar when total == 0',
      (tester) async {
        const info = SubscriptionInfo(
          upload: 0,
          download: 0,
          total: 0,
          expire: 1794430800,
        );
        await tester.pumpWidget(
          const TestApp(
            child: Scaffold(
              body: Column(
                children: [
                  SubscriptionInfoView(subscriptionInfo: info),
                  SubscriptionInfoDetailView(subscriptionInfo: info),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.textContaining('0 B'), findsNothing);
        expect(find.byType(Text), findsWidgets);
      },
    );
  });

  group('OI-44 Windows & Android out-of-the-box invariants', () {
    test('DNS fallback, Windows TUN gvisor, and Android dnsHijacking defaults', () {
      expect(defaultSystemDnsFallback, '77.88.8.8');
      expect(defaultTun.stack, TunStack.gvisor);
      expect(defaultWindowsTun.enable, isTrue);
      expect(defaultWindowsTun.autoRoute, isTrue);
      expect(defaultWindowsTun.stack, TunStack.gvisor);
      expect(defaultVpnProps.dnsHijacking, isTrue);

      final freshConfig = Config.realFromJson(null);
      expect(freshConfig.vpnProps.dnsHijacking, isTrue);
      expect(
        freshConfig.patchClashConfig.tun.enable,
        system.isWindows,
      );
      expect(freshConfig.patchClashConfig.tun.stack, TunStack.gvisor);
    });

    test('Inno Setup registers flclash:// URL protocol and Android MTU is 1360', () {
      final iss = File('windows/packaging/exe/inno_setup.iss').readAsStringSync();
      expect(iss, contains('[Registry]'));
      expect(iss, contains(r'Subkey: "Software\\Classes\\flclash"'));
      expect(iss, contains('ValueName: "URL Protocol"'));

      final vpnKt = File(
        'android/service/src/main/java/com/follow/clash/service/VpnService.kt',
      ).readAsStringSync();
      expect(vpnKt, contains('private const val MTU = 1360'));

      final tunGo = File('core/tun/tun.go').readAsStringSync();
      expect(tunGo, contains('MTU:                 1360,'));
    });
  });
}
