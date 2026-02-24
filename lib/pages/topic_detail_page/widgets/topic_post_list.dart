import 'package:flutter/material.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../../../models/topic.dart';
import '../../../providers/message_bus_providers.dart';
import '../../../services/toast_service.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/post/post_item/post_item.dart';
import '../../../widgets/post/post_item_skeleton.dart';
import 'topic_detail_header.dart';
import 'typing_indicator.dart';

/// 话题帖子列表
/// 负责构建 CustomScrollView 及其 Slivers
///
/// Before-center 和 after-center 帖子使用 SliverList.builder 实现虚拟化：
/// Flutter 会在 item 离开 viewport + cacheExtent 范围时自动 dispose 对应 widget，
/// 释放视频播放器、WebView 等资源。
/// 长帖子内部的 HTML 分块由 ChunkedHtmlContent 的 Column + SelectionArea 处理，
/// 保留跨块文本选择能力。
class TopicPostList extends StatefulWidget {
  final TopicDetail detail;
  final AutoScrollController scrollController;
  final GlobalKey centerKey;
  final GlobalKey headerKey;
  final int? highlightPostNumber;
  final List<TypingUser> typingUsers;
  final bool isLoggedIn;
  final bool hasMoreBefore;
  final bool hasMoreAfter;
  final bool isLoadingPrevious;
  final bool isLoadingMore;
  final int centerPostIndex;
  final int? dividerPostIndex;
  final void Function(int postNumber) onFirstVisiblePostChanged;
  final void Function(Set<int> visiblePostNumbers)? onVisiblePostsChanged;
  final void Function(int postNumber) onJumpToPost;
  final void Function(Post? replyToPost) onReply;
  final void Function(Post post) onEdit;
  final void Function(Post post)? onShareAsImage;
  final void Function(int postId) onRefreshPost;
  final void Function(int, bool) onVoteChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool Function(ScrollNotification) onScrollNotification;

  const TopicPostList({
    super.key,
    required this.detail,
    required this.scrollController,
    required this.centerKey,
    required this.headerKey,
    required this.highlightPostNumber,
    required this.typingUsers,
    required this.isLoggedIn,
    required this.hasMoreBefore,
    required this.hasMoreAfter,
    required this.isLoadingPrevious,
    required this.isLoadingMore,
    required this.centerPostIndex,
    required this.dividerPostIndex,
    required this.onFirstVisiblePostChanged,
    this.onVisiblePostsChanged,
    required this.onJumpToPost,
    required this.onReply,
    required this.onEdit,
    this.onShareAsImage,
    required this.onRefreshPost,
    required this.onVoteChanged,
    this.onNotificationLevelChanged,
    this.onSolutionChanged,
    required this.onScrollNotification,
  });

  @override
  State<TopicPostList> createState() => _TopicPostListState();
}

class _TopicPostListState extends State<TopicPostList> {
  int? _lastReportedPostNumber;
  bool _isThrottled = false;

  @override
  void initState() {
    super.initState();
    // 首帧渲染后触发一次可见性检测，确保进入页面时即上报阅读状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateFirstVisiblePost();
      }
    });
  }

  // 便捷 getter，简化 widget.xxx 访问
  TopicDetail get detail => widget.detail;
  AutoScrollController get scrollController => widget.scrollController;
  GlobalKey get centerKey => widget.centerKey;
  GlobalKey get headerKey => widget.headerKey;
  int? get highlightPostNumber => widget.highlightPostNumber;
  List<TypingUser> get typingUsers => widget.typingUsers;
  bool get isLoggedIn => widget.isLoggedIn;
  bool get hasMoreBefore => widget.hasMoreBefore;
  bool get hasMoreAfter => widget.hasMoreAfter;
  bool get isLoadingPrevious => widget.isLoadingPrevious;
  bool get isLoadingMore => widget.isLoadingMore;
  int get centerPostIndex => widget.centerPostIndex;
  int? get dividerPostIndex => widget.dividerPostIndex;
  void Function(int postNumber) get onJumpToPost => widget.onJumpToPost;
  void Function(Post? replyToPost) get onReply => widget.onReply;
  void Function(Post post) get onEdit => widget.onEdit;
  void Function(Post post)? get onShareAsImage => widget.onShareAsImage;
  void Function(int postId) get onRefreshPost => widget.onRefreshPost;
  void Function(int, bool) get onVoteChanged => widget.onVoteChanged;
  void Function(TopicNotificationLevel)? get onNotificationLevelChanged => widget.onNotificationLevelChanged;
  void Function(int postId, bool accepted)? get onSolutionChanged => widget.onSolutionChanged;
  bool Function(ScrollNotification) get onScrollNotification => widget.onScrollNotification;
  void Function(Set<int> visiblePostNumbers)? get onVisiblePostsChanged => widget.onVisiblePostsChanged;

  /// 检测当前可见帖子（Eyeline 机制）
  ///
  /// 参考 Discourse 官方实现（post-stream-viewport-tracker.js）的 eyeline 算法：
  /// Eyeline 是一条虚拟水平线，代表用户"正在看"的位置。
  /// - 大部分滚动过程中，eyeline 固定在视口顶部，当前帖子即顶部帖子
  /// - 接近底部的最后一个视口距离内，eyeline 逐渐从顶部移向底部
  /// - 滚到最底时，eyeline 在视口底部，确保能显示最后一个帖子
  /// 这使得进度指示器在整个滚动过程中平滑过渡，无需硬编码特殊情况。
  void _updateFirstVisiblePost() {
    final posts = detail.postStream.posts;
    if (posts.isEmpty) return;

    final tagMap = scrollController.tagMap;
    if (tagMap.isEmpty) return;

    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    final viewportHeight = position.viewportDimension;

    // 视口可见区域的上下边界
    final topBoundary = kToolbarHeight + MediaQuery.of(context).padding.top;
    final bottomBoundary = viewportHeight;

    // === 计算 eyeline 位置 ===
    double eyeline;
    if (hasMoreAfter) {
      // 还有更多帖子未加载，eyeline 固定在顶部（标准行为）
      eyeline = topBoundary;
    } else {
      // 所有帖子已加载，根据滚动进度动态计算 eyeline
      final remainingScroll = position.maxScrollExtent - position.pixels;
      final totalScrollRange = position.maxScrollExtent - position.minScrollExtent;
      // eyeline 在最后一个视口距离内从顶部过渡到底部
      final scrollableArea = viewportHeight.clamp(0.0, totalScrollRange);
      final progress = scrollableArea > 0
          ? (1 - (remainingScroll / scrollableArea).clamp(0.0, 1.0))
          : 1.0;
      eyeline = topBoundary + progress * (bottomBoundary - topBoundary);
    }

    // === 找到 eyeline 所在的帖子并收集可见帖子 ===
    int? eyelinePostIndex;
    final visiblePostNumbers = <int>{};
    double closestDistance = double.infinity;
    int? closestPostIndex;

    for (final entry in tagMap.entries) {
      final postIndex = entry.key;
      if (postIndex >= posts.length) continue;

      final ctx = entry.value.context;
      if (!ctx.mounted) continue;

      final renderBox = ctx.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) continue;

      final topY = renderBox.localToGlobal(Offset.zero).dy;
      final bottomY = topY + renderBox.size.height;

      // 收集可见帖子（帖子与视口有交集）
      if (topY < viewportHeight && bottomY > topBoundary) {
        visiblePostNumbers.add(posts[postIndex].postNumber);
      }

      // 帖子包含 eyeline → 即为当前帖子
      if (topY <= eyeline && bottomY > eyeline) {
        eyelinePostIndex = postIndex;
      }

      // 记录距 eyeline 最近的帖子（兜底用）
      final distance = topY > eyeline
          ? topY - eyeline
          : (bottomY < eyeline ? eyeline - bottomY : 0.0);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestPostIndex = postIndex;
      }
    }

    // 没有帖子包含 eyeline 时（如处于帖子间隙或底部留白），取最近的帖子
    eyelinePostIndex ??= closestPostIndex;

    // 通知可见帖子变化（用于 screenTrack）
    if (visiblePostNumbers.isNotEmpty) {
      onVisiblePostsChanged?.call(visiblePostNumbers);
    }

    if (eyelinePostIndex != null) {
      final reportPostNumber = posts[eyelinePostIndex].postNumber;

      // 防止重复报告相同的帖子
      if (reportPostNumber != _lastReportedPostNumber) {
        _lastReportedPostNumber = reportPostNumber;
        widget.onFirstVisiblePostChanged(reportPostNumber);
      }
    }
  }

  /// 处理滚动通知，同时更新可见帖子
  bool _handleScrollNotification(ScrollNotification notification) {
    // 先调用原有的滚动通知处理
    final result = onScrollNotification(notification);

    // 在滚动更新时检测可见帖子（节流 16ms）
    if (notification is ScrollUpdateNotification && !_isThrottled) {
      _isThrottled = true;
      Future.delayed(const Duration(milliseconds: 16), () {
        if (mounted) {
          _isThrottled = false;
          _updateFirstVisiblePost();
        }
      });
    }

    return result;
  }

  /// 在大屏上为内容添加宽度约束
  Widget _wrapContent(BuildContext context, Widget child) {
    if (Responsive.isMobile(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.maxContentWidth),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posts = detail.postStream.posts;
    final hasFirstPost = posts.isNotEmpty && posts.first.postNumber == 1;

    final loadMoreSkeletonCount = calculateSkeletonCount(
      MediaQuery.of(context).size.height * 0.4,
      minCount: 2,
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: CustomScrollView(
          controller: scrollController,
          center: centerKey,
          cacheExtent: 500,
          physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
          slivers: [
          // 向上加载骨架屏
          if (hasMoreBefore && isLoadingPrevious)
            LoadingSkeletonSliver(
              itemCount: loadMoreSkeletonCount,
              wrapContent: _wrapContent,
            ),

          // 话题 Header（centerPostIndex > 0 时放在 before-center 区域）
          if (hasFirstPost && centerPostIndex > 0)
            SliverToBoxAdapter(
              child: _wrapContent(
                context,
                TopicDetailHeader(
                  detail: detail,
                  headerKey: headerKey,
                  onVoteChanged: onVoteChanged,
                  onNotificationLevelChanged: onNotificationLevelChanged,
                ),
              ),
            ),

          // Before-center 帖子（SliverList.builder 实现虚拟化回收）
          // center 之前的 sliver 向上增长，index 0 离 center 最近，需要反转映射
          if (centerPostIndex > 0)
            SliverList.builder(
              itemCount: centerPostIndex,
              itemBuilder: (context, index) {
                final postIndex = centerPostIndex - 1 - index;
                return _buildPostItem(context, theme, posts[postIndex], postIndex);
              },
            ),

          // 中心帖子 + after-center 帖子（合并为一个 SliverList.builder）
          // SliverList 不会回收最后一个 child，所以必须合并，确保 center 帖子
          // 是多 item 列表中的一项，滚出视口后能被正常回收。
          // centerPostIndex == 0 且有 header 时，用 SliverMainAxisGroup 将
          // header 和帖子列表组合为 center，保证 header 默认可见。
          if (centerPostIndex == 0 && hasFirstPost)
            SliverMainAxisGroup(
              key: centerKey,
              slivers: [
                SliverToBoxAdapter(
                  child: _wrapContent(
                    context,
                    TopicDetailHeader(
                      detail: detail,
                      headerKey: headerKey,
                      onVoteChanged: onVoteChanged,
                      onNotificationLevelChanged: onNotificationLevelChanged,
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: posts.length,
                  itemBuilder: (context, index) =>
                      _buildPostItem(context, theme, posts[index], index),
                ),
              ],
            )
          else
            SliverList.builder(
              key: centerKey,
              itemCount: posts.length - centerPostIndex,
              itemBuilder: (context, index) {
                final postIndex = centerPostIndex + index;
                return _buildPostItem(context, theme, posts[postIndex], postIndex);
              },
            ),

          // 正在输入指示器（始终占位，通过 AnimatedSize 平滑过渡避免列表抖动）
          if (!hasMoreAfter)
            SliverToBoxAdapter(
              child: _wrapContent(
                context,
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: TypingAvatars(users: typingUsers),
                ),
              ),
            ),

          // 底部加载骨架屏
          if (hasMoreAfter && isLoadingMore)
            LoadingSkeletonSliver(
              itemCount: loadMoreSkeletonCount,
              wrapContent: _wrapContent,
            ),
          SliverPadding(
            padding: EdgeInsets.only(bottom: 80 + MediaQuery.of(context).padding.bottom),
          ),
        ],
      ),
    );
  }

  /// 构建单个帖子 Widget（供 SliverList.builder 的 itemBuilder 使用）
  Widget _buildPostItem(BuildContext context, ThemeData theme, Post post, int postIndex) {
    final showDivider = dividerPostIndex == postIndex;

    return _wrapContent(
      context,
      AutoScrollTag(
        key: ValueKey('post-${post.postNumber}'),
        controller: scrollController,
        index: postIndex,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showDivider)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                child: Text(
                  '上次看到这里',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            PostItem(
              post: post,
              topicId: detail.id,
              highlight: highlightPostNumber == post.postNumber,
              isTopicOwner: detail.createdBy?.username == post.username,
              topicHasAcceptedAnswer: detail.hasAcceptedAnswer,
              acceptedAnswerPostNumber: detail.acceptedAnswerPostNumber,
              onLike: () => ToastService.showInfo('点赞功能开发中...'),
              onReply: isLoggedIn ? () => onReply(post.postNumber == 1 ? null : post) : null,
              onEdit: isLoggedIn && post.canEdit ? () => onEdit(post) : null,
              onShareAsImage: onShareAsImage != null ? () => onShareAsImage!(post) : null,
              onRefreshPost: onRefreshPost,
              onJumpToPost: onJumpToPost,
              onSolutionChanged: onSolutionChanged,
            ),
          ],
        ),
      ),
    );
  }
}
