import 'dart:convert';
import 'dart:io' as io;
import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../constants.dart';
import '../../cf_challenge_logger.dart';

/// Cookie 值编解码工具
/// Dart 的 io.Cookie 严格遵循 RFC 6265，禁止值中包含双引号、逗号等字符，
/// 但浏览器允许这些字符（如 g_state 的 JSON 值）。
/// 对不合规的值进行 URL 编码后加前缀存储，在所有出口处解码还原。
class CookieValueCodec {
  static const _prefix = '~enc~';

  /// 编码不合规的 cookie 值
  static String encode(String value) =>
      '$_prefix${Uri.encodeComponent(value)}';

  /// 解码还原浏览器原始值；未编码的值原样返回
  static String decode(String value) {
    if (value.startsWith(_prefix)) {
      return Uri.decodeComponent(value.substring(_prefix.length));
    }
    return value;
  }
}

/// 统一的 Cookie 管理服务
/// 使用 cookie_jar 库管理 Cookie，支持持久化和 WebView 同步
class CookieJarService {
  static final CookieJarService _instance = CookieJarService._internal();
  factory CookieJarService() => _instance;
  CookieJarService._internal();

  CookieJar? _cookieJar;
  bool _initialized = false;
  final _webViewCookieManager = CookieManager.instance();

  /// Apple 平台 platform channel，用于将 cookie 写入 HTTPCookieStorage.shared。
  /// WKWebView 的 sharedCookiesEnabled 在创建时从 HTTPCookieStorage.shared 读取 cookie，
  /// 比 WKHTTPCookieStore 的跨进程异步同步更可靠。
  static const _nativeCookieChannel = MethodChannel('com.fluxdo/cookie_storage');

  /// 获取 CookieJar 实例（用于 Dio CookieManager）
  CookieJar get cookieJar {
    if (_cookieJar == null) {
      throw StateError('CookieJarService not initialized. Call initialize() first.');
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

      _cookieJar = PersistCookieJar(
        ignoreExpires: false,
        storage: FileStorage(cookiePath),
      );

      _initialized = true;
      debugPrint('[CookieJar] Initialized with path: $cookiePath');

      // 一次性迁移：v2 规范化 domain 为前导点格式并去重，
      // 消除 host-only 与 domain cookie 共存导致的冲突。
      await _migrateCookieStorage();
    } catch (e) {
      debugPrint('[CookieJar] Failed to create persistent storage, using memory: $e');
      _cookieJar = CookieJar();
      _initialized = true;
    }
  }

  static const _migrationKey = 'cookie_domain_migration_v2';

  /// 一次性迁移（v2）：读出所有 cookie，按 name+path 去重
  /// （优先保留 domain cookie），清空后重新存入，
  /// 消除旧版本 hostCookies / domainCookies 的重复冲突。
  Future<void> _migrateCookieStorage() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationKey) == true) return;

    debugPrint('[CookieJar] Migrating cookie storage (v2)...');
    final jar = _cookieJar!;
    final baseHost = Uri.parse(AppConstants.baseUrl).host;
    final hosts = await _getRelatedHosts(baseHost);

    // 按 host 读出所有 cookie
    final collected = <Uri, List<io.Cookie>>{};
    for (final host in hosts) {
      final hostUri = Uri.parse('https://$host');
      final cookies = await jar.loadForRequest(hostUri);
      if (cookies.isNotEmpty) {
        collected[hostUri] = cookies;
      }
    }

    // 清空
    await jar.deleteAll();

    // 去重后重新存入：同 name+path 下优先保留 domain cookie
    for (final entry in collected.entries) {
      final sorted = [...entry.value]..sort((a, b) {
        // domain cookie 排前面
        if (a.domain != null && b.domain == null) return -1;
        if (a.domain == null && b.domain != null) return 1;
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
    // 清除旧版迁移标记
    await prefs.remove('cookie_domain_migration_v1');
    debugPrint('[CookieJar] Migration v2 complete');
  }

  // ---------------------------------------------------------------------------
  // WebView ↔ CookieJar 同步
  // ---------------------------------------------------------------------------

  /// 从 WebView 同步 Cookie 到 CookieJar
  Future<void> syncFromWebView() async {
    if (!_initialized) await initialize();

    try {
      final webViewCookies = await _webViewCookieManager.getCookies(
        url: WebUri(AppConstants.baseUrl),
      );

      if (CfChallengeLogger.isEnabled) {
        CfChallengeLogger.logCookieSync(
          direction: 'WebView -> CookieJar',
          cookies: webViewCookies.map((wc) => CookieLogEntry(
            name: wc.name,
            domain: wc.domain,
            path: wc.path,
            expires: wc.expiresDate != null
                ? DateTime.fromMillisecondsSinceEpoch(wc.expiresDate!.toInt())
                : null,
            valueLength: wc.value.length,
          )).toList(),
        );
      }

      if (webViewCookies.isEmpty) return;

      final baseUri = Uri.parse(AppConstants.baseUrl);

      // 按 URI 分桶、按 name+path+domain 去重
      final bucketedCookies = <Uri, Map<String, io.Cookie>>{};

      for (final wc in webViewCookies) {
        final rawDomain = wc.domain?.trim();
        String? domainAttr;
        String hostForUri = baseUri.host;

        if (rawDomain != null && rawDomain.isNotEmpty) {
          if (rawDomain.startsWith('.')) {
            domainAttr = rawDomain;
            hostForUri = rawDomain.substring(1);
          } else {
            // 无前导点的 domain：保持 host-only（不加前导点），
            // 与 dio 官方 cookie_jar 行为一致。
            // WKWebView 的前导点需求由 syncToWebView 的 _resolveWebViewDomain 处理。
            hostForUri = rawDomain;
          }
        }

        // Dart Cookie 构造函数严格遵循 RFC 6265，对不合规值使用编码存储
        io.Cookie cookie;
        try {
          cookie = io.Cookie(wc.name, wc.value)
            ..path = wc.path ?? '/'
            ..secure = wc.isSecure ?? false
            ..httpOnly = wc.isHttpOnly ?? false;
        } catch (_) {
          cookie = io.Cookie(wc.name, CookieValueCodec.encode(wc.value))
            ..path = wc.path ?? '/'
            ..secure = wc.isSecure ?? false
            ..httpOnly = wc.isHttpOnly ?? false;
        }

        if (domainAttr != null) {
          cookie.domain = domainAttr;
        }
        if (wc.expiresDate != null) {
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(wc.expiresDate!.toInt());
        }

        // 跳过已过期的 cookie：写入 CookieJar 会覆盖同名有效 cookie 后被自动移除
        if (cookie.expires != null && cookie.expires!.isBefore(DateTime.now())) {
          debugPrint('[CookieJar] syncFromWebView: 跳过已过期 cookie ${cookie.name}');
          continue;
        }

        // 跳过空值的认证 cookie：防止覆盖 CookieJar 中的有效值
        if (cookie.value.isEmpty && _isAuthCookie(cookie.name)) {
          debugPrint('[CookieJar] syncFromWebView: 跳过空值认证 cookie ${cookie.name}');
          continue;
        }

        final bucketUri = Uri(scheme: baseUri.scheme, host: hostForUri);
        final dedupeKey = '${cookie.name}|${cookie.path}|${cookie.domain ?? hostForUri}';
        bucketedCookies.putIfAbsent(bucketUri, () => <String, io.Cookie>{})[dedupeKey] = cookie;
      }

      var totalSynced = 0;
      for (final entry in bucketedCookies.entries) {
        final cookies = entry.value.values.toList();
        if (cookies.isEmpty) continue;
        await _cookieJar!.saveFromResponse(entry.key, cookies);
        totalSynced += cookies.length;
      }

      debugPrint('[CookieJar] Synced $totalSynced cookies from WebView');
    } catch (e) {
      debugPrint('[CookieJar] Failed to sync from WebView: $e');
    }
  }

  /// 从 CookieJar 同步 Cookie 到 WebView
  Future<void> syncToWebView() async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);

      // 收集主域及所有子域的 cookie，保留来源 host 用于 host-only cookie
      final relatedHosts = await _getRelatedHosts(uri.host);
      final seen = <String>{};
      final cookies = <(io.Cookie, String)>[];
      for (final host in relatedHosts) {
        final hostCookies = await _cookieJar!.loadForRequest(Uri.parse('https://$host'));
        for (final c in hostCookies) {
          if (seen.add('${c.name}|${c.domain}|${c.path}')) {
            cookies.add((c, host));
          }
        }
      }

      // 清除 WebView 中现有的 cookie
      // 1. deleteCookies（批量）清除 host-only cookie（domain 匹配 url host）
      await _webViewCookieManager.deleteCookies(url: WebUri(AppConstants.baseUrl));
      // 2. 逐个 deleteCookie 精确清除 domain cookie（带前导点的无法被批量删除匹配到）
      //    以及子域 cookie
      for (final host in relatedHosts) {
        final url = 'https://$host';
        final existing = await _webViewCookieManager.getCookies(url: WebUri(url));
        for (final wc in existing) {
          await _webViewCookieManager.deleteCookie(
            url: WebUri(url),
            name: wc.name,
            domain: wc.domain,
            path: wc.path ?? '/',
          );
        }
      }

      if (cookies.isEmpty) return;

      if (CfChallengeLogger.isEnabled) {
        CfChallengeLogger.logCookieSync(
          direction: 'CookieJar -> WebView',
          cookies: cookies.map((e) => CookieLogEntry(
            name: e.$1.name,
            domain: e.$1.domain,
            path: e.$1.path,
            expires: e.$1.expires,
            valueLength: e.$1.value.length,
          )).toList(),
        );
      }

      // 设置 cookie 到 WebView
      // Apple 平台：iOS setCookie 的 domain 必须带前导点，否则静默失败
      //   （flutter_inappwebview #338）。对 domain cookie 补前导点，
      //   host-only cookie 用 sourceHost 兜底。
      // Android 平台：保持 cookie.domain 原值（与 0.1.28 一致），
      //   host-only cookie 保持 null，syncFromWebView 读回时存入 hostCookies，
      //   不会覆盖 Dio saveCookies 存入 domainCookies 中的有效副本。
      final isApple = io.Platform.isIOS || io.Platform.isMacOS;
      final cookieMaps = <Map<String, dynamic>>[];
      for (final (cookie, sourceHost) in cookies) {
        final value = CookieValueCodec.decode(cookie.value);
        final String? domain;
        if (isApple) {
          // Apple: domain 必须非 null 且带前导点，否则 setCookie 静默失败
          // （flutter_inappwebview #338，b272dbf）。
          if (cookie.domain != null) {
            domain = cookie.domain!.startsWith('.') ? cookie.domain : '.${cookie.domain}';
          } else {
            domain = '.$sourceHost';
          }
        } else {
          // Android: 保持原值（与 0.1.28 一致），
          // host-only cookie 保持 null，syncFromWebView 读回时存入 hostCookies，
          // 不会覆盖 Dio saveCookies 存入 domainCookies 中的有效副本。
          domain = cookie.domain;
        }
        final cookieUrl = 'https://${domain != null && domain.startsWith('.') ? domain.substring(1) : (domain ?? sourceHost)}';

        await _webViewCookieManager.setCookie(
          url: WebUri(cookieUrl),
          name: cookie.name,
          value: value.isEmpty ? ' ' : value,
          domain: domain,
          path: cookie.path ?? '/',
          isSecure: cookie.secure,
          isHttpOnly: cookie.httpOnly,
          expiresDate: cookie.expires?.millisecondsSinceEpoch,
        );

        cookieMaps.add({
          'url': cookieUrl,
          'name': cookie.name,
          'value': value.isEmpty ? ' ' : value,
          'domain': domain,
          'path': cookie.path ?? '/',
          'isSecure': cookie.secure,
          'isHttpOnly': cookie.httpOnly,
          'expiresDate': cookie.expires?.millisecondsSinceEpoch,
        });
      }

      // Apple 平台：同时写入 HTTPCookieStorage.shared
      if (io.Platform.isMacOS || io.Platform.isIOS) {
        try {
          await _nativeCookieChannel.invokeMethod('clearCookies', AppConstants.baseUrl);
          await _nativeCookieChannel.invokeMethod('setCookies', cookieMaps);
        } catch (e) {
          debugPrint('[CookieJar] HTTPCookieStorage sync failed: $e');
        }
      }

      debugPrint('[CookieJar] Synced ${cookies.length} cookies to WebView');
    } catch (e) {
      debugPrint('[CookieJar] Failed to sync to WebView: $e');
    }
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

      // 优先返回 domain cookie（更可能是最新的、由服务器设置的），
      // 避免 host-only 和 domain cookie 共存时取到旧值。
      String? fallback;
      for (final cookie in cookies) {
        if (cookie.name == name) {
          if (cookie.domain != null) {
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

  /// 设置 Cookie
  Future<void> setCookie(String name, String value, {
    String? domain,
    String? path,
    DateTime? expires,
    bool secure = true,
    bool httpOnly = false,
  }) async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookie = io.Cookie(name, value)
        ..path = path ?? '/'
        ..secure = secure
        ..httpOnly = httpOnly;

      if (domain != null && domain.startsWith('.')) {
        cookie.domain = domain;
      }
      if (expires != null) {
        cookie.expires = expires;
      }

      await _cookieJar!.saveFromResponse(uri, [cookie]);
    } catch (e) {
      debugPrint('[CookieJar] Failed to set cookie $name: $e');
    }
  }

  /// 删除指定 Cookie（遍历所有相关 host，删除所有匹配 name 的 cookie）
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
      await _webViewCookieManager.deleteAllCookies();

      // Apple 平台：同时清除 HTTPCookieStorage.shared，
      // 否则 sharedCookiesEnabled=true 的 WebView 创建时会读到旧 cookie。
      if (io.Platform.isMacOS || io.Platform.isIOS) {
        try {
          await _nativeCookieChannel.invokeMethod('clearCookies', AppConstants.baseUrl);
        } catch (e) {
          debugPrint('[CookieJar] HTTPCookieStorage clear failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to clear cookies: $e');
    }
  }

  /// 获取所有 Cookie 的字符串形式（用于请求头）
  Future<String?> getCookieHeader() async {
    if (!_initialized) await initialize();

    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);

      if (cookies.isEmpty) return null;

      return cookies.map((c) => '${c.name}=${CookieValueCodec.decode(c.value)}').join('; ');
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cookie header: $e');
      return null;
    }
  }

  /// 获取 _t token
  Future<String?> getTToken() => getCookieValue('_t');

  /// 获取 cf_clearance
  Future<String?> getCfClearance() => getCookieValue('cf_clearance');

  /// 获取 cf_clearance 的原始 Cookie 对象（保留 domain、expires 等属性）
  Future<io.Cookie?> getCfClearanceCookie() async {
    if (!_initialized) await initialize();
    try {
      final uri = Uri.parse(AppConstants.baseUrl);
      final cookies = await _cookieJar!.loadForRequest(uri);
      io.Cookie? fallback;
      for (final cookie in cookies) {
        if (cookie.name == 'cf_clearance') {
          if (cookie.domain != null) return cookie;
          fallback ??= cookie;
        }
      }
      return fallback;
    } catch (e) {
      debugPrint('[CookieJar] Failed to get cf_clearance cookie: $e');
    }
    return null;
  }

  /// 恢复 cf_clearance（登出清除 cookie 后调用）
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
  // 私有工具方法
  // ---------------------------------------------------------------------------

  /// 从 cookie jar 存储中获取所有与 [baseHost] 相关的域名（主域 + 子域）
  Future<List<String>> _getRelatedHosts(String baseHost) async {
    final hosts = <String>{baseHost};
    final jar = _cookieJar;
    if (jar is PersistCookieJar) {
      try {
        await jar.forceInit();
        final indexStr = await jar.storage.read('.index');
        if (indexStr != null && indexStr.isNotEmpty) {
          for (final host in (json.decode(indexStr) as List).cast<String>()) {
            if (host == baseHost || host.endsWith('.$baseHost')) {
              hosts.add(host);
            }
          }
        }
      } catch (e) {
        debugPrint('[CookieJar] Failed to read cookie index: $e');
      }
    }
    return hosts.toList();
  }

  /// 是否是认证关键 cookie（丢失会导致登出）
  static bool _isAuthCookie(String name) {
    return name == '_t' || name == '_forum_session';
  }
}
