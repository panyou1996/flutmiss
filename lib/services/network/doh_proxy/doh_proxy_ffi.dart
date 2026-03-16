import 'package:flutter/foundation.dart';

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// DOH Proxy FFI bindings
///
/// This provides direct FFI bindings to the Rust DOH proxy library
/// for Android and iOS platforms.
class DohProxyFfi {
  DohProxyFfi._();
  static final DohProxyFfi instance = DohProxyFfi._();

  DynamicLibrary? _lib;
  bool _initialized = false;

  // FFI function types
  late final int Function(Pointer<Utf8> configJson) _dohProxyStartWithConfigJson;
  late final void Function() _dohProxyStop;
  late final int Function() _dohProxyIsRunning;
  late final int Function() _dohProxyGetPort;
  late final void Function() _dohProxyInitLogging;

  /// Initialize FFI bindings
  bool initialize() {
    if (_initialized) return true;

    try {
      _lib = _loadLibrary();
      if (_lib == null) return false;

      // Load function pointers
      _dohProxyStartWithConfigJson = _lib!
          .lookup<NativeFunction<Int32 Function(Pointer<Utf8>)>>(
              'doh_proxy_start_with_config_json')
          .asFunction();

      _dohProxyStop = _lib!
          .lookup<NativeFunction<Void Function()>>('doh_proxy_stop')
          .asFunction();

      _dohProxyIsRunning = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_is_running')
          .asFunction();

      _dohProxyGetPort = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_get_port')
          .asFunction();

      _dohProxyInitLogging = _lib!
          .lookup<NativeFunction<Void Function()>>('doh_proxy_init_logging')
          .asFunction();

      _initialized = true;
      return true;
    } catch (e) {
      lastInitError = '初始化 FFI 绑定失败: $e';
      debugPrint('[DOH FFI] $lastInitError');
      return false;
    }
  }

  DynamicLibrary? _loadLibrary() {
    try {
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libdoh_proxy.so');
      } else if (Platform.isIOS) {
        // iOS uses static linking, so we use the process itself
        return DynamicLibrary.process();
      } else if (Platform.isWindows) {
        return DynamicLibrary.open('doh_proxy.dll');
      } else if (Platform.isMacOS) {
        return DynamicLibrary.open('libdoh_proxy.dylib');
      } else if (Platform.isLinux) {
        return DynamicLibrary.open('libdoh_proxy.so');
      }
    } catch (e) {
      lastInitError = '加载原生库失败: $e';
      debugPrint('[DOH FFI] $lastInitError');
    }
    return null;
  }

  /// 最近一次初始化失败的原因
  String? lastInitError;

  /// Start the DOH proxy server
  /// Returns the port number on success, or -1 on failure
  ///
  /// [port] - Port to bind (0 for auto-select)
  /// [preferIpv6] - Whether to prefer IPv6 addresses
  /// [dohServer] - DOH server URL (null for default Cloudflare)
  int start({
    int port = 0,
    bool enableDoh = true,
    bool preferIpv6 = false,
    String? dohServer,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
  }) {
    if (!_initialized && !initialize()) {
      return -1;
    }

    final configJson = jsonEncode({
      'bind_addr': '127.0.0.1',
      'bind_port': port,
      'enable_doh': enableDoh,
      'doh_server': dohServer ?? 'cloudflare',
      'prefer_ipv6': preferIpv6,
      'timeout_secs': 30,
      if (serverIp != null && serverIp.isNotEmpty)
        'server_ip': serverIp,
      if (upstreamHost != null && upstreamHost.isNotEmpty && upstreamPort != null && upstreamPort > 0)
        'upstream_proxy': {
          'protocol': upstreamProtocol ?? 'http',
          'host': upstreamHost,
          'port': upstreamPort,
          if (upstreamCipher != null && upstreamCipher.isNotEmpty)
            'cipher': upstreamCipher,
          if (upstreamUsername != null && upstreamUsername.isNotEmpty)
            'username': upstreamUsername,
          if (upstreamPassword != null && upstreamPassword.isNotEmpty)
            'password': upstreamPassword,
        },
    });
    final configPtr = configJson.toNativeUtf8();
    try {
      return _dohProxyStartWithConfigJson(configPtr);
    } finally {
      calloc.free(configPtr);
    }
  }

  /// Stop the DOH proxy server
  void stop() {
    if (!_initialized) return;
    _dohProxyStop();
  }

  /// Check if the DOH proxy is running
  bool isRunning() {
    if (!_initialized) return false;
    return _dohProxyIsRunning() != 0;
  }

  /// Get the DOH proxy port
  int getPort() {
    if (!_initialized) return 0;
    return _dohProxyGetPort();
  }

  /// Initialize logging
  void initLogging() {
    if (!_initialized && !initialize()) return;
    _dohProxyInitLogging();
  }

  /// Check if FFI is available on this platform
  static bool get isAvailable {
    return Platform.isAndroid || Platform.isIOS;
  }
}

/// Backwards compatibility alias
@Deprecated('Use DohProxyFfi instead')
typedef EchProxyFfi = DohProxyFfi;
