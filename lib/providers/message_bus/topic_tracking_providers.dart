import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/message_bus_service.dart';
import '../discourse_providers.dart';
import 'message_bus_service_provider.dart';

/// 话题追踪状态元数据 Provider（MessageBus 频道初始 message ID）
final topicTrackingStateMetaProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getPreloadedTopicTrackingMeta();
});

/// MessageBus 初始化 Notifier
/// 统一管理所有频道的批量订阅，避免串行等待
class MessageBusInitNotifier extends Notifier<void> {
  final Map<String, MessageBusCallback> _allCallbacks = {};
  
  @override
  void build() {
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;
    final metaAsync = ref.watch(topicTrackingStateMetaProvider);
    
    // 清理之前的订阅
    if (_allCallbacks.isNotEmpty) {
      debugPrint('[MessageBusInit] 清理旧订阅: ${_allCallbacks.keys}');
      for (final entry in _allCallbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _allCallbacks.clear();
    }
    
    if (currentUser == null) {
      debugPrint('[MessageBusInit] 用户未登录，跳过订阅');
      return;
    }
    
    final meta = metaAsync.value;
    if (meta == null) {
      debugPrint('[MessageBusInit] topicTrackingStateMeta 未加载');
      return;
    }
    
    // 逐个订阅话题追踪频道
    // 注意: /notification/ 和 /notification-alert/ 频道由专门的
    // NotificationChannelNotifier 和 NotificationAlertChannelNotifier 管理，
    // 此处只负责话题追踪频道
    debugPrint('[MessageBusInit] 订阅 ${meta.length} 个频道: ${meta.keys}');
    for (final entry in meta.entries) {
      final channel = entry.key;
      final messageId = entry.value as int;

      void onTopicTracking(MessageBusMessage message) {
        debugPrint('[TopicTracking] 收到消息: ${message.channel} #${message.messageId}');
        // TODO: 根据频道类型更新对应的话题列表
      }

      _allCallbacks[channel] = onTopicTracking;
      messageBus.subscribeWithMessageId(channel, onTopicTracking, messageId);
    }
    
    ref.onDispose(() {
      debugPrint('[MessageBusInit] 取消所有订阅: ${_allCallbacks.keys}');
      for (final entry in _allCallbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _allCallbacks.clear();
    });
  }
}

final messageBusInitProvider = NotifierProvider<MessageBusInitNotifier, void>(
  MessageBusInitNotifier.new,
);

/// 话题列表新消息状态（按分类隔离）
class TopicListIncomingState {
  /// topicId → categoryId 的映射，用于按 tab/分类隔离新话题指示器
  final Map<int, int?> incomingTopics;

  const TopicListIncomingState({this.incomingTopics = const {}});

  bool get hasIncoming => incomingTopics.isNotEmpty;
  int get incomingCount => incomingTopics.length;

  /// 指定分类是否有新话题（null 表示"全部"tab，统计所有分类）
  bool hasIncomingForCategory(int? categoryId) {
    if (categoryId == null) return incomingTopics.isNotEmpty;
    return incomingTopics.values.any((c) => c == categoryId);
  }

  /// 获取指定分类的新话题数量（null 表示"全部"tab）
  int incomingCountForCategory(int? categoryId) {
    if (categoryId == null) return incomingTopics.length;
    return incomingTopics.values.where((c) => c == categoryId).length;
  }
}

/// 话题列表频道监听器
/// 只标记有新话题，不主动刷新（避免频繁 API 调用）
/// 存储每条新话题的 categoryId，让各 tab 独立查询自己的新话题数
/// 仅根据全局标签筛选条件过滤消息
/// 使用防抖机制批量更新，避免频繁触发 UI 刷新
class LatestChannelNotifier extends Notifier<TopicListIncomingState> {
  Timer? _debounceTimer;
  final Map<int, int?> _pendingTopics = {};
  static const _debounceDuration = Duration(seconds: 3);

  @override
  TopicListIncomingState build() {
    final messageBus = ref.watch(messageBusServiceProvider);
    const channel = '/latest';

    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      final topicId = data['topic_id'] as int?;
      if (topicId == null) return;

      // 提取话题分类 ID（用于按 tab 隔离）
      final payload = data['payload'] as Map<String, dynamic>?;
      final topicCategoryId = payload?['category_id'] as int? ?? data['category_id'] as int?;

      debugPrint('[LatestChannel] 收到新话题: $topicId (category=$topicCategoryId)');

      _pendingTopics[topicId] = topicCategoryId;

      _debounceTimer?.cancel();
      _debounceTimer = Timer(_debounceDuration, () {
        if (_pendingTopics.isNotEmpty) {
          debugPrint('[LatestChannel] 批量添加 ${_pendingTopics.length} 条新话题');
          state = TopicListIncomingState(
            incomingTopics: {...state.incomingTopics, ..._pendingTopics},
          );
          _pendingTopics.clear();
        }
      });
    }

    messageBus.subscribe(channel, onMessage);

    ref.onDispose(() {
      _debounceTimer?.cancel();
      _pendingTopics.clear();
      messageBus.unsubscribe(channel, onMessage);
    });

    return const TopicListIncomingState();
  }

  /// 清除指定分类的新话题标记（null 表示清除全部）
  void clearNewTopicsForCategory(int? categoryId) {
    if (categoryId == null) {
      _debounceTimer?.cancel();
      _pendingTopics.clear();
      state = const TopicListIncomingState();
    } else {
      _pendingTopics.removeWhere((_, c) => c == categoryId);
      final remaining = Map<int, int?>.from(state.incomingTopics)
        ..removeWhere((_, c) => c == categoryId);
      state = TopicListIncomingState(incomingTopics: remaining);
    }
  }

  /// 清除所有新话题标记
  void clearNewTopics() {
    clearNewTopicsForCategory(null);
  }
}

final latestChannelProvider = NotifierProvider<LatestChannelNotifier, TopicListIncomingState>(() {
  return LatestChannelNotifier();
});
