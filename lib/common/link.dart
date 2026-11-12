import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'print.dart';
import 'protocol.dart';
import 'string.dart';

typedef InstallConfigCallBack = void Function(String url);
typedef InstallConfigWithNameCallBack = void Function(
  String url,
  String? name,
);

String? profileUrlFromQrCodes(Iterable<String?> values) {
  for (final value in values) {
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      continue;
    }
    if (text.isUrl || text.isShareLink) {
      return text;
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !protocolSchemes.contains(uri.scheme)) {
      continue;
    }
    final url = _installConfigUrl(uri);
    if (url != null && url.isUrl) {
      return url;
    }
  }
  return null;
}

String? _installConfigUrl(Uri uri) {
  if (uri.host != 'install-config') {
    return null;
  }
  final url = uri.queryParameters['url']?.trim();
  return url == null || url.isEmpty ? null : url;
}

class LinkManager {
  static LinkManager? _instance;
  StreamSubscription? subscription;
  Uri? _pendingUri;

  LinkManager._internal();

  @visibleForTesting
  Stream<Uri> Function() uriLinkStream = () => AppLinks().uriLinkStream;

  /// Linux argv: the gtk plugin hooks GApplication too late to see it.
  void seedInitialLink(List<String> args) {
    for (final arg in args) {
      final uri = Uri.tryParse(arg);
      if (uri != null && protocolSchemes.contains(uri.scheme)) {
        _pendingUri = uri;
        return;
      }
    }
  }

  Future<void> initAppLinksListen(
    Function(String url) installConfigCallBack, {
    InstallConfigWithNameCallBack? onInstallConfig,
  }) async {
    commonPrint.log('initAppLinksListen');
    destroy();
    subscription = uriLinkStream().listen((uri) {
      _handle(uri, installConfigCallBack, onInstallConfig);
    });
    final pending = _pendingUri;
    _pendingUri = null;
    if (pending != null) {
      _handle(pending, installConfigCallBack, onInstallConfig);
    }
  }

  void _handle(
    Uri uri,
    Function(String url) installConfigCallBack,
    InstallConfigWithNameCallBack? onInstallConfig,
  ) {
    final safeLog = uri.host == 'install-config'
        ? '${uri.scheme}://${uri.host}${uri.path}?hasUrl=${uri.queryParameters.containsKey("url")}'
        : '${uri.scheme}://${uri.host}${uri.path}';
    commonPrint.log('onAppLink: $safeLog');
    final url = _installConfigUrl(uri);
    if (url != null) {
      final rawName = uri.queryParameters['name']?.trim();
      final name = (rawName != null && rawName.isNotEmpty) ? rawName : null;
      if (onInstallConfig != null) {
        onInstallConfig(url, name);
      } else {
        installConfigCallBack(url);
      }
    }
  }

  void destroy() {
    if (subscription != null) {
      subscription?.cancel();
      subscription = null;
    }
  }

  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }
}

final linkManager = LinkManager();
