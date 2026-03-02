import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_providers.dart';
import 'notification_list_provider.dart';
import 'topic_list_provider.dart';
import 'topic_sort_provider.dart';
import 'pinned_categories_provider.dart';
import 'user_content_providers.dart';
import 'category_provider.dart';
import 'message_bus/notification_providers.dart';
import 'message_bus/topic_tracking_providers.dart';
import 'ldc_providers.dart';
import 'cdk_providers.dart';

class AppStateRefresher {
  AppStateRefresher._();

  static void refreshAll(WidgetRef ref) {
    for (final refresh in _refreshers) {
      refresh(ref);
    }
  }

  static Future<void> resetForLogout(WidgetRef ref) async {
    ref.read(topicSortProvider.notifier).setSort(TopicListFilter.latest);
    refreshAll(ref);
    // 清理各 tab 的标签筛选
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    ref.read(tabTagsProvider(null).notifier).state = [];
    for (final id in pinnedIds) {
      ref.read(tabTagsProvider(id).notifier).state = [];
    }
    ref.read(activeCategorySlugsProvider.notifier).reset();
    await ref.read(ldcUserInfoProvider.notifier).disable();
    await ref.read(cdkUserInfoProvider.notifier).disable();
  }

  static final List<void Function(WidgetRef ref)> _refreshers = [
    (ref) => ref.invalidate(currentUserProvider),
    (ref) => ref.invalidate(userSummaryProvider),
    (ref) => ref.invalidate(notificationListProvider),
    (ref) => ref.invalidate(categoriesProvider),
    (ref) => ref.invalidate(tagsProvider),
    (ref) => ref.invalidate(canTagTopicsProvider),
    (ref) {
      final activeSlugs = ref.read(activeCategorySlugsProvider);
      for (final slug in activeSlugs) {
        ref.invalidate(categoryTopicsProvider(slug));
      }
    },
    (ref) => ref.invalidate(browsingHistoryProvider),
    (ref) => ref.invalidate(bookmarksProvider),
    (ref) => ref.invalidate(myTopicsProvider),
    (ref) => ref.invalidate(topicTrackingStateMetaProvider),
    (ref) => ref.invalidate(notificationCountStateProvider),
    (ref) => ref.invalidate(notificationChannelProvider),
    (ref) => ref.invalidate(notificationAlertChannelProvider),
    (ref) => ref.invalidate(latestChannelProvider),
    (ref) => ref.invalidate(messageBusInitProvider),
    (ref) => ref.invalidate(ldcUserInfoProvider),
    (ref) => ref.invalidate(cdkUserInfoProvider),
    // 当前 tab 立即 invalidate；非当前 tab 先释放 keepAlive，
    // 延迟到下一帧 widget 被销毁后再 invalidate，避免触发请求
    (ref) {
      final currentSort = ref.read(topicSortProvider);
      final currentCategoryId = ref.read(currentTabCategoryIdProvider);
      ref.invalidate(topicListProvider((currentSort, currentCategoryId)));

      ref.read(topicTabDeactivateSignal.notifier).state++;

      final pinnedIds = ref.read(pinnedCategoriesProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final sort in TopicListFilter.values) {
          for (final categoryId in [null, ...pinnedIds]) {
            if (sort == currentSort && categoryId == currentCategoryId) continue;
            ref.invalidate(topicListProvider((sort, categoryId)));
          }
        }
      });
    },
  ];
}
