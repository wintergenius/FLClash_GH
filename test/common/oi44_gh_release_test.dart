import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/host_scaffold.dart';
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
        'upload=12; download=34; total=0; expire=1794430800; ; malformed; =99',
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
          HostApp(
            builder: (context, child) => wrapAppScopes(context, child!),
            home: const HostScaffold(
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

  group('OI-44 & v1.0.5 Windows/Android out-of-the-box invariants', () {
    test(
      'DNS fallback, Windows TUN gvisor, Android VpnProps (F2), and clean bypass domains',
      () {
        expect(defaultSystemDnsFallback, '77.88.8.8');
        expect(defaultTunMtu, 1360);
        expect(defaultTun.stack, TunStack.gvisor);
        expect(defaultTun.mtu, 1360);
        expect(defaultWindowsTun.enable, isTrue);
        expect(defaultWindowsTun.coreJson['auto-route'], isTrue);
        expect(defaultWindowsTun.stack, TunStack.gvisor);

        // F2 invariants: Android VPN HTTP proxy off by default, DNS hijack on,
        // allowBypass on, desktop NetworkProps.systemProxy untouched.
        expect(defaultVpnProps.systemProxy, isFalse);
        expect(defaultVpnProps.dnsHijacking, isTrue);
        expect(defaultVpnProps.allowBypass, isTrue);
        expect(defaultNetworkProps.systemProxy, isTrue);
        for (final legacyDomain in const [
          '*zhihu.com',
          '*zhimg.com',
          '*jd.com',
          '100ime-iat-api.xfyun.cn',
          '*360buyimg.com',
        ]) {
          expect(defaultBypassDomain, isNot(contains(legacyDomain)));
        }

        final freshConfig = Config.realFromJson(null);
        expect(freshConfig.vpnProps.systemProxy, isFalse);
        expect(freshConfig.vpnProps.dnsHijacking, isTrue);
        expect(freshConfig.patchClashConfig.tun.enable, system.isWindows);
        expect(freshConfig.patchClashConfig.tun.stack, TunStack.gvisor);
        expect(freshConfig.patchClashConfig.tun.mtu, 1360);
      },
    );

    test(
      'makeRealProfileTask enables store-fake-ip by default (A5) and preserves explicit false',
      () async {
        final defaultBuilt = await makeRealProfileTask(
          const MakeRealProfileState(
            profilesPath: '/tmp/profiles',
            profileId: 1,
            rawConfig: <String, dynamic>{},
            realPatchConfig: PatchClashConfig(),
            appendSystemDns: false,
            proxyGroups: [],
            rules: [],
            addedRules: [],
            defaultUA: 'FlClashGH/v1.0.5',
          ),
        );
        final defaultYaml = loadYaml(defaultBuilt.yaml) as YamlMap;
        expect(defaultYaml['profile']['store-selected'], isFalse);
        expect(defaultYaml['profile']['store-fake-ip'], isTrue);

        final explicitFalseBuilt = await makeRealProfileTask(
          const MakeRealProfileState(
            profilesPath: '/tmp/profiles',
            profileId: 2,
            rawConfig: <String, dynamic>{
              'profile': <String, dynamic>{'store-fake-ip': false},
            },
            realPatchConfig: PatchClashConfig(),
            appendSystemDns: false,
            proxyGroups: [],
            rules: [],
            addedRules: [],
            defaultUA: 'FlClashGH/v1.0.5',
          ),
        );
        final explicitFalseYaml = loadYaml(explicitFalseBuilt.yaml) as YamlMap;
        expect(explicitFalseYaml['profile']['store-fake-ip'], isFalse);
      },
    );

    test(
      'Inno Setup registers flclash:// URL protocol and Android/Go MTU default is 1360',
      () {
        final iss = File(
          'windows/packaging/exe/inno_setup.iss',
        ).readAsStringSync();
        expect(iss, contains('[Registry]'));
        expect(iss, contains(r'Subkey: "Software\\Classes\\flclash"'));
        expect(iss, contains('ValueName: "URL Protocol"'));

        final vpnOptsKt = File(
          'android/service/src/main/java/com/follow/clash/service/models/VpnOptions.kt',
        ).readAsStringSync();
        expect(vpnOptsKt, contains('const val DEFAULT_TUN_MTU = 1360'));

        final tunGo = File('core/tun/tun.go').readAsStringSync();
        expect(tunGo, contains('mtu = 1360'));
      },
    );
  });
}
