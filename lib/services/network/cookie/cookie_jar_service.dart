import 'dart:convert';
import 'dart:io' as io;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../constants.dart';
import '../../windows_webview_environment_service.dart';
import 'cookie_sync_context.dart';
import 'cookie_sync_coordinator.dart';
import 'cookie_value_codec.dart';
import 'strategy/platform_cookie_strategy.dart';

export 'cookie_value_codec.dart';

/// 统一的 Cookie 管理服务
/// 使用 cookie_jar 库管理 Cookie，支持持久化和 WebView 同步
class CookieJarService {
  static final CookieJarService _instance = CookieJarService._internal();
  factory CookieJarService() => _instance;
  CookieJarService._internal();

  CookieJar? _cookieJar;
  bool _initialized = false;
  CookieSyncCoordinator? _coordinator;

  CookieManager get webViewCookieManager =>
      WindowsWebViewEnvironmentService.instance.cookieManager;

  /// 获取 CookieJar 实例（用于 Dio CookieManager）
  CookieJar get cookieJar {
    if (_cookieJar == null) {
      throw StateError(
        'CookieJarService not initialized. Call initialize() first.',
      );
    }
    return _cookieJar!;
  }

  /// 是否已初始化
  bool get isInitialized => _initialized;

  /// 初始化 CookieJar（应用启动时调用）
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final cookiePath = path.join(directory.path, '.cookies');

      final cookieDir = io.Directory(cookiePath);
      if (!await cookieDir.exists()) {
        await cookieDir.create(recursive: true);
      }

      _cookieJar = EnhancedPersistCookieJar(
        ignoreExpires: false,
        store: FileCookieStore(cookiePath),
      );

      _initialized = true;

      // 创建同步编排器
      final strategy = PlatformCookieStrategy.create();
      _coordinator = CookieSyncCoordinator(jar: this, strategy: strategy);

      debugPrint('[CookieJar] Initialized with path: $cookiePath');

      await _migrateCookieStorage();
    } catch (e) {
      debugPrint(
        '[CookieJar] Failed to create persistent storage, using memory: $e',
      );
      _cookieJar = CookieJar();
      _initialized = true;

      final strategy = PlatformCookieStrategy.create();
      _coordinator = CookieSyncCoordinator(jar: this, strategy: strategy);
    }
  }

  static const _migrationKey = 'cookie_domain_migration_v2';

  /// 一次性迁移（v2）
  Future<void> _migrateCookieStorage() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationKey) == true) return;

    debugPrint('[CookieJar] Migrating cookie storage (v2)...');
    final jar = _cookieJar!;
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    final hosts = await _getRelatedHosts(baseHost);

    final collected = <Uri, List<io.Cookie>>{};
    for (final host in hosts) {
      final hostUri = Uri.parse('https://$host');
      final cookies = await jar.loadForRequest(hostUri);
      if (cookies.isNotEmpty) {
        collected[hostUri] = cookies;
      }
    }

    await jar.deleteAll();

    for (final entry in collected.entries) {
      final sorted = [...entry.value]
        ..sort((a, b) {
          // host-only（domain == null）优先，与 _mergeCookies 策略一致
          if (a.domain == null && b.domain != null) return -1;
          if (a.domain != null && b.domain == null) return 1;
          return 0;
        });
      final seen = <String>{};
      final deduped = <io.Cookie>[];
      for (final cookie in sorted) {
        if (seen.add('${cookie.name}|${cookie.path}')) {
          deduped.add(cookie);
        }
      }
      await jar.saveFromResponse(entry.key, deduped);
    }

    await prefs.setBool(_migrationKey, true);
    await prefs.remove('cookie_domain_migration_v1');
    debugPrint('[CookieJar] Migration v2 complete');
  }

  // ---------------------------------------------------------------------------
  // WebView ↔ CookieJar 同步（委托给 CookieSyncCoordinator）
  // ---------------------------------------------------------------------------

  /// 从 WebView 同步 Cookie 到 CookieJar
  Future<void> syncFromWebView({
    String? currentUrl,
    InAppWebViewController? controller,
    Set<String>? cookieNames,
  }) async {
    if (!_initialized) await initialize();

    final ctx = await _buildSyncContext(
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: cookieNames,
    );
    await _coordinator!.syncFromWebView(ctx);
  }

  /// 从 CookieJar 同步 Cookie 到 WebView
  Future<void> syncToWebView({
    String? currentUrl,
    InAppWebViewController? controller,
  }) async {
    if (!_initialized) await initialize();

    final ctx = await _buildSyncContext(
      currentUrl: currentUrl,
      controller: controller,
    );
    await _coordinator!.syncToWebView(ctx);
  }

  /// Windows 专用：通过页面级 controller 的 CDP 直接写入 CookieJar 中的 cookie
  Future<void> syncToWebViewViaController(
    InAppWebViewController controller, {
    String? currentUrl,
  }) async {
    if (!io.Platform.isWindows) return;
    if (!_initialized) await initialize();

    final ctx = await _buildSyncContext(
      currentUrl: currentUrl,
      controller: controller,
    );
    await _coordinator!.syncToWebViewViaController(controller, ctx);
  }

  /// 从当前 WebView 控制器的实时 Cookie 中读取指定值
  Future<String?> readCookieValueFromController(
    InAppWebViewController controller,
    String name, {
    String? currentUrl,
  }) async {
    if (!io.Platform.isWindows &&
        !io.Platform.isLinux &&
        !io.Platform.isAndroid) {
      return null;
    }
    return _coordinator?.readCookieValueFromController(
      controller,
      name,
      currentUrl: currentUrl,
    );
  }

  /// 将当前 WebView 控制器里的关键实时 Cookie 直接回写到 CookieJar
  Future<void> syncCriticalCookiesFromController(
    InAppWebViewController controller, {
    String? currentUrl,
    Set<String>? cookieNames,
  }) async {
    if (!_initialized) await initialize();
    if (!io.Platform.isWindows &&
        !io.Platform.isLinux &&
        !io.Platform.isAndroid) {
      return;
    }

    final ctx = await _buildSyncContext(
      currentUrl: currentUrl,
      controller: controller,
    );
    await _coordinator!.syncCriticalCookiesFromController(
      controller,
      ctx,
      cookieNames: cookieNames,
    );
  }

  // ---------------------------------------------------------------------------
  // 单个 Cookie 操作
  // ---------------------------------------------------------------------------

  /// 获取指定 Cookie 的值
  Future<String?> getCookieValue(String name) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      String? fallback;
      for (final cookie in cookies) {
        if (cookie.name == name) {
          if (cookie.domain == null) {
            return CookieValueCodec.decode(cookie.value);
          }
          fallback ??= CookieValueCodec.decode(cookie.value);
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie $name: $e');
    }
    return null;
  }

  Future<List<CanonicalCookie>> loadCanonicalCookiesForRequest(Uri uri) async {
    if (!_initialized) await initialize();
    final jar = _cookieJar;
    if (jar is EnhancedPersistCookieJar) {
      return jar.loadCanonicalForRequest(uri);
    }
    final cookies = await _cookieJar!.loadForRequest(uri);
    return cookies
        .map(
          (cookie) => CanonicalCookie(
            name: cookie.name,
            value: CookieValueCodec.decode(cookie.value),
            domain: cookie.domain,
            path: cookie.path ?? '/',
            expiresAt: cookie.expires?.toUtc(),
            maxAge: cookie.maxAge,
            secure: cookie.secure,
            httpOnly: cookie.httpOnly,
            hostOnly: cookie.domain == null || cookie.domain!.trim().isEmpty,
            persistent: cookie.expires != null || cookie.maxAge != null,
            originUrl: uri.toString(),
          ),
        )
        .toList(growable: false);
  }

  Future<CanonicalCookie?> getCanonicalCookie(String name) async {
    if (!_initialized) await initialize();
    final uri = Uri.parse(AppConstants.baseUrl);
    final cookies = await loadCanonicalCookiesForRequest(uri);

    CanonicalCookie? fallback;
    for (final cookie in cookies) {
      if (cookie.name != name) continue;
      if (cookie.domain == null) return cookie;
      fallback ??= cookie;
    }
    return fallback;
  }

  /// 设置 Cookie
  Future<void> setCookie(
    String name,
    String value, {
    String? url,
    String? domain,
    String? path,
    DateTime? expires,
    bool secure = true,
    bool httpOnly = false,
  }) async {
    if (!_initialized) await initialize();

    try {
      final uri =
          Uri.tryParse(url ?? AppConstants.baseUrl) ??
          Uri.parse(AppConstants.baseUrl);
      final cookie = io.Cookie(name, value)
        ..path = path ?? '/'
        ..secure = secure
        ..httpOnly = httpOnly;

      final normalizedDomain = domain?.trim();
      if (normalizedDomain != null && normalizedDomain.isNotEmpty) {
        cookie.domain = normalizedDomain;
      }
      if (expires != null) {
        cookie.expires = expires;
      }

      await _cookieJar!.saveFromResponse(uri, [cookie]);
    } catch (e) {
      debugPrint('[CookieJar] Failed to set cookie $name: $e');
    }
  }

  /// 删除指定 Cookie
  Future<void> deleteCookie(String name) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final expired = DateTime.now().subtract(const Duration(days: 1));
      final relatedHosts = await _getRelatedHosts(uri.host);

      for (final host in relatedHosts) {
        final hostUri = Uri.parse('https://$host');
        final cookies = await _cookieJar!.loadForRequest(hostUri);
        final expiredCookies = <io.Cookie>[];

        for (final cookie in cookies) {
          if (cookie.name == name) {
            final expired0 = io.Cookie(name, '')
              ..path = cookie.path ?? '/'
              ..expires = expired;
            if (cookie.domain != null) {
              expired0.domain = cookie.domain;
            }
            expiredCookies.add(expired0);
          }
        }

        if (expiredCookies.isNotEmpty) {
          await _cookieJar!.saveFromResponse(hostUri, expiredCookies);
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to delete cookie $name: $e');
    }
  }

  /// 清除所有 Cookie
  Future<void> clearAll() async {
    if (!_initialized) return;

    try {
      await _cookieJar!.deleteAll();

      // Android：加 timeout 保护
      if (io.Platform.isAndroid) {
        try {
          await webViewCookieManager
              .deleteAllCookies()
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          debugPrint('[CookieJar][Android] deleteAllCookies timeout in clearAll');
        }
      } else {
        await webViewCookieManager.deleteAllCookies();
      }

      // Apple 平台：同时清除 HTTPCookieStorage.shared
      if (io.Platform.isMacOS || io.Platform.isIOS) {
        final strategy = _coordinator?.strategy;
        if (strategy != null) {
          final ctx = await _buildSyncContext();
          await strategy.clearWebViewCookies(ctx);
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to clear cookies: $e');
    }
  }

  /// 从 WebView 中删除指定名称的 cookie（使用策略处理 domain 变体）
  /// 会遍历所有相关 host 和 domain 变体，确保彻底删除
  Future<void> deleteWebViewCookie(String name) async {
    if (!_initialized) await initialize();

    try {
      final strategy = _coordinator?.strategy;
      if (strategy == null) return;

      final baseHost = Uri.parse(AppConstants.baseUrl).host;
      final relatedHosts = await _getRelatedHosts(baseHost);

      for (final host in relatedHosts) {
        final url = WebUri('https://$host');
        // 无 domain 删除（host-only cookie）
        await webViewCookieManager.deleteCookie(
          url: url,
          name: name,
          path: '/',
        );
        // 通过策略获取 domain 变体并逐个删除
        for (final domain in strategy.buildDeleteDomainVariants('.$host')) {
          await webViewCookieManager.deleteCookie(
            url: url,
            name: name,
            domain: domain,
            path: '/',
          );
        }
        for (final domain in strategy.buildDeleteDomainVariants(host)) {
          await webViewCookieManager.deleteCookie(
            url: url,
            name: name,
            domain: domain,
            path: '/',
          );
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to delete WebView cookie $name: $e');
    }
  }

  /// 获取所有 Cookie 的字符串形式（用于请求头）
  Future<String?> getCookieHeader() async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      if (cookies.isEmpty) return null;

      return cookies
          .map((c) => '${c.name}=${CookieValueCodec.decode(c.value)}')
          .join('; ');
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie header: $e');
      return null;
    }
  }

  /// 获取 _t token
  Future<String?> getTToken() => getCookieValue('_t');

  /// 获取 _t 的诊断信息
  Future<Map<String, dynamic>> getTTokenDiagnostics() async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);
      final tCookies = cookies.where((c) => c.name == '_t').toList();
      return {
        'count': tCookies.length,
        'variants': tCookies
            .map(
              (c) => {
                'domain': c.domain,
                'path': c.path,
                'len': c.value.length,
                'hasPrefix': c.value.startsWith(CookieValueCodec.prefix),
              },
            )
            .toList(),
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// 获取 cf_clearance
  Future<String?> getCfClearance() => getCookieValue('cf_clearance');

  /// 获取 cf_clearance 的原始 Cookie 对象
  /// 优先 host-only cookie（与 getCookieValue 策略一致）
  Future<io.Cookie?> getCfClearanceCookie() async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);
      io.Cookie? fallback;
      for (final cookie in cookies) {
        if (cookie.name == 'cf_clearance') {
          if (cookie.domain == null) return cookie;
          fallback ??= cookie;
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cf_clearance cookie: $e');
    }
    return null;
  }

  /// 恢复 cf_clearance
  Future<void> restoreCfClearance(io.Cookie cookie) async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      await _cookieJar!.saveFromResponse(uri, [cookie]);
    } catch (e) {
      debugPrint('[CookieJar] Failed to restore cf_clearance: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 公开的工具方法（供 strategy/coordinator 使用）
  // ---------------------------------------------------------------------------

  /// 标准化 WebView cookie domain
  static String? normalizeWebViewCookieDomain(String? rawDomain) {
    final trimmed = rawDomain?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed.startsWith('.') ? trimmed.substring(1) : trimmed;
  }

  /// flutter_inappwebview Windows 插件的 expires 兼容处理
  static DateTime? parseWebViewCookieExpires(int? rawExpiresDate) {
    if (rawExpiresDate == null || rawExpiresDate <= 0) return null;

    final normalizedMillis = rawExpiresDate < 100000000000
        ? rawExpiresDate * 1000
        : rawExpiresDate;
    return DateTime.fromMillisecondsSinceEpoch(normalizedMillis);
  }

  /// 是否是关键 cookie
  static bool isCriticalCookie(String name) {
    return name == '_t' || name == '_forum_session' || name == 'cf_clearance';
  }

  /// 检查 domain 是否匹配应用主域
  static bool matchesAppHost(String? domain) {
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    final normalized = domain?.trim().replaceFirst(RegExp(r'^\.'), '');
    if (normalized == null || normalized.isEmpty) return true;
    return normalized == baseHost || normalized.endsWith('.$baseHost');
  }

  // ---------------------------------------------------------------------------
  // 私有工具方法
  // ---------------------------------------------------------------------------

  /// 构建同步上下文
  Future<CookieSyncContext> _buildSyncContext({
    String? currentUrl,
    InAppWebViewController? controller,
    Set<String>? cookieNames,
  }) async {
    final baseUri = Uri.parse(AppConstants.baseUrl);
    final extraHosts = <String>{};
    final currentHost = Uri.tryParse(
      currentUrl ?? '',
    )?.host.trim().toLowerCase();
    if (currentHost != null &&
        currentHost.isNotEmpty &&
        (currentHost == baseUri.host ||
            currentHost.endsWith('.${baseUri.host}'))) {
      extraHosts.add(currentHost);
    }

    final relatedHosts = await _getRelatedHosts(
      baseUri.host,
      extraHosts: extraHosts,
    );

    return CookieSyncContext(
      baseUri: baseUri,
      relatedHosts: relatedHosts,
      currentUrl: currentUrl,
      controller: controller,
      cookieNames: cookieNames,
      webViewCookieManager: webViewCookieManager,
    );
  }

  /// 从 cookie jar 存储中获取所有与 [baseHost] 相关的域名
  Future<List<String>> _getRelatedHosts(
    String baseHost, {
    Set<String>? extraHosts,
  }) async {
    bool isRelatedHost(String host) {
      return host == baseHost || host.endsWith('.$baseHost');
    }

    final hosts = <String>{baseHost, ...?extraHosts?.where(isRelatedHost)};
    final jar = _cookieJar;
    if (jar is DefaultCookieJar) {
      for (final host in jar.domainCookies.keys) {
        final normalizedHost = host.trim().replaceFirst(RegExp(r'^\.'), '');
        if (normalizedHost.isNotEmpty && isRelatedHost(normalizedHost)) {
          hosts.add(normalizedHost);
        }
      }
      for (final host in jar.hostCookies.keys) {
        final normalizedHost = host.trim().toLowerCase();
        if (normalizedHost.isNotEmpty && isRelatedHost(normalizedHost)) {
          hosts.add(normalizedHost);
        }
      }
    }
    if (jar is PersistCookieJar) {
      try {
        await jar.forceInit();
        for (final host in jar.domainCookies.keys) {
          final normalizedHost = host.trim().replaceFirst(RegExp(r'^\.'), '');
          if (normalizedHost.isNotEmpty && isRelatedHost(normalizedHost)) {
            hosts.add(normalizedHost);
          }
        }
        final indexStr = await jar.storage.read('.index');
        if (indexStr != null && indexStr.isNotEmpty) {
          for (final host in (json.decode(indexStr) as List).cast<String>()) {
            final normalizedHost = host.trim().toLowerCase();
            if (normalizedHost.isNotEmpty && isRelatedHost(normalizedHost)) {
              hosts.add(normalizedHost);
            }
          }
        }
      } catch (e) {
        debugPrint('[CookieJar] Failed to read cookie index: $e');
      }
    }
    if (jar is EnhancedPersistCookieJar) {
      try {
        final cookies = await jar.readAllCookies();
        for (final cookie in cookies) {
          final normalizedHost = cookie.normalizedDomain;
          if (normalizedHost != null &&
              normalizedHost.isNotEmpty &&
              isRelatedHost(normalizedHost)) {
            hosts.add(normalizedHost);
          }
        }
      } catch (e) {
        debugPrint('[CookieJar] Failed to read enhanced cookie store: $e');
      }
    }
    final relatedHosts = hosts.toList()..sort();
    return relatedHosts;
  }
}
