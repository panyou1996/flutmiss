import 'dart:async';
import 'dart:io';

import 'package:catcher_2/catcher_2.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'pages/topics_page.dart';
import 'pages/topics_screen.dart';
import 'pages/profile_page.dart';
import 'providers/discourse_providers.dart';
import 'providers/locale_provider.dart';
import 'providers/message_bus_providers.dart';
import 'services/discourse/discourse_service.dart';
import 'providers/app_state_refresher.dart';
import 'services/highlighter_service.dart';
import 'widgets/common/smart_avatar.dart';
import 'widgets/common/notification_icon_button.dart';
import 'services/network/cookie/cookie_sync_service.dart';
import 'services/network/cookie/cookie_jar_service.dart';
import 'services/network/adapters/cronet_fallback_service.dart';
import 'services/local_notification_service.dart';
import 'services/data_management/cache_size_service.dart';
import 'services/discourse_cache_manager.dart';
import 'services/toast_service.dart';
import 'l10n/s.dart';

import 'services/preloaded_data_service.dart';
import 'services/network/doh/network_settings_service.dart';
import 'services/network/proxy/proxy_settings_service.dart';
import 'services/network/rhttp/rhttp_settings_service.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'services/network/vpn_auto_toggle_service.dart';
import 'services/network/doh_proxy/proxy_certificate.dart';
import 'services/cf_challenge_logger.dart';
import 'services/cf_clearance_refresh_service.dart';
import 'services/update_service.dart';
import 'services/update_checker_helper.dart';
import 'services/deep_link_service.dart';
import 'services/background/background_notification_service.dart';
import 'services/message_bus_service.dart';
import 'services/connectivity_service.dart';
import 'services/log/json_file_handler.dart';
import 'services/log/log_writer.dart';
import 'services/log/logger_utils.dart';
import 'services/download_service.dart';
import 'services/navigation/app_route_observer.dart';
import 'services/window_state_service.dart';
import 'services/windows_webview_environment_service.dart';
import 'models/user.dart';
import 'constants.dart';
import 'providers/connectivity_provider.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_model_manager/ai_model_manager.dart';
import 'services/network/adapters/platform_adapter.dart';
import 'providers/preferences_provider.dart';
import 'providers/theme_provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'widgets/preheat_gate.dart';
import 'widgets/onboarding_gate.dart';
import 'widgets/layout/adaptive_scaffold.dart';
import 'widgets/layout/adaptive_navigation.dart';
import 'widgets/notification/notification_quick_panel.dart';
import 'widgets/read_later/read_later_bubble.dart';
import 'providers/read_later_provider.dart';

/// 初始化 rhttp Rust runtime
Future<bool> _initRhttp() async {
  await rhttp.Rhttp.init();
  return true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 启用 Edge-to-Edge 模式（小白条沉浸式）
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // 初始化语法高亮服务（预热 Isolate Worker 和字体）
  HighlighterService.instance.initialize(); // 不需要 await，后台初始化

  // 初始化本地通知服务（请求权限）
  LocalNotificationService().initialize(); // 不需要 await，后台初始化

  // 阶段 1：并行执行所有不相互依赖的初始化
  final futures = <Future<dynamic>>[
    SharedPreferences.getInstance(),
    AppConstants.initUserAgent(),
    LogWriter.init(),
    ProxyCertificate.initialize(),
    if (Platform.isWindows)
      WindowsWebViewEnvironmentService.instance.initialize(),
    CookieJarService().initialize(),
    CookieSyncService().init(),
    BackgroundNotificationService().initialize(),
  ];
  // 桌面平台初始化 window_manager 和 flutter_acrylic
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    futures.add(windowManager.ensureInitialized());
    futures.add(acrylic.Window.initialize());
  }
  final results = await Future.wait(futures);
  final prefs = results[0] as SharedPreferences;

  // 桌面平台：恢复窗口状态后再显示，避免默认位置闪烁
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await acrylic.Window.setEffect(
      effect: Platform.isMacOS
          ? acrylic.WindowEffect.sidebar
          : Platform.isWindows
          ? acrylic.WindowEffect.mica
          : acrylic.WindowEffect.transparent,
    );
    final isVisible = await windowManager.isVisible();
    await windowManager.setPreventClose(true);
    if (isVisible) {
      await WindowStateService.instance.attach(prefs);
    } else {
      await windowManager.waitUntilReadyToShow(null, () async {
        await WindowStateService.instance.restore(prefs);
      });
    }
  }

  // 阶段 2：依赖 prefs 的步骤并行
  final crashlyticsEnabled = prefs.getBool('pref_crashlytics') ?? false;
  await Future.wait([
    CfChallengeLogger.setEnabled(prefs.getBool('developer_mode') ?? false),
    CronetFallbackService.instance.initialize(prefs),
    ProxySettingsService.instance.initialize(prefs),
    if (Platform.isAndroid && crashlyticsEnabled)
      const MethodChannel(
        'com.github.lingyan000.fluxdo/crashlytics',
      ).invokeMethod('setCrashlyticsEnabled', {'enabled': true}),
  ]);
  // rhttp (Rust reqwest) 初始化：在 ProxySettingsService 之后、NetworkSettingsService 之前
  await RhttpSettingsService.instance.initialize(prefs);
  try {
    final rhttp = await Future.any([
      _initRhttp(),
      Future.delayed(const Duration(seconds: 5), () => false),
    ]);
    if (rhttp != true) {
      debugPrint('[rhttp] 初始化超时或失败');
      await RhttpSettingsService.instance.forceDisable();
    }
  } catch (e) {
    debugPrint('[rhttp] 初始化异常: $e');
    await RhttpSettingsService.instance.forceDisable();
  }

  await NetworkSettingsService.instance.initialize(prefs);
  VpnAutoToggleService.instance.initialize(prefs);
  try {
    final initialConnectivity = await Connectivity().checkConnectivity();
    await VpnAutoToggleService.instance.syncInitialState(initialConnectivity);
  } catch (e) {
    debugPrint('[Main] 初始 VPN 状态同步失败: $e');
  }

  // 初始化下载服务（依赖网络栈已就绪）
  DownloadService().initialize();

  // 冷启动自动清除图片缓存（如果用户开启了该选项）
  if (prefs.getBool('pref_clear_cache_on_exit') == true) {
    Future.wait([
      DiscourseCacheManager().emptyCache(),
      EmojiCacheManager().emptyCache(),
      ExternalImageCacheManager().emptyCache(),
    ]).then((_) => CacheSizeService.deleteImageCacheDirs()).ignore();
  }

  // 应用竖屏锁定设置（仅移动端）
  if (Platform.isIOS || Platform.isAndroid) {
    final portraitLock = prefs.getBool('pref_portrait_lock') ?? false;
    if (portraitLock) {
      PreferencesNotifier.isPortraitLocked = true;
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  // 提前触发预加载数据请求，与 runApp 并行执行
  // PreheatGate 中的 ensureLoaded() 会复用这个已在进行的请求
  PreloadedDataService().ensureLoaded().ignore();

  // 记录应用启动日志
  LogWriter.instance.write({
    'timestamp': DateTime.now().toIso8601String(),
    'level': 'info',
    'type': 'lifecycle',
    'event': 'app_start',
    'message': '应用启动',
  });

  // 清理过期日志（14 天前）
  LoggerUtils.cleanExpiredLogs().ignore();

  // 注入 AI 模型管理包的消息提示实现
  AiToastDelegate.configure((message, {type = AiToastType.info}) {
    switch (type) {
      case AiToastType.success:
        ToastService.showSuccess(message);
      case AiToastType.error:
        ToastService.showError(message);
      case AiToastType.info:
        ToastService.showInfo(message);
    }
  });

  // 根据当前语言配置 AI 模型管理包的语言
  final savedLocale = prefs.getString('pref_locale');
  if (savedLocale != null && savedLocale != 'system') {
    final parts = savedLocale.split('_');
    AiL10n.configureLocale(
      Locale(parts[0], parts.length > 1 ? parts[1] : null),
    );
  }

  // 过滤 Flutter 框架已知 bug（https://github.com/flutter/flutter/issues/115787）
  // SelectionArea + CustomScrollView 拖选时触发的断言错误，仅 debug 模式出现
  bool filterKnownFrameworkBugs(Report report) {
    final error = report.error;
    if (error is AssertionError &&
        error.message?.toString().contains(
              'Drag target size is larger than scrollable size',
            ) ==
            true) {
      return false;
    }
    return true;
  }

  // 配置 Catcher2 全局异常捕获
  final debugConfig = Catcher2Options(
    SilentReportMode(),
    [ConsoleHandler(), JsonFileHandler()],
    handlerTimeout: 10000,
    filterFunction: filterKnownFrameworkBugs,
  );
  final releaseConfig = Catcher2Options(
    SilentReportMode(),
    [JsonFileHandler()],
    handlerTimeout: 10000,
    filterFunction: filterKnownFrameworkBugs,
  );

  Catcher2(
    navigatorKey: navigatorKey,
    rootWidget: ProviderScope(
      // 禁用 Riverpod 3 默认的自动重试机制
      // 默认会对所有失败的异步 provider 指数退避重试 10 次，
      // 在网络不通时会造成大量无意义的重复请求
      retry: (_, _) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        aiSharedPreferencesProvider.overrideWithValue(prefs),
        aiDioAdapterFactoryProvider.overrideWithValue(
          createExternalHttpAdapter,
        ),
      ],
      child: const MainApp(),
    ),
    debugConfig: debugConfig,
    releaseConfig: releaseConfig,
    profileConfig: releaseConfig,
    enableLogger: kDebugMode,
  );
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        ColorScheme lightScheme;
        ColorScheme darkScheme;

        if (themeState.useDynamicColor &&
            lightDynamic != null &&
            darkDynamic != null) {
          // Optimization: Use standard ColorScheme.fromSeed with the dynamic primary color
          // This ensures better contrast and consistency than using the raw OEM scheme
          lightScheme = ColorScheme.fromSeed(
            seedColor: lightDynamic.primary,
            brightness: Brightness.light,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: darkDynamic.primary,
            brightness: Brightness.dark,
          );
        } else {
          lightScheme = ColorScheme.fromSeed(
            seedColor: themeState.seedColor,
            brightness: Brightness.light,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: themeState.seedColor,
            brightness: Brightness.dark,
          );
        }

        return MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [appRouteObserver],
          title: 'FluxDO',
          locale: ref.watch(localeProvider),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          themeMode: themeState.mode,
          theme: ThemeData(
            colorScheme: lightScheme,
            useMaterial3: true,
            fontFamily: themeState.fontFamilyName,
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              color: lightScheme.surfaceContainerLow,
              margin: EdgeInsets.zero,
            ),
          ),
          darkTheme: ThemeData(
            colorScheme: darkScheme,
            useMaterial3: true,
            fontFamily: themeState.fontFamilyName,
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              color: darkScheme.surfaceContainerLow,
              margin: EdgeInsets.zero,
            ),
          ),
          builder: (context, child) {
            final brightness = Theme.of(context).brightness;
            final iconBrightness = brightness == Brightness.light
                ? Brightness.dark
                : Brightness.light;
            // 桌面平台：跟随应用主题明暗切换窗口效果
            if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
              final isDark = brightness == Brightness.dark;
              acrylic.Window.setEffect(
                effect: Platform.isMacOS
                    ? acrylic.WindowEffect.sidebar
                    : Platform.isWindows
                    ? acrylic.WindowEffect.mica
                    : acrylic.WindowEffect.transparent,
                dark: isDark,
              );
              if (Platform.isMacOS) {
                acrylic.Window.overrideMacOSBrightness(dark: isDark);
              }
            }
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: iconBrightness,
                systemNavigationBarIconBrightness: iconBrightness,
                systemNavigationBarColor: Colors.transparent,
                // Android 28 上 dividerColor 不能完全透明，用 withAlpha(1) 兼容
                systemNavigationBarDividerColor: Colors.transparent.withAlpha(
                  1,
                ),
                // 关闭系统自动 scrim，实现完全沉浸
                systemNavigationBarContrastEnforced: false,
              ),
              child: Stack(
                fit: StackFit.passthrough,
                children: [child!, const ReadLaterBubble()],
              ),
            );
          },
          home: const OnboardingGate(child: PreheatGate(child: MainPage())),
        );
      },
    );
  }
}

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  ProviderSubscription<AsyncValue<String>>? _authErrorSub;
  ProviderSubscription<AsyncValue<void>>? _authStateSub;
  ProviderSubscription<AsyncValue<User?>>? _currentUserSub;
  ProviderSubscription<void>? _messageBusSub;
  ProviderSubscription<void>? _notificationChannelSub;
  ProviderSubscription<void>? _notificationAlertChannelSub;
  ProviderSubscription<AsyncValue<bool>>? _connectivitySub;
  bool _messageBusInitialized = false;
  int? _lastTappedIndex;
  DateTime? _lastTapTime;
  Timer? _resumeDebounceTimer;
  DateTime? _lastBackPressTime;

  static const _profilePage = ProfilePage();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      WindowStateService.instance.startListening();
    }

    // 设置导航 context（用于 CF 验证弹窗）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 标记应用已就绪（MainPage 在 PreheatGate 之后才挂载）
      ref.read(appReadyProvider.notifier).state = true;
      DiscourseService().setNavigatorContext(context);
      PreloadedDataService().setNavigatorContext(context);

      // 初始化 Deep Link 服务
      DeepLinkService.instance.initialize(context);

      // 自动检查更新
      _autoCheckUpdate();
    });
    // 监听登录失效事件
    _authErrorSub = ref.listenManual<AsyncValue<String>>(authErrorProvider, (
      _,
      next,
    ) {
      next.whenData((message) => _handleAuthError(message));
    });

    // 初始化连通性检测服务
    ConnectivityService().init();

    // 全局监听连接状态变化，弹 Toast 通知用户
    _connectivitySub = ref.listenManual<AsyncValue<bool>>(isConnectedProvider, (
      prev,
      next,
    ) {
      final wasConnected = prev?.value ?? true;
      final isNow = next.value;
      if (isNow == false && wasConnected) {
        ToastService.showError(S.current.toast_networkDisconnected);
      } else if (isNow == true && prev?.value == false) {
        ToastService.showSuccess(S.current.toast_networkRestored);
      }
    });

    _authStateSub = ref.listenManual<AsyncValue<void>>(authStateProvider, (
      _,
      next,
    ) {
      next.whenData((_) {
        if (mounted) {
          AppStateRefresher.refreshAll(ref);
        }
      });
    });
    _currentUserSub = ref.listenManual<AsyncValue<User?>>(currentUserProvider, (
      _,
      next,
    ) {
      final user = next.value;
      if (user != null && !_messageBusInitialized) {
        _messageBusInitialized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _messageBusSub?.close();
          _messageBusSub = ref.listenManual<void>(
            messageBusInitProvider,
            (_, _) {},
          );
          _notificationChannelSub?.close();
          _notificationChannelSub = ref.listenManual<void>(
            notificationChannelProvider,
            (_, _) {},
          );
          _notificationAlertChannelSub?.close();
          _notificationAlertChannelSub = ref.listenManual<void>(
            notificationAlertChannelProvider,
            (_, _) {},
          );
        });
      } else if (user == null) {
        _messageBusInitialized = false;
        _messageBusSub?.close();
        _messageBusSub = null;
        _notificationChannelSub?.close();
        _notificationChannelSub = null;
        _notificationAlertChannelSub?.close();
        _notificationAlertChannelSub = null;
      }
    }, fireImmediately: true);
  }

  Future<void> _autoCheckUpdate() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final updateService = UpdateService(prefs: prefs);
    await UpdateCheckerHelper.checkUpdateOnStartup(context, updateService);
  }

  void _onDestinationSelected(int index) {
    final now = DateTime.now();
    final isDoubleTap =
        _lastTappedIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!).inMilliseconds < 300;

    if (isDoubleTap && index == _currentIndex) {
      // 双击当前 tab，滚动到顶部
      if (index == 0) {
        ref.read(scrollToTopProvider.notifier).trigger();
      }
      _lastTappedIndex = null;
      _lastTapTime = null;
    } else {
      _lastTappedIndex = index;
      _lastTapTime = now;
      if (index != _currentIndex) {
        // 切换 tab 时重置底栏可见性
        ref.read(barVisibilityProvider.notifier).state = 1.0;
        setState(() => _currentIndex = index);
      }
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      WindowStateService.instance.stopListening();
    }
    WidgetsBinding.instance.removeObserver(this);
    _resumeDebounceTimer?.cancel();
    _authErrorSub?.close();
    _authStateSub?.close();
    _currentUserSub?.close();
    _messageBusSub?.close();
    _notificationChannelSub?.close();
    _notificationAlertChannelSub?.close();
    _connectivitySub?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.hidden) {
      // hidden 比 paused 更早触发，在系统挂起 Dart isolate 之前启动前台服务
      // 取消待执行的 resume 操作（防止配置变更等假 resume）
      _resumeDebounceTimer?.cancel();
      _resumeDebounceTimer = null;
      _enterBackground();
      CfClearanceRefreshService().pause();
    } else if (state == AppLifecycleState.resumed) {
      // 延迟执行，避免系统配置变更（主题切换等）触发的假 resume
      _resumeDebounceTimer?.cancel();
      _resumeDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        _resumeDebounceTimer = null;
        // App 回到前台 — 停止后台保活 + 恢复所有频道 + 刷新通知
        BackgroundNotificationService().disable();
        MessageBusService().exitBackgroundMode();
        ref.invalidate(notificationListProvider);
        // 回到前台时主动检查连通性（等同 Discourse 的 visibilitychange）
        ConnectivityService().check();
        // 恢复 cf_clearance 自动续期监控
        CfClearanceRefreshService().resume();
      });
    }
  }

  /// App 进入后台：先启动前台服务保活，再切换到只轮询通知频道
  Future<void> _enterBackground() async {
    // 清除 Flutter 图片内存缓存，降低后台内存占用
    PaintingBinding.instance.imageCache.clear();

    try {
      final user = ref.read(currentUserProvider).value;
      if (user != null) {
        // 先启动前台服务，确保进程不被杀死
        await BackgroundNotificationService().enable(user.id);
      }
      // 服务就绪后再切换轮询模式
      MessageBusService().enterBackgroundMode();
    } catch (e) {
      // 自签名应用可能不支持 BGTaskScheduler，静默忽略
      debugPrint('[MainPage] 进入后台失败: $e');
    }
  }

  Future<void> _handleAuthError(String message) async {
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(S.current.auth_loginExpiredTitle),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );

    if (mounted) {
      await AppStateRefresher.resetForLogout(ref);
    }
    if (mounted) {
      setState(() => _currentIndex = 0);
      Navigator.of(context).popUntil((route) => route.isFirst);
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听当前用户状态
    final currentUserAsync = ref.watch(currentUserProvider);
    final user = currentUserAsync.value;

    // 首页的 FAB 由 TopicsScreen 内部处理，避免切换时闪烁
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        if (NotificationQuickPanel.isVisible) {
          NotificationQuickPanel.dismiss();
          return;
        }
        final now = DateTime.now();
        if (_lastBackPressTime != null &&
            now.difference(_lastBackPressTime!).inMilliseconds < 2000) {
          SystemNavigator.pop();
        } else {
          _lastBackPressTime = now;
          ToastService.showInfo(S.current.toast_pressAgainToExit);
        }
      },
      child: AdaptiveScaffold(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: _buildDestinations(user),
        railBottomLeading: user != null ? const NotificationIconButton() : null,
        body: IndexedStack(
          index: _currentIndex,
          children: [
            TopicsScreen(isActive: _currentIndex == 0),
            _profilePage,
          ],
        ),
      ),
    );
  }

  List<AdaptiveDestination> _buildDestinations(User? user) {
    final avatarUrl = user?.getAvatarUrl();
    final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;
    final avatarWidget = hasAvatar
        ? SmartAvatar(
            imageUrl: avatarUrl,
            radius: 12,
            fallbackText: user?.username,
          )
        : null;

    return [
      AdaptiveDestination(
        icon: const Icon(Icons.home_outlined),
        selectedIcon: const Icon(Icons.home),
        label: S.current.nav_home,
      ),
      AdaptiveDestination(
        icon: avatarWidget ?? const Icon(Icons.person_outline),
        selectedIcon: avatarWidget ?? const Icon(Icons.person),
        label: S.current.nav_mine,
      ),
    ];
  }
}
