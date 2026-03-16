import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/network/doh/doh_resolver.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import '../../../services/toast_service.dart';

/// DOH 设置卡片（含服务器列表和测速）
class DohSettingsCard extends StatefulWidget {
  const DohSettingsCard({
    super.key,
    required this.settings,
    required this.isApplying,
    this.isSuppressedByVpn = false,
  });

  final NetworkSettings settings;
  final bool isApplying;
  final bool isSuppressedByVpn;

  @override
  State<DohSettingsCard> createState() => _DohSettingsCardState();
}

class _DohSettingsCardState extends State<DohSettingsCard> {
  final NetworkSettingsService _service = NetworkSettingsService.instance;
  final Map<String, int?> _latencies = {};
  final Set<String> _testingServers = {};
  bool _testingAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.settings;
    final isApplying = widget.isApplying;
    final proxyService = _service.proxyService;
    final isRunning = proxyService.isRunning;
    final port = settings.proxyPort;
    final showLoading = isApplying ||
        _service.pendingStart ||
        (settings.dohEnabled && !isRunning && !_service.lastStartFailed);

    return Card(
      clipBehavior: Clip.antiAlias,
      color: settings.dohEnabled
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: settings.dohEnabled
            ? BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.3))
            : BorderSide.none,
      ),
      child: Column(
        children: [
          // DOH 开关
          SwitchListTile(
            title: const Text('DNS over HTTPS'),
            subtitle: Text(
              widget.isSuppressedByVpn
                  ? '已被 VPN 自动关闭，VPN 断开后将自动恢复'
                  : settings.dohEnabled
                      ? '已启用加密 DNS 解析'
                      : '使用系统默认 DNS',
            ),
            secondary: Icon(
              settings.dohEnabled ? Icons.shield : Icons.shield_outlined,
              color: settings.dohEnabled ? theme.colorScheme.primary : null,
            ),
            value: settings.dohEnabled,
            onChanged: (value) async {
              await _service.setDohEnabled(value);
              // 用户在 VPN 活跃时手动开启，清除压制标记
              if (value && widget.isSuppressedByVpn) {
                VpnAutoToggleService.instance.clearDohSuppression();
              }
            },
          ),

          // 仅在开启 DOH 后显示以下内容
          if (settings.dohEnabled) ...[
            // 状态区域
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: showLoading
                        ? _buildStatusChip(
                            theme,
                            key: const ValueKey('applying'),
                            customIcon: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            label: _service.wasRunningBeforeApply ? '正在重启...' : '正在启动...',
                            color: theme.colorScheme.primary,
                          )
                        : _buildStatusChip(
                            theme,
                            key: ValueKey('status_${isRunning}_${_service.lastStartFailed}'),
                            icon: isRunning
                                ? Icons.check_circle
                                : _service.lastStartFailed
                                    ? Icons.error
                                    : Icons.hourglass_top,
                            label: isRunning ? '代理运行中' : '代理未启动',
                            color: isRunning ? Colors.green : theme.colorScheme.error,
                          ),
                  ),
                  const SizedBox(width: 12),
                  if (port != null && isRunning)
                    _buildStatusChip(
                      theme,
                      icon: Icons.lan,
                      label: '端口 $port',
                      color: theme.colorScheme.secondary,
                    ),
                  if (isRunning) ...[
                    const Spacer(),
                    IconButton(
                      onPressed: isApplying ? null : _service.restartProxy,
                      icon: const Icon(Icons.refresh, size: 20),
                      tooltip: '重启代理',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ],
              ),
            ),

            // 启动失败提示
            if (!isRunning && !isApplying && _service.lastStartFailed)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '代理启动失败，DoH/ECH 无法生效',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: isApplying ? null : _service.restartProxy,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                    if (proxyService.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 24, top: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                proxyService.lastError!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: proxyService.lastError!));
                                ToastService.showInfo('已复制错误信息');
                              },
                              child: Icon(
                                Icons.copy,
                                size: 14,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

            // IPv6 开关
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            SwitchListTile(
              title: const Text('IPv6 优先'),
              subtitle: const Text('优先尝试 IPv6，失败自动回落 IPv4'),
              secondary: const Icon(Icons.language),
              value: settings.preferIPv6,
              onChanged: (value) => _service.setPreferIPv6(value),
              dense: true,
            ),

            // 服务器列表标题
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Text(
                    '服务器',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _testingAll ? null : _testAllServers,
                    icon: _testingAll
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.speed, size: 16),
                    label: Text(_testingAll ? '测速中' : '全部测速'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _showAddServerDialog,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),

            // 服务器列表
            _buildServerList(theme, settings),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusChip(
    ThemeData theme, {
    Key? key,
    IconData? icon,
    Widget? customIcon,
    required String label,
    required Color color,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (customIcon != null)
            customIcon
          else if (icon != null)
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildServerList(ThemeData theme, NetworkSettings settings) {
    final servers = _service.servers;

    return RadioGroup<String>(
      groupValue: settings.selectedServerUrl,
      onChanged: (value) {
        if (value != null) _service.setSelectedServer(value);
      },
      child: Column(
        children: [
          for (int i = 0; i < servers.length; i++) ...[
            _buildServerTile(theme, servers[i], settings),
            if (i != servers.length - 1)
              Divider(
                  height: 1, indent: 56, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
          ],
          if (servers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('暂无服务器'),
            ),
        ],
      ),
    );
  }

  Widget _buildServerTile(ThemeData theme, DohServer server, NetworkSettings settings) {
    final selected = server.url == settings.selectedServerUrl;
    final isTesting = _testingServers.contains(server.url);
    final latency = _latencies[server.url];

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 12),
      leading: Radio<String>(
        value: server.url,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              server.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (server.isCustom)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '自定义',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        server.serverIp != null && server.serverIp!.isNotEmpty
            ? '${server.url}\nIP: ${server.serverIp}'
            : server.url,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 延迟显示
          if (isTesting)
            const SizedBox(
              width: 48,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (latency != null)
            SizedBox(
              width: 48,
              child: Text(
                '${latency}ms',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _getLatencyColor(latency),
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            )
          else
            SizedBox(
              width: 48,
              child: IconButton(
                icon: const Icon(Icons.speed, size: 20),
                tooltip: '测速',
                onPressed: () => _testServer(server),
                visualDensity: VisualDensity.compact,
              ),
            ),

          // 更多操作按钮
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 20, color: theme.colorScheme.onSurfaceVariant),
            tooltip: '更多',
            padding: EdgeInsets.zero,
            onSelected: (value) {
              switch (value) {
                case 'copy':
                  Clipboard.setData(ClipboardData(text: server.url));
                  ToastService.showInfo('已复制 DoH 地址');
                case 'edit':
                  _showEditServerDialog(server);
                case 'delete':
                  _confirmDeleteServer(server);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  leading: Icon(Icons.copy, size: 20),
                  title: Text('复制地址'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (server.isCustom) ...[
                const PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: Icon(Icons.edit, size: 20),
                    title: Text('编辑'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
                    title: Text('删除', style: TextStyle(color: theme.colorScheme.error)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      selected: selected,
      onTap: () => _service.setSelectedServer(server.url),
    );
  }

  Color _getLatencyColor(int latency) {
    if (latency < 100) return Colors.green;
    if (latency < 300) return Colors.orange;
    return Colors.red;
  }

  Future<void> _testServer(DohServer server) async {
    if (_testingServers.contains(server.url)) return;

    setState(() => _testingServers.add(server.url));

    final resolver = DohResolver(
      serverUrl: server.url,
      bootstrapIps: server.bootstrapIps,
      enableFallback: false,
    );
    try {
      final ms = await resolver.testLatency(_service.testHost);
      if (mounted) {
        setState(() {
          _latencies[server.url] = ms;
          _testingServers.remove(server.url);
        });
      }
    } finally {
      resolver.dispose();
    }
  }

  Future<void> _testAllServers() async {
    if (_testingAll) return;
    setState(() => _testingAll = true);

    final servers = _service.servers;
    final futures = <Future<void>>[];

    for (final server in servers) {
      futures.add(_testServer(server));
    }

    await Future.wait(futures);

    if (mounted) {
      setState(() => _testingAll = false);
    }
  }

  Future<void> _showAddServerDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final serverIpController = TextEditingController();

    final result = await showDialog<DohServer>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('添加服务器'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：My DNS',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'DoH 地址',
                  hintText: 'https://dns.example.com/dns-query',
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: serverIpController,
                decoration: const InputDecoration(
                  labelText: '服务端 IP（可选）',
                  hintText: '直接使用指定 IP 连接，跳过 DNS 解析',
                ),
                keyboardType: TextInputType.text,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final url = urlController.text.trim();
                final serverIp = serverIpController.text.trim();
                if (name.isEmpty || url.isEmpty) {
                  ToastService.showInfo('请填写完整信息');
                  return;
                }
                if (!url.startsWith('https://')) {
                  ToastService.showError('地址必须以 https:// 开头');
                  return;
                }
                Navigator.pop(
                  context,
                  DohServer(
                    name: name,
                    url: url,
                    isCustom: true,
                    serverIp: serverIp.isEmpty ? null : serverIp,
                  ),
                );
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await _service.addCustomServer(result);
    }
  }

  Future<void> _showEditServerDialog(DohServer server) async {
    final nameController = TextEditingController(text: server.name);
    final urlController = TextEditingController(text: server.url);
    final serverIpController = TextEditingController(text: server.serverIp ?? '');

    final result = await showDialog<DohServer>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('编辑服务器'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：My DNS',
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'DoH 地址',
                  hintText: 'https://dns.example.com/dns-query',
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: serverIpController,
                decoration: const InputDecoration(
                  labelText: '服务端 IP（可选）',
                  hintText: '直接使用指定 IP 连接，跳过 DNS 解析',
                ),
                keyboardType: TextInputType.text,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final url = urlController.text.trim();
                final serverIp = serverIpController.text.trim();
                if (name.isEmpty || url.isEmpty) {
                  ToastService.showInfo('请填写完整信息');
                  return;
                }
                if (!url.startsWith('https://')) {
                  ToastService.showError('地址必须以 https:// 开头');
                  return;
                }
                Navigator.pop(
                  context,
                  DohServer(
                    name: name,
                    url: url,
                    isCustom: true,
                    serverIp: serverIp.isEmpty ? null : serverIp,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await _service.updateCustomServer(server, result);
    }
  }

  Future<void> _confirmDeleteServer(DohServer server) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定要删除 "${server.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.removeCustomServer(server);
    }
  }
}
