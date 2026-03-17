import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../constants.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'local_notification_service.dart'; // 用于获取全局 navigatorKey
import 'cf_challenge_logger.dart';
import 'cf_clearance_refresh_service.dart';
import 'toast_service.dart';
import '../l10n/s.dart';
import '../widgets/draggable_floating_pill.dart';

/// CF 验证服务
/// 处理 Cloudflare Turnstile 验证（仅手动模式）
class CfChallengeService {
  static final CfChallengeService _instance = CfChallengeService._internal();
  factory CfChallengeService() => _instance;
  CfChallengeService._internal();

  bool _isVerifying = false;

  /// CF 验证是否正在进行中（用于外部判断是否应忽略路由变化）
  bool get isVerifying => _isVerifying;

  final _verifyCompleter = <Completer<bool>>[];
  BuildContext? _context;
  static DateTime? _lastToastAt;
  Completer<BuildContext>? _contextReadyCompleter;

  /// 冷却机制：连续失败 N 次后进入冷却期
  DateTime? _cooldownUntil;
  int _consecutiveFailures = 0;
  static const _cooldownDuration = Duration(seconds: 30);
  static const _maxFailuresBeforeCooldown = 3;
  static const _toastCooldown = Duration(seconds: 2);

  /// 检查是否在冷却期
  bool get isInCooldown {
    if (_cooldownUntil == null) return false;
    if (DateTime.now().isAfter(_cooldownUntil!)) {
      _cooldownUntil = null;
      return false;
    }
    return true;
  }

  /// 重置冷却期和失败计数（验证成功后调用）
  void resetCooldown() {
    _cooldownUntil = null;
    _consecutiveFailures = 0;
    CfChallengeLogger.logCooldown(entering: false);
  }

  /// 记录一次验证失败，连续达到上限后进入冷却期
  void startCooldown() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxFailuresBeforeCooldown) {
      _cooldownUntil = DateTime.now().add(_cooldownDuration);
      debugPrint('[CfChallenge] 连续失败 $_consecutiveFailures 次，进入 ${_cooldownDuration.inSeconds}s 冷却期');
      CfChallengeLogger.logCooldown(entering: true, until: _cooldownUntil);
    } else {
      debugPrint('[CfChallenge] 验证失败 $_consecutiveFailures/$_maxFailuresBeforeCooldown，允许重试');
    }
  }

  static void showGlobalMessage(String message, {bool isError = true}) {
    final now = DateTime.now();
    if (_lastToastAt != null && now.difference(_lastToastAt!) < _toastCooldown) {
      return;
    }
    _lastToastAt = now;
    if (isError) {
      ToastService.showError(message);
    } else {
      ToastService.showInfo(message);
    }
  }

  void setContext(BuildContext context) {
    _context = context;
    if (context.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      if (!_contextReadyCompleter!.isCompleted) {
        _contextReadyCompleter!.complete(context);
      }
    }
  }

  /// 检测是否是 CF 验证页面（用于 403 响应体判断）
  static bool isCfChallenge(dynamic responseData) {
    if (responseData == null) return false;
    final str = responseData.toString();
    // cf_chl_opt 是 CF 验证页面的可靠标记（challenge options JS 变量）
    if (str.contains('cf_chl_opt')) return true;
    // challenge-platform 路径需配合 cloudflare 标记，避免误匹配
    if (str.contains('challenge-platform') && str.contains('cloudflare')) {
      return true;
    }
    // "Just a moment" 需配合 CF 特征，避免误匹配用户内容
    if (str.contains('Just a moment') &&
        (str.contains('cloudflare') || str.contains('cf-challenge'))) {
      return true;
    }
    return false;
  }

  /// 检测页面 HTML 中是否有活跃的 CF 验证盾
  /// 用于判断已加载的页面是否仍在展示验证挑战
  static bool hasActiveCfChallenge(String html) {
    return html.contains('cf-turnstile') ||
        html.contains('challenge-running') ||
        html.contains('challenge-stage') ||
        html.contains('cf_chl_opt');
  }

  /// 显示手动验证页面
  /// 返回值：true=验证成功, false=验证失败, null=冷却期内暂不可用或无 context
  /// [forceForeground] 是否强制前台显示（默认为 true）
  Future<bool?> showManualVerify([BuildContext? context, bool forceForeground = true]) async {
    // 检查冷却期
    if (isInCooldown) {
      debugPrint('[CfChallenge] In cooldown, skipping manual verify');
      CfChallengeLogger.log('[VERIFY] Skipped: in cooldown');
      return null;
    }

    final verifyUrl = '${AppConstants.baseUrl}/challenge';
    CfChallengeLogger.logVerifyStart(verifyUrl);
    unawaited(CfChallengeLogger.logAccessIps(url: verifyUrl, context: 'verify_start'));

    // 尝试获取 context：传入的 > 已设置的 > 全局 navigatorKey
    BuildContext? ctx = context ?? _context;
    if (ctx == null || !ctx.mounted) {
      // 使用全局 navigatorKey 作为备用
      final navState = navigatorKey.currentState;
      if (navState != null && navState.context.mounted) {
        ctx = navState.context;
        debugPrint('[CfChallenge] Using global navigatorKey context');
      }
    }

    // 启动时可能还没有可用的 context，等到 context 可用后立即弹出
    if (ctx == null || !ctx.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      debugPrint('[CfChallenge] Waiting for context to be ready...');
      ctx = await _contextReadyCompleter!.future;
    }

    // 如果已经在验证中 (Overlay 存在)
    if (_isVerifying) {
        // 如果当前是后台模式，且请求强制前台，则提升为前台
        if (forceForeground) {
             // 找到当前的 State 并调用 promoteToForeground
             // 这里我们需要访问到 CfChallengePage 的 State
             // 由于无法直接访问，我们将通过 EventBus 或简单的 GlobalKey/Callback 机制
             // 在此简化处理：我们假设 _isVerifying 意味着正在运行
             // 实际上，如果已经在运行，我们只需返回当前的 future
             // 但我们需要通知 UI 切换到前台。
             // FIXME: 这里简单的返回 future 可能无法触发 UI 变更。
             // 由于 CfChallengeService 是单例，我们可以持有一个 key 或回调
        }

      final completer = Completer<bool>();
      _verifyCompleter.add(completer);
      return completer.future;
    }

    _isVerifying = true;

    // ignore: use_build_context_synchronously
    final overlayState = Overlay.maybeOf(ctx, rootOverlay: true) ?? navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      debugPrint('[CfChallenge] No overlay available for manual verify');
      CfChallengeLogger.log('[VERIFY] No overlay available');
      _isVerifying = false;
      return null;
    }

    // 停止自动续期服务，避免与手动验证冲突
    CfClearanceRefreshService().stop();

    // 备份旧 cf_clearance，验证失败时恢复（避免误删仍有效的值）
    final cookieJarService = CookieJarService();
    final backupCfClearance = await cookieJarService.getCfClearanceCookie();

    // Dio 请求已经 403，说明当前 cf_clearance 可能失效了。
    // 在同步到 WebView 前删除它，否则 WebView 带着旧 cf_clearance 访问
    // /challenge 时 CF 会直接放行，导致验证被跳过。
    await cookieJarService.deleteCookie('cf_clearance');
    await cookieJarService.syncToWebView();
    if (!overlayState.mounted) {
      debugPrint('[CfChallenge] Overlay no longer mounted');
      CfChallengeLogger.log('[VERIFY] Overlay not mounted');
      _isVerifying = false;
      return null;
    }

    final resultCompleter = Completer<bool>();
    late final OverlayEntry entry;
    // 引用当前的拦截 Route，用于 cleanup
    ModalRoute? interceptorRoute;

    // Page Key 用于触发内部弹窗
    final pageKey = GlobalKey<_CfChallengePageState>();

    // 清理资源
    void cleanup() {
       if (entry.mounted) {
         entry.remove();
       }
       if (interceptorRoute?.isActive ?? false) {
         interceptorRoute?.navigator?.removeRoute(interceptorRoute!);
       }
       _isVerifying = false;
    }

    void finish(bool success) {
      if (!resultCompleter.isCompleted) {
        resultCompleter.complete(success);
      }
      cleanup();
    }

    // 创建 OverlayEntry
    // 我们需要传递一个 promoteCallback 给 Page，让 Page 能调用 Service 来 push route
    void onPromoteToForeground(BuildContext pageContext) {
        if (interceptorRoute != null && interceptorRoute!.isActive) return; // 已经有 Route 了

        // Push 透明 Route 用于拦截返回键
        interceptorRoute = PageRouteBuilder(
            opaque: false,
            barrierColor: Colors.transparent,
            pageBuilder: (context, _, _) {
                 return PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, result) async {
                        if (didPop) return;
                        if (!_isVerifying) return;

                        // 触发内部弹窗 via GlobalKey
                        pageKey.currentState?.showExitConfirmation();
                    },
                    // 使用 IgnorePointer 让点击事件穿透到下层的 Overlay (WebView)
                    child: const IgnorePointer(
                      child: SizedBox.expand(),
                    ),
                 );
            },
        );

        Navigator.of(pageContext).push(interceptorRoute!).then((_) {
            // Route 被 pop
        });
    }

    entry = OverlayEntry(
      builder: (context) => CfChallengePage(
        key: pageKey,
        startInBackground: !forceForeground,
        onResult: finish,
        onPromoteRequest: () => onPromoteToForeground(context),
      ),
    );
    overlayState.insert(entry);

    // 如果初始就是前台，立即执行 promote
    if (forceForeground) {
        // Post frame callback to ensure overlay is mounted and context is valid
        WidgetsBinding.instance.addPostFrameCallback((_) {
            // 注意：这里的 ctx 是 Service 传入的 ctx，可能不是 Overlay 的 context
            // 但 Navigator.of(ctx) 应该能找到正确的 Navigator
            // 我们最好使用 OverlayEntry builder 里的 context，但这里访问不到。
            // 使用 ctx 应该是安全的。
             onPromoteToForeground(ctx!);
        });
    }

    final result = await resultCompleter.future;

    // 通知所有等待者
    for (final c in _verifyCompleter) {
      if (!c.isCompleted) c.complete(result);
    }
    _verifyCompleter.clear();

    // 验证成功后重置冷却期
    if (result == true) {
      resetCooldown();
      CfChallengeLogger.logVerifyResult(success: true, reason: 'user completed');
      // 手动验证成功后重新启动自动续期
      CfClearanceRefreshService().start();
    } else {
      // 验证失败，恢复备份的 cf_clearance（避免丢失可能仍有效的值）
      if (backupCfClearance != null) {
        await cookieJarService.restoreCfClearance(backupCfClearance);
        debugPrint('[CfChallenge] 验证失败，已恢复备份 cf_clearance');
      }
      // 验证失败，启动冷却期
      startCooldown();
      debugPrint('[CfChallenge] Verification failed, cooldown until $_cooldownUntil');
      CfChallengeLogger.logVerifyResult(success: false, reason: 'user cancelled or timeout');
    }

    return result;
  }
}

/// CF 验证页面
class CfChallengePage extends StatefulWidget {
  const CfChallengePage({
    super.key,
    this.startInBackground = false,
    this.onResult,
    this.onPromoteRequest,
  });

  /// 先后台尝试验证，超时后再切到前台
  final bool startInBackground;
  final ValueChanged<bool>? onResult;
  final VoidCallback? onPromoteRequest;

  @override
  State<CfChallengePage> createState() => _CfChallengePageState();
}

class _CfChallengePageState extends State<CfChallengePage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  double _progress = 0;
  bool _hasPopped = false; // 防止重复 pop
  late bool _isBackground;
  int _checkCount = 0;
  Timer? _timeoutTimer;
  Timer? _noChallengeCheckTimer;
  static const _backgroundMaxCheckCount = 10;
  static const _foregroundMaxCheckCount = 60;
  static const _noChallengeCheckDelay = Duration(seconds: 5);

  /// 验证页面加载时 WebView 中的 cf_clearance 快照
  /// 用于区分「旧值残留」和「验证后新设的值」
  String? _initialCfClearance;

  int get _activeMaxCheckCount =>
      _isBackground ? _backgroundMaxCheckCount : _foregroundMaxCheckCount;

  @override
  void initState() {
    super.initState();
    _isBackground = widget.startInBackground;
    _snapshotInitialClearance();
  }

  /// 记录验证开始时 WebView 中的 cf_clearance（应为空，因为 showManualVerify 已删除）
  Future<void> _snapshotInitialClearance() async {
    try {
      final cookie = await CookieManager.instance().getCookie(
        url: WebUri(AppConstants.baseUrl),
        name: 'cf_clearance',
      );
      _initialCfClearance = cookie?.value;
      if (_initialCfClearance != null && _initialCfClearance!.isNotEmpty) {
        debugPrint('[CfChallenge] ⚠️ 验证页加载时 WebView 仍存在旧 cf_clearance '
            '(${_initialCfClearance!.length} chars)，将忽略该值');
      }
    } catch (e) {
      debugPrint('[CfChallenge] 快照 cf_clearance 失败: $e');
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // JS 注入：拦截 XHR/fetch 对 cdn-cgi/challenge-platform 的响应
  // 当 challenge-platform 请求完成时，通过 JS Handler 通知 Flutter 侧
  // Flutter 侧用 CookieManager（可读 HttpOnly cookie）检查 cf_clearance
  // ---------------------------------------------------------------------------

  /// 注入 XHR/fetch 拦截脚本
  Future<void> _injectChallengeInterceptor(
      InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: '''
(function() {
  if (window._cfInterceptorInstalled) return;
  window._cfInterceptorInstalled = true;

  var CP = 'cdn-cgi/challenge-platform';

  // 拦截 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this._cfUrl = url;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    var self = this;
    if (self._cfUrl && self._cfUrl.indexOf(CP) !== -1) {
      self.addEventListener('load', function() {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', self._cfUrl, self.status);
        } catch(e) {}
      });
    }
    return origSend.apply(this, arguments);
  };

  // 拦截 fetch
  var origFetch = window.fetch;
  window.fetch = function(input, init) {
    var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
    return origFetch.apply(this, arguments).then(function(resp) {
      if (url.indexOf(CP) !== -1) {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', url, resp.status);
        } catch(e) {}
      }
      return resp;
    });
  };
})();
''');
  }

  /// challenge-platform 响应到达时的回调
  Future<void> _onChallengeComplete(List<dynamic> args) async {
    if (_hasPopped) return;
    final url = args.isNotEmpty ? args[0] : '';
    final status = args.length > 1 ? args[1] : 0;
    debugPrint('[CfChallenge] challenge-platform 响应: url=$url, status=$status');
    CfChallengeLogger.log('[VERIFY] Challenge response: url=$url, status=$status');

    try {
      // CookieManager 可读 HttpOnly cookie
      final cookie = await CookieManager.instance().getCookie(
        url: WebUri(AppConstants.baseUrl),
        name: 'cf_clearance',
      );

      if (cookie == null || cookie.value.isEmpty) {
        debugPrint('[CfChallenge] 未检测到 cf_clearance，等待后续响应');
        return;
      }

      // 关键：对比初始快照，过滤掉未被清除干净的旧值
      if (_initialCfClearance != null &&
          _initialCfClearance!.isNotEmpty &&
          cookie.value == _initialCfClearance) {
        debugPrint('[CfChallenge] cf_clearance 与初始值相同（旧值残留），忽略');
        return;
      }

      // cf_clearance 是新值，但需要确认页面已真正通过验证
      // challenge-platform 在验证过程中有多次请求（脚本加载、初始化、提交等），
      // 只有最终完成时页面才不再包含验证标记
      final html = await _controller?.evaluateJavascript(
        source: 'document.body ? document.body.innerHTML : ""',
      );
      if (html != null && CfChallengeService.hasActiveCfChallenge(html)) {
        debugPrint('[CfChallenge] 检测到新 cf_clearance 但页面仍在验证中，继续等待');
        return;
      }

      debugPrint('[CfChallenge] ✓ 验证完成：新 cf_clearance (${cookie.value.length} chars) 且页面已通过');
      CfChallengeLogger.logVerifyResult(
        success: true,
        reason: 'new cf_clearance detected and page passed challenge',
      );
      await CookieJarService().syncFromWebView();
      // 验证 cf_clearance 是否真正写入了 CookieJar
      final synced = await CookieJarService().getCfClearance();
      if (synced != null && synced.isNotEmpty) {
        debugPrint('[CfChallenge] cf_clearance 已同步到 CookieJar (${synced.length} chars)');
      } else {
        debugPrint('[CfChallenge] ⚠️ syncFromWebView 后 CookieJar 中未找到 cf_clearance');
      }
      _timeoutTimer?.cancel();
      if (mounted) _finish(true);
    } catch (e) {
      debugPrint('[CfChallenge] cookie 检查异常: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 超时计时器（兜底机制）
  // ---------------------------------------------------------------------------

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _checkCount = 0;
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _checkCount++;
      if (!_isBackground) setState(() {}); // 更新计数显示

      // 兜底轮询：验证通过后页面重定向会销毁 JS 上下文，
      // 导致 onChallengeComplete 回调丢失（macOS 上尤为明显），
      // 每秒主动检查 cf_clearance 变化来弥补
      _pollCfClearance();

      if (_checkCount > _activeMaxCheckCount) {
        if (_isBackground) {
          CfChallengeLogger.log(
              '[VERIFY] Background timeout after $_activeMaxCheckCount seconds, prompting manual verify');
          _promoteToForeground();
          return;
        }
        timer.cancel();
        CfChallengeLogger.logVerifyResult(
            success: false,
            reason: 'timeout after $_activeMaxCheckCount seconds');
        if (mounted) {
          _showError(S.current.cf_verifyTimeout);
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) _finish(false);
          });
        }
      }
    });
  }

  /// 延迟检测页面是否存在 CF 验证盾
  /// 如果页面加载完成后没有盾，快速退出避免死等超时导致循环
  void _scheduleNoChallengeCheck(InAppWebViewController controller) {
    _noChallengeCheckTimer?.cancel();
    _noChallengeCheckTimer = Timer(_noChallengeCheckDelay, () async {
      if (_hasPopped || !mounted) return;

      try {
        final html = await controller.evaluateJavascript(
          source: 'document.body ? document.body.innerHTML : ""',
        );
        if (_hasPopped) return;
        if (html == null) return;

        final hasChallenge =
            CfChallengeService.hasActiveCfChallenge(html.toString());
        if (hasChallenge) return; // 页面有盾，等待正常验证流程

        // 页面没有盾，检查是否已有新的 cf_clearance（CF 可能自动放行了）
        final cookie = await CookieManager.instance().getCookie(
          url: WebUri(AppConstants.baseUrl),
          name: 'cf_clearance',
        );
        if (_hasPopped) return;

        if (cookie != null &&
            cookie.value.isNotEmpty &&
            (_initialCfClearance == null ||
                _initialCfClearance!.isEmpty ||
                cookie.value != _initialCfClearance)) {
          debugPrint('[CfChallenge] 页面无盾但检测到新 cf_clearance，自动完成');
          CfChallengeLogger.logVerifyResult(
            success: true,
            reason: 'no challenge but new cf_clearance detected',
          );
          await CookieJarService().syncFromWebView();
          _timeoutTimer?.cancel();
          if (mounted) _finish(true);
        } else {
          // 没有盾也没有新 cookie，非 CF 验证场景，快速退出
          debugPrint('[CfChallenge] 页面无盾且无新 cf_clearance，快速退出');
          CfChallengeLogger.logVerifyResult(
            success: false,
            reason:
                'no challenge detected after ${_noChallengeCheckDelay.inSeconds}s',
          );
          _timeoutTimer?.cancel();
          if (mounted) _finish(false);
        }
      } catch (e) {
        debugPrint('[CfChallenge] 检测 challenge 状态异常: $e');
      }
    });
  }

  /// 轮询检测 cf_clearance 变化（兜底 JS 回调被重定向吞掉的场景）
  bool _polling = false;
  Future<void> _pollCfClearance() async {
    if (_hasPopped || _polling) return;
    _polling = true;
    try {
      final cookie = await CookieManager.instance().getCookie(
        url: WebUri(AppConstants.baseUrl),
        name: 'cf_clearance',
      );
      if (_hasPopped) return;
      if (cookie == null || cookie.value.isEmpty) return;

      // 与初始快照对比，过滤旧值残留
      if (_initialCfClearance != null &&
          _initialCfClearance!.isNotEmpty &&
          cookie.value == _initialCfClearance) {
        return;
      }

      debugPrint('[CfChallenge] ✓ 轮询检测到新 cf_clearance (${cookie.value.length} chars)');
      CfChallengeLogger.logVerifyResult(
        success: true,
        reason: 'polling detected new cf_clearance',
      );
      await CookieJarService().syncFromWebView();
      _timeoutTimer?.cancel();
      if (mounted) _finish(true);
    } catch (e) {
      debugPrint('[CfChallenge] 轮询检查异常: $e');
    } finally {
      _polling = false;
    }
  }

  // ---------------------------------------------------------------------------
  // UI 操作
  // ---------------------------------------------------------------------------

  bool _showExitDialog = false;
  bool _showHelpDialog = false;

  Future<void> showExitConfirmation() async {
     if (!mounted) return;
     setState(() {
       _showExitDialog = true;
     });
  }

  void _dismissExitConfirmation() {
    if (!mounted) return;
    setState(() {
      _showExitDialog = false;
    });
  }

  void _confirmExit() {
    if (!mounted) return;
    _finish(false);
  }

  void _refresh() {
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _checkCount = 0;
    setState(() {
      _isLoading = true;
      _progress = 0;
    });
    _controller?.reload();
  }

  void _promoteToForeground() {
    if (!_isBackground) return;
    setState(() {
      _isBackground = false;
      _checkCount = 0;
    });
    widget.onPromoteRequest?.call();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showInfo(S.current.cf_autoVerifyTimeout);
    });
  }

  void _finish(bool success) {
    if (_hasPopped) return;
    _hasPopped = true;
    _timeoutTimer?.cancel();
    final handler = widget.onResult;
    if (handler != null) {
      handler(success);
    } else {
      Navigator.of(context).pop(success);
    }
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ToastService.showInfo(message);
  }

  void _showHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = true;
    });
  }

  void _dismissHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ToastService.showError(message);
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showUi = !_isBackground;

    return Stack(
      children: [
        // 内容层：显示 WebView UI
        IgnorePointer(
          ignoring: _isBackground || _showExitDialog,
          child: Opacity(
            opacity: _isBackground ? 0 : 1,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: showUi
                  ? AppBar(
                      title: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.l10n.cf_securityVerifyTitle),
                          if (_checkCount > 0)
                            Text(
                              context.l10n.cf_verifying(_checkCount),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      leading: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: showExitConfirmation,
                      ),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _refresh,
                          tooltip: context.l10n.common_refresh,
                        ),
                        IconButton(
                          icon: const Icon(Icons.help_outline),
                          onPressed: _showHelp,
                          tooltip: context.l10n.common_help,
                        ),
                      ],
                    )
                  : null,
              body: Column(
                children: [
                  if (showUi && _isLoading)
                    LinearProgressIndicator(
                      value: _progress > 0 ? _progress : null,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        IgnorePointer(
                          ignoring: _isBackground,
                          child: InAppWebView(
                            initialUrlRequest: URLRequest(
                                url: WebUri('${AppConstants.baseUrl}/challenge')),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              userAgent: AppConstants.userAgent,
                              mediaPlaybackRequiresUserGesture: false,
                            ),
                            onWebViewCreated: (controller) {
                              _controller = controller;
                              // 注册 JS Handler，challenge-platform 响应到达时触发
                              controller.addJavaScriptHandler(
                                handlerName: 'onChallengeComplete',
                                callback: _onChallengeComplete,
                              );
                            },
                            onLoadStart: (controller, url) {
                              setState(() {
                                _isLoading = true;
                                _progress = 0;
                              });
                            },
                            onProgressChanged: (controller, progress) {
                              _progress = progress / 100;
                              if (showUi) {
                                setState(() {});
                              }
                            },
                            onLoadStop: (controller, url) {
                              if (mounted) {
                                setState(() => _isLoading = false);
                              }
                              // 注入 XHR/fetch 拦截脚本
                              _injectChallengeInterceptor(controller);
                              _startTimeout();
                              // 延迟检测页面是否存在 CF 验证盾，无盾则快速退出
                              _scheduleNoChallengeCheck(controller);
                            },
                            onReceivedError: (controller, request, error) {
                              if (mounted) {
                                setState(() => _isLoading = false);
                              }
                              if (showUi) {
                                _showError(context.l10n.cf_loadFailed(error.description));
                              }
                            },
                          ),
                        ),

                        // 警告卡片
                        if (showUi &&
                            _checkCount > _activeMaxCheckCount - 10 &&
                            _checkCount <= _activeMaxCheckCount)
                          Positioned(
                            bottom: 16,
                            left: 16,
                            right: 16,
                            child: Card(
                              color: theme.colorScheme.errorContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.warning_amber_rounded,
                                      color: theme.colorScheme.onErrorContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        context.l10n.cf_verifyLonger(_activeMaxCheckCount - _checkCount),
                                        style: TextStyle(
                                          color: theme.colorScheme.onErrorContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 内部弹窗层
        if (_showExitDialog)
           Stack(
             children: [
                GestureDetector(
                  onTap: _dismissExitConfirmation,
                  child: Container(
                    color: Colors.black54,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
                Center(
                  child: AlertDialog(
                    title: Text(context.l10n.cf_abandonVerifyTitle),
                    content: Text(context.l10n.cf_abandonVerifyMessage),
                    actions: [
                      TextButton(
                        onPressed: _dismissExitConfirmation,
                        child: Text(context.l10n.cf_continueVerify),
                      ),
                      TextButton(
                        onPressed: _confirmExit,
                        child: Text(
                          context.l10n.common_exit,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
             ],
           ),

        if (_showHelpDialog)
          Stack(
            children: [
              GestureDetector(
                onTap: _dismissHelp,
                child: Container(
                  color: Colors.black54,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              Center(
                child: AlertDialog(
                  title: Text(context.l10n.cf_helpTitle),
                  content: Text(context.l10n.cf_helpContent),
                  actions: [
                    TextButton(
                      onPressed: _dismissHelp,
                      child: Text(context.l10n.common_gotIt),
                    ),
                  ],
                ),
              ),
            ],
          ),

        // 悬浮验证胶囊
        if (_isBackground)
          DraggableFloatingPill(
            initialTop: 100,
            onTap: _promoteToForeground,
            child: Text(S.current.cf_backgroundVerifying),
          ),
      ],
    );
  }
}
