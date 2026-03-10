import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/preloaded_data_service.dart';
import '../services/discourse/discourse_service.dart';
import '../services/emoji_handler.dart';
import '../services/log/log_writer.dart';
import '../pages/network_settings_page/network_settings_page.dart';
import '../utils/error_utils.dart';
import '../widgets/common/error_view.dart';

class PreheatGate extends StatefulWidget {
  final Widget child;

  const PreheatGate({super.key, required this.child});

  @override
  State<PreheatGate> createState() => _PreheatGateState();
}

class _PreheatGateState extends State<PreheatGate> {
  late Future<bool> _loadFuture;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadFuture = _preload();
  }

  Future<bool> _preload() async {
    try {
      await PreloadedDataService().ensureLoaded();

      DiscourseService().getEnabledReactions();
      EmojiHandler().init();

      _error = null;
      return true;
    } catch (e) {
      debugPrint('[PreheatGate] Preload failed: $e');
      _error = e;
      return false;
    }
  }

  void _retry() {
    setState(() {
      _loadFuture = _preload();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _loadFuture,
      builder: (context, snapshot) {
        // 无论加载状态如何，都设置 context
        // 避免 CF 验证等待 context 而 context 等待加载完成导致的死锁
        PreloadedDataService().setNavigatorContext(context);

        Widget currentWidget;
        if (snapshot.connectionState != ConnectionState.done) {
          currentWidget = const _PreheatLoading(key: ValueKey('loading'));
        } else if (snapshot.data == true) {
          currentWidget = KeyedSubtree(
            key: const ValueKey('content'),
            child: widget.child,
          );
        } else {
          currentWidget = _PreheatFailed(
            key: const ValueKey('error'),
            error: _error,
            onRetry: _retry,
          );
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeOut,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.95, end: 1.0).animate(animation),
                child: child,
              ),
            );
          },
          child: currentWidget,
        );
      },
    );
  }
}

class _PreheatLoading extends StatefulWidget {
  const _PreheatLoading({super.key});

  @override
  State<_PreheatLoading> createState() => _PreheatLoadingState();
}

class _PreheatLoadingState extends State<_PreheatLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );

    _fadeAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Opacity(
                        opacity: _fadeAnimation.value,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: colorScheme.primary.withValues(alpha: 0.15),
                                blurRadius: 40,
                                spreadRadius: 0,
                              ),
                            ],
                          ),
                          child: SvgPicture.asset(
                            'assets/logo.svg',
                            width: 100,
                            height: 100,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 32),
                Text(
                  'FluxDO',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 48),
                 SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: colorScheme.primary.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),

        ],
      ),
    );
  }
}

class _PreheatFailed extends StatelessWidget {
  final VoidCallback onRetry;
  final Object? error;

  const _PreheatFailed({super.key, required this.onRetry, this.error});

  void _openNetworkSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const NetworkSettingsPage()),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？退出后将清除本地登录信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      // 记录主动退出日志（网络错误页面）
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'lifecycle',
        'event': 'logout_active',
        'message': '用户主动退出登录（预热失败页面）',
      });
      await DiscourseService().logout(callApi: false, refreshPreload: false);
      onRetry();
    }
  }

  void _showErrorDetails(BuildContext context) {
    final details = ErrorUtils.getErrorDetails(error, null);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ErrorDetailsSheet(details: details),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final errorInfo = ErrorUtils.getErrorInfo(error);
    final buttonStyle = IconButton.styleFrom(
      backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            // 右上角：网络设置 + 退出登录
            Positioned(
              top: 16,
              right: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.network_check_rounded),
                    tooltip: '网络设置',
                    style: buttonStyle,
                    onPressed: () => _openNetworkSettings(context),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.logout_rounded),
                    tooltip: '退出登录',
                    style: buttonStyle,
                    onPressed: () => _confirmLogout(context),
                  ),
                ],
              ),
            ),
            // 居中内容
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        errorInfo.icon,
                        size: 48,
                        color: colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      errorInfo.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      errorInfo.message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),
                    FilledButton.tonalIcon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                      label: const Text('重试连接'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _showErrorDetails(context),
                      icon: const Icon(Icons.info_outline_rounded, size: 20),
                      label: const Text('查看详情'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}