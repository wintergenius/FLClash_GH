import 'dart:convert';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/migration.dart';
import 'package:fl_clash/common/russian_apps.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart';

void main() {
  group('Migration', () {
    test('returns current config without rewriting storage', () async {
      final configMap = _createConfigMap(
        davProps: const DAVProps(
          uri: 'https://example.com/dav',
          user: 'user',
          password: 'secret',
        ),
      );
      final store = _FakeMigrationStore(
        configMap: configMap,
        version: Migration.currentVersion,
      );

      final config = await Migration(store: store).run();

      expect(config, Config.realFromJson(configMap));
      expect(config.davProps?.password, 'secret');
      expect(store.events, ['getConfigMap', 'getVersion']);
    });

    test(
      'obfuscates a compatible DAV password without a version migration',
      () async {
        final configMap = _createConfigMap(
          davProps: const DAVProps(
            uri: 'https://example.com/dav',
            user: 'user',
          ),
        );
        final davProps = configMap['davProps']! as Map<String, Object?>;
        davProps['password'] = 'secret';
        final store = _FakeMigrationStore(configMap: configMap, version: 1);

        final config = await Migration(store: store).run();

        expect(config.davProps?.user, 'user');
        expect(config.davProps?.password, 'secret');
        expect(store.savedConfig, config);
        expect(store.version, Migration.currentVersion);
        expect(store.events, ['getConfigMap', 'getVersion', 'saveConfig']);
        final savedConfigMap =
            jsonDecode(jsonEncode(store.savedConfig)) as Map<String, Object?>;
        final savedDavProps =
            savedConfigMap['davProps']! as Map<String, Object?>;
        expect(savedDavProps['password'], startsWith('v1.'));
        expect(savedDavProps['password'], isNot(contains('secret')));
      },
    );

    test(
      'commits v0 cleanup and version only after migrated data is saved',
      () async {
        final configMap = <String, Object?>{
          'proxiesStyle': <String, Object?>{},
          'dav': <String, Object?>{
            'uri': 'https://example.com/dav',
            'user': 'user',
            'password': 'secret',
          },
        };
        final store = _FakeMigrationStore(
          configMap: configMap,
          version: 0,
          clashConfigMap: <String, Object?>{'mixed-port': 7890},
        );
        final migration = Migration(
          store: store,
          migrateV0: (configMap) async {
            store.events.add('migrateV0');
            expect(configMap['patchClashConfig'], store.clashConfigMap);
            return MigrationData(
              configMap: _createConfigMap(
                davProps: const DAVProps(
                  uri: 'https://example.com/dav',
                  user: 'user',
                  password: 'secret',
                ),
              ),
            );
          },
        );

        await migration.run();

        expect(store.events, [
          'getConfigMap',
          'getVersion',
          'getClashConfigMap',
          'migrateV0',
          'restore',
          'saveConfig',
          'clearClashConfig',
          'setVersion',
        ]);
        expect(store.savedConfig?.davProps?.password, 'secret');
        expect(store.didClearClashConfig, isTrue);
        expect(store.version, Migration.currentVersion);
      },
    );

    test(
      'preserves legacy clash config when current-shaped data has version zero',
      () async {
        final configMap = _createConfigMap()..remove('patchClashConfig');
        final clashConfigMap = _createClashConfigMap(mixedPort: 1234);
        final store = _FakeMigrationStore(
          configMap: configMap,
          version: 0,
          clashConfigMap: clashConfigMap,
        );

        final config = await Migration(store: store).run();

        expect(config.patchClashConfig.mixedPort, 1234);
        expect(store.savedConfig?.patchClashConfig.mixedPort, 1234);
        expect(store.didClearClashConfig, isTrue);
        expect(store.events, [
          'getConfigMap',
          'getVersion',
          'getClashConfigMap',
          'restore',
          'saveConfig',
          'clearClashConfig',
          'setVersion',
        ]);
      },
    );

    test('does not clear legacy clash config when saving fails', () async {
      final configMap = _createConfigMap()..remove('patchClashConfig');
      final store = _FakeMigrationStore(
        configMap: configMap,
        version: 0,
        clashConfigMap: _createClashConfigMap(mixedPort: 1234),
        configSaveResult: false,
      );

      await expectLater(
        Migration(store: store).run(),
        throwsA(isA<StateError>()),
      );

      expect(store.didClearClashConfig, isFalse);
      expect(store.version, 0);
      expect(store.events, [
        'getConfigMap',
        'getVersion',
        'getClashConfigMap',
        'restore',
        'saveConfig',
        'isAvailable',
      ]);
    });

    test('starts with defaults when the store cannot be opened', () async {
      final store = _FakeMigrationStore(
        configMap: null,
        version: 0,
        configSaveResult: false,
        available: false,
      );

      final config = await Migration(store: store).run();

      expect(config, isNotNull);
      expect(store.didClearClashConfig, isFalse);
      expect(store.version, 0);
      expect(store.events, [
        'getConfigMap',
        'getVersion',
        'getClashConfigMap',
        'restore',
        'saveConfig',
        'isAvailable',
      ]);
    });

    group('upgrade', () {
      Map<String, Object?> customized() =>
          _createConfigMap()
            ..['themeProps'] = {
              'primaryColor': 0xFF123456,
              'primaryColors': [0xFF795548, 0xFF123456],
              'schemeVariant': 'tonalSpot',
              'themeMode': 'dark',
              'pureBlack': true,
              'liquidGlass': true,
              'systemFontFamily': 'Beta Serif',
            };

      test('starts theme colors over once and keeps the rest', () async {
        final store = _FakeMigrationStore(
          configMap: customized(),
          version: Migration.currentVersion,
          upgradeVersion: 0,
        );

        final config = await Migration(store: store).run();

        final theme = config.themeProps;
        expect(theme.primaryColor, defaultPrimaryColor);
        expect(theme.primaryColors, defaultPrimaryColors);
        expect(theme.colorStyle, ColorStyle.vivid);
        expect(theme.themeMode, ThemeMode.dark);
        expect(theme.pureBlack, isTrue);
        expect(theme.liquidGlass, LiquidGlassMode.ultra);
        expect(theme.fontFamily, 'Beta Serif');
        expect(store.savedConfig, config);
        expect(store.version, Migration.currentVersion);
        expect(store.upgradeVersion, Migration.upgradeVersion);
        expect(store.events, [
          'getConfigMap',
          'getVersion',
          'saveConfig',
          'setUpgradeVersion',
        ]);

        final later = _FakeMigrationStore(
          configMap: jsonDecode(
            jsonEncode(config.copyWith.themeProps(primaryColor: 0xFF123456)),
          ),
          version: store.version,
          upgradeVersion: store.upgradeVersion,
        );
        final kept = await Migration(store: later).run();

        expect(kept.themeProps.primaryColor, 0xFF123456);
        expect(later.events, ['getConfigMap', 'getVersion']);
      });

      test('keeps standard glass on the ultra tier it became, once', () async {
        Future<LiquidGlassMode> upgrade(String mode, int from) async {
          final configMap = _createConfigMap();
          (configMap['themeProps']! as Map<String, Object?>)['liquidGlass'] =
              mode;
          final store = _FakeMigrationStore(
            configMap: configMap,
            version: Migration.currentVersion,
            upgradeVersion: from,
          );
          return (await Migration(store: store).run()).themeProps.liquidGlass;
        }

        expect(await upgrade('standard', 1), LiquidGlassMode.ultra);
        expect(await upgrade('none', 1), LiquidGlassMode.none);
        expect(await upgrade('standard', 2), LiquidGlassMode.standard);
      });

      test('moves presets picked before to the current system colors, '
          'once', () async {
        Future<ThemeProps> upgrade(int from) async {
          final configMap = _createConfigMap();
          (configMap['themeProps']! as Map<String, Object?>)
            ..['primaryColor'] = 0xFFFF9500
            ..['primaryColors'] = [
              0xFF007AFF,
              0xFFAF52DE,
              0xFFCB30E0,
              0xFFFF9500,
              0xFF123456,
            ];
          final store = _FakeMigrationStore(
            configMap: configMap,
            version: Migration.currentVersion,
            upgradeVersion: from,
          );
          return (await Migration(store: store).run()).themeProps;
        }

        final moved = await upgrade(2);
        expect(moved.primaryColor, 0xFFFF8D28);
        expect(moved.primaryColors, [
          0xFF007AFF,
          0xFFCB30E0,
          0xFFFF8D28,
          0xFF123456,
        ]);
        expect((await upgrade(3)).primaryColor, 0xFFFF9500);
      });

      test('turns off the sidebar blur releases stored unseen, once', () async {
        Future<bool> upgrade(int from) async {
          final configMap = _createConfigMap();
          (configMap['themeProps']! as Map<String, Object?>)['sidebarBlur'] =
              true;
          final store = _FakeMigrationStore(
            configMap: configMap,
            version: Migration.currentVersion,
            upgradeVersion: from,
          );
          return (await Migration(store: store).run()).themeProps.sidebarBlur;
        }

        expect(await upgrade(3), isFalse);
        expect(await upgrade(4), isTrue);
      });

      test(
        'turns off Android VPN systemProxy and strips legacy Chinese bypass domains, once',
        () async {
          Future<Config> upgrade(int from) async {
            final configMap = _createConfigMap();
            configMap['vpnProps'] = <String, Object?>{
              'enable': true,
              'systemProxy': true,
              'ipv6': false,
              'allowBypass': true,
              'dnsHijacking': false,
            };
            configMap['networkProps'] = <String, Object?>{
              'systemProxy': true,
              'bypassDomain': [
                '*zhihu.com',
                '*zhimg.com',
                '*jd.com',
                '100ime-iat-api.xfyun.cn',
                '*360buyimg.com',
                'localhost',
                '*.corp.example',
              ],
            };
            final store = _FakeMigrationStore(
              configMap: configMap,
              version: Migration.currentVersion,
              upgradeVersion: from,
            );
            return Migration(store: store).run();
          }

          final upgraded = await upgrade(4);
          expect(upgraded.vpnProps.systemProxy, isFalse);
          expect(upgraded.vpnProps.dnsHijacking, isTrue);
          expect(upgraded.networkProps.systemProxy, isTrue);
          expect(upgraded.networkProps.bypassDomain, [
            'localhost',
            '*.corp.example',
          ]);

          final keptAfterUpgrade = await upgrade(5);
          expect(keptAfterUpgrade.vpnProps.systemProxy, isTrue);
          expect(keptAfterUpgrade.vpnProps.dnsHijacking, isFalse);
        },
      );

      test(
        'enables Russian split tunneling on Android upgrades without touching desktop or custom setups',
        () async {
          expect(
            defaultAndroidRussianRejectPackages.toSet().length,
            defaultAndroidRussianRejectPackages.length,
          );
          expect(
            defaultAndroidRussianRejectPackages,
            orderedEquals([...defaultAndroidRussianRejectPackages]..sort()),
          );
          expect(
            defaultAndroidRussianRejectPackages.any(
              (pkg) =>
                  pkg == 'com.yandex.browser' ||
                  pkg.startsWith('com.yandex.browser.') ||
                  pkg == 'ru.mail.browser',
            ),
            isFalse,
          );
          expect(
            defaultAndroidRussianRejectPackages,
            containsAll(<String>[
              'ru.sberbankmobile',
              'com.idamob.tinkoff.android',
              'ru.vtb24.mobilebanking.android',
              'ru.alfabank.mobile.android',
              'ru.rostel',
              'ru.nspk.mirpay',
              'ru.vk.store',
              'ru.oneme.app',
              'com.vkontakte.android',
              'com.avito.android',
              'com.wildberries.ru',
              'ru.ozon.app.android',
            ]),
          );

          // Android upgrade from v1.0.4 / upgradeVersion 5 with untouched split tunneling:
          final androidStore = _FakeMigrationStore(
            configMap: _createConfigMap(),
            version: Migration.currentVersion,
            upgradeVersion: 5,
          );
          final androidUpgraded = await Migration(
            store: androidStore,
            isAndroid: true,
          ).run();
          final androidAccess = androidUpgraded.vpnProps.accessControlProps;
          expect(androidAccess.enable, isTrue);
          expect(androidAccess.mode, AccessControlMode.rejectSelected);
          expect(androidAccess.autoRejectRussian, isTrue);
          expect(
            androidAccess.rejectList,
            defaultAndroidRussianRejectPackages,
          );

          // Desktop upgrade from upgradeVersion 5 stays untouched:
          final desktopStore = _FakeMigrationStore(
            configMap: _createConfigMap(),
            version: Migration.currentVersion,
            upgradeVersion: 5,
          );
          final desktopUpgraded = await Migration(
            store: desktopStore,
            isAndroid: false,
          ).run();
          expect(desktopUpgraded.vpnProps.accessControlProps.enable, isFalse);
          expect(desktopUpgraded.vpnProps.accessControlProps.rejectList, isEmpty);

          // Android user who already configured custom split tunneling keeps their setup:
          final customMap = _createConfigMap();
          customMap['vpnProps'] = <String, Object?>{
            'enable': true,
            'systemProxy': false,
            'ipv6': false,
            'allowBypass': true,
            'dnsHijacking': true,
            'accessControlProps': <String, Object?>{
              'enable': false,
              'mode': 'rejectSelected',
              'acceptList': <String>[],
              'rejectList': <String>['ru.sberbankmobile'],
            },
          };
          final customStore = _FakeMigrationStore(
            configMap: customMap,
            version: Migration.currentVersion,
            upgradeVersion: 5,
          );
          final customUpgraded = await Migration(
            store: customStore,
            isAndroid: true,
          ).run();
          expect(customUpgraded.vpnProps.accessControlProps.enable, isFalse);
          expect(customUpgraded.vpnProps.accessControlProps.rejectList, [
            'ru.sberbankmobile',
          ]);
        },
      );

      test('a new install only records it', () async {
        final store = _FakeMigrationStore(
          configMap: null,
          version: 0,
          upgradeVersion: 0,
        );

        final config = await Migration(store: store).run();

        expect(config.themeProps, defaultThemeProps);
        expect(store.upgradeVersion, Migration.upgradeVersion);
        expect(
          store.events.where((event) => event == 'saveConfig'),
          hasLength(1),
        );
      });

      test('waits for the next launch when saving fails', () async {
        final store = _FakeMigrationStore(
          configMap: customized(),
          version: Migration.currentVersion,
          upgradeVersion: 0,
          configSaveResult: false,
        );

        final config = await Migration(store: store).run();

        expect(config.themeProps.primaryColor, 0xFF123456);
        expect(store.upgradeVersion, 0);
      });
    });

    test('keeps what it can read of a damaged current config', () async {
      final configMap = _createConfigMap()
        ..['currentProfileId'] = 7
        ..['excludeSSIDs'] = 'home';
      final store = _FakeMigrationStore(
        configMap: configMap,
        version: Migration.currentVersion,
      );

      final config = await Migration(store: store).run();

      expect(config.currentProfileId, 7);
      expect(config.excludeSSIDs, isEmpty);
      expect(store.events, ['getConfigMap', 'getVersion']);
    });

    test('keeps the current version when password obfuscation fails', () async {
      final configMap = _createConfigMap(
        davProps: const DAVProps(uri: 'https://example.com/dav', user: 'user'),
      );
      final davProps = configMap['davProps']! as Map<String, Object?>;
      davProps['password'] = 'secret';
      final store = _FakeMigrationStore(
        configMap: configMap,
        version: Migration.currentVersion,
        configSaveResult: false,
      );

      await expectLater(
        Migration(store: store).run(),
        throwsA(isA<StateError>()),
      );

      expect(store.events, ['getConfigMap', 'getVersion', 'saveConfig']);
      expect(store.version, Migration.currentVersion);
    });
  });
}

Map<String, Object?> _createConfigMap({DAVProps? davProps}) {
  return jsonDecode(
        jsonEncode(Config(themeProps: defaultThemeProps, davProps: davProps)),
      )
      as Map<String, Object?>;
}

Map<String, Object?> _createClashConfigMap({required int mixedPort}) {
  return jsonDecode(jsonEncode(PatchClashConfig(mixedPort: mixedPort)))
      as Map<String, Object?>;
}

class _FakeMigrationStore implements MigrationStore {
  final Map<String, Object?>? configMap;
  final Map<String, Object?>? clashConfigMap;
  final bool configSaveResult;
  final bool available;
  final List<String> events = [];

  int version;
  int upgradeVersion;
  Config? savedConfig;
  MigrationData? restoredData;
  bool didClearClashConfig = false;

  _FakeMigrationStore({
    required this.configMap,
    required this.version,
    this.upgradeVersion = Migration.upgradeVersion,
    this.clashConfigMap,
    this.configSaveResult = true,
    this.available = true,
  });

  @override
  Future<bool> get isAvailable async {
    events.add('isAvailable');
    return available;
  }

  @override
  Future<void> clearClashConfig() async {
    events.add('clearClashConfig');
    didClearClashConfig = true;
  }

  @override
  Future<Map<String, Object?>?> getClashConfigMap() async {
    events.add('getClashConfigMap');
    return clashConfigMap;
  }

  @override
  Future<Map<String, Object?>?> getConfigMap() async {
    events.add('getConfigMap');
    return configMap;
  }

  @override
  Future<int> getVersion() async {
    events.add('getVersion');
    return version;
  }

  @override
  Future<void> restore(MigrationData data) async {
    events.add('restore');
    restoredData = data;
  }

  @override
  Future<bool> saveConfig(Config config) async {
    events.add('saveConfig');
    savedConfig = config;
    return configSaveResult;
  }

  @override
  Future<void> setVersion(int version) async {
    events.add('setVersion');
    this.version = version;
  }

  @override
  Future<int> getUpgradeVersion() async => upgradeVersion;

  @override
  Future<void> setUpgradeVersion(int version) async {
    events.add('setUpgradeVersion');
    upgradeVersion = version;
  }
}
