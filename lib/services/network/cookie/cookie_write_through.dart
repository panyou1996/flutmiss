import 'dart:async';
import 'dart:io' as io;

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../constants.dart';
import '../../windows_webview_environment_service.dart';
import 'android_cdp_service.dart';
import 'cookie_jar_service.dart';
import 'raw_cookie_writer.dart';
import 'strategy/platform_cookie_strategy.dart';

/// Cookie Write-Through 服务
/// Dio 收到 Set-Cookie 后，实时推送关键 cookie 到 WebView，
/// 避免 CookieJar 和 WebView 之间的不一致。
class CookieWriteThrough {
  static final instance = CookieWriteThrough._();
  CookieWriteThrough._();

  static const Duration _androidTargetReadyTimeout = Duration(seconds: 4);
  bool? _androidTargetReady;
  Future<bool>? _pendingAndroidTargetReady;

  /// 删除 WebView 中指定 cookie 的所有 domain 变体（去重后执行）
  Future<void> _deleteFromWebView(
    CookieManager webViewCookieManager,
    String host,
    String name,
    String path,
  ) async {
    // 合并所有 domain 变体到 Set 去重，避免重复调用 deleteCookie
    final variants = <String?>{
      ..._strategy.buildDeleteDomainVariants('.$host'),
      ..._strategy.buildDeleteDomainVariants(host),
      null, // host-only 变体（无 domain）
    };
    final url = WebUri('https://$host');
    for (final domain in variants) {
      try {
        if (domain != null) {
          await webViewCookieManager.deleteCookie(url: url, name: name, domain: domain, path: path);
        } else {
          await webViewCookieManager.deleteCookie(url: url, name: name, path: path);
        }
      } catch (_) {}
    }
  }

  int _pendingWriteCount = 0;
  Completer<void>? _pendingWrite;
  late final PlatformCookieStrategy _strategy = PlatformCookieStrategy.create();

  Future<bool> _ensureAndroidTargetReady() async {
    if (!io.Platform.isAndroid) return false;
    if (_androidTargetReady == true) return true;

    final pending = _pendingAndroidTargetReady;
    if (pending != null) {
      return pending;
    }

    final future = AndroidCdpService.instance.awaitTargetReady(
      timeout: _androidTargetReadyTimeout,
    );
    _pendingAndroidTargetReady = future;
    try {
      final ready = await future;
      _androidTargetReady = ready;
      if (!ready) {
        debugPrint('[CookieWriteThrough] Android CDP target not ready within ${_androidTargetReadyTimeout.inMilliseconds}ms');
      }
      return ready;
    } finally {
      if (identical(_pendingAndroidTargetReady, future)) {
        _pendingAndroidTargetReady = null;
      }
    }
  }

  Future<bool> _deleteFromAndroidCdp(
    String host,
    String name,
    String path,
  ) async {
    final variants = <String?>{
      ..._strategy.buildDeleteDomainVariants('.$host'),
      ..._strategy.buildDeleteDomainVariants(host),
      null,
    };

    var deleted = false;
    for (final domain in variants) {
      final result = await AndroidCdpService.instance.deleteCookies({
        'name': name,
        'url': 'https://$host',
        'path': path,
        if (domain != null && domain.isNotEmpty) 'domain': domain,
      });
      if (result?['ok'] == true) {
        deleted = true;
      }
    }
    return deleted;
  }

  Future<bool> _setFromAndroidCdp(
    io.Cookie cookie,
    String host, {
    CanonicalCookie? canonical,
    String? rawHeader,
  }) async {
    final normalizedDomain =
        CookieJarService.normalizeWebViewCookieDomain(canonical?.domain ?? cookie.domain);
    final value = canonical?.value ?? CookieValueCodec.decode(cookie.value);
    final params = <String, dynamic>{
      'url': 'https://${normalizedDomain ?? host}',
      'name': cookie.name,
      'value': value.isEmpty ? ' ' : value,
      'path': cookie.path ?? '/',
      'secure': cookie.secure,
      'httpOnly': cookie.httpOnly,
    };

    final domain = canonical?.domain ?? cookie.domain;
    if (domain != null && domain.trim().isNotEmpty) {
      params['domain'] = domain.trim();
    }
    if (cookie.expires != null) {
      params['expires'] = cookie.expires!.millisecondsSinceEpoch / 1000.0;
    }

    final sameSite = _canonicalSameSite(canonical);
    if (sameSite != null) {
      params['sameSite'] = sameSite;
    } else if (cookie.httpOnly && cookie.secure) {
      params['sameSite'] = 'None';
    }
    if (canonical?.priority case final priority?) {
      params['priority'] = priority;
    }
    if (canonical?.sourceScheme case final sourceScheme?) {
      params['sourceScheme'] = sourceScheme;
    }
    if (canonical?.sourcePort case final sourcePort?) {
      params['sourcePort'] = sourcePort;
    }
    if (canonical?.partitionKey case final partitionKey?) {
      params['partitionKey'] = partitionKey;
    }

    final result = await AndroidCdpService.instance.setCookie(params);
    if (result?['ok'] == true) {
      return true;
    }

    if (rawHeader != null) {
      debugPrint('[CookieWriteThrough] Android CDP setCookie failed for ${cookie.name}, fallback to raw header');
    }
    return false;
  }

  /// Dio 收到 Set-Cookie 后调用（在 AppCookieManager.saveCookies 内）
  /// 只处理关键 cookie，非关键 cookie 不推送
  /// [rawSetCookieHeaders] — cookie name → 原始 Set-Cookie 头，优先用 raw 写入
  Future<void> writeThrough(
    List<io.Cookie> cookies,
    Uri uri, {
    Map<String, String>? rawSetCookieHeaders,
  }) async {
    final criticals =
        cookies.where((c) => CookieJarService.isCriticalCookie(c.name)).toList();
    if (criticals.isEmpty) return;

    _pendingWriteCount++;
    _pendingWrite ??= Completer<void>();
    try {
      final rawWriter = RawCookieWriter.instance;
      final webViewCookieManager =
          WindowsWebViewEnvironmentService.instance.cookieManager;
      final baseHost = Uri.parse(AppConstants.baseUrl).host;
      final androidTargetReady = await _ensureAndroidTargetReady();

      for (final cookie in criticals) {
        final normalizedDomain =
            CookieJarService.normalizeWebViewCookieDomain(cookie.domain);
        final host = normalizedDomain ?? baseHost;
        final cookieUrl = 'https://$host';
        final webUri = WebUri(cookieUrl);

        CanonicalCookie? canonical;
        try {
          canonical = await CookieJarService().getCanonicalCookie(cookie.name);
        } catch (_) {}

        if (io.Platform.isAndroid && androidTargetReady) {
          await _deleteFromAndroidCdp(host, cookie.name, cookie.path ?? '/');
        }

        await _deleteFromWebView(webViewCookieManager, host, cookie.name, cookie.path ?? '/');

        // 优先用 Set-Cookie 头写入（保留 host-only 等完整语义）
        var rawHeader = rawSetCookieHeaders?[cookie.name];
        // 没有原始头时从 jar 中的 canonical cookie 重建
        if (rawHeader == null) {
          try {
            final jar = CookieJarService();
            canonical ??= await jar.getCanonicalCookie(cookie.name);
            rawHeader = canonical?.toSetCookieHeader();
          } catch (_) {}
        }
        if (io.Platform.isAndroid && androidTargetReady) {
          try {
            if (await _setFromAndroidCdp(
              cookie,
              host,
              canonical: canonical,
              rawHeader: rawHeader,
            )) {
              continue;
            }
          } catch (e) {
            debugPrint('[CookieWriteThrough] Android CDP 写入 ${cookie.name} 失败，fallback: $e');
          }
        }
        if (rawHeader != null && rawWriter.isSupported) {
          try {
            await rawWriter.setRawCookie(cookieUrl, rawHeader);
            continue;
          } catch (e) {
            debugPrint('[CookieWriteThrough] raw 写入 ${cookie.name} 失败，fallback: $e');
          }
        }

        // Fallback：结构化 API
        final value = CookieValueCodec.decode(cookie.value);
        try {
          await webViewCookieManager.setCookie(
            url: webUri,
            name: cookie.name,
            value: value.isEmpty ? ' ' : value,
            domain: cookie.domain,
            path: cookie.path ?? '/',
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
            expiresDate: cookie.expires?.millisecondsSinceEpoch,
            sameSite: (cookie.httpOnly && cookie.secure)
                ? HTTPCookieSameSitePolicy.NONE
                : null,
          );
        } catch (e) {
          debugPrint('[CookieWriteThrough] 写入 ${cookie.name} 失败: $e');
        }
      }

      debugPrint(
        '[CookieWriteThrough] 已推送 ${criticals.length} 个关键 cookie 到 WebView',
      );
    } catch (e) {
      debugPrint('[CookieWriteThrough] writeThrough 失败: $e');
    } finally {
      _pendingWriteCount--;
      if (_pendingWriteCount <= 0) {
        _pendingWriteCount = 0;
        _pendingWrite?.complete();
        _pendingWrite = null;
      }
    }
  }

  /// WebView 加载前等待在飞写入完成
  Future<void> barrier({Duration timeout = const Duration(seconds: 3)}) async {
    final pending = _pendingWrite;
    if (pending == null) return;
    await pending.future.timeout(timeout, onTimeout: () {});
  }

  /// 冷启动时从 CookieJar 注入关键 cookie 到 WebView
  Future<void> seedCriticalCookies({
    InAppWebViewController? controller,
  }) async {
    final jar = CookieJarService();
    if (!jar.isInitialized) await jar.initialize();

    final webViewCookieManager =
        WindowsWebViewEnvironmentService.instance.cookieManager;
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    final androidTargetReady = await _ensureAndroidTargetReady();

    for (final name in const ['_t', '_forum_session', 'cf_clearance']) {
      final canonical = await jar.getCanonicalCookie(name);
      final cookie = canonical?.toIoCookie() ?? await _loadCriticalCookie(jar, name);
      if (cookie == null) continue;

      final value = canonical?.value ?? CookieValueCodec.decode(cookie.value);
      if (value.isEmpty) continue;

      final normalizedDomain =
          CookieJarService.normalizeWebViewCookieDomain(canonical?.domain ?? cookie.domain);
      final host = normalizedDomain ?? baseHost;

      // Windows 通过 CDP 写入
      if (io.Platform.isWindows && controller != null) {
        await _seedViaCDP(
          controller,
          cookie,
          value,
          host,
          _strategy,
          canonical: canonical,
        );
        continue;
      }

      // 其他平台：先删旧值，再写入
      final cookieUrl = 'https://$host';
      final webUri = WebUri(cookieUrl);

      if (io.Platform.isAndroid && androidTargetReady) {
        await _deleteFromAndroidCdp(host, name, cookie.path ?? '/');
      }

      await _deleteFromWebView(webViewCookieManager, host, name, cookie.path ?? '/');

      if (io.Platform.isAndroid && androidTargetReady) {
        try {
          if (await _setFromAndroidCdp(
            cookie,
            host,
            canonical: canonical,
            rawHeader: canonical?.toSetCookieHeader(),
          )) {
            continue;
          }
        } catch (e) {
          debugPrint('[CookieWriteThrough] Android CDP seed $name 失败，fallback: $e');
        }
      }

      // 优先用 raw Set-Cookie 头写入（保留 host-only 语义）
      final rawWriter = RawCookieWriter.instance;
      final rawHeader = canonical?.toSetCookieHeader();
      if (rawHeader != null && rawWriter.isSupported) {
        try {
          if (await rawWriter.setRawCookie(cookieUrl, rawHeader)) continue;
        } catch (_) {}
      }

      // Fallback：结构化 API
      try {
        await webViewCookieManager.setCookie(
          url: webUri,
          name: name,
          value: value,
          domain: cookie.domain,
          path: cookie.path ?? '/',
          isSecure: cookie.secure,
          isHttpOnly: cookie.httpOnly,
          expiresDate: cookie.expires?.millisecondsSinceEpoch,
          sameSite: (cookie.httpOnly && cookie.secure)
              ? HTTPCookieSameSitePolicy.NONE
              : null,
        );
      } catch (e) {
        debugPrint('[CookieWriteThrough] seed $name 失败: $e');
      }
    }

    debugPrint('[CookieWriteThrough] seedCriticalCookies 完成');
  }

  /// 从 CookieJar 加载关键 cookie 的原始对象
  Future<io.Cookie?> _loadCriticalCookie(
    CookieJarService jar,
    String name,
  ) async {
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await jar.cookieJar.loadForRequest(uri);

      io.Cookie? fallback;
      for (final cookie in cookies) {
        if (cookie.name == name && cookie.value.isNotEmpty) {
          // 优先返回 host-only cookie（服务端直接下发，最新值）
          if (cookie.domain == null) return cookie;
          fallback ??= cookie;
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('[CookieWriteThrough] 加载 $name 失败: $e');
      return null;
    }
  }

  /// Windows CDP 写入单个 cookie
  Future<void> _seedViaCDP(
    InAppWebViewController controller,
    io.Cookie cookie,
    String value,
    String host,
    PlatformCookieStrategy strategy, {
    CanonicalCookie? canonical,
  }
  ) async {
    final normalizedDomain =
        CookieJarService.normalizeWebViewCookieDomain(canonical?.domain ?? cookie.domain);

    String cdpUrl;
    String? cdpDomain;
    if (normalizedDomain != null) {
      cdpUrl = 'https://$normalizedDomain';
      cdpDomain = cookie.domain!.startsWith('.')
          ? cookie.domain
          : '.$normalizedDomain';
    } else {
      cdpUrl = 'https://$host';
      cdpDomain = null;
    }

    try {
      // 确保 Network domain 已启用
      try {
        await controller.callDevToolsProtocolMethod(
          methodName: 'Network.enable',
          parameters: {},
        );
      } catch (_) {}

      // 删除旧 cookie
      final deleteParams = <String, dynamic>{
        'name': cookie.name,
        'url': cdpUrl,
        'path': cookie.path ?? '/',
      };
      if (cdpDomain != null) {
        deleteParams['domain'] = cdpDomain;
      }
      await controller.callDevToolsProtocolMethod(
        methodName: 'Network.deleteCookies',
        parameters: deleteParams,
      );

      // 写入新 cookie
      final params = <String, dynamic>{
        'url': cdpUrl,
        'name': cookie.name,
        'value': value.isEmpty ? ' ' : value,
        'path': cookie.path ?? '/',
        'secure': cookie.secure,
        'httpOnly': cookie.httpOnly,
      };
      if (cdpDomain != null) {
        params['domain'] = cdpDomain;
      }
      if (cookie.expires != null) {
        params['expires'] = cookie.expires!.millisecondsSinceEpoch / 1000.0;
      }
      final sameSite = _canonicalSameSite(canonical);
      if (sameSite != null) {
        params['sameSite'] = sameSite;
      } else if (cookie.httpOnly && cookie.secure) {
        params['sameSite'] = 'None';
      }
      if (canonical?.priority case final priority?) {
        params['priority'] = priority;
      }
      if (canonical?.sourceScheme case final sourceScheme?) {
        params['sourceScheme'] = sourceScheme;
      }
      if (canonical?.sourcePort case final sourcePort?) {
        params['sourcePort'] = sourcePort;
      }
      if (canonical?.partitionKey case final partitionKey?) {
        params['partitionKey'] = partitionKey;
      }

      await controller.callDevToolsProtocolMethod(
        methodName: 'Network.setCookie',
        parameters: params,
      );
    } catch (e) {
      debugPrint('[CookieWriteThrough] CDP seed ${cookie.name} 失败: $e');
    }
  }

  String? _canonicalSameSite(CanonicalCookie? canonical) {
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
  }

}
