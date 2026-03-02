import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../utils/client_id_generator.dart';
import 'network/discourse_dio.dart';

/// MessageBus 消息
class MessageBusMessage {
  final String channel;
  final int messageId;
  final dynamic data;

  MessageBusMessage({
    required this.channel,
    required this.messageId,
    required this.data,
  });

  factory MessageBusMessage.fromJson(Map<String, dynamic> json) {
    return MessageBusMessage(
      channel: json['channel'] as String,
      messageId: json['message_id'] as int,
      data: json['data'],
    );
  }
}

/// MessageBus 频道订阅
typedef MessageBusCallback = void Function(MessageBusMessage message);

class _ChannelSubscription {
  final String channel;
  int lastMessageId;
  final List<MessageBusCallback> callbacks;

  _ChannelSubscription({
    required this.channel,
    this.lastMessageId = -1,
    List<MessageBusCallback>? callbacks,
  }) : callbacks = callbacks ?? [];
}

/// Discourse MessageBus 客户端
/// 使用 HTTP 长轮询实现实时消息推送
class MessageBusService {
  static final MessageBusService _instance = MessageBusService._internal();
  factory MessageBusService() => _instance;

  final Dio _dio;

  final Map<String, _ChannelSubscription> _subscriptions = {};
  final String _clientId;
  
  bool _isPolling = false;
  bool _shouldStop = false;
  bool _backgroundMode = false; // 后台模式：使用更长的轮询间隔
  CancelToken? _currentCancelToken; // 当前请求的 CancelToken
  int _failureCount = 0;
  static const int _maxBackoffSeconds = 30;
  static const Duration _backgroundPollInterval = Duration(seconds: 60);

  // 消息流（用于全局监听）
  final _messageController = StreamController<MessageBusMessage>.broadcast();
  Stream<MessageBusMessage> get messageStream => _messageController.stream;

  String get clientId => _clientId;

  MessageBusService._internal()
      : _clientId = ClientIdGenerator.generate(),
        _dio = DiscourseDio.create(
          receiveTimeout: const Duration(seconds: 60),
          defaultHeaders: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        );

  /// 订阅频道
  void subscribe(String channel, MessageBusCallback callback, {int lastMessageId = -1}) {
    if (!_subscriptions.containsKey(channel)) {
      _subscriptions[channel] = _ChannelSubscription(
        channel: channel,
        lastMessageId: lastMessageId,
      );
    }
    _subscriptions[channel]!.callbacks.add(callback);

    if (!_isPolling) {
      _startPolling();
    } else {
      // 中止当前请求，轮询循环会自然重启并包含新频道
      final token = _currentCancelToken;
      _currentCancelToken = null;
      token?.cancel();
    }
  }

  /// 取消订阅
  void unsubscribe(String channel, [MessageBusCallback? callback]) {
    if (!_subscriptions.containsKey(channel)) return;
    
    if (callback != null) {
      _subscriptions[channel]!.callbacks.remove(callback);
      if (_subscriptions[channel]!.callbacks.isEmpty) {
        _subscriptions.remove(channel);
      }
    } else {
      _subscriptions.remove(channel);
    }
    
    // 无订阅时停止轮询
    if (_subscriptions.isEmpty) {
      _stopPolling();
    }
  }

  /// 使用指定的 messageId 订阅
  void subscribeWithMessageId(String channel, MessageBusCallback callback, int messageId) {
    if (_subscriptions.containsKey(channel)) {
      _subscriptions[channel]!.callbacks.add(callback);
      if (messageId > _subscriptions[channel]!.lastMessageId) {
        _subscriptions[channel]!.lastMessageId = messageId;
      }
    } else {
      _subscriptions[channel] = _ChannelSubscription(
        channel: channel,
        lastMessageId: messageId,
        callbacks: [callback],
      );
    }

    if (!_isPolling) {
      _startPolling();
    } else {
      // 中止当前请求，轮询循环会自然重启并包含新频道
      final token = _currentCancelToken;
      _currentCancelToken = null;
      token?.cancel();
    }
  }


  /// 开始轮询
  void _startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _shouldStop = false;
    _poll();
  }

  /// 停止轮询
  void _stopPolling() {
    _shouldStop = true;
    _isPolling = false;
    _currentCancelToken?.cancel('[MessageBus] 停止轮询');
    _currentCancelToken = null;
  }

  /// 可被 CancelToken 中断的延迟
  Future<void> _cancelableDelay(Duration duration, CancelToken cancelToken) {
    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    cancelToken.whenCancel.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// 执行长轮询（流式处理）
  Future<void> _poll() async {
    while (!_shouldStop && _subscriptions.isNotEmpty) {
      _currentCancelToken = CancelToken();

      try {
        // 后台模式使用更长的轮询间隔（对齐 Discourse backgroundCallbackInterval）
        if (_backgroundMode) {
          await _cancelableDelay(_backgroundPollInterval, _currentCancelToken!);
          if (_shouldStop || (_currentCancelToken?.isCancelled ?? false)) {
            if (_shouldStop) break;
            continue;
          }
        }

        final payload = <String, String>{};
        for (final sub in _subscriptions.values) {
          payload[sub.channel] = sub.lastMessageId.toString();
        }

        debugPrint('[MessageBus] 发起轮询: $payload');

        // 使用流式响应 + CancelToken
        final response = await _dio.post<ResponseBody>(
          '/message-bus/$_clientId/poll',
          data: payload,
          cancelToken: _currentCancelToken,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.stream,
            extra: {'isSilent': true},
          ),
        );

        _failureCount = 0;

        // 流式处理响应
        String buffer = '';
        await for (final chunk in response.data!.stream) {
          if (_currentCancelToken?.isCancelled ?? false) {
            debugPrint('[MessageBus] 检测到取消信号，中断当前响应处理');
            break;
          }

          final text = utf8.decode(chunk);
          buffer += text;

          // 按 | 分割处理每个完整的消息块
          while (buffer.contains('|')) {
            final delimiterIndex = buffer.indexOf('|');
            final messageChunk = buffer.substring(0, delimiterIndex).trim();
            buffer = buffer.substring(delimiterIndex + 1);

            if (messageChunk.isNotEmpty) {
              _processChunk(messageChunk);
            }
          }
        }

        // 处理剩余的数据
        if (!(_currentCancelToken?.isCancelled ?? false) && buffer.trim().isNotEmpty) {
          _processChunk(buffer.trim());
        }

      } on DioException catch (e) {
        _currentCancelToken = null;

        if (e.type == DioExceptionType.cancel) {
          if (_shouldStop) {
            debugPrint('[MessageBus] 请求已取消，停止轮询');
            break;
          }
          debugPrint('[MessageBus] 请求已取消，重新轮询');
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        // 处理速率限制（429 Too Many Requests）
        if (e.response?.statusCode == 429) {
          final retryAfter = int.tryParse(
            e.response?.headers.value('Retry-After') ?? '',
          );
          final waitSeconds = (retryAfter ?? 60) + Random().nextInt(30);
          debugPrint('[MessageBus] 触发速率限制，$waitSeconds秒后重试');
          await Future.delayed(Duration(seconds: waitSeconds));
          continue;
        }

        if (e.type == DioExceptionType.receiveTimeout) {
          debugPrint('[MessageBus] 长轮询超时，继续...');
          _failureCount = 0;
          continue;
        }

        _failureCount++;

        final backoffSeconds = min(pow(2, _failureCount).toInt(), _maxBackoffSeconds);
        debugPrint('[MessageBus] 轮询失败: ${e.type}, ${e.message}');
        debugPrint('[MessageBus] $backoffSeconds秒后重试');

        await Future.delayed(Duration(seconds: backoffSeconds));
      } catch (e, stack) {
        _failureCount++;
        final backoffSeconds = min(pow(2, _failureCount).toInt(), _maxBackoffSeconds);
        debugPrint('[MessageBus] 未知错误: $e');
        debugPrint('[MessageBus] $stack');
        debugPrint('[MessageBus] $backoffSeconds秒后重试');
        await Future.delayed(Duration(seconds: backoffSeconds));
      }
    }

    _isPolling = false;
  }
  
  /// 处理单个消息块
  void _processChunk(String chunk) {
    try {
      final parsed = jsonDecode(chunk);
      if (parsed is List) {
        for (final item in parsed) {
          if (item is Map<String, dynamic>) {
            final message = MessageBusMessage.fromJson(item);
            _handleMessage(message);
          }
        }
      }
    } catch (e) {
      debugPrint('[MessageBus] JSON 解析失败: $e, chunk: $chunk');
    }
  }

  /// 处理收到的消息
  void _handleMessage(MessageBusMessage message) {
    debugPrint('[MessageBus] 收到消息: ${message.channel} #${message.messageId}');
    
    // 处理 __status 消息：更新各频道的 lastMessageId
    if (message.channel == '/__status') {
      final data = message.data;
      if (data is Map<String, dynamic>) {
        for (final entry in data.entries) {
          final channelName = entry.key;
          final lastId = entry.value;
          if (_subscriptions.containsKey(channelName) && lastId is int) {
            _subscriptions[channelName]!.lastMessageId = lastId;
            debugPrint('[MessageBus] 更新频道 $channelName 的 lastMessageId: $lastId');
          }
        }
      }
      return; // __status 消息不需要通知订阅者
    }
    
    // 更新 lastMessageId
    if (_subscriptions.containsKey(message.channel)) {
      final sub = _subscriptions[message.channel]!;
      if (message.messageId > sub.lastMessageId) {
        sub.lastMessageId = message.messageId;
      }
      
      // 通知订阅者
      for (final callback in sub.callbacks) {
        try {
          callback(message);
        } catch (e) {
          debugPrint('[MessageBus] 回调执行错误: $e');
        }
      }
    }
    
    // 广播到全局流
    _messageController.add(message);
  }

  /// 当前是否正在轮询
  bool get isPolling => _isPolling;

  /// 进入后台模式：使用更长的轮询间隔（不取消当前请求）
  void enterBackgroundMode() {
    if (_backgroundMode) return;
    _backgroundMode = true;
    debugPrint('[MessageBus] 进入后台模式，轮询间隔 ${_backgroundPollInterval.inSeconds}s');
  }

  /// 退出后台模式：取消当前请求以立即重新轮询
  void exitBackgroundMode() {
    if (!_backgroundMode) return;
    _backgroundMode = false;
    _failureCount = 0;
    debugPrint('[MessageBus] 退出后台模式，立即恢复轮询');
    if (_isPolling) {
      // 取消可能正在等待的后台间隔延迟或长轮询请求，立即重新轮询
      final token = _currentCancelToken;
      _currentCancelToken = null;
      token?.cancel();
    } else if (_subscriptions.isNotEmpty) {
      _startPolling();
    }
  }

  /// 释放资源
  void dispose() {
    _stopPolling();
    _messageController.close();
  }
}
