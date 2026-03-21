import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../constants.dart';
import '../adapters/platform_adapter.dart';
import 'app_cookie_manager.dart';
import 'cookie_jar_service.dart';
import '../../storage/resilient_secure_storage.dart';

/// Cookie 同步服务
/// 管理 CSRF token，支持自动刷新（对齐 Discourse 官方前端策略）
class CookieSyncService {
  static final CookieSyncService _instance = CookieSyncService._internal();
  factory CookieSyncService() => _instance;
  CookieSyncService._internal();

  static const String _csrfTokenKey = 'linux_do_csrf_token';

  final ResilientSecureStorage _storage = ResilientSecureStorage();

  String? _csrfToken;
  Dio? _mainSiteDio;

  /// 正在进行的 CSRF 刷新请求（防止并发重复请求，与 Discourse 前端的 activeCsrfRequest 对齐）
  Future<void>? _activeCsrfRequest;

  String? get csrfToken => _csrfToken;

  /// 初始化：从本地存储恢复 CSRF token
  Future<void> init() async {
    final raw = await _storage.read(key: _csrfTokenKey);
    if (raw != null && raw.isNotEmpty) {
      _csrfToken = raw;
    }
  }

  void setCsrfToken(String? token) {
    if (token == null || token.isEmpty) return;
    _csrfToken = token;
    unawaited(_storage.write(key: _csrfTokenKey, value: token));
  }

  /// 清空 CSRF token（BAD CSRF 时调用，下次 POST 前会自动刷新）
  void clearCsrfToken() {
    _csrfToken = null;
    unawaited(_storage.delete(key: _csrfTokenKey));
  }

  /// 从主站 /session/csrf 获取新的 CSRF token
  /// 带去重：多个并发调用共享同一个请求（对齐 Discourse 前端的 updateCsrfToken）
  Future<void> updateCsrfToken() {
    _activeCsrfRequest ??= _fetchCsrfToken().whenComplete(() {
      _activeCsrfRequest = null;
    });
    return _activeCsrfRequest!;
  }

  Future<Dio> _getMainSiteDio() async {
    if (_mainSiteDio != null) return _mainSiteDio!;

    final cookieJarService = CookieJarService();
    if (!cookieJarService.isInitialized) {
      await cookieJarService.initialize();
    }

    final dio = Dio(
      BaseOptions(
        baseUrl: AppConstants.baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
      ),
    );

    configurePlatformAdapter(dio);
    dio.interceptors.add(AppCookieManager(cookieJarService.cookieJar));
    _mainSiteDio = dio;
    return dio;
  }

  Future<void> _fetchCsrfToken() async {
    try {
      final dio = await _getMainSiteDio();
      final response = await dio.get(
        '/session/csrf',
        options: Options(
          extra: {
            'skipCsrf': true,
            'skipAuthCheck': true,
            'isSilent': true,
            'skipScheduler': true, // 绕过并发调度，避免与调用方的并发槽位死锁
          },
        ),
      );
      final csrf = (response.data as Map<String, dynamic>?)?['csrf'] as String?;
      if (csrf != null && csrf.isNotEmpty) {
        setCsrfToken(csrf);
        debugPrint('[CookieSyncService] CSRF token 已刷新');
      }
    } catch (e) {
      debugPrint('[CookieSyncService] CSRF token 刷新失败: $e');
    }
  }

  /// 重置（登出时调用）
  Future<void> reset() async {
    _csrfToken = null;
    await _storage.delete(key: _csrfTokenKey);
  }
}
