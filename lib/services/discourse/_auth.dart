part of 'discourse_service.dart';

/// 认证相关
mixin _AuthMixin on _DiscourseServiceBase {
  /// 初始化拦截器
  void _initInterceptors() {
    // 设置 PreloadedDataService 的登录失效回调
    PreloadedDataService().setAuthInvalidCallback(() {
      _handleAuthInvalid('登录已失效，请重新登录');
    });

    // 添加业务特定拦截器
    _dio.interceptors.insert(0, InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (!_credentialsLoaded) {
          await _loadStoredCredentials();
          _credentialsLoaded = true;
        }

        if (_tToken != null && _tToken!.isNotEmpty) {
          options.headers['Discourse-Logged-In'] = 'true';
          options.headers['Discourse-Present'] = 'true';
        }

        debugPrint('[DIO] ${options.method} ${options.uri}');
        handler.next(options);
      },
      onResponse: (response, handler) async {
        final skipAuthCheck = response.requestOptions.extra['skipAuthCheck'] == true;

        final loggedOut = response.headers.value('discourse-logged-out');
        if (!skipAuthCheck && loggedOut != null && loggedOut.isNotEmpty && !_isLoggingOut) {
          await AuthLogService().logAuthInvalid(
            source: 'response_header',
            reason: 'discourse-logged-out',
            extra: {
              'method': response.requestOptions.method,
              'url': response.requestOptions.uri.toString(),
              'statusCode': response.statusCode,
              'responseHeaders': response.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
              'requestHeaders': response.requestOptions.headers,
            },
          );
          await _handleAuthInvalid('登录已失效，请重新登录');
          return handler.next(response);
        }

        final tToken = await _cookieJar.getTToken();
        if (tToken != null && tToken.isNotEmpty) {
          _tToken = tToken;
        }

        final username = response.headers.value('x-discourse-username');
        if (username != null && username.isNotEmpty && username != _username) {
          _username = username;
          _storage.write(key: DiscourseService._usernameKey, value: username);
        }

        debugPrint('[DIO] ${response.statusCode} ${response.requestOptions.uri}');
        handler.next(response);
      },
      onError: (error, handler) async {
        final skipAuthCheck = error.requestOptions.extra['skipAuthCheck'] == true;
        final data = error.response?.data;
        debugPrint('[DIO] Error: ${error.response?.statusCode}');

        final loggedOut = error.response?.headers.value('discourse-logged-out');
        if (!skipAuthCheck && loggedOut != null && loggedOut.isNotEmpty && !_isLoggingOut) {
          await AuthLogService().logAuthInvalid(
            source: 'error_response_header',
            reason: 'discourse-logged-out',
            extra: {
              'method': error.requestOptions.method,
              'url': error.requestOptions.uri.toString(),
              'statusCode': error.response?.statusCode,
              'responseHeaders': error.response?.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
              'requestHeaders': error.requestOptions.headers,
              'errorMessage': error.message,
            },
          );
          await _handleAuthInvalid('登录已失效，请重新登录');
          return handler.next(error);
        }

        if (!skipAuthCheck && data is Map && data['error_type'] == 'not_logged_in') {
          await AuthLogService().logAuthInvalid(
            source: 'error_response',
            reason: data['error_type']?.toString() ?? 'not_logged_in',
            extra: {
              'method': error.requestOptions.method,
              'url': error.requestOptions.uri.toString(),
              'statusCode': error.response?.statusCode,
              'errors': data['errors'],
              'responseHeaders': error.response?.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
              'requestHeaders': error.requestOptions.headers,
              'errorMessage': error.message,
            },
          );
          final message = (data['errors'] as List?)?.first?.toString() ?? '登录已失效，请重新登录';
          await _handleAuthInvalid(message);
        }

        handler.next(error);
      },
    ));
  }

  /// 设置导航 context
  void setNavigatorContext(BuildContext context) {
    _cfChallenge.setContext(context);
  }

  Future<void> _handleAuthInvalid(String message) async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;
    await logout(callApi: false, refreshPreload: true);
    _isLoggingOut = false;
    _authErrorController.add(message);
  }

  /// 检查是否已登录
  Future<bool> isLoggedIn() async {
    final tToken = await _cookieJar.getTToken();
    if (tToken == null || tToken.isEmpty) return false;
    _tToken = tToken;
    _username = await _storage.read(key: DiscourseService._usernameKey);
    return true;
  }

  /// 登录成功后更新内存状态并通知监听者。
  /// Cookie 写入由 syncFromWebView() 统一处理。
  void onLoginSuccess(String tToken) {
    _tToken = tToken;
    _credentialsLoaded = false;
    _authStateController.add(null);
  }

  /// 保存用户名
  Future<void> saveUsername(String username) async {
    _username = username;
    await _storage.write(key: DiscourseService._usernameKey, value: username);
  }

  /// 登出
  Future<void> logout({bool callApi = true, bool refreshPreload = true}) async {
    if (callApi) {
      final usernameForLogout = _username ?? await _storage.read(key: DiscourseService._usernameKey);
      try {
        if (usernameForLogout != null && usernameForLogout.isNotEmpty) {
          await _dio.delete('/session/$usernameForLogout');
        }
      } catch (e) {
        debugPrint('[DiscourseService] Logout API failed: $e');
      }
    }

    _tToken = null;
    _username = null;
    _cachedUserSummary = null;
    _cachedUserSummaryUsername = null;
    _userSummaryCacheTime = null;
    await _storage.delete(key: DiscourseService._usernameKey);
    currentUserNotifier.value = null;
    await _cookieSync.reset();
    _credentialsLoaded = false;

    PreloadedDataService().reset();
    // 保留 cf_clearance 避免清除 cookie 后触发 Cloudflare 盾
    final cfClearanceCookie = await _cookieJar.getCfClearanceCookie();
    await _cookieJar.clearAll();
    if (cfClearanceCookie != null) {
      await _cookieJar.restoreCfClearance(cfClearanceCookie);
    }

    if (refreshPreload) {
      await PreloadedDataService().refresh();
    }
    _authStateController.add(null);
  }
}
