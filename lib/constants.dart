import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ua_client_hints/ua_client_hints.dart';
import 'config/site_customization.dart';
import 'config/sites/linuxdo.dart';
import 'services/windows_webview_environment_service.dart';

/// 应用常量
class AppConstants {
  /// 当前站点自定义配置
  static final SiteCustomization siteCustomization = linuxdoCustomization;

  /// 是否启用 WebView Cookie 同步（启动时预热 WebView）
  /// 设为 false 时，不使用 WebView 同步，Cookie 由 Dio Set-Cookie 与本地存储维护
  static const bool enableWebViewCookieSync = false;

  /// 缓存的 User-Agent
  static String? _cachedUserAgent;
  static final Completer<String> _uaCompleter = Completer<String>();
  static bool _uaInitialized = false;

  /// 缓存的 Client Hints 请求头（仅移动端可用）
  static Map<String, String>? _cachedClientHints;

  /// 初始化 User-Agent（应用启动时调用一次）
  /// 获取 WebView 的真实 UA 并移除 wv 标识（解决 Google 登录问题）
  static Future<void> initUserAgent() async {
    if (_uaInitialized) return;
    _uaInitialized = true;

    if (Platform.isWindows || Platform.isLinux) {
      try {
        final runtimeUa = await _getDesktopWebViewUserAgent();
        if (runtimeUa != null && runtimeUa.isNotEmpty) {
          _cachedUserAgent = runtimeUa;
          debugPrint(
            '[AppConstants] Desktop WebView runtime UA: $_cachedUserAgent',
          );
        } else {
          _cachedUserAgent = _buildDefaultUserAgent();
          debugPrint(
            '[AppConstants] Desktop WebView runtime UA 为空，使用内置默认 UA: '
            '$_cachedUserAgent',
          );
        }
      } catch (e) {
        debugPrint('[AppConstants] 获取 Desktop WebView UA 失败: $e');
        _cachedUserAgent = _buildDefaultUserAgent();
      }
      _uaCompleter.complete(_cachedUserAgent!);
      await _initClientHints();
      return;
    }

    try {
      // 移动端 / macOS 尝试获取 WebView 的真实 UA，确保 UA 与 WebView 能力匹配
      final webViewUA = await InAppWebViewController.getDefaultUserAgent();
      // 清理 UA，使其看起来像普通浏览器
      _cachedUserAgent = _sanitizeUserAgent(webViewUA);
      debugPrint('[AppConstants] WebView UA: $webViewUA');
      debugPrint('[AppConstants] Sanitized UA: $_cachedUserAgent');
    } catch (e) {
      debugPrint('[AppConstants] 获取 WebView UA 失败: $e');
      _cachedUserAgent = _buildDefaultUserAgent();
    }
    _uaCompleter.complete(_cachedUserAgent!);

    // 初始化 Client Hints（仅 Android/iOS）
    await _initClientHints();
  }

  static Future<String?> _getDesktopWebViewUserAgent() async {
    if (Platform.isWindows) {
      await WindowsWebViewEnvironmentService.instance.initialize();
    }

    HeadlessInAppWebView? headlessWebView;
    final completer = Completer<String?>();

    try {
      headlessWebView = HeadlessInAppWebView(
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialData: InAppWebViewInitialData(
          data: '<!DOCTYPE html><html><head></head><body></body></html>',
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          isInspectable: false,
        ),
        onLoadStop: (controller, url) async {
          if (completer.isCompleted) return;
          try {
            final result = await controller.evaluateJavascript(
              source: 'navigator.userAgent',
            );
            completer.complete(result?.toString());
          } catch (e) {
            debugPrint(
              '[AppConstants] 读取 WebView navigator.userAgent 失败: $e',
            );
            completer.complete(null);
          }
        },
        onReceivedError: (controller, request, error) {
          if (!completer.isCompleted) {
            debugPrint(
              '[AppConstants] WebView UA 页面加载失败: ${error.description}',
            );
            completer.complete(null);
          }
        },
      );

      await headlessWebView.run();
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[AppConstants] 获取 Desktop WebView UA 超时');
          return null;
        },
      );
    } finally {
      await headlessWebView?.dispose();
    }
  }

  /// 初始化 User-Agent Client Hints 请求头
  /// ua_client_hints 仅支持 Android/iOS，桌面端跳过
  static Future<void> _initClientHints() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final hints = await userAgentClientHintsHeader();
      // 移除包自带的 User-Agent（我们用自己清理过的）
      hints.remove('User-Agent');
      _cachedClientHints = hints;
      debugPrint('[AppConstants] Client Hints: $_cachedClientHints');
    } catch (e) {
      debugPrint('[AppConstants] 获取 Client Hints 失败: $e');
    }
  }

  /// 获取缓存的 Client Hints 请求头（可能为 null）
  static Map<String, String>? get clientHints => _cachedClientHints;

  /// 清理 WebView UA，使其看起来像普通浏览器，以通过 Google OAuth 检测
  ///
  /// Android: 移除 "; wv" 标识及变体
  /// iOS: 补充缺失的 Version/x.x 和 Safari/xxx 字段
  /// macOS: 移除可能的嵌入式 WebView 标记
  static String _sanitizeUserAgent(String ua) {
    var sanitized = ua;

    if (Platform.isAndroid) {
      // Android: 移除 wv 标识的各种变体
      // 常见格式: "; wv)"  ";wv)"  "; wv;"  "wv; " 等
      sanitized = sanitized.replaceAll(RegExp(r'[;\s]*\bwv\b[;\s]*(?=\))'), '');
    }

    if (Platform.isIOS && !sanitized.contains('Safari/')) {
      // iOS WKWebView UA 缺少 Version/x.x 和 Safari/xxx
      // Google 通过此特征检测 WebView 并拒绝 OAuth 登录
      //
      // WKWebView: "... (KHTML, like Gecko) Mobile/15E148"
      // Safari:    "... (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
      //
      // 真实 Safari 的 Version/ 只有 major.minor 两段，
      // 不跟 iOS 的补丁号（iOS 18_3_2 → Version/18.3）

      // 提取 iOS 主版本号和次版本号（仅取前两段）
      final versionMatch = RegExp(
        r'CPU (?:iPhone )?OS (\d+)[_\.](\d+)',
      ).firstMatch(sanitized);
      final version = versionMatch != null
          ? '${versionMatch.group(1)}.${versionMatch.group(2)}'
          : '18.0';

      // iOS Safari/ 固定为 604.1（自 iOS 11 起冻结，不随系统版本变化）
      const safariBuild = '604.1';

      // 在 Mobile/ 前插入 Version/x.x
      sanitized = sanitized.replaceFirstMapped(
        RegExp(r'Mobile/'),
        (m) => 'Version/$version ${m.group(0)}',
      );
      sanitized = '$sanitized Safari/$safariBuild';
    }

    if (Platform.isMacOS) {
      // macOS WKWebView 可能包含 "Safari" 但缺少版本号，
      // 或包含非标准标记，这里做基本清理
      // 移除可能的 Electron/Chromium 嵌入标记
      sanitized = sanitized.replaceAll(RegExp(r'\s*Electron/[\d.]+'), '');
    }

    return sanitized;
  }

  /// 异步获取 User-Agent
  static Future<String> getUserAgent() async {
    if (_cachedUserAgent != null) return _cachedUserAgent!;
    if (!_uaInitialized) await initUserAgent();
    return _uaCompleter.future;
  }

  /// 同步获取 User-Agent（需确保已初始化，否则返回默认值）
  static String get userAgent => _cachedUserAgent ?? _buildDefaultUserAgent();

  /// WebView 内核层面的 UA 覆写。
  ///
  /// Windows 不再强行覆写 WebView UA，让底层 WebView2
  /// 使用自己的原生默认值，避免验证页基于 UA/能力特征出现不一致。
  static String? get webViewUserAgentOverride {
    // Windows/Linux 桌面端不覆写 WebView UA，让底层引擎使用原生默认值，
    // 避免 UA 与引擎能力指纹不一致被 CF 等检测到
    if (Platform.isWindows || Platform.isLinux) {
      return null;
    }
    return userAgent;
  }

  /// 构建默认 User-Agent（降级方案）
  /// 版本号对齐 Chrome 131 (2024.11)，避免过旧被 Cloudflare 等拦截
  static String _buildDefaultUserAgent() {
    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1';
    }
    if (Platform.isWindows) {
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
    }
    if (Platform.isMacOS) {
      // macOS 底层是 WKWebView (WebKit)，使用 Safari 风格的 UA 与引擎匹配
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Safari/605.1.15';
    }
    return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  }

  /// linux.do 域名
  static const String baseUrl = String.fromEnvironment(
    'FLUXDO_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  /// 请求首页时是否跳过 X-CSRF-Token（用于预热）
  static const bool skipCsrfForHomeRequest = true;
}
