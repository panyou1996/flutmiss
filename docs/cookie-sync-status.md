# Cookie 同步架构

## 设计原则

1. **`EnhancedPersistCookieJar` 是元数据的权威来源** — hostOnly、sameSite、partitionKey 等字段以 jar 为准
2. **WebView 是 value 的权威来源** — 页面交互可能更新 cookie 值，syncFromWebView 只更新 value
3. **写入 WebView 用原始 `Set-Cookie` 头** — 保留 host-only 等完整语义，不经过结构化 API 二次转换
4. **storageKey 遵循 RFC 6265bis + CHIPS** — `(name, normalizedDomain, path, hostOnly, partitionKey)`

## 数据流

### Dio 响应 → CookieJar → WebView（write-through）

```
服务端 Set-Cookie: _t=xxx; path=/; secure; httponly
  │
  ▼
AppCookieManager.saveCookies()
  ├─ EnhancedPersistCookieJar.saveFromSetCookieHeaders()  ← 存 rawSetCookie 原始头
  └─ CookieWriteThrough.writeThrough(cookies, uri, rawSetCookieHeaders)
       │
       ├─ [Android/iOS/macOS] RawCookieWriter.setRawCookie(url, rawHeader)
       │    ├─ Android: CookieManager.setCookie(url, rawHeader)
       │    ├─ iOS/macOS: HTTPCookie.cookies(withResponseHeaderFields:for:) → WKHTTPCookieStore
       │    └─ 无 raw 头时：从 CanonicalCookie.toSetCookieHeader() 重建
       │
       ├─ [Windows] CDP Network.setCookie(hostOnly: true/false)
       └─ [Linux] fallback 结构化 API（SoupCookie 前导点约定兜底）
```

### 打开 WebView 前（syncToWebView）

```
WebViewPage / WebViewLoginPage
  ├─ [非 Windows] syncToWebView()
  │    └─ strategy.writeCookiesToWebView()
  │         ├─ 批量加载 rawHeaders Map
  │         ├─ RawCookieWriter 优先
  │         └─ fallback 结构化 API
  │
  └─ [Windows] syncToWebViewViaController() 仅 CDP 路径
```

### WebView → CookieJar（syncFromWebView）

```
页面加载完成 → syncFromWebView()
  │
  ├─ [Windows/Android] CDP Network.getCookies
  │    ├─ 完整字段（hostOnly/sameSite/partitionKey）
  │    └─ saveFromCdpCookies → EnhancedPersistCookieJar
  │
  ├─ [iOS/macOS] WKHTTPCookieStore.getAllCookies → NSHTTPCookie
  │    ├─ sameSite（iOS 13+）、httpOnly、secure、expires
  │    └─ hostOnly 由 domain 前导点推断 + jar 已有记录优先
  │
  └─ [Linux] SoupCookie
       ├─ sameSite（libsoup 2.70+）、httpOnly、secure、expires
       └─ hostOnly 由 domain 前导点推断 + jar 已有记录优先

合并策略：
  jar 已有 cookie → 保留 jar 的 hostOnly/sameSite/partitionKey，只更新 value
  jar 没有 → 使用平台数据
```

## 平台能力矩阵

### 写入 WebView

| 平台 | 方法 | host-only 保证 |
|------|------|------|
| Android | platform channel → `CookieManager.setCookie(url, rawSetCookie)` | 省略 Domain= → host-only |
| iOS/macOS | platform channel → `HTTPCookie.cookies(withResponseHeaderFields:for:)` → `WKHTTPCookieStore` | 从原始头构造 |
| Windows | CDP `Network.setCookie` 带 `hostOnly` 参数 | 显式控制 |
| Linux | fallback 结构化 API | SoupCookie 前导点约定 |

### 从 WebView 读取

| 字段 | Windows CDP | Android CDP | iOS/macOS | Linux WPE |
|------|-------------|-------------|-----------|-----------|
| hostOnly | 显式字段 | 显式字段 | 前导点推断 | 前导点推断 |
| sameSite | 显式字段 | 显式字段 | NSHTTPCookie.sameSitePolicy | soup_cookie_get_same_site_policy |
| partitionKey | 显式字段 | 显式字段 | 无 API | 无 API |
| httpOnly | 显式字段 | 显式字段 | NSHTTPCookie.isHTTPOnly | SoupCookie.http_only |

## enhanced_cookie_jar 存储

### CanonicalCookie 字段

RFC 6265bis 标准字段 + 扩展字段：

- `name`、`value`、`domain`、`path`、`expiresAt`、`maxAge`
- `secure`、`httpOnly`、`sameSite`、`hostOnly`、`persistent`
- `partitionKey`、`partitioned`（CHIPS）
- `priority`、`sourceScheme`、`sourcePort`
- `rawSetCookie`（原始 Set-Cookie 头）
- `creationTime`、`lastAccessTime`

### storageKey

```
jsonEncode([name, normalizedDomain, path, hostOnly, partitionKey])
```

遵循 RFC 6265bis：同 name/domain/path 但不同 hostOnly 是两条不同的 cookie。

### 持久化策略

- 有 `expiresAt` 或 `maxAge` → 写入文件（持久化 cookie）
- 无过期时间 → 仅内存缓存（session cookie，与浏览器行为一致）
- 文件写入使用原子操作（先写 .tmp 再 rename）
- 文件读取有 try-catch 容错，单条解析失败不影响其余

## 升级迁移

### MigrationService

- 位置：`lib/services/migration_service.dart`
- 在 `main()` 中所有网络服务之前执行
- 通用框架，新增迁移只需在 `_migrations` 列表追加一条

### cookie_clean_slate_v2

- 检测旧版本用户（`cookie_domain_migration_v2` 标记或 jar 中有 `_t`）
- 清空所有 cookie 存储（CookieJar + WebView）
- 弹 Dialog 提示用户需要重新登录
- 全新安装不触发

## 已修复问题汇总

| 问题 | 根因 | 修复 |
|------|------|------|
| domain cookie 无法命中子域 | `_domainMatches()` 实现错误 | 已修复 |
| host-only cookie 存了无法命中 | domain=null 时无法回推 host | 已修复 |
| 非法 cookie 值导致崩溃 | `toIoCookie()` 直接塞原始值 | 自动编码 `~enc~` |
| OAuth 重定向 cookie 丢失 | 未保存重定向目标域 cookie | `allowRedirectSetCookie` |
| 同名 cookie 选错 | 去重不含 domain 优先级 | 按请求 host 评分 |
| redirect 路径用未过滤 cookies | 被拦截的删除指令写入重定向 URI | 改用 `filteredCookies` |
| `_mergeCookies` path null | key 变成 `name\|null` 导致误覆盖 | 规范化为 `'/'` |
| 迁移排序方向反 | domain 优先保留，与 host-only 优先矛盾 | 改为 host-only 优先 |
| `getCfClearanceCookie` 优先级不一致 | 与 `getCookieValue` 策略相反 | 统一 host-only 优先 |
| CDP `_parseMillis` 单位错误 | 秒 vs 毫秒 | 改为 `_parseSeconds` |
| CDP `expiresAt` 溢出 | 极大值导致异常 | 加 `< 1e12` 保护 |
| 文件损坏丢全部 cookie | `readAll` 无 try-catch | 逐条容错 + 原子写 |
| WebView 去重 key 含 value.hashCode | 同名不同值不去重 | 去掉 |
| `_pendingWrite` 并发丢失 | 只追踪最后一次 Completer | 改为计数器 |
| Windows 错误日志漏 `$e` | 日志字符串截断 | 补上 |
| host-only 变成 domain cookie | syncFromWebView 误判 + 写入丢失语义 | raw Set-Cookie 写入 + 合并策略 |
| Windows 双写 | `syncToWebView` + `syncToWebViewViaController` | 只保留 CDP |
| Apple 双写 | rawWriter 成功仍写 HTTPCookieStorage | rawWriter 成功时 skip |
| 删除逻辑重复 | 多处三段式删除 | 提取 `_deleteFromWebView` |
| jar 读取冗余 | 循环内逐个查 | 批量加载 Map |

## 关键文件

### enhanced_cookie_jar 包

- `packages/enhanced_cookie_jar/lib/src/canonical_cookie.dart`
- `packages/enhanced_cookie_jar/lib/src/set_cookie_parser.dart`
- `packages/enhanced_cookie_jar/lib/src/cdp_cookie_parser.dart`
- `packages/enhanced_cookie_jar/lib/src/enhanced_persist_cookie_jar.dart`
- `packages/enhanced_cookie_jar/lib/src/file_cookie_store.dart`

### 应用层 cookie 管理

- `lib/services/network/cookie/app_cookie_manager.dart` — Dio 拦截器
- `lib/services/network/cookie/cookie_jar_service.dart` — CookieJar 管理
- `lib/services/network/cookie/cookie_sync_coordinator.dart` — 双向同步编排
- `lib/services/network/cookie/cookie_write_through.dart` — 实时推送 + 冷启动注入
- `lib/services/network/cookie/raw_cookie_writer.dart` — 原生平台通道写入

### 平台策略

- `lib/services/network/cookie/strategy/platform_cookie_strategy.dart` — 抽象基类
- `lib/services/network/cookie/strategy/default_cookie_strategy.dart` — 默认实现
- `lib/services/network/cookie/strategy/android_cookie_strategy.dart`
- `lib/services/network/cookie/strategy/apple_cookie_strategy.dart`
- `lib/services/network/cookie/strategy/windows_cookie_strategy.dart`
- `lib/services/network/cookie/strategy/linux_cookie_strategy.dart`

### 原生代码

- `android/app/src/main/kotlin/.../MainActivity.kt` — `com.fluxdo/raw_cookie` channel
- `ios/Runner/AppDelegate.swift` — `com.fluxdo/raw_cookie` channel
- `macos/Runner/AppDelegate.swift` — `com.fluxdo/raw_cookie` channel

### 迁移

- `lib/services/migration_service.dart`

## 待实测验证

- [ ] iOS 上 `HTTPCookie.cookies(withResponseHeaderFields:for:)` 对 host-only cookie 是否真的比属性构造可靠
- [x] Android 应用内原生 CDP bridge 已打通 `Network.getCookies`
- [ ] Android 应用内原生 CDP bridge 的 `Network.setCookie` 需继续补实测验证
- [ ] `rawSetCookie` 是否被 `SetCookieParser.parse` 正确存入
- [ ] 全平台：`_t` 多副本日志是否消失
