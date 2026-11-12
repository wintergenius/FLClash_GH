import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';

class Request {
  late final Dio dio;
  late final Dio _clashDio;
  String? userAgent;

  ProviderReader? _read;

  void attach(ProviderReader read) {
    _read = read;
  }

  Request() {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          final read = _read;
          if (read == null) {
            return 'DIRECT';
          }
          return FlClashHttpOverrides.findProxyForReader(read, uri);
        };
        return client;
      },
    );
  }

  Future<Map<String, String>?> _subscriptionHeaders(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      return null;
    }
    return hwidManager.getHeaders();
  }

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      final initialUri = Uri.tryParse(url);
      var currentUrl = url;
      var currentUri = initialUri;
      final initialHeaders = await _subscriptionHeaders(url);

      for (var hop = 0; hop <= 3; hop++) {
        final attachSubHeaders = initialHeaders != null &&
            currentUri != null &&
            currentUri.scheme.toLowerCase() == 'https' &&
            initialUri != null &&
            currentUri.authority.toLowerCase() ==
                initialUri.authority.toLowerCase();

        final response = await _clashDio.get<Uint8List>(
          currentUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: attachSubHeaders ? initialHeaders : null,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 400,
          ),
        );

        final statusCode = response.statusCode ?? 0;
        if (statusCode >= 300 && statusCode < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || location.trim().isEmpty || hop == 3) {
            throw DioException.badResponse(
              statusCode: statusCode,
              requestOptions: response.requestOptions,
              response: response,
            );
          }
          final resolvedUri =
              (currentUri ?? Uri.parse(currentUrl)).resolve(location.trim());
          if (initialUri?.scheme.toLowerCase() == 'https' &&
              resolvedUri.scheme.toLowerCase() != 'https') {
            throw DioException(
              requestOptions: response.requestOptions,
              response: response,
              type: DioExceptionType.badResponse,
              error: 'Refusing insecure HTTPS-to-HTTP subscription redirect',
            );
          }
          currentUri = resolvedUri;
          currentUrl = resolvedUri.toString();
          continue;
        }
        return response;
      }
      throw StateError('Redirect loop exceeded');
    } catch (e) {
      commonPrint.log(
        'getFileResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    try {
      return await _clashDio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
        ),
      );
    } catch (e) {
      commonPrint.log(
        'getTextResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final response = await dio.get(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      if (response.statusCode != 200) return null;
      final data = response.data as Map<String, dynamic>;
      final remoteVersion = data['tag_name'];
      final version = globalState.packageInfo.version;
      final hasUpdate =
          compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
      if (!hasUpdate) return null;
      return data;
    } catch (e) {
      commonPrint.log('checkForUpdate failed', logLevel: LogLevel.warning);
      return null;
    }
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    var failureCount = 0;
    final token = cancelToken ?? CancelToken();
    final futures = _ipInfoSources.entries.map((source) async {
      final Completer<Result<IpInfo?>> completer = Completer();
      void handleFailRes() {
        if (!completer.isCompleted && failureCount == _ipInfoSources.length) {
          completer.complete(Result.success(null));
        }
      }

      final future = dio
          .get<Map<String, dynamic>>(
            source.key,
            cancelToken: token,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      unawaited(
        future
            .then((res) {
              if (res.statusCode == HttpStatus.ok && res.data != null) {
                completer.complete(Result.success(source.value(res.data!)));
                return;
              }
              commonPrint.log('checkIp data empty', logLevel: LogLevel.info);
              failureCount++;
              handleFailRes();
            })
            .catchError((e) {
              failureCount++;
              if (e is DioException && e.type == DioExceptionType.cancel) {
                completer.complete(Result.error('cancelled'));
                return;
              }
              commonPrint.log('checkIp error $e', logLevel: LogLevel.warning);
              handleFailRes();
            }),
      );
      return completer.future;
    });
    final res = await Future.any(futures);
    token.cancel();
    return res;
  }
}

final request = Request();

String? getFileNameForDisposition(String? disposition) {
  if (disposition == null) return null;
  final parseValue = HeaderValue.parse(disposition);
  final parameters = parseValue.parameters;
  final fileNamePointKey = parameters.keys.firstWhere(
    (key) => key == 'filename*',
    orElse: () => '',
  );
  if (fileNamePointKey.isNotEmpty) {
    final res = parameters[fileNamePointKey]?.split("''") ?? [];
    if (res.length >= 2) {
      return Uri.decodeComponent(res[1]);
    }
  }
  final fileNameKey = parameters.keys.firstWhere(
    (key) => key == 'filename',
    orElse: () => '',
  );
  if (fileNameKey.isEmpty) return null;
  return parameters[fileNameKey];
}

String? decodeProfileTitle(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.toLowerCase().startsWith('base64:')) {
    final encoded = trimmed.substring(7).trim();
    if (encoded.isEmpty) return null;
    try {
      final decoded = utf8
          .decode(
            base64.decode(base64.normalize(encoded)),
            allowMalformed: true,
          )
          .trim();
      return decoded.isEmpty ? null : decoded;
    } catch (_) {
      return null;
    }
  }
  return trimmed;
}

Duration? parseProfileUpdateInterval(String? raw) {
  if (raw == null) return null;
  final hours = int.tryParse(raw.trim());
  if (hours == null || hours < 1 || hours > 168) {
    return null;
  }
  return Duration(hours: hours);
}
