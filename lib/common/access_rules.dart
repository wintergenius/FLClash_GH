import 'package:fl_clash/models/models.dart';

/// Per-application split for desktop, rendered as mihomo rules.
///
/// The semantics mirror WireSock's "Tunneled / Non-tunneled applications":
///
/// * The tunneled list is non-empty: only the listed applications follow the
///   profile rules, everything else goes DIRECT. The non-tunneled list is
///   ignored in that case, tunneled applications take priority.
/// * Only the non-tunneled list is non-empty: the listed applications go
///   DIRECT, everything else follows the profile rules.
/// * Both lists empty, or the feature disabled: no rules at all.
///
/// Entry forms, matched case-insensitively like WireSock does:
///
/// * `name` or `name.exe`: the process name, `.exe` is appended when missing.
/// * `C:\dir\app.exe`: the exact executable path.
/// * `C:\dir` or `C:\dir\`: every executable under the directory.
/// * `*` and `?` inside an entry switch to wildcard matching.
///
/// On desktop the [AccessControlProps.acceptList] holds the tunneled entries
/// and [AccessControlProps.rejectList] the non-tunneled ones; the Android-only
/// [AccessControlProps.mode] is not consulted.
abstract final class DesktopAccessRules {
  static const _direct = 'DIRECT';

  /// The rules to prepend before the profile rules.
  static List<String> build(AccessControlProps props) {
    if (!props.enable) {
      return const [];
    }
    final tunneled = _matchers(props.acceptList);
    if (tunneled.isNotEmpty) {
      return [_notRule(tunneled)];
    }
    final nonTunneled = _matchers(props.rejectList);
    return [for (final matcher in nonTunneled) '$matcher,$_direct'];
  }

  /// `NOT,((...)),DIRECT`: everything that is not a tunneled application
  /// leaves the tunnel; the tunneled ones fall through to the profile rules.
  static String _notRule(List<String> matchers) {
    if (matchers.length == 1) {
      return 'NOT,((${matchers.single})),$_direct';
    }
    final alternatives = matchers.map((matcher) => '($matcher)').join(',');
    return 'NOT,((OR,($alternatives))),$_direct';
  }

  static List<String> _matchers(List<String> entries) {
    final seen = <String>{};
    final matchers = <String>[];
    for (final entry in entries) {
      final matcher = matcherOf(entry);
      if (matcher == null || !seen.add(matcher.toLowerCase())) {
        continue;
      }
      matchers.add(matcher);
    }
    return matchers;
  }

  /// The `TYPE,payload` part of a mihomo rule for one list entry, or null when
  /// the entry is blank.
  static String? matcherOf(String raw) {
    var entry = raw.trim();
    if (entry.length >= 2 && entry.startsWith('"') && entry.endsWith('"')) {
      entry = entry.substring(1, entry.length - 1).trim();
    }
    if (entry.isEmpty) {
      return null;
    }
    // A comma splits a mihomo rule and unbalanced parentheses break the
    // logic-rule parser; `?` matches exactly one character instead.
    entry = entry.replaceAll(',', '?');
    if (!_balanced(entry)) {
      entry = entry.replaceAll('(', '?').replaceAll(')', '?');
    }
    final wildcard = entry.contains('*') || entry.contains('?');
    final isPath = entry.contains('\\') || entry.contains('/');
    if (isPath) {
      final path = entry.replaceAll('/', '\\');
      if (path.endsWith('\\')) {
        return 'PROCESS-PATH-WILDCARD,$path*';
      }
      if (path.toLowerCase().endsWith('.exe')) {
        return wildcard
            ? 'PROCESS-PATH-WILDCARD,$path'
            : 'PROCESS-PATH,$path';
      }
      if (wildcard) {
        return 'PROCESS-PATH-WILDCARD,$path';
      }
      return 'PROCESS-PATH-WILDCARD,$path\\*';
    }
    final name = entry.toLowerCase().endsWith('.exe') ? entry : '$entry.exe';
    return wildcard ? 'PROCESS-NAME-WILDCARD,$name' : 'PROCESS-NAME,$name';
  }

  static bool _balanced(String value) {
    var depth = 0;
    for (final code in value.codeUnits) {
      if (code == 0x28) {
        depth++;
      } else if (code == 0x29) {
        if (depth == 0) return false;
        depth--;
      }
    }
    return depth == 0;
  }
}
