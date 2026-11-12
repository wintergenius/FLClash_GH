import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:win32_registry/win32_registry.dart';

const _fallbackPrefKey = 'ghosthop_hwid_fallback_v1';
const _brokenAndroidEmulatorId = '9774d56d682e549c';
final _asciiAlphaNumPattern = RegExp(r'[A-Za-z0-9]');

/// Sanitizes arbitrary OS/model strings to printable ASCII `0x20..0x7E` (`<= 64`
/// chars). Falls back to [fallback] when empty or devoid of alphanumeric chars
/// (for example, a Cyrillic-only Windows computer name).
String sanitizeDeviceHeaderValue(
  String? raw, {
  required String fallback,
  int maxLength = 64,
}) {
  if (raw == null || raw.isEmpty) {
    return fallback;
  }
  final buffer = StringBuffer();
  var previousWasSpace = false;
  for (final unit in raw.codeUnits) {
    if (unit <= 0x20 || unit == 0x7F) {
      if (buffer.isNotEmpty && !previousWasSpace) {
        buffer.write(' ');
        previousWasSpace = true;
      }
      continue;
    }
    if (unit >= 0x21 && unit <= 0x7E) {
      buffer.writeCharCode(unit);
      previousWasSpace = false;
    }
  }
  var cleaned = buffer.toString().trim();
  if (cleaned.length > maxLength) {
    cleaned = cleaned.substring(0, maxLength).trimRight();
  }
  if (cleaned.isEmpty || !_asciiAlphaNumPattern.hasMatch(cleaned)) {
    return fallback;
  }
  return cleaned;
}

String computeGhostHopHwid({
  required String platformTag,
  required String rawId,
}) {
  final normalized = rawId.trim().toLowerCase();
  return sha256
      .convert(utf8.encode('ghosthop-hwid-v1:$platformTag:$normalized'))
      .toString();
}

String? readWindowsMachineGuidFromRegistry() {
  if (!Platform.isWindows) {
    return null;
  }
  try {
    final key = LOCAL_MACHINE.open(r'SOFTWARE\Microsoft\Cryptography');
    try {
      final guid = key.getString('MachineGuid')?.trim();
      if (guid != null && guid.isNotEmpty) {
        return guid;
      }
    } finally {
      key.close();
    }
  } catch (error) {
    commonPrint.log(
      'readWindowsMachineGuid error: $error',
      logLevel: LogLevel.warning,
    );
  }
  return null;
}

class HwidManager {
  static HwidManager? _instance;

  HwidManager._internal();

  factory HwidManager() {
    _instance ??= HwidManager._internal();
    return _instance!;
  }

  Map<String, String>? _cachedHeaders;
  Future<Map<String, String>>? _pendingTask;

  @visibleForTesting
  String? Function() windowsMachineGuidReader =
      readWindowsMachineGuidFromRegistry;

  @visibleForTesting
  Future<String?> Function() androidIdReader = () async => app?.getAndroidId();

  @visibleForTesting
  Future<BaseDeviceInfo> Function() deviceInfoReader =
      () => DeviceInfoPlugin().deviceInfo;

  @visibleForTesting
  void resetForTesting() {
    _cachedHeaders = null;
    _pendingTask = null;
    windowsMachineGuidReader = readWindowsMachineGuidFromRegistry;
    androidIdReader = () async => app?.getAndroidId();
    deviceInfoReader = () => DeviceInfoPlugin().deviceInfo;
  }

  Future<Map<String, String>> getHeaders() {
    final cached = _cachedHeaders;
    if (cached != null) {
      return Future.value(cached);
    }
    return _pendingTask ??= _resolveHeaders().whenComplete(() {
      _pendingTask = null;
    });
  }

  Future<Map<String, String>> _resolveHeaders() async {
    final hwidResult = await _resolveHwid();
    final meta = await _resolveDeviceMeta();
    final headers = <String, String>{
      'x-hwid': hwidResult.hwid,
      'x-device-os': meta.os,
      'x-ver-os': meta.verOs,
      'x-device-model': meta.model,
    };
    if (hwidResult.cacheable) {
      _cachedHeaders = Map.unmodifiable(headers);
    }
    return headers;
  }

  Future<({String hwid, bool cacheable})> _resolveHwid() async {
    if (Platform.isWindows) {
      final guid = windowsMachineGuidReader()?.trim();
      if (guid != null && guid.isNotEmpty) {
        return (
          hwid: computeGhostHopHwid(platformTag: 'win', rawId: guid),
          cacheable: true,
        );
      }
    } else if (Platform.isAndroid) {
      final androidId = (await androidIdReader())?.trim().toLowerCase();
      if (androidId != null &&
          androidId.isNotEmpty &&
          androidId != _brokenAndroidEmulatorId) {
        return (
          hwid: computeGhostHopHwid(platformTag: 'and', rawId: androidId),
          cacheable: true,
        );
      }
    } else if (Platform.isLinux) {
      for (final path in const [
        '/etc/machine-id',
        '/var/lib/dbus/machine-id',
      ]) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            final machineId = file.readAsStringSync().trim();
            if (machineId.isNotEmpty) {
              return (
                hwid: computeGhostHopHwid(platformTag: 'lin', rawId: machineId),
                cacheable: true,
              );
            }
          }
        } catch (_) {}
      }
    }

    final fallbackId = await _getOrCreateFallbackSeed();
    return (
      hwid: computeGhostHopHwid(
        platformTag: 'fallback',
        rawId: fallbackId.seed,
      ),
      cacheable: fallbackId.persisted,
    );
  }

  Future<({String seed, bool persisted})> _getOrCreateFallbackSeed() async {
    try {
      final prefs = await preferences.sharedPreferencesCompleter.future
          .timeout(const Duration(seconds: 1), onTimeout: () => null);
      if (prefs != null) {
        final existing = prefs.getString(_fallbackPrefKey)?.trim();
        if (existing != null && existing.isNotEmpty) {
          return (seed: existing, persisted: true);
        }
        final generated = _generateRandomHex(16);
        final saved = await prefs.setString(_fallbackPrefKey, generated);
        return (seed: generated, persisted: saved);
      }
    } catch (_) {}
    return (seed: _generateRandomHex(16), persisted: false);
  }

  String _generateRandomHex(int byteLength) {
    final rng = Random.secure();
    return List.generate(
      byteLength,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<({String os, String verOs, String model})> _resolveDeviceMeta() async {
    final fallbackOs = switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'android' => 'Android',
      'macos' => 'macOS',
      'linux' => 'Linux',
      final other => sanitizeDeviceHeaderValue(other, fallback: 'Desktop'),
    };
    final fallbackModel = switch (Platform.operatingSystem) {
      'windows' => 'Windows PC',
      'android' => 'Android Device',
      'macos' => 'Mac',
      'linux' => 'Linux PC',
      _ => 'Device',
    };
    try {
      final info = await deviceInfoReader();
      if (info is WindowsDeviceInfo) {
        final ver =
            '${info.majorVersion}.${info.minorVersion}.${info.buildNumber}';
        return (
          os: 'Windows',
          verOs: sanitizeDeviceHeaderValue(ver, fallback: '10.0'),
          model: sanitizeDeviceHeaderValue(
            info.computerName,
            fallback: 'Windows PC',
          ),
        );
      }
      if (info is AndroidDeviceInfo) {
        final brand = info.manufacturer.trim();
        final modelRaw = info.model.trim();
        final combinedModel =
            modelRaw.toLowerCase().startsWith(brand.toLowerCase())
            ? modelRaw
            : '$brand $modelRaw'.trim();
        return (
          os: 'Android',
          verOs: sanitizeDeviceHeaderValue(
            info.version.release,
            fallback: '${info.version.sdkInt}',
          ),
          model: sanitizeDeviceHeaderValue(
            combinedModel,
            fallback: 'Android Device',
          ),
        );
      }
      if (info is MacOsDeviceInfo) {
        final ver =
            '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}';
        return (
          os: 'macOS',
          verOs: sanitizeDeviceHeaderValue(ver, fallback: '14.0'),
          model: sanitizeDeviceHeaderValue(info.model, fallback: 'Mac'),
        );
      }
      if (info is LinuxDeviceInfo) {
        return (
          os: 'Linux',
          verOs: sanitizeDeviceHeaderValue(info.versionId, fallback: 'Linux'),
          model: sanitizeDeviceHeaderValue(info.prettyName, fallback: 'Linux PC'),
        );
      }
    } catch (_) {}

    return (
      os: fallbackOs,
      verOs: sanitizeDeviceHeaderValue(
        Platform.operatingSystemVersion,
        fallback: '1.0',
      ),
      model: fallbackModel,
    );
  }
}

final hwidManager = HwidManager();
