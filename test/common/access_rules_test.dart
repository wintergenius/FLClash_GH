import 'package:fl_clash/common/access_rules.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopAccessRules.matcherOf', () {
    test('process name gets .exe appended', () {
      expect(
        DesktopAccessRules.matcherOf('msedge'),
        'PROCESS-NAME,msedge.exe',
      );
      expect(
        DesktopAccessRules.matcherOf(' RiotClientServices.exe '),
        'PROCESS-NAME,RiotClientServices.exe',
      );
    });

    test('executable path is matched exactly', () {
      expect(
        DesktopAccessRules.matcherOf(
          r'C:\Program Files (x86)\AnyDesk\AnyDesk.exe',
        ),
        r'PROCESS-PATH,C:\Program Files (x86)\AnyDesk\AnyDesk.exe',
      );
    });

    test('directory covers every executable under it', () {
      expect(
        DesktopAccessRules.matcherOf(r'C:\Program Files (x86)\AnyDesk'),
        r'PROCESS-PATH-WILDCARD,C:\Program Files (x86)\AnyDesk\*',
      );
      expect(
        DesktopAccessRules.matcherOf('C:/Games/'),
        r'PROCESS-PATH-WILDCARD,C:\Games\*',
      );
    });

    test('wildcards and unsafe characters', () {
      expect(
        DesktopAccessRules.matcherOf('chrome*'),
        'PROCESS-NAME-WILDCARD,chrome*.exe',
      );
      expect(
        DesktopAccessRules.matcherOf(r'C:\a,b\app.exe'),
        r'PROCESS-PATH-WILDCARD,C:\a?b\app.exe',
      );
      expect(
        DesktopAccessRules.matcherOf(r'C:\odd(\app.exe'),
        r'PROCESS-PATH-WILDCARD,C:\odd?\app.exe',
      );
      expect(
        DesktopAccessRules.matcherOf('  "quoted.exe" '),
        'PROCESS-NAME,quoted.exe',
      );
      expect(DesktopAccessRules.matcherOf('   '), isNull);
    });
  });

  group('DesktopAccessRules.build', () {
    test('disabled renders nothing', () {
      const props = AccessControlProps(
        acceptList: ['a.exe'],
        rejectList: ['b.exe'],
      );
      expect(DesktopAccessRules.build(props), isEmpty);
    });

    test('tunneled only: everything else goes direct', () {
      const props = AccessControlProps(enable: true, acceptList: ['discord']);
      expect(DesktopAccessRules.build(props), [
        'NOT,((PROCESS-NAME,discord.exe)),DIRECT',
      ]);
    });

    test('several tunneled entries are joined with OR', () {
      const props = AccessControlProps(
        enable: true,
        acceptList: ['discord', 'C:/Games/'],
      );
      expect(DesktopAccessRules.build(props), [
        r'NOT,((OR,((PROCESS-NAME,discord.exe),(PROCESS-PATH-WILDCARD,C:\Games\*)))),DIRECT',
      ]);
    });

    test('tunneled takes priority over non-tunneled', () {
      const props = AccessControlProps(
        enable: true,
        acceptList: ['discord'],
        rejectList: ['discord', 'msedge'],
      );
      expect(DesktopAccessRules.build(props), [
        'NOT,((PROCESS-NAME,discord.exe)),DIRECT',
      ]);
    });

    test('non-tunneled only: listed apps go direct', () {
      const props = AccessControlProps(
        enable: true,
        rejectList: ['msedge', r'C:\Program Files (x86)\AnyDesk', 'msedge.exe'],
      );
      expect(DesktopAccessRules.build(props), [
        'PROCESS-NAME,msedge.exe,DIRECT',
        r'PROCESS-PATH-WILDCARD,C:\Program Files (x86)\AnyDesk\*,DIRECT',
      ]);
    });
  });
}
