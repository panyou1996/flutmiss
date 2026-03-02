import 'package:flutter/material.dart';
import '../../providers/topic_list_provider.dart';
import 'sort_and_tags_bar.dart';

/// 排序下拉样式
enum SortDropdownStyle {
  /// 带背景框完整版（用于排序栏）
  normal,

  /// 紧凑版 swap_vert 图标 + 文字（用于折叠状态）
  compact,
}

/// 排序下拉公共组件
class SortDropdown extends StatelessWidget {
  final TopicListFilter currentSort;
  final bool isLoggedIn;
  final ValueChanged<TopicListFilter> onSortChanged;
  final SortDropdownStyle style;

  const SortDropdown({
    super.key,
    required this.currentSort,
    required this.isLoggedIn,
    required this.onSortChanged,
    this.style = SortDropdownStyle.normal,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopupMenuButton<TopicListFilter>(
      onSelected: onSortChanged,
      offset: const Offset(0, 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tooltip: '排序: ${sortLabel(currentSort)}',
      itemBuilder: (context) {
        return sortOptions
            .where((option) => isLoggedIn || (option.$1 != TopicListFilter.newTopics && option.$1 != TopicListFilter.unread && option.$1 != TopicListFilter.unseen))
            .map((option) => PopupMenuItem<TopicListFilter>(
                  value: option.$1,
                  child: Row(
                    children: [
                      if (option.$1 == currentSort)
                        Icon(Icons.check, size: 16, color: colorScheme.primary)
                      else
                        const SizedBox(width: 16),
                      const SizedBox(width: 8),
                      Text(option.$2),
                    ],
                  ),
                ))
            .toList();
      },
      child: style == SortDropdownStyle.compact
          ? _buildCompactChild(colorScheme)
          : _buildNormalChild(colorScheme),
    );
  }

  Widget _buildNormalChild(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            sortLabel(currentSort),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.arrow_drop_down, size: 18, color: colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }

  Widget _buildCompactChild(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_vert, size: 18, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 2),
          Text(
            sortLabel(currentSort),
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
