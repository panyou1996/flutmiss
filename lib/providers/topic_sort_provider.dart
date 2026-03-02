// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'topic_list_provider.dart';
import 'theme_provider.dart';

/// 排序模式持久化 Notifier
class TopicSortNotifier extends StateNotifier<TopicListFilter> {
  static const String _key = 'topic_sort_filter';
  final SharedPreferences _prefs;

  TopicSortNotifier(this._prefs)
      : super(_fromName(_prefs.getString(_key)));

  static TopicListFilter _fromName(String? name) {
    for (final filter in TopicListFilter.values) {
      if (filter.name == name) return filter;
    }
    return TopicListFilter.latest;
  }

  void setSort(TopicListFilter sort) {
    state = sort;
    _prefs.setString(_key, sort.name);
  }
}

/// 当前排序模式（持久化到 SharedPreferences）
final topicSortProvider =
    StateNotifierProvider<TopicSortNotifier, TopicListFilter>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return TopicSortNotifier(prefs);
});

/// 每个 tab 独立的标签筛选（categoryId -> tags）
/// null 表示"全部"tab
final tabTagsProvider = StateProvider.family<List<String>, int?>((ref, categoryId) => []);

/// 当前选中 tab 对应的分类 ID（null 表示"全部"tab）
final currentTabCategoryIdProvider = StateProvider<int?>((ref) => null);

/// 话题列表 tab 失活信号
/// refreshAll 时递增，通知非当前 tab 释放 keepAlive
final topicTabDeactivateSignal = StateProvider<int>((ref) => 0);
