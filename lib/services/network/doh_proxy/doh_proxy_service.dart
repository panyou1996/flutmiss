import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../network_logger.dart';
import 'doh_proxy_ffi.dart';

/// DOH (DNS over HTTPS) 代理服务
/// 使用 Rust 实现的本地代理，通过 DOH 解析 DNS 并支持 ECH
///
/// 在桌面平台（Windows/macOS/Linux）使用进程方式运行代理
/// 在移动平台（Android/iOS）使用 FFI 直接调用 Rust 库
class DohProxyService {
  DohProxyService._();
  static final DohProxyService instance = DohProxyService._();

  // 桌面平台进程管理
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  // 共享状态
  int? _port;
  bool _isRunning = false;
  bool? _currentEnableDoh;
  String? _currentDohServer;
  bool? _currentPreferIPv6;
  int? _currentPreferredPort;
  String? _currentUpstreamSignature;
  String? _lastError;
  // ignore: unused_field
  Isolate? _ffiIsolate; // 保持引用防止 GC
  SendPort? _ffiSendPort;
  Future<void> _ffiQueue = Future.value();

  /// 代理是否正在运行
  bool get isRunning => _isRunning;

  /// 代理端口
  int? get port => _port;

  /// 最近一次启动失败的原因
  String? get lastError => _lastError;

  /// 启动 DOH 代理
  ///
  /// [preferredPort] - 首选端口（0 为自动选择）
  /// [preferIPv6] - 是否优先使用 IPv6
  /// [dohServer] - DOH 服务器 URL（null 为默认 Cloudflare）
  Future<bool> start({
    int preferredPort = 0,
    bool enableDoh = true,
    bool preferIPv6 = false,
    String? dohServer,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
  }) async {
    final upstreamSignature = _buildUpstreamSignature(
      protocol: upstreamProtocol,
      host: upstreamHost,
      port: upstreamPort,
      username: upstreamUsername,
      password: upstreamPassword,
      cipher: upstreamCipher,
    );
    if (_isRunning) {
      final sameConfig = _currentEnableDoh == enableDoh
          && _currentDohServer == dohServer
          && _currentPreferIPv6 == preferIPv6
          && _currentPreferredPort == preferredPort
          && _currentUpstreamSignature == upstreamSignature;
      if (sameConfig) {
        NetworkLogger.log('[DOH] 代理已在运行，端口: $_port');
        return true;
      }
      NetworkLogger.log('[DOH] 配置变更，重启代理');
      await stop();
    }

    _lastError = null;

    // 根据平台选择启动方式
    if (DohProxyFfi.isAvailable) {
      return _startWithFfi(
        preferredPort,
        enableDoh,
        preferIPv6,
        dohServer,
        serverIp,
        upstreamProtocol,
        upstreamHost,
        upstreamPort,
        upstreamUsername,
        upstreamPassword,
        upstreamCipher,
      );
    } else {
      return _startWithProcess(
        preferredPort,
        enableDoh,
        preferIPv6,
        dohServer,
        serverIp,
        upstreamProtocol,
        upstreamHost,
        upstreamPort,
        upstreamUsername,
        upstreamPassword,
        upstreamCipher,
      );
    }
  }

  /// 使用 FFI 启动代理（Android/iOS）
  Future<bool> _startWithFfi(
    int port,
    bool enableDoh,
    bool preferIPv6,
    String? dohServer,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
  ) async {
    try {
      return await _enqueueFfiOp(() async {
        NetworkLogger.log(
          '[DOH] 使用 FFI 启动代理，模式: ${enableDoh ? "DoH 网关" : "纯上游代理"}',
        );

        _currentPreferredPort = port;
        await _ensureFfiStopped();
        final resultPort = await _callFfiStart(
          port: port,
          enableDoh: enableDoh,
          preferIpv6: preferIPv6,
          dohServer: dohServer,
          serverIp: serverIp,
          upstreamProtocol: upstreamProtocol,
          upstreamHost: upstreamHost,
          upstreamPort: upstreamPort,
          upstreamUsername: upstreamUsername,
          upstreamPassword: upstreamPassword,
          upstreamCipher: upstreamCipher,
        );
        if (resultPort <= 0) {
          // _callFfiStart 已设置更详细的 _lastError，仅在未设置时补充
          _lastError ??= 'FFI 启动失败，返回值: $resultPort';
          NetworkLogger.log('[DOH] $_lastError');
          return false;
        }

        _port = resultPort;
        _isRunning = true;
        _currentEnableDoh = enableDoh;
        _currentDohServer = dohServer;
        _currentPreferIPv6 = preferIPv6;
        _currentPreferredPort = port;
        _currentUpstreamSignature = _buildUpstreamSignature(
          protocol: upstreamProtocol,
          host: upstreamHost,
          port: upstreamPort,
          username: upstreamUsername,
          password: upstreamPassword,
          cipher: upstreamCipher,
        );
        NetworkLogger.log('[DOH] FFI 代理已启动，端口: $_port');
        return true;
      });
    } catch (e) {
      _lastError = 'FFI 启动异常: $e';
      NetworkLogger.log('[DOH] $_lastError');
      return false;
    }
  }

  /// 使用进程启动代理（桌面平台）
  Future<bool> _startWithProcess(
    int preferredPort,
    bool enableDoh,
    bool preferIPv6,
    String? dohServer,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
  ) async {
    try {
      final executablePath = await _getExecutablePath();
      if (executablePath == null) {
        _lastError = '找不到代理可执行文件';
        NetworkLogger.log('[DOH] $_lastError');
        return false;
      }

      NetworkLogger.log(
        '[DOH] 启动代理进程: $executablePath, 模式: ${enableDoh ? "DoH 网关" : "纯上游代理"}',
      );

      // 构建命令行参数
      final args = <String>[
        preferredPort.toString(),
        if (!enableDoh) '--no-doh',
        if (preferIPv6) '--ipv6',
        if (dohServer != null && dohServer.isNotEmpty) ...[
          '--doh',
          dohServer,
        ],
        if (serverIp != null && serverIp.isNotEmpty) ...[
          '--server-ip',
          serverIp,
        ],
        if (upstreamHost != null && upstreamHost.isNotEmpty) ...[
          '--upstream-protocol',
          upstreamProtocol ?? 'http',
          '--upstream-host',
          upstreamHost,
          if (upstreamPort != null) ...[
            '--upstream-port',
            upstreamPort.toString(),
          ],
          if (upstreamCipher != null && upstreamCipher.isNotEmpty) ...[
            '--upstream-cipher',
            upstreamCipher,
          ],
          if (upstreamUsername != null && upstreamUsername.isNotEmpty) ...[
            '--upstream-user',
            upstreamUsername,
          ],
          if (upstreamPassword != null && upstreamPassword.isNotEmpty) ...[
            '--upstream-pass',
            upstreamPassword,
          ],
        ],
      ];

      // 启动进程
      _process = await Process.start(executablePath, args);

      // 监听 stdout 获取端口信息
      final stdoutLines = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      final completer = Completer<bool>();
      var completed = false;

      _stdoutSubscription = stdoutLines.listen((line) {
        NetworkLogger.log('[DOH] $line');
        // 解析端口: "DOH proxy server listening on 127.0.0.1:12345"
        final match = RegExp(r'listening on [\d.]+:(\d+)').firstMatch(line);
        if (match != null && !completed) {
          _port = int.tryParse(match.group(1) ?? '');
          _isRunning = true;
          _currentEnableDoh = enableDoh;
          _currentDohServer = dohServer;
          _currentPreferIPv6 = preferIPv6;
          _currentPreferredPort = preferredPort;
          _currentUpstreamSignature = _buildUpstreamSignature(
            protocol: upstreamProtocol,
            host: upstreamHost,
            port: upstreamPort,
            username: upstreamUsername,
            password: upstreamPassword,
            cipher: upstreamCipher,
          );
          NetworkLogger.log('[DOH] 代理已启动，端口: $_port');
          completed = true;
          completer.complete(true);
        }
      });

      // 监听 stderr
      final stderrLines = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      _stderrSubscription = stderrLines.listen((line) {
        NetworkLogger.log('[DOH][ERROR] $line');
      });

      // 监听进程退出
      _process!.exitCode.then((code) {
        NetworkLogger.log('[DOH] 进程退出，代码: $code');
        if (!completed) {
          _lastError = '代理进程异常退出，退出码: $code';
          NetworkLogger.log('[DOH] $_lastError');
        }
        _cleanup();
        if (!completed) {
          completed = true;
          completer.complete(false);
        }
      });

      // 等待代理启动或超时
      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _lastError = '代理启动超时（5秒内未响应）';
          NetworkLogger.log('[DOH] $_lastError');
          return false;
        },
      );

      if (!result) {
        await stop();
        return false;
      }

      return true;
    } catch (e) {
      _lastError = '启动失败: $e';
      NetworkLogger.log('[DOH] $_lastError');
      await stop();
      return false;
    }
  }

  /// 停止 DOH 代理
  Future<void> stop() async {
    if (DohProxyFfi.isAvailable) {
      await _enqueueFfiOp(() async {
        await _stopWithFfi();
      });
    } else {
      await _stopWithProcess();
    }
    _cleanup();
  }

  Future<void> _stopWithFfi() async {
    try {
      await _callFfiStop();
      await _ensureFfiStopped();
      NetworkLogger.log('[DOH] FFI 代理已停止');
    } catch (e) {
      NetworkLogger.log('[DOH] FFI 停止异常: $e');
    }
  }

  Future<void> _stopWithProcess() async {
    if (_process != null) {
      NetworkLogger.log('[DOH] 停止代理进程...');
      _process!.kill();
      await _process!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _process!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  void _cleanup() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _process = null;
    _port = null;
    _isRunning = false;
    _currentEnableDoh = null;
    _currentDohServer = null;
    _currentPreferIPv6 = null;
    _currentPreferredPort = null;
    _currentUpstreamSignature = null;
    // 注意：不清除 _lastError，保留用于 UI 展示
  }

  /// 获取 DOH 代理可执行文件路径（仅桌面平台）
  Future<String?> _getExecutablePath() async {
    // 根据平台确定可执行文件名
    String executableName;
    if (Platform.isWindows) {
      executableName = 'doh_proxy_bin.exe';
    } else if (Platform.isMacOS || Platform.isLinux) {
      executableName = 'doh_proxy_bin';
    } else {
      // Android/iOS 使用 FFI，不需要可执行文件
      return null;
    }

    // 查找可执行文件的可能位置
    final possiblePaths = <String>[
      // 开发时：core/doh_proxy/target/release/
      p.join(Directory.current.path, 'core', 'doh_proxy', 'target', 'release', executableName),
      // 开发时：core/doh_proxy/target/debug/
      p.join(Directory.current.path, 'core', 'doh_proxy', 'target', 'debug', executableName),
      // 打包后：与应用程序同目录
      p.join(p.dirname(Platform.resolvedExecutable), executableName),
      // 打包后：assets 目录
      p.join(p.dirname(Platform.resolvedExecutable), 'data', 'flutter_assets', 'assets', executableName),
    ];

    for (final path in possiblePaths) {
      if (File(path).existsSync()) {
        return path;
      }
    }

    return null;
  }

  /// 获取代理 URL（用于配置 HTTP 客户端）
  String? get proxyUrl {
    if (_isRunning && _port != null) {
      return 'http://127.0.0.1:$_port';
    }
    return null;
  }

  Future<T> _enqueueFfiOp<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _ffiQueue = _ffiQueue.then((_) async {
      try {
        final result = await op();
        completer.complete(result);
      } catch (e, stack) {
        completer.completeError(e, stack);
      }
    });
    return completer.future;
  }

  Future<int> _callFfiStart({
    required int port,
    required bool enableDoh,
    required bool preferIpv6,
    required String? dohServer,
    required String? serverIp,
    required String? upstreamProtocol,
    required String? upstreamHost,
    required int? upstreamPort,
    required String? upstreamUsername,
    required String? upstreamPassword,
    required String? upstreamCipher,
  }) async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'start',
      'port': port,
      'enableDoh': enableDoh,
      'preferIpv6': preferIpv6,
      'dohServer': dohServer,
      'serverIp': serverIp,
      'upstreamProtocol': upstreamProtocol,
      'upstreamHost': upstreamHost,
      'upstreamPort': upstreamPort,
      'upstreamUsername': upstreamUsername,
      'upstreamPassword': upstreamPassword,
      'upstreamCipher': upstreamCipher,
      'preferredPort': port,
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] == true) {
      return (result['port'] as int?) ?? -1;
    }
    final error = result is Map ? result['error']?.toString() : null;
    _lastError = 'FFI 启动失败: ${error ?? 'unknown error'}';
    NetworkLogger.log('[DOH] $_lastError');
    return -1;
  }

  Future<void> _callFfiStop() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'stop',
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map && result['ok'] != true) {
      if (result['error'] != null) {
        NetworkLogger.log('[DOH] FFI 停止失败: ${result['error']}');
      } else {
        NetworkLogger.log('[DOH] FFI 停止失败: unknown error');
      }
    }
  }

  Future<Map<String, dynamic>> _callFfiStatus() async {
    final sendPort = await _ensureFfiIsolate();
    final response = ReceivePort();
    sendPort.send({
      'cmd': 'status',
      'replyTo': response.sendPort,
    });
    final result = await response.first;
    response.close();
    if (result is Map<String, dynamic>) return result;
    return {'ok': false};
  }

  Future<void> _ensureFfiStopped() async {
    const timeout = Duration(seconds: 1);
    const interval = Duration(milliseconds: 50);
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      final status = await _callFfiStatus();
      final running = status['running'] as bool? ?? false;
      if (!running) return;
      await Future<void>.delayed(interval);
    }
    NetworkLogger.log('[DOH] FFI 停止超时，可能仍占用端口');
  }

  String? _buildUpstreamSignature({
    required String? protocol,
    required String? host,
    required int? port,
    required String? username,
    required String? password,
    required String? cipher,
  }) {
    if (host == null || host.isEmpty || port == null || port <= 0) {
      return null;
    }
    return jsonEncode({
      'protocol': protocol ?? 'http',
      'host': host,
      'port': port,
      'username': username ?? '',
      'password': password ?? '',
      'cipher': cipher ?? '',
    });
  }

  Future<SendPort> _ensureFfiIsolate() async {
    if (_ffiSendPort != null) return _ffiSendPort!;
    final readyPort = ReceivePort();
    _ffiIsolate = await Isolate.spawn(_ffiIsolateEntry, readyPort.sendPort);
    _ffiSendPort = await readyPort.first as SendPort;
    readyPort.close();
    return _ffiSendPort!;
  }
}

void _ffiIsolateEntry(SendPort mainSendPort) {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);

  port.listen((message) {
    if (message is! Map) return;
    final cmd = message['cmd']?.toString();
    final replyTo = message['replyTo'];
    if (replyTo is! SendPort) return;

    try {
      if (!DohProxyFfi.instance.initialize()) {
        final detail = DohProxyFfi.instance.lastInitError ?? '未知原因';
        replyTo.send({'ok': false, 'error': '无法加载原生库: $detail'});
        return;
      }

      switch (cmd) {
        case 'start':
          final portValue = message['port'] as int? ?? 0;
          final preferredPort = message['preferredPort'] as int? ?? 0;
          final enableDoh = message['enableDoh'] as bool? ?? true;
          final preferIpv6 = message['preferIpv6'] as bool? ?? false;
          final dohServer = message['dohServer'] as String?;
          final serverIp = message['serverIp'] as String?;
          final upstreamProtocol = message['upstreamProtocol'] as String?;
          final upstreamHost = message['upstreamHost'] as String?;
          final upstreamPort = message['upstreamPort'] as int?;
          final upstreamUsername = message['upstreamUsername'] as String?;
          final upstreamPassword = message['upstreamPassword'] as String?;
          final upstreamCipher = message['upstreamCipher'] as String?;
          var resultPort = DohProxyFfi.instance.start(
            port: portValue,
            enableDoh: enableDoh,
            preferIpv6: preferIpv6,
            dohServer: dohServer,
            serverIp: serverIp,
            upstreamProtocol: upstreamProtocol,
            upstreamHost: upstreamHost,
            upstreamPort: upstreamPort,
            upstreamUsername: upstreamUsername,
            upstreamPassword: upstreamPassword,
            upstreamCipher: upstreamCipher,
          );
          if (resultPort <= 0 && preferredPort != 0) {
            resultPort = DohProxyFfi.instance.start(
              port: 0,
              enableDoh: enableDoh,
              preferIpv6: preferIpv6,
              dohServer: dohServer,
              serverIp: serverIp,
              upstreamProtocol: upstreamProtocol,
              upstreamHost: upstreamHost,
              upstreamPort: upstreamPort,
              upstreamUsername: upstreamUsername,
              upstreamPassword: upstreamPassword,
              upstreamCipher: upstreamCipher,
            );
          }
          if (resultPort <= 0) {
            // Rust 内部只等 200ms 就检查端口，老设备可能不够
            // 在 Dart 侧延迟重试，最多再等 1 秒
            for (var i = 0; i < 5; i++) {
              sleep(const Duration(milliseconds: 200));
              if (DohProxyFfi.instance.isRunning()) {
                final runningPort = DohProxyFfi.instance.getPort();
                if (runningPort > 0) {
                  replyTo.send({'ok': true, 'port': runningPort});
                  return;
                }
              }
            }
            // 重试后仍失败，构建诊断信息
            final details = StringBuffer('Rust 代理启动返回 $resultPort');
            details.write('，端口=$portValue');
            if (dohServer != null) details.write('，DoH=$dohServer');
            details.write('，延迟重试后仍未就绪');
            replyTo.send({'ok': false, 'error': details.toString()});
          } else {
            replyTo.send({'ok': true, 'port': resultPort});
          }
          return;
        case 'stop':
          DohProxyFfi.instance.stop();
          replyTo.send({'ok': true});
          return;
        case 'status':
          final running = DohProxyFfi.instance.isRunning();
          final portValue = running ? DohProxyFfi.instance.getPort() : 0;
          replyTo.send({'ok': true, 'running': running, 'port': portValue});
          return;
      }
      replyTo.send({'ok': false, 'error': 'unknown command'});
    } catch (e) {
      replyTo.send({'ok': false, 'error': e.toString()});
    }
  });
}

/// Backwards compatibility alias
@Deprecated('Use DohProxyService instead')
typedef EchProxyService = DohProxyService;
