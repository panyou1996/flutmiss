import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';

import '../../../../constants.dart';
import '../android_cdp_service.dart';
import '../cookie_jar_service.dart';
import '../cookie_sync_context.dart';
import 'default_cookie_strategy.dart';

/// Android 平台 Cookie 策略
/// domain 保持原值，host-only cookie 保持 null
class AndroidCookieStrategy extends DefaultCookieStrategy {
  Future<bool>? _pendingTargetReady;
  bool? _targetReady;

  @override
  Future<List<CollectedWebViewCookie>> readCookiesFromWebView(
    CookieSyncContext ctx,
  ) async {
    if (ctx.controller == null) {
      return super.readCookiesFromWebView(ctx);
    }

    final liveCookies = await _readLiveCookiesFromController(
      ctx.controller!,
      currentUrl: ctx.currentUrl,
    );
    if (liveCookies.isEmpty) {
      return super.readCookiesFromWebView(ctx);
    }

    final collected = <String, CollectedWebViewCookie>{};
    for (final snapshot in liveCookies) {
      if (!CookieJarService.matchesAppHost(snapshot.domain)) continue;

      final normalizedDomain =
          CookieJarService.normalizeWebViewCookieDomain(snapshot.domain) ??
          ctx.baseUri.host;
      final key = '${snapshot.name}|$normalizedDomain|${snapshot.path}';
      final webViewCookie = Cookie(
        name: snapshot.name,
        value: snapshot.value,
        domain: snapshot.domain,
        path: snapshot.path,
        isSecure: snapshot.secure,
        isHttpOnly: snapshot.httpOnly,
      );
      if (snapshot.expires != null) {
        webViewCookie.expiresDate = snapshot.expires!.millisecondsSinceEpoch;
      }

      final collectedSnapshot = collected.putIfAbsent(
        key,
        () => CollectedWebViewCookie(
          cookie: webViewCookie,
          primaryHost: normalizedDomain,
        ),
      );
      collectedSnapshot.sourceHosts.add(normalizedDomain);
    }

    return collected.values.toList(growable: false);
  }

  @override
  Future<void> clearWebViewCookies(CookieSyncContext ctx) async {
    // Bug #3 fix：deleteAllCookies 可能 ANR，加 timeout 保护
    try {
      await ctx.webViewCookieManager
          .deleteAllCookies()
          .timeout(const Duration(seconds: 5));
    } on TimeoutException catch (_) {
      debugPrint(
        '[CookieJar][Android] deleteAllCookies timed out after 5s, '
        'falling back to per-host deletion',
      );
      // 兜底：逐 host 删除
      await super.clearWebViewCookies(ctx);
      return;
    } catch (e) {
      debugPrint('[CookieJar][Android] deleteAllCookies failed: $e');
      await super.clearWebViewCookies(ctx);
      return;
    }

    // 补充逐个精确删除残留的 domain cookie
    for (final host in ctx.relatedHosts) {
      final url = 'https://$host';
      final existing = await ctx.webViewCookieManager.getCookies(
        url: WebUri(url),
      );
      for (final wc in existing) {
        await ctx.webViewCookieManager.deleteCookie(
          url: WebUri(url),
          name: wc.name,
          domain: wc.domain,
          path: wc.path ?? '/',
        );
      }
    }
  }

  @override
  Future<String?> readLiveCookieValue(
    InAppWebViewController controller,
    String name, {
    String? currentUrl,
  }) async {
    try {
      final liveCookies = await _readLiveCookies(
        controller,
        currentUrl: currentUrl,
      );
      String? fallback;
      for (final cookie in liveCookies) {
        if (cookie.name != name || cookie.value.isEmpty) continue;
        if (CookieJarService.matchesAppHost(cookie.domain)) {
          return cookie.value;
        }
        fallback ??= cookie.value;
      }
      return fallback;
    } catch (e) {
      debugPrint('[CookieJar][Android] Failed to read live cookie $name: $e');
      return null;
    }
  }

  @override
  Future<void> syncCriticalFromController(
    InAppWebViewController controller,
    Set<String> names,
    CookieSyncContext ctx,
    CookieJarService jar,
  ) async {
    try {
      final liveCookies = await _readLiveCookies(
        controller,
        currentUrl: ctx.currentUrl,
      );
      var synced = 0;
      final seen = <String>{};
      for (final cookie in liveCookies) {
        if (!names.contains(cookie.name) || cookie.value.isEmpty) continue;
        if (!CookieJarService.matchesAppHost(cookie.domain)) continue;

        final key = '${cookie.name}|${cookie.persistedDomain}|${cookie.path}';
        if (!seen.add(key)) continue;

        await jar.setCookie(
          cookie.name,
          cookie.value,
          url: ctx.currentUrl,
          domain: cookie.persistedDomain,
          path: cookie.path,
          expires: cookie.expires,
          secure: cookie.secure,
          httpOnly: cookie.httpOnly,
        );
        synced++;
      }

      if (synced > 0) {
        debugPrint(
          '[CookieJar][Android] Synced $synced live cookies from CDP: '
          '${names.join(', ')}',
        );
      }
    } catch (e) {
      debugPrint('[CookieJar][Android] Failed to sync live cookies: $e');
    }
  }

  @override
  Future<int> writeCookiesToWebView(
    List<(io.Cookie, String)> cookies,
    CookieSyncContext ctx,
  ) async {
    if (cookies.isEmpty) return 0;
    final cdpReady = await _ensureTargetReady();

    final rawHeaders = <String, String?>{};
    for (final (cookie, _) in cookies) {
      if (!rawHeaders.containsKey(cookie.name)) {
        rawHeaders[cookie.name] = await loadSetCookieHeader(cookie.name);
      }
    }

    var written = 0;
    for (final (cookie, sourceHost) in cookies) {
      final attempts = buildWriteAttempts(cookie, sourceHost);
      var success = false;
      if (cdpReady) {
        for (final attempt in attempts) {
          final deleteResult = await _deleteCookieViaCdp(cookie, attempt);
          if (!deleteResult) {
            debugPrint('[CookieJar][Android] CDP delete fallback for ${cookie.name}');
          }

          final setResult = await _setCookieViaCdp(cookie, attempt, rawHeaders[cookie.name]);
          if (setResult) {
            success = true;
            break;
          }
        }
      }

      if (!success) {
        debugPrint('[CookieJar][Android] CDP write failed for ${cookie.name}, fallback to CookieManager');
        final fallbackWritten = await super.writeCookiesToWebView([(cookie, sourceHost)], ctx);
        if (fallbackWritten > 0) {
          written += fallbackWritten;
          continue;
        }
      }

      if (success) {
        written++;
      }
    }

    return written;
  }

  Future<bool> _ensureTargetReady() async {
    if (_targetReady == true) return true;

    final pending = _pendingTargetReady;
    if (pending != null) {
      return pending;
    }

    final future = AndroidCdpService.instance.awaitTargetReady(
      timeout: const Duration(seconds: 4),
    );
    _pendingTargetReady = future;
    try {
      final ready = await future;
      _targetReady = ready;
      if (!ready) {
        debugPrint('[CookieJar][Android] Native CDP target not ready before writeCookiesToWebView');
      }
      return ready;
    } finally {
      if (identical(_pendingTargetReady, future)) {
        _pendingTargetReady = null;
      }
    }
  }

  Future<List<_AndroidDevToolsCookieSnapshot>> _readLiveCookies(
    InAppWebViewController controller, {
    String? currentUrl,
  }) async {
    final cdpCookies = await _readLiveCookiesFromController(
      controller,
      currentUrl: currentUrl,
    );
    if (cdpCookies.isNotEmpty) {
      return cdpCookies;
    }

    debugPrint(
      '[CookieJar][Android] CDP returned no cookies, falling back to CookieManager.getCookies',
    );
    return _readLiveCookiesViaCookieManager(currentUrl: currentUrl);
  }

  Future<bool> _setCookieViaCdp(
    io.Cookie cookie,
    WebViewCookieWriteAttempt attempt,
    String? rawHeader,
  ) async {
    final value = CookieValueCodec.decode(cookie.value);
    final params = <String, dynamic>{
      'url': attempt.url,
      'name': cookie.name,
      'value': value.isEmpty ? ' ' : value,
      'path': cookie.path ?? '/',
      'secure': cookie.secure,
      'httpOnly': cookie.httpOnly,
    };

    if (attempt.domain != null && attempt.domain!.isNotEmpty) {
      params['domain'] = attempt.domain;
    }
    if (cookie.expires != null) {
      params['expires'] = cookie.expires!.millisecondsSinceEpoch / 1000.0;
    }

    final sameSite = await _loadCanonicalSameSite(cookie.name);
    if (sameSite != null) {
      params['sameSite'] = sameSite;
    } else if (cookie.httpOnly && cookie.secure) {
      params['sameSite'] = 'None';
    }

    final result = await AndroidCdpService.instance.setCookie(params);
    if (result?['ok'] == true) {
      return true;
    }

    if (rawHeader != null) {
      debugPrint('[CookieJar][Android] CDP setCookie failed for ${cookie.name}, rawHeader preserved for fallback');
    }
    return false;
  }

  Future<bool> _deleteCookieViaCdp(
    io.Cookie cookie,
    WebViewCookieWriteAttempt attempt,
  ) async {
    final params = <String, dynamic>{
      'name': cookie.name,
      'url': attempt.url,
      'path': cookie.path ?? '/',
    };
    if (attempt.domain != null && attempt.domain!.isNotEmpty) {
      params['domain'] = attempt.domain;
    }
    final result = await AndroidCdpService.instance.deleteCookies(params);
    return result?['ok'] == true;
  }

  Future<String?> _loadCanonicalSameSite(String name) async {
    try {
      final canonical = await CookieJarService().getCanonicalCookie(name);
      switch (canonical?.sameSite) {
        case CookieSameSite.lax:
          return 'Lax';
        case CookieSameSite.strict:
          return 'Strict';
        case CookieSameSite.none:
          return 'None';
        case CookieSameSite.unspecified:
        case null:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  Future<List<_AndroidDevToolsCookieSnapshot>> _readLiveCookiesFromController(
    InAppWebViewController controller, {
    String? currentUrl,
  }) async {
    final resolvedCurrentUrl =
        currentUrl ?? (await controller.getUrl())?.toString();

    final urls = <String>{
      AppConstants.baseUrl,
      '${AppConstants.baseUrl}/',
      if (resolvedCurrentUrl != null && resolvedCurrentUrl.isNotEmpty)
        resolvedCurrentUrl,
    }.toList();

    final result = await AndroidCdpService.instance
        .getCookies(urls)
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            debugPrint('[CookieJar][Android] Native CDP getCookies timed out');
            return null;
          },
        );
    if (result?['ok'] == false) {
      debugPrint(
        '[CookieJar][Android] Native CDP getCookies returned ok=false: '
        '${result?['error']}',
      );
    }
    final rawCookies = result?['cookies'];
    if (rawCookies is! List) return const [];

    final cookies = rawCookies
        .whereType<Map>()
        .map(
          (raw) => _AndroidDevToolsCookieSnapshot.fromMap(
            raw.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .whereType<_AndroidDevToolsCookieSnapshot>()
        .toList(growable: false);

    if (cookies.isNotEmpty) {
      final names = cookies.map((e) => e.name).toSet().join(', ');
      debugPrint('[CookieJar][Android] DevTools cookies: [$names]');
    }

    return cookies;
  }

  Future<List<_AndroidDevToolsCookieSnapshot>>
  _readLiveCookiesViaCookieManager({
    String? currentUrl,
  }) async {
    final candidates = <String>{
      AppConstants.baseUrl,
      '${AppConstants.baseUrl}/',
      if (currentUrl != null && currentUrl.isNotEmpty) currentUrl,
    };

    final collected = <String, _AndroidDevToolsCookieSnapshot>{};
    for (final url in candidates) {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      for (final cookie in cookies) {
        final normalizedDomain =
            CookieJarService.normalizeWebViewCookieDomain(cookie.domain);
        final host = normalizedDomain ?? Uri.parse(url).host;
        final key =
            '${cookie.name}|${normalizedDomain ?? '<host-only>'}|${cookie.path ?? '/'}';
        collected.putIfAbsent(
          key,
          () => _AndroidDevToolsCookieSnapshot(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path ?? '/',
            expires: CookieJarService.parseWebViewCookieExpires(
              cookie.expiresDate,
            ),
            secure: cookie.isSecure ?? false,
            httpOnly: cookie.isHttpOnly ?? false,
            hostOnly: normalizedDomain == null || normalizedDomain != host,
          ),
        );
      }
    }

    final fallbackCookies = collected.values.toList(growable: false);
    if (fallbackCookies.isNotEmpty) {
      final names = fallbackCookies.map((e) => e.name).toSet().join(', ');
      debugPrint('[CookieJar][Android] CookieManager fallback cookies: [$names]');
    }
    return fallbackCookies;
  }

  @override
  List<WebViewCookieWriteAttempt> buildWriteAttempts(
    io.Cookie cookie,
    String sourceHost,
  ) {
    // Android 平台：保持 cookie.domain 原值（与 0.1.28 一致），
    // host-only cookie 保持 null
    final normalizedCookieDomain =
        CookieJarService.normalizeWebViewCookieDomain(cookie.domain);
    return [
      WebViewCookieWriteAttempt(
        url: 'https://${normalizedCookieDomain ?? sourceHost}',
        domain: cookie.domain?.trim(),
      ),
    ];
  }
}

class _AndroidDevToolsCookieSnapshot {
  const _AndroidDevToolsCookieSnapshot({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.secure,
    required this.httpOnly,
    required this.hostOnly,
  });

  final String name;
  final String value;
  final String? domain;
  final String path;
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;
  final bool hostOnly;

  String? get persistedDomain {
    final normalized = CookieJarService.normalizeWebViewCookieDomain(domain);
    if (hostOnly || normalized == null || normalized.isEmpty) {
      return null;
    }
    return domain != null && domain!.startsWith('.')
        ? domain
        : '.$normalized';
  }

  static _AndroidDevToolsCookieSnapshot? fromMap(Map<String, dynamic> raw) {
    final name = raw['name']?.toString();
    if (name == null || name.isEmpty) return null;

    final value = raw['value']?.toString() ?? '';
    final domain = raw['domain']?.toString();
    final path = raw['path']?.toString() ?? '/';
    final expiresRaw = raw['expires'];

    DateTime? expires;
    if (expiresRaw is num && expiresRaw > 0 && expiresRaw < 1e12) {
      expires = DateTime.fromMillisecondsSinceEpoch(
        (expiresRaw * 1000).round(),
        isUtc: true,
      );
    }

    return _AndroidDevToolsCookieSnapshot(
      name: name,
      value: value,
      domain: domain,
      path: path,
      expires: expires,
      secure: raw['secure'] == true,
      httpOnly: raw['httpOnly'] == true,
      hostOnly: raw['hostOnly'] == true,
    );
  }
}
