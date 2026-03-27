import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class AndroidCdpService {
  static const Duration _getCookiesCacheTtl = Duration(milliseconds: 350);

  AndroidCdpService._();

  static final AndroidCdpService instance = AndroidCdpService._();

  static const MethodChannel _channel = MethodChannel('com.fluxdo/android_cdp');
  Future<Map<String, dynamic>?>? _pendingGetCookies;
  String? _pendingGetCookiesKey;
  Map<String, dynamic>? _lastGetCookiesResult;
  String? _lastGetCookiesKey;
  DateTime? _lastGetCookiesAt;

  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    final result = await _channel.invokeMethod<bool>('isAvailable');
    return result ?? false;
  }

  Future<bool> awaitTargetReady({Duration timeout = const Duration(milliseconds: 2500)}) async {
    if (!Platform.isAndroid) return false;
    final result = await _channel.invokeMethod<bool>('awaitTargetReady', {
      'timeoutMs': timeout.inMilliseconds,
    });
    return result ?? false;
  }

  Future<Map<String, dynamic>?> getCookies(List<String> urls) async {
    if (!Platform.isAndroid || urls.isEmpty) return null;
    final normalizedUrls = urls.toSet().toList(growable: false)..sort();
    final key = normalizedUrls.join('\n');
    final now = DateTime.now();
    final lastAt = _lastGetCookiesAt;
    if (_lastGetCookiesKey == key &&
        _lastGetCookiesResult != null &&
        lastAt != null &&
        now.difference(lastAt) <= _getCookiesCacheTtl) {
      return Map<String, dynamic>.from(_lastGetCookiesResult!);
    }

    final pending = _pendingGetCookies;
    if (pending != null && _pendingGetCookiesKey == key) {
      return pending;
    }

    final future = _invokeGetCookies(normalizedUrls);
    _pendingGetCookiesKey = key;
    _pendingGetCookies = future;
    try {
      final result = await future;
      _lastGetCookiesKey = key;
      _lastGetCookiesResult =
          result == null ? null : Map<String, dynamic>.from(result);
      _lastGetCookiesAt = DateTime.now();
      return result;
    } finally {
      if (identical(_pendingGetCookies, future)) {
        _pendingGetCookies = null;
        _pendingGetCookiesKey = null;
      }
    }
  }

  Future<Map<String, dynamic>?> _invokeGetCookies(List<String> urls) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getCookies',
      {'urls': urls},
    );
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<Map<String, dynamic>?> setCookie(Map<String, dynamic> params) async {
    if (!Platform.isAndroid || params.isEmpty) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'setCookie',
      params,
    );
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<Map<String, dynamic>?> deleteCookies(Map<String, dynamic> params) async {
    if (!Platform.isAndroid || params.isEmpty) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'deleteCookies',
      params,
    );
    return result == null ? null : Map<String, dynamic>.from(result);
  }
}
