import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ai_model_manager/ai_model_manager.dart';

import '../l10n/s.dart';
import '../providers/preferences_provider.dart';
import '../providers/theme_provider.dart';
import '../services/data_management/cache_size_service.dart';
import '../services/data_management/data_backup_service.dart';
import '../services/discourse_cache_manager.dart';
import '../services/network/cookie/cookie_jar_service.dart';
import '../services/toast_service.dart';

/// 数据管理页面
class DataManagementPage extends ConsumerStatefulWidget {
  const DataManagementPage({super.key});

  @override
  ConsumerState<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends ConsumerState<DataManagementPage> {
  int _imageCacheSize = -1;
  int _aiChatDataSize = -1;
  int _cookieCacheSize = -1;
  bool _isClearing = false;

  @override
  void initState() {
    super.initState();
    _loadCacheSizes();
  }

  Future<void> _loadCacheSizes() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final results = await Future.wait([
      CacheSizeService.getImageCacheSize(),
      CacheSizeService.getAiChatDataSize(prefs),
      CacheSizeService.getCookieCacheSize(),
    ]);
    if (mounted) {
      setState(() {
        _imageCacheSize = results[0];
        _aiChatDataSize = results[1];
        _cookieCacheSize = results[2];
      });
    }
  }

  int get _totalCacheSize {
    int total = 0;
    if (_imageCacheSize > 0) total += _imageCacheSize;
    if (_aiChatDataSize > 0) total += _aiChatDataSize;
    if (_cookieCacheSize > 0) total += _cookieCacheSize;
    return total;
  }

  String _formatCacheSize(int size) {
    if (size < 0) return S.current.dataManagement_calculating;
    if (size == 0) return S.current.dataManagement_noCache;
    return CacheSizeService.formatSize(size);
  }

  Future<void> _clearImageCache() async {
    setState(() => _isClearing = true);
    try {
      await Future.wait([
        DiscourseCacheManager().emptyCache(),
        EmojiCacheManager().emptyCache(),
        ExternalImageCacheManager().emptyCache(),
        StickerCacheManager().emptyCache(),
      ]);
      // emptyCache() 只清除了索引，磁盘文件可能残留，需要删除整个目录
      await CacheSizeService.deleteImageCacheDirs();
      PaintingBinding.instance.imageCache.clear();
      setState(() => _imageCacheSize = 0);
      ToastService.showSuccess(S.current.dataManagement_imageCacheCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearAiChatData() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearAiChatTitle,
      content: S.current.dataManagement_clearAiChatContent,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await AiChatStorageService(prefs).deleteAllSessions();
      setState(() => _aiChatDataSize = 0);
      ToastService.showSuccess(S.current.dataManagement_aiChatCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearCookieCache() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearCookieTitle,
      content: S.current.dataManagement_clearCookieContent,
      confirmText: S.current.dataManagement_clearAndLogout,
      isDestructive: true,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      await _doClearCookies();
      setState(() => _cookieCacheSize = 0);
      ToastService.showSuccess(S.current.dataManagement_cookieCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearAllCache() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearAllTitle,
      content: S.current.dataManagement_clearAllContent,
      confirmText: S.current.dataManagement_clearAll,
      isDestructive: true,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await Future.wait([
        DiscourseCacheManager().emptyCache(),
        EmojiCacheManager().emptyCache(),
        ExternalImageCacheManager().emptyCache(),
        StickerCacheManager().emptyCache(),
        AiChatStorageService(prefs).deleteAllSessions(),
        _doClearCookies(),
      ]);
      await CacheSizeService.deleteImageCacheDirs();
      PaintingBinding.instance.imageCache.clear();
      setState(() {
        _imageCacheSize = 0;
        _aiChatDataSize = 0;
        _cookieCacheSize = 0;
      });
      ToastService.showSuccess(S.current.dataManagement_allCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  /// 清除 Cookie 文件和内存（保留 cf_clearance）
  Future<void> _doClearCookies() async {
    final cookieJarService = CookieJarService();
    final cfClearanceCookie = await cookieJarService.getCfClearanceCookie();
    await cookieJarService.cookieJar.deleteAll();
    if (cfClearanceCookie != null) {
      await cookieJarService.restoreCfClearance(cfClearanceCookie);
    }
  }

  Future<void> _exportData() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final filePath = await DataBackupService.exportToFile(prefs);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(filePath, mimeType: 'application/json')],
          subject: S.current.dataManagement_backupSubject,
        ),
      );
    } catch (e) {
      ToastService.showError(S.current.dataManagement_exportFailed(e.toString()));
    }
  }

  Future<void> _importData() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.single.path;
      if (filePath == null) return;

      final backup = await DataBackupService.parseBackupFile(filePath);
      final data = backup['data'] as Map<String, dynamic>;
      final apiKeys = backup['apiKeys'] as Map<String, dynamic>?;
      final appVersion = backup['appVersion'] as String? ?? S.current.common_unknown;
      final exportTime = backup['exportTime'] as String? ?? S.current.common_unknown;

      if (!mounted) return;

      final details = StringBuffer()
        ..writeln(S.current.dataManagement_backupSource(appVersion))
        ..writeln(S.current.dataManagement_exportTime(exportTime))
        ..writeln(S.current.dataManagement_settingsCount(data.length));
      if (apiKeys != null && apiKeys.isNotEmpty) {
        details.writeln(S.current.dataManagement_apiKeysCount(apiKeys.length));
      }
      details.write('\n${S.current.dataManagement_importWarning}');

      final confirmed = await _showConfirmDialog(
        title: S.current.dataManagement_confirmImport,
        content: details.toString(),
        confirmText: S.current.dataManagement_importAndRestart,
      );
      if (confirmed != true) return;

      final prefs = ref.read(sharedPreferencesProvider);
      await DataBackupService.importData(prefs, backup);
      ToastService.showSuccess(S.current.dataManagement_importSuccess);
    } on FormatException catch (e) {
      ToastService.showError(e.message);
    } catch (e) {
      ToastService.showError(S.current.dataManagement_importFailed(e.toString()));
    }
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String content,
    String? confirmText,
    bool isDestructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: isDestructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirmText ?? context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preferences = ref.watch(preferencesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.dataManagement_title)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Section 1 — 缓存管理
          _buildSectionHeader(theme, Icons.cleaning_services_rounded, context.l10n.dataManagement_cacheManagement),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _buildCacheTile(
                  icon: Icons.image_rounded,
                  title: context.l10n.dataManagement_imageCache,
                  size: _imageCacheSize,
                  onClear: _isClearing ? null : _clearImageCache,
                ),
                _buildDivider(theme),
                _buildCacheTile(
                  icon: Icons.smart_toy_rounded,
                  title: context.l10n.dataManagement_aiChatData,
                  size: _aiChatDataSize,
                  onClear: _isClearing ? null : _clearAiChatData,
                ),
                _buildDivider(theme),
                _buildCacheTile(
                  icon: Icons.cookie_rounded,
                  title: context.l10n.dataManagement_cookieCache,
                  size: _cookieCacheSize,
                  onClear: _isClearing ? null : _clearCookieCache,
                ),
                _buildDivider(theme),
                ListTile(
                  leading: Icon(
                    Icons.delete_sweep_rounded,
                    color: theme.colorScheme.error,
                  ),
                  title: Text(context.l10n.dataManagement_clearAllCache),
                  subtitle: Text(_formatCacheSize(_totalCacheSize)),
                  trailing: TextButton(
                    onPressed: _isClearing || _totalCacheSize <= 0
                        ? null
                        : _clearAllCache,
                    child: Text(context.l10n.common_clear),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Section 2 — 自动管理
          _buildSectionHeader(theme, Icons.auto_delete_rounded, context.l10n.dataManagement_autoManagement),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile(
              title: Text(context.l10n.dataManagement_clearOnExit),
              subtitle: Text(context.l10n.dataManagement_clearOnExitDesc),
              secondary: Icon(
                Icons.auto_delete_rounded,
                color: preferences.clearCacheOnExit
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              value: preferences.clearCacheOnExit,
              onChanged: (value) {
                ref.read(preferencesProvider.notifier).setClearCacheOnExit(value);
              },
            ),
          ),
          const SizedBox(height: 24),

          // Section 3 — 数据备份
          _buildSectionHeader(theme, Icons.backup_rounded, context.l10n.dataManagement_dataBackup),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_rounded),
                  title: Text(context.l10n.dataManagement_exportData),
                  subtitle: Text(context.l10n.dataManagement_exportDesc),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.outline.withValues(alpha: 0.4),
                    size: 20,
                  ),
                  onTap: _exportData,
                ),
                _buildDivider(theme),
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: Text(context.l10n.dataManagement_importData),
                  subtitle: Text(context.l10n.dataManagement_importDesc),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.outline.withValues(alpha: 0.4),
                    size: 20,
                  ),
                  onTap: _importData,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildCacheTile({
    required IconData icon,
    required String title,
    required int size,
    required VoidCallback? onClear,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(_formatCacheSize(size)),
      trailing: TextButton(
        onPressed: size <= 0 ? null : onClear,
        child: Text(S.current.common_clear),
      ),
    );
  }

  Widget _buildDivider(ThemeData theme) {
    return Divider(
      height: 1,
      indent: 56,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }
}
