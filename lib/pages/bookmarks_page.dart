import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../providers/preferences_provider.dart';
import '../providers/user_content_search_provider.dart';
import '../services/app_error_handler.dart';
import '../services/discourse/discourse_service.dart';
import '../services/toast_service.dart';
import '../utils/time_utils.dart';
import '../widgets/bookmark/bookmark_edit_sheet.dart';
import '../widgets/search/searchable_app_bar.dart';
import '../widgets/search/user_content_search_view.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/topic_preview_dialog.dart';
import '../widgets/common/error_view.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 我的书签页面
class BookmarksPage extends ConsumerStatefulWidget {
  const BookmarksPage({super.key});

  @override
  ConsumerState<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends ConsumerState<BookmarksPage> {
  final ScrollController _scrollController = ScrollController();
  late final UserContentSearchNotifier _searchNotifier;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchNotifier = ref.read(userContentSearchProvider(SearchInType.bookmarks).notifier);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // 延迟清理搜索状态，避免在 widget tree finalizing 期间修改 provider
    Future(_searchNotifier.exitSearchMode);
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(bookmarksProvider.notifier).loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await ref.read(bookmarksProvider.notifier).refresh();
  }

  void _onItemTap(Topic topic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          // 帖子书签跳转到被书签的帖子，话题书签使用最后阅读位置
          scrollToPostNumber: topic.bookmarkedPostNumber ?? topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookmarksAsync = ref.watch(bookmarksProvider);
    final searchState = ref.watch(userContentSearchProvider(SearchInType.bookmarks));

    return PopScope(
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          // 搜索模式下按返回键，退出搜索而不是退出页面
          ref.read(userContentSearchProvider(SearchInType.bookmarks).notifier).exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: SearchableAppBar(
          title: '我的书签',
          isSearchMode: searchState.isSearchMode,
          onSearchPressed: () => ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .enterSearchMode(),
          onCloseSearch: () => ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .exitSearchMode(),
          onSearch: (query) => ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .search(query),
          showFilterButton: searchState.isSearchMode,
          filterActive: searchState.filter.isNotEmpty,
          onFilterPressed: () =>
              showSearchFilterPanel(context, ref, SearchInType.bookmarks),
          searchHint: '在书签中搜索...',
        ),
        body: Stack(
          children: [
            // 使用 Offstage 保持列表存在但在搜索模式下隐藏，保留滚动位置
            Offstage(
              offstage: searchState.isSearchMode,
              child: _buildTopicList(bookmarksAsync),
            ),
            if (searchState.isSearchMode)
              const UserContentSearchView(
                inType: SearchInType.bookmarks,
                emptySearchHint: '输入关键词搜索书签',
              ),
          ],
        ),
      ),
    );
  }

  /// 卡片顶部色带：书签名称、提醒时间
  Widget? _buildBookmarkTopBar(BuildContext context, Topic topic) {
    final hasName = topic.bookmarkName != null && topic.bookmarkName!.isNotEmpty;
    final hasReminder = topic.bookmarkReminderAt != null;
    if (!hasName && !hasReminder) return null;

    final colorScheme = Theme.of(context).colorScheme;
    final isExpired = hasReminder &&
        topic.bookmarkReminderAt!.isBefore(DateTime.now());
    final bgColor = isExpired
        ? colorScheme.errorContainer.withValues(alpha: 0.5)
        : colorScheme.secondaryContainer.withValues(alpha: 0.6);
    final fgColor = isExpired
        ? colorScheme.error
        : colorScheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: bgColor,
      child: Text.rich(
        TextSpan(
          children: [
            // 书签名称
            if (hasName) ...[
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(Icons.bookmark_outlined, size: 13, color: fgColor),
              ),
              TextSpan(text: ' ${topic.bookmarkName!}'),
            ],
            // 提醒时间
            if (hasReminder) ...[
              if (hasName)
                TextSpan(
                  text: '  ·  ',
                  style: TextStyle(color: fgColor.withValues(alpha: 0.4)),
                ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(Icons.alarm, size: 13, color: fgColor),
              ),
              TextSpan(
                text: isExpired
                    ? ' 已过期'
                    : ' ${TimeUtils.formatDetailTime(topic.bookmarkReminderAt!)}',
              ),
            ],
          ],
        ),
        style: TextStyle(
          fontSize: 12,
          color: fgColor,
          height: 1.3,
        ),
      ),
    );
  }

  /// 卡片底部：摘要
  Widget? _buildBookmarkExcerpt(BuildContext context, Topic topic) {
    if (topic.excerpt == null) return null;
    final cleaned = _cleanExcerpt(topic.excerpt!);
    if (cleaned.isEmpty) return null;

    final colorScheme = Theme.of(context).colorScheme;
    return Text(
      cleaned,
      style: TextStyle(
        fontSize: 12,
        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        height: 1.4,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 清理 excerpt 中的 HTML 标签和实体
  String _cleanExcerpt(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&hellip;', '...')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  List<PreviewAction> _buildPreviewActions(Topic topic) {
    final theme = Theme.of(context);
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return [];

    return [
      PreviewAction(
        icon: Icons.edit_outlined,
        label: '编辑书签',
        color: theme.colorScheme.primary,
        onTap: () => _editBookmark(topic),
      ),
      if (topic.bookmarkReminderAt != null)
        PreviewAction(
          icon: Icons.alarm_off,
          label: '取消提醒',
          onTap: () => _clearReminder(topic),
        ),
      PreviewAction(
        icon: Icons.delete_outline,
        label: '删除书签',
        color: theme.colorScheme.error,
        onTap: () => _deleteBookmark(topic),
      ),
    ];
  }

  Future<void> _editBookmark(Topic topic) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return;

    final result = await BookmarkEditSheet.show(
      context,
      bookmarkId: bookmarkId,
      initialName: topic.bookmarkName,
      initialReminderAt: topic.bookmarkReminderAt,
    );
    if (result == null || !mounted) return;

    final notifier = ref.read(bookmarksProvider.notifier);
    if (result.deleted) {
      notifier.removeBookmarkById(bookmarkId);
    } else {
      notifier.updateBookmarkMeta(
        bookmarkId,
        name: result.name,
        reminderAt: result.reminderAt,
        clearReminderAt: result.reminderAt == null,
      );
    }
  }

  Future<void> _clearReminder(Topic topic) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return;

    try {
      await DiscourseService().clearBookmarkReminder(bookmarkId);
      if (!mounted) return;
      ref.read(bookmarksProvider.notifier).updateBookmarkMeta(
        bookmarkId,
        clearReminderAt: true,
      );
      ToastService.showSuccess('已取消提醒');
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _deleteBookmark(Topic topic) async {
    final bookmarkId = topic.bookmarkId;
    if (bookmarkId == null) return;

    try {
      await DiscourseService().deleteBookmark(bookmarkId);
      if (!mounted) return;
      ref.read(bookmarksProvider.notifier).removeBookmarkById(bookmarkId);
      ToastService.showSuccess('已删除书签');
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Widget _buildTopicList(AsyncValue<List<Topic>> bookmarksAsync) {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: bookmarksAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bookmark_border, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('暂无书签', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: topics.length + 1,
            itemBuilder: (context, index) {
              if (index == topics.length) {
                final notifier = ref.watch(bookmarksProvider.notifier);
                if (!notifier.hasMore) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(
                      child: Text(
                        '没有更多了',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  );
                }
                if (notifier.isLoadMoreFailed) {
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Center(
                      child: GestureDetector(
                        onTap: () => notifier.retryLoadMore(),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.refresh, size: 16, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 6),
                            Text(
                              '加载失败，点击重试',
                              style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.primary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
                if (bookmarksAsync.isLoading && !bookmarksAsync.hasError) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return const SizedBox();
              }

              final topic = topics[index];
              final enableLongPress = ref.watch(preferencesProvider).longPressPreview;
              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: false,
                onTap: () => _onItemTap(topic),
                enableLongPress: enableLongPress,
                topWidget: _buildBookmarkTopBar(context, topic),
                bottomWidget: _buildBookmarkExcerpt(context, topic),
                previewActions: topic.bookmarkId != null
                    ? _buildPreviewActions(topic)
                    : null,
              );
            },
          );
        },
        loading: () => const TopicListSkeleton(),
        error: (error, stack) => ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: _onRefresh,
        ),
      ),
    );
  }
}
