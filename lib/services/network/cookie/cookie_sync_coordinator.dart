import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../constants.dart';
import '../../cf_challenge_logger.dart';
import '../../windows_webview_environment_service.dart';
import 'cookie_diagnostics.dart';
import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';

import 'cookie_jar_service.dart';
import 'cookie_sync_context.dart';
import 'strategy/platform_cookie_strategy.dart';
import 'strategy/windows_cookie_strategy.dart';

/// Cookie 同步编排器
/// 负责 WebView ↔ CookieJar 的双向同步，委托平台策略处理差异
class CookieSyncCoordinator {
  CookieSyncCoordinator({
    required this.jar,
    required this.strategy,
  });

  final CookieJarService jar;
  final PlatformCookieStrategy strategy;

  CookieManager get _webViewCookieManager =>
      WindowsWebViewEnvironmentService.instance.cookieManager;

  // ---------------------------------------------------------------------------
  // syncFromWebView：WebView → CookieJar
  // ---------------------------------------------------------------------------

  /// 从 WebView 同步 Cookie 到 CookieJar
  Future<void> syncFromWebView(CookieSyncContext ctx) async {
    try {
      // Windows + controller 可用时，通过 CDP 读取完整 cookie 属性
      if (io.Platform.isWindows && ctx.controller != null) {
        await _syncFromWebViewViaCDP(ctx);
        return;
      }

      final webViewCookies = await strategy.readCookiesFromWebView(ctx);

      if (CfChallengeLogger.isEnabled) {
        CfChallengeLogger.logCookieSync(
          direction: 'WebView -> CookieJar',
          cookies: webViewCookies.map((snapshot) {
            final wc = snapshot.cookie;
            return CookieLogEntry(
              name: wc.name,
              domain: wc.domain,
              path: wc.path,
              expires: CookieJarService.parseWebViewCookieExpires(
                wc.expiresDate,
              ),
              valueLength: wc.value.length,
            );
          }).toList(),
        );
      }

      if (webViewCookies.isEmpty) {
        if (io.Platform.isWindows) {
          debugPrint(
            '[CookieJar][Windows] syncFromWebView 未读取到任何 Cookie: '
            'userDataFolder='
            '${WindowsWebViewEnvironmentService.instance.userDataFolder ?? "<default>"}',
          );
        }
        return;
      }

      // 预加载 jar 中已有 cookie 的 hostOnly 信息，用于合并时保留元数据
      final jarHostOnlyFlags = <String, bool>{};
      final enhancedJar = jar.cookieJar;
      if (enhancedJar is EnhancedPersistCookieJar) {
        final existing = await enhancedJar.readAllCookies();
        for (final c in existing) {
          // key: name|normalizedDomain|path
          final key = '${c.name}|${c.normalizedDomain}|${c.path}';
          jarHostOnlyFlags[key] = c.hostOnly;
        }
      }

      // 按 URI 分桶、去重
      final bucketedCookies = <Uri, Map<String, io.Cookie>>{};

      for (final snapshot in webViewCookies) {
        final wc = snapshot.cookie;
        if (ctx.cookieNames != null && !ctx.cookieNames!.contains(wc.name)) {
          continue;
        }
        final rawDomain = wc.domain?.trim();
        final normalizedDomain =
            CookieJarService.normalizeWebViewCookieDomain(rawDomain);

        // 合并策略：jar 中已有 cookie 的 hostOnly 优先于 WebView 推断
        final jarKey = '${wc.name}|${normalizedDomain ?? snapshot.primaryHost}|${wc.path ?? '/'}';
        final jarHostOnly = jarHostOnlyFlags[jarKey];

        final shouldPersistAsDomainCookie = jarHostOnly != null
            ? !jarHostOnly // jar 已知是 domain cookie
            : _shouldPersistWebViewDomainCookie(
                rawDomain: rawDomain,
                normalizedDomain: normalizedDomain,
                sourceHosts: snapshot.sourceHosts,
              );
        String? domainAttr;
        var hostForUri = snapshot.primaryHost;

        if (normalizedDomain != null) {
          hostForUri = normalizedDomain;
          if (shouldPersistAsDomainCookie) {
            domainAttr = '.$normalizedDomain';
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
        final expires = CookieJarService.parseWebViewCookieExpires(
          wc.expiresDate,
        );
        if (expires != null) {
          cookie.expires = expires;
        }

        // 跳过已过期的 cookie
        if (cookie.expires != null &&
            cookie.expires!.isBefore(DateTime.now())) {
          debugPrint(
            '[CookieJar] syncFromWebView: 跳过已过期 cookie ${cookie.name}',
          );
          continue;
        }

        // 跳过空值的关键 cookie
        if (cookie.value.isEmpty &&
            CookieJarService.isCriticalCookie(cookie.name)) {
          debugPrint(
            '[CookieJar] syncFromWebView: 跳过空值关键 cookie ${cookie.name}',
          );
          continue;
        }

        final bucketUri = Uri(scheme: ctx.baseUri.scheme, host: hostForUri);
        final dedupeKey =
            '${cookie.name}|${cookie.path}|${cookie.domain ?? hostForUri}';
        bucketedCookies.putIfAbsent(
          bucketUri,
          () => <String, io.Cookie>{},
        )[dedupeKey] = cookie;
      }

      // Bug #5 fix：先清掉 CookieJar 中关键 cookie 旧值，再写入新值
      // 确保同名不存在 domain 类型冲突的副本
      final namesAboutToSync = <String>{};
      for (final cookies in bucketedCookies.values) {
        for (final cookie in cookies.values) {
          if (CookieJarService.isCriticalCookie(cookie.name)) {
            namesAboutToSync.add(cookie.name);
          }
        }
      }
      for (final name in namesAboutToSync) {
        await jar.deleteCookie(name);
      }

      var totalSynced = 0;
      for (final entry in bucketedCookies.entries) {
        final cookies = entry.value.values.toList();
        if (cookies.isEmpty) continue;
        await jar.cookieJar.saveFromResponse(entry.key, cookies);
        totalSynced += cookies.length;
      }



      debugPrint('[CookieJar] Synced $totalSynced cookies from WebView');
      if (io.Platform.isWindows) {
        await CookieDiagnostics.logWindowsCookieSyncStatus(
          'syncFromWebView',
          jar: jar,
          ctx: ctx,
          webViewCookies: webViewCookies.map((s) => s.cookie).toList(),
        );
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to sync from WebView: $e');
    }
  }

  /// 将当前 WebView 控制器里的关键实时 Cookie 直接回写到 CookieJar
  Future<void> syncCriticalCookiesFromController(
    InAppWebViewController controller,
    CookieSyncContext ctx, {
    Set<String>? cookieNames,
  }) async {
    if (!io.Platform.isWindows &&
        !io.Platform.isLinux &&
        !io.Platform.isAndroid) {
      return;
    }

    final names = cookieNames ?? const {'_t', '_forum_session', 'cf_clearance'};
    await strategy.syncCriticalFromController(controller, names, ctx, jar);
  }

  /// 从当前 WebView 控制器的实时 Cookie 中读取指定值
  Future<String?> readCookieValueFromController(
    InAppWebViewController controller,
    String name, {
    String? currentUrl,
  }) async {
    return strategy.readLiveCookieValue(
      controller,
      name,
      currentUrl: currentUrl,
    );
  }

  Future<void> syncToWebView(CookieSyncContext ctx) async {
    try {
      final seen = <String>{};
      final windowsCriticalCookies = <String, (io.Cookie, String)>{};
      final jarCookies = <(io.Cookie, String)>[];
      for (final host in ctx.relatedHosts) {
        final hostCookies = await jar.cookieJar.loadForRequest(
          Uri.parse('https://$host'),
        );
        for (final c in hostCookies) {
          if (io.Platform.isWindows &&
              CookieJarService.isCriticalCookie(c.name)) {
            final selectionKey = '${c.name}|${c.path ?? '/'}';
            final existing = windowsCriticalCookies[selectionKey];
            if (existing == null ||
                WindowsCookieStrategy.compareWindowsCriticalCookieCandidates(
                      c,
                      existing.$1,
                      requestHost: host,
                    ) >
                    0) {
              windowsCriticalCookies[selectionKey] = (c, host);
            }
            continue;
          }
          final dedupeKey = _buildJarToWebViewSyncKey(c, host);
          if (seen.add(dedupeKey)) {
            jarCookies.add((c, host));
          }
        }
      }
      jarCookies.insertAll(0, windowsCriticalCookies.values);

      if (jarCookies.isEmpty) return;

      final webViewCookies = await strategy.readCookiesFromWebView(ctx);
      final toDelete = <(String name, String url, String? domain, String path)>[];
      final toWrite = <(io.Cookie, String)>[];

      final jarIndex = <String, (io.Cookie, String)>{};
      for (final (cookie, sourceHost) in jarCookies) {
        final normalizedDomain =
            CookieJarService.normalizeWebViewCookieDomain(cookie.domain) ??
            sourceHost;
        final key =
            '${cookie.name}|$normalizedDomain|${cookie.path ?? '/'}';
        jarIndex[key] = (cookie, sourceHost);
      }

      final webViewIndex = <String, CollectedWebViewCookie>{};
      final webViewDuplicates = <String, List<CollectedWebViewCookie>>{};
      for (final snapshot in webViewCookies) {
        final wc = snapshot.cookie;
        final normalizedDomain =
            CookieJarService.normalizeWebViewCookieDomain(wc.domain) ??
            snapshot.primaryHost;
        final key = '${wc.name}|$normalizedDomain|${wc.path ?? '/'}';
        webViewDuplicates.putIfAbsent(key, () => []).add(snapshot);
        webViewIndex[key] = snapshot;
      }

      for (final entry in webViewDuplicates.entries) {
        if (entry.value.length <= 1) continue;
        final jarEntry = jarIndex[entry.key];
        final jarValue = jarEntry != null
            ? CookieValueCodec.decode(jarEntry.$1.value)
            : null;
        for (final snapshot in entry.value) {
          final wc = snapshot.cookie;
          if (jarValue != null && wc.value == jarValue) {
            webViewIndex[entry.key] = snapshot;
            continue;
          }
          final normalizedDomain =
              CookieJarService.normalizeWebViewCookieDomain(wc.domain) ??
              snapshot.primaryHost;
          if (CookieJarService.matchesAppHost(wc.domain)) {
            toDelete.add((
              wc.name,
              'https://$normalizedDomain',
              normalizedDomain,
              wc.path ?? '/',
            ));
          }
        }
      }

      for (final entry in webViewIndex.entries) {
        if (!jarIndex.containsKey(entry.key)) {
          final wc = entry.value.cookie;
          final normalizedDomain =
              CookieJarService.normalizeWebViewCookieDomain(wc.domain) ??
              entry.value.primaryHost;
          if (CookieJarService.matchesAppHost(wc.domain)) {
            toDelete.add((
              wc.name,
              'https://$normalizedDomain',
              normalizedDomain,
              wc.path ?? '/',
            ));
          }
        }
      }

      for (final entry in jarIndex.entries) {
        final webViewEntry = webViewIndex[entry.key];
        final (cookie, sourceHost) = entry.value;
        if (webViewEntry == null) {
          toWrite.add((cookie, sourceHost));
        }
      }

      for (final (name, url, domain, path) in toDelete) {
        try {
          final domainVariants = strategy.buildDeleteDomainVariants(domain);
          for (final variant in domainVariants) {
            await _webViewCookieManager.deleteCookie(
              url: WebUri(url),
              name: name,
              domain: variant,
              path: path,
            );
          }
        } catch (e) {
          debugPrint('[CookieJar] Failed to delete stale cookie $name: $e');
        }
      }

      if (CfChallengeLogger.isEnabled) {
        CfChallengeLogger.logCookieSync(
          direction: 'CookieJar -> WebView',
          cookies: jarCookies
              .map(
                (e) => CookieLogEntry(
                  name: e.$1.name,
                  domain: e.$1.domain,
                  path: e.$1.path,
                  expires: e.$1.expires,
                  valueLength: e.$1.value.length,
                ),
              )
              .toList(),
        );
      }

      if (toWrite.isNotEmpty) {
        await strategy.writeCookiesToWebView(toWrite, ctx);
      }

      debugPrint(
        '[CookieJar] Synced to WebView: ${toWrite.length} written, '
        '${toDelete.length} deleted (total jar: ${jarCookies.length})',
      );
      if (io.Platform.isWindows) {
        await CookieDiagnostics.logWindowsDuplicateCriticalCookies(
          'syncToWebView',
          ctx.relatedHosts,
          _webViewCookieManager,
        );
        await CookieDiagnostics.logWindowsCookieSyncStatus(
          'syncToWebView',
          jar: jar,
          ctx: ctx,
        );
      }
    } catch (e) {
      debugPrint('[CookieJar] Failed to sync to WebView: $e');
    }
  }

  Future<void> syncToWebViewViaController(
    InAppWebViewController controller,
    CookieSyncContext ctx,
  ) async {
    if (!io.Platform.isWindows) return;

    try {
      final seen = <String>{};
      final windowsCriticalCookies = <String, (io.Cookie, String)>{};
      final cookiesToWrite = <(io.Cookie, String)>[];
      for (final host in ctx.relatedHosts) {
        final hostCookies = await jar.cookieJar.loadForRequest(
          Uri.parse('https://$host'),
        );
        for (final c in hostCookies) {
          if (CookieJarService.isCriticalCookie(c.name)) {
            final key = '${c.name}|${c.path ?? '/'}';
            final existing = windowsCriticalCookies[key];
            if (existing == null ||
                WindowsCookieStrategy.compareWindowsCriticalCookieCandidates(
                      c,
                      existing.$1,
                      requestHost: host,
                    ) >
                    0) {
              windowsCriticalCookies[key] = (c, host);
            }
            continue;
          }

          final dedupeKey = _buildJarToWebViewSyncKey(c, host);
          if (seen.add(dedupeKey)) {
            cookiesToWrite.add((c, host));
          }
        }
      }
      final cookies = <(io.Cookie, String)>[
        ...windowsCriticalCookies.values,
        ...cookiesToWrite,
      ];
      if (cookies.isEmpty) return;
      await strategy.writeViaController(controller, cookies, ctx);
    } catch (e) {
      debugPrint('[CookieJar][Windows] syncToWebViewViaController failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 私有辅助方法
  // ---------------------------------------------------------------------------

  /// CDP 同步（Windows）
  Future<void> _syncFromWebViewViaCDP(CookieSyncContext ctx) async {
    final controller = ctx.controller!;
    final resolvedCurrentUrl =
        ctx.currentUrl ?? (await controller.getUrl())?.toString();
    final cdpUrls = <String>{
      AppConstants.baseUrl,
      '${AppConstants.baseUrl}/',
      if (resolvedCurrentUrl != null && resolvedCurrentUrl.isNotEmpty)
        resolvedCurrentUrl,
      for (final host in ctx.relatedHosts) 'https://$host',
    }.toList();

    try {
      final result = await controller.callDevToolsProtocolMethod(
        methodName: 'Network.getCookies',
        parameters: {'urls': cdpUrls},
      );
      final rawCookies = result is Map<String, dynamic>
          ? result['cookies']
          : null;
      if (rawCookies is! List || rawCookies.isEmpty) {
        debugPrint(
          '[CookieJar][CDP] syncFromWebView(controller): no cookies',
        );
        return;
      }

      // 将 CDP 原始数据持久化到 EnhancedPersistCookieJar（保留 SameSite/partitionKey 等完整元数据）
      final enhancedJar = jar.cookieJar;
      if (enhancedJar is EnhancedPersistCookieJar) {
        final cdpMaps = rawCookies
            .whereType<Map>()
            .map((raw) => raw.map((k, v) => MapEntry(k.toString(), v)))
            .cast<Map<String, dynamic>>()
            .toList(growable: false);
        if (cdpMaps.isNotEmpty) {
          final uri = Uri.tryParse(resolvedCurrentUrl ?? '') ??
              Uri.parse(AppConstants.baseUrl);
          try {
            await enhancedJar.saveFromCdpCookies(uri, cdpMaps);
          } catch (e) {
            debugPrint(
              '[CookieJar][CDP] Failed to persist CDP cookies in syncFromWebView: $e',
            );
          }
        }
      }

      // 按 (name, path, hostOnly) 去重，保留 CDP 原始 hostOnly 信息
      final bestCookies = <String, Map<String, dynamic>>{};
      for (final raw in rawCookies.whereType<Map>()) {
        final name = raw['name']?.toString();
        final domain = raw['domain']?.toString() ?? '';
        if (name == null) continue;
        final normalized = domain.replaceFirst(RegExp(r'^\.'), '');
        if (normalized.isNotEmpty &&
            normalized != ctx.baseUri.host &&
            !normalized.endsWith('.${ctx.baseUri.host}') &&
            !ctx.baseUri.host.endsWith('.$normalized')) {
          continue;
        }
        final path = raw['path']?.toString() ?? '/';
        final hostOnly = raw['hostOnly'] == true;
        final key = '$name|$path|$hostOnly';
        bestCookies.putIfAbsent(
          key,
          () => Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry(k.toString(), v)),
          ),
        );
      }

      // 存入 CookieJar
      final bucketedCookies = <Uri, Map<String, io.Cookie>>{};
      for (final raw in bestCookies.values) {
        final name = raw['name'].toString();
        if (ctx.cookieNames != null && !ctx.cookieNames!.contains(name)) {
          continue;
        }
        final value = raw['value']?.toString() ?? '';
        final rawDomain = raw['domain']?.toString().trim();
        final hostOnly = raw['hostOnly'] == true;
        final normalizedDomain = rawDomain != null
            ? (rawDomain.startsWith('.')
                ? rawDomain.substring(1)
                : rawDomain)
            : null;

        io.Cookie cookie;
        try {
          cookie = io.Cookie(name, value);
        } catch (_) {
          cookie = io.Cookie(name, CookieValueCodec.encode(value));
        }
        cookie
          ..path = raw['path']?.toString() ?? '/'
          ..secure = raw['secure'] == true
          ..httpOnly = raw['httpOnly'] == true;

        // 只有 domain cookie（hostOnly=false）才设 domain 属性
        if (!hostOnly && normalizedDomain != null) {
          cookie.domain = '.$normalizedDomain';
        }

        final expiresRaw = raw['expires'];
        if (expiresRaw is num && expiresRaw > 0) {
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(
            (expiresRaw * 1000).round(),
          );
        }

        if (cookie.expires != null &&
            cookie.expires!.isBefore(DateTime.now())) {
          continue;
        }
        if (cookie.value.isEmpty &&
            CookieJarService.isCriticalCookie(cookie.name)) {
          continue;
        }

        final hostForUri = normalizedDomain ?? ctx.baseUri.host;
        final bucketUri = Uri(scheme: ctx.baseUri.scheme, host: hostForUri);
        final dedupeKey =
            '${cookie.name}|${cookie.path}|${cookie.domain ?? hostForUri}';
        bucketedCookies.putIfAbsent(
          bucketUri,
          () => <String, io.Cookie>{},
        )[dedupeKey] = cookie;
      }

      // 先清掉关键 cookie 旧值
      final namesAboutToSync = <String>{};
      for (final cookies in bucketedCookies.values) {
        for (final cookie in cookies.values) {
          if (CookieJarService.isCriticalCookie(cookie.name)) {
            namesAboutToSync.add(cookie.name);
          }
        }
      }
      for (final name in namesAboutToSync) {
        await jar.deleteCookie(name);
      }

      var totalSynced = 0;
      for (final entry in bucketedCookies.entries) {
        final cookies = entry.value.values.toList();
        if (cookies.isEmpty) continue;
        await jar.cookieJar.saveFromResponse(entry.key, cookies);
        totalSynced += cookies.length;
      }


      debugPrint(
        '[CookieJar][CDP] syncFromWebView(controller): $totalSynced cookies',
      );
      if (io.Platform.isWindows) {
        await CookieDiagnostics.logWindowsCookieSyncStatus(
          'syncFromWebView(controller)',
          jar: jar,
          ctx: ctx,
        );
      }
    } catch (e) {
      debugPrint(
        '[CookieJar][CDP] syncFromWebView(controller) failed: $e',
      );
    }
  }


  bool _shouldPersistWebViewDomainCookie({
    required String? rawDomain,
    required String? normalizedDomain,
    required Set<String> sourceHosts,
  }) {
    if (normalizedDomain == null) return false;
    if (rawDomain != null && rawDomain.trim().startsWith('.')) return true;
    for (final sourceHost in sourceHosts) {
      if (sourceHost != normalizedDomain &&
          sourceHost.endsWith('.$normalizedDomain')) {
        return true;
      }
    }
    return false;
  }

  String _buildJarToWebViewSyncKey(io.Cookie cookie, String sourceHost) {
    final normalizedDomain =
        CookieJarService.normalizeWebViewCookieDomain(cookie.domain) ??
        sourceHost;
    final normalizedPath = cookie.path ?? '/';
    return '${cookie.name}|$normalizedDomain|$normalizedPath';
  }

}
