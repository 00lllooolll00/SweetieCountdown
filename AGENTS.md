# Repository Guidelines

## 项目概览

SweetieCountdown 甜系治愈风 Android 番茄钟（Flutter + Material 3）：倒计时/正计时、Tag 标签、
多尺度统计图表、英文暖心阅读（在线抓取 + 翻译 + Hive 缓存）、启动页每日一言。
仅 Android 平台（仓库只有 `android/`，无 ios/web/desktop）。

## 架构与数据流

- **状态管理**：flutter_riverpod 2.x，**全部手写 API，无 codegen**（无 build_runner/riverpod_generator）。
  provider 命名 `<领域>Provider`，统一声明在各模块文件尾部的 `// ---- Riverpod ----` 分节区。
- **可变状态一律 `Notifier`**（不用 StateNotifier/StateProvider）：`TimerEngineNotifier`、`TagHistoryNotifier`、
  `SelectedTagNotifier`、`StatsScaleNotifier`、`TranslationSettingsNotifier`。
- **Provider 类型选择**：装配用 `Provider`（`readingServiceProvider`/`tagStoreProvider`）、一次异步
  `FutureProvider`（`readingArticleProvider`/`favoritesProvider`）、订阅存储用 `StreamProvider`
  （`focusRecordsProvider` 监听 `box.watch()`）、派生用 `Provider`（`statsSnapshotProvider`）。
- **持久化**：hive_flutter，`lib/main.dart` 是唯一 init 点（模块只读写不 init，opener 幂等）。
  5 个 box：`focus_records`（`Box<FocusRecord>`）、`sweetie_tags`、`reading_cache`、`reading_favorites`、
  `app_settings`。仅 `FocusRecord` 用手写 `TypeAdapter`（`typeId = 7`），其余对象一律
  `jsonEncode` 字符串存储 + 宽松 `fromJson`（字段缺失/类型错退默认值）。
- **页面结构**：`SplashPage` → `SweetieHomeShell`（`IndexedStack` 三页签：Timer/Reading/Stats）。
  无 go_router；命名路由只有 `/home`，其余 `Navigator.push` + `showModalBottomSheet`/`showDialog`。
- **计时数据流**：`TimerPage` 每帧 Ticker 读时间戳差值重绘 → 结束 `saveFocusRecord` 写 Hive →
  `focusRecordsProvider`（`box.watch()`）推送 → `statsSnapshotProvider` 聚合 → `StatsPage` 重绘。
- **阅读数据流**：`ref.invalidate(readingArticleProvider)` → `ReadingService.fetchNext()` 乱序选源 →
  8s 超时抓取 → 翻译 → Hive 缓存（LRU 30 篇）；失败按 **在线源 → 缓存 → `builtInArticles`** 三级降级。
- **计时引擎不变量**：`TimerEngine` 是不可变纯 Dart 类，剩余/已用时长**永远由绝对时间戳差值计算**
  （倒计时 `endAt - now`，正计时 `now - startedAt - pausedTotal`），**不存在 `Timer.periodic` 累减**——
  切后台/锁屏/掉帧不漂移。暂停→恢复把 `endAt` 顺延同样的 gap，剩余时间不缩水。

## 关键目录

| 路径 | 用途 |
|---|---|
| `lib/main.dart` | 入口 + Hive 全局初始化 + MaterialApp/导航壳 |
| `lib/timer/` | 计时引擎（`timer_engine.dart`，含 TagStorage/TagStore + provider）、计时页、表盘 |
| `lib/reading/` | 抓取/翻译/缓存/收藏服务（`reading_service.dart` 为模块核心，含全部解析纯函数）、腾讯云签名、阅读/收藏/启动页 |
| `lib/stats/` | `focus_record.dart`（模型 + 手写 adapter）、`stats_logic.dart`（分桶聚合纯函数 + Hive 存取 + provider）、统计页 |
| `lib/settings/` | 翻译设置模型/Store/provider + 设置弹窗 |
| `lib/theme/` | `sweetie_theme.dart` 调色板与主题工厂、`aurora_background.dart` 极光背景 |
| `lib/widgets/` | 通用组件（`liquid_segmented_control.dart`，导航与模式切换复用） |
| `test/` | 12 个测试文件，平铺无子目录，与 lib 模块一一对应 |
| `assets/` | `quotes.json`（每日一言语料）、`secrets.example.json`（密钥模板）、`icon/` |
| `@env/` | 本地开发沙箱（SDK/缓存/keystore/日志），整体 gitignored |

## 开发命令

⚠️ **每个 shell 会话先激活沙箱**，否则 flutter/dart/gradle 不可用或触发联网下载：

```bash
source @env/env.sh        # 注入仓库内 Flutter SDK/Pub 缓存/Gradle/Android SDK，并导出 SWEETIE_SANDBOX=1

flutter pub get
flutter run
flutter analyze lib test  # 静态分析（README 与 CI 的精确命令）
flutter test              # 全量测试
flutter test test/timer_engine_test.dart                          # 单文件
flutter test test/timer_engine_test.dart --plain-name "用例名"     # 按名过滤
flutter build apk --release   # 产物：build/app/outputs/flutter-apk/app-release.apk
```

分支流：`feat/*` → 测试全绿 → review → `--no-ff` 合 `main`。
CI（`.github/workflows/release-apk.yml`）在 Release published 时重建签名并上传 APK，**不依赖 @env**。

## 代码约定与常见模式

- **命名**：provider `<名>Provider`；Notifier 类 `<名>Notifier`；box 名常量 `kXxxBoxName`/`<域>BoxName`；
  存储 key 常量 `kTranslationSettingsKey`/`cacheIndexKey`。私有 widget 一律 `_Xxx`（如 `_TagChip`、
  `_PrimaryActionButton`、`_DurationWheelSheet`）。
- **注释语言中文，且写"为什么"**：如 `_recordFocus` 注释解释为何用 `elapsedAt(endAt)` 口径而非起止区间
  （暂停顺延会虚增）；`_box()` 注释解释 Hive 泛型校验陷阱。新增复杂逻辑应沿用此风格。
- **错误处理 = 降级而非抛出**（核心契约）：catch 后静默换路并注释后果——
  语录失败退 `fallbackQuotes`、翻译失败置 `translationFailed` 保留英文、抓取逐源吞异常换下一个、
  设置读写失败退默认值、落库失败"只影响统计，不打断庆祝"。**新增抓取/翻译路径必须维持"永不抛错给 UI"链条**。
  唯一主动抛错的是装配期契约检查（`tagStoreProvider` 的 `StateError`）。
- **异步**：IO 用 `async/await`；唯一持续流是 `focusRecordsProvider` 的 `box.watch()`；
  UI 帧驱动用 `Ticker` + `ValueNotifier<int> _frames`（不 setState 刷全页）；
  刻意发后不管的写操作用 `unawaited()`。
- **依赖注入 = 构造参数可选注入 + provider override**：`ReadingService({Dio? dio, translate, readSettings, ...})`；
  `TagStorage` 接口 + `MemoryTagStorage`/`HiveTagStorage` 双实现；纯函数显式收 `DateTime now` 保证可测。
  服务装配在 provider 内，settings 用 `ref.read` 实时读取（避免服务实例随设置重建）。
- **widget 拆分**：页面 = 1 个 Consumer(Stateful)Widget + 多个私有展示 widget；
  子 widget 尽量收参数而非自己读 provider（`TimerDial` 收 `engine/frames/breath`）。
- **theme**：颜色一律引用 `SweetieColors.*`、圆角/阴影用 `SweetieTheme.radius`/`cardShadow()`，模块不自带色值。
- **纯函数优先**：解析/聚合/格式化全为无 Flutter 依赖的顶层函数（`parseFeedArticles`、`aggregateStats`），
  与 provider 接线分离，对应 test/ 下同名测试。

## 隐式契约与陷阱（改动前必读）

1. **落库口径**：用 `elapsedAt(engine.endAt ?? now)`（暂停顺延后仍准确），勿改用 `startedAt→endAt` 区间；
   时长 <1s 不留痕。`FocusRecord` 时间字段统一 epoch 毫秒，统计按 `[startMs, endMs)` 半开区间切分。
2. **Tag 必选且计时中锁定**：仅 idle/finished 可换 Tag/模式；未选 Tag 落库用 `defaultFocusTag = '专注'` 兜底；
   删除当前选中 Tag 后选中需切到历史第一个。`TagStore.clear()` 存空列表而非删 key（"清空 ≠ 从未写入"）。
3. **Hive**：`Box<String>` 的箱必须用 `Hive.box<String>` 取（用 `dynamic` 会抛 HiveError）；
   新增 box 要同步改 `main.dart`；`focusRecordTypeId = 7` 全项目唯一，`FocusRecordAdapter` 字段顺序即落盘顺序，勿调。
4. **`reading_cache` 箱**：`__reading_cache_index__` 是淘汰索引保留键，遍历时必须跳过。
5. **腾讯云签名必须 UTC**：`TencentTranslator` TC3-HMAC-SHA256 的时间戳与 date 段用 `isUtc: true`，本地时区签不过。
6. **密钥双通道**：Hive 设置（`TranslationSettings.tencentSecretId/Key`）优先，`assets/secrets.json`（运行时读 asset，非编译期 env）仅兜底，缺失静默走免费链 MyMemory/Google。
7. **布局陷阱（有防回归测试）**：计时页 `resizeToAvoidBottomInset: false`（键盘只出现在弹窗 route）；
   标签条高度 84 且 `clipBehavior: Clip.none`（否则选中胶囊光晕被裁）。
8. **省电契约**：`TimerPage.active`/`AuroraBackground.running` 为 false 时停 Ticker/呼吸动画；
   Ticker 启停用 `statusAt(now)` 判断（到点后引擎仍 isActive，不能用 `isTicking`）。
9. **`android/build.gradle.kts` 的 `SWEETIE_SANDBOX=1` 离线钉定分支是沙箱专属补丁，勿删**；
   且不要在 `source @env/env.sh` 之前手动跑 gradle。

## 重要文件

| 文件 | 说明 |
|---|---|
| `lib/main.dart` | 入口；Hive 唯一初始化点（`initStatsStorage` + 各 `openBox`）；`SweetieHomeShell` 三页签 |
| `lib/timer/timer_engine.dart` | 计时引擎 + `TagStorage`/`TagStore` + 该域全部 provider |
| `lib/reading/reading_service.dart` | 阅读模块核心：数据类、解析纯函数、三级降级服务、缓存/收藏、provider |
| `lib/reading/tencent_translate.dart` | 腾讯云 TMT 签名（纯函数）与调用 |
| `lib/stats/focus_record.dart` | `FocusRecord` 模型 + 手写 `TypeAdapter`（typeId 7） |
| `lib/stats/stats_logic.dart` | 六档分桶/聚合纯函数 + Hive 存取 + 统计 provider |
| `lib/theme/sweetie_theme.dart` | `SweetieColors` 调色板 + `SweetieTheme.toThemeData()`（Material 3） |
| `pubspec.yaml` | 依赖与资产声明；`version: 1.0.1+2` 驱动 Android versionCode/Name |
| `.github/workflows/release-apk.yml` | CI：publish Release → 签名构建 → 验签 → 上传 `app-release.apk` 附件 |
| `@env/env.sh` | 沙箱激活脚本（本机开发唯一环境入口） |
| `android/app/build.gradle.kts` | applicationId `com.sweetie.sweetie_countdown`；签名二态（有 `key.properties` → release，缺失 → debug 回退） |

## 运行时与工具链偏好

- **SDK**：`pubspec.yaml` 要求 Dart `>=3.5.0 <4.0.0`；`pubspec.lock` 锁 Dart `>=3.11.0 <4.0.0`、Flutter `>=3.38.4`；
  CI 固定 Flutter **3.47.4** stable。本机用 `@env/flutter` 内 SDK。
- **包管理器**：pub（`flutter pub get`）。
- **Android 构建**：Java/Kotlin JVM **17**；Gradle **9.3.1**；AGP **9.1.0** + Kotlin **2.4.0**；
  compileSdk 35、build-tools 34.0.0、NDK 27.0.12077973；repos 走阿里云/腾讯镜像。
- **Lint**：仓库根**无 `analysis_options.yaml`**，规则仅来自 dev 依赖 `flutter_lints: ^6.0.0`（默认规则集）。
- **签名**：`android/key.properties` 由开发者本地填写（字段 `storePassword/keyPassword/keyAlias/storeFile`，
  `storeFile` 指向仓库外 `../@env/.keystore/`）；CI 从 GitHub Secrets 现场生成。密钥值永不进仓库。
- **禁区（已 gitignore，禁止提交/复述其内容）**：`@env/` 整目录（含 keystore、`*.log` 日志）、
  `assets/secrets.json`、`android/key.properties`、`android/local.properties`、`*.hive`、`build/`、`.dart_tool/`。
- 构建/测试输出按约定重定向到 `@env/*.log`（如 `relbuild*.log`、`gates*.log`），不进仓库。

## 测试与 QA

- **框架**：`flutter_test`（无 mocktail/mockito/金标测试/integration_test，**全部手写 fake**：
  `MemoryTagStorage implements TagStorage`、`_FakeAdapter implements HttpClientAdapter`）。
- **两层结构**（12 个文件，6 纯逻辑 + 6 widget，平铺 `test/`，命名 `<模块>_test.dart` 与 lib 一一对应）：
  纯逻辑直接构造领域对象断言；widget 用 `ProviderContainer(overrides:)` 或
  `UncontrolledProviderScope` + `overrideWithValue` 注入，`addTearDown(container.dispose)`。
- **运行**：`flutter analyze lib test && flutter test`（CI 与 README 一致）；coverage 仅本地可选（CI 未用）。
- **约定**：
  - 时间相关一律固定 `final t0 = DateTime(2026, 3, 11, 9);` 显式传参，不 mock 时钟；
  - 分组与用例名用中文完整句：`group('中文描述', ...)`、`testWidgets('用例名：行为预期', ...)`；
  - **勿用 `pumpAndSettle`**（常驻动画组件永远安定不了），统一 `await tester.pump(const Duration(milliseconds: 400))` 固定推进；
  - 长按：`startGesture → pump(60ms) → pump(1600ms) → hold.up()`；
  - 需要验证 Hive 落盘契约时用真实 Hive + `Directory.systemTemp.createTemp`（tearDown 里 `Hive.close()` 再删目录）；
  - 断言加 `reason:` 中文说明；浮点/颜色用近似比较。
- **新增代码的测试要求**：新纯逻辑 → 配套 `<模块>_test.dart`（参考 `test/stats_logic_test.dart` 边界风格、
  `test/timer_engine_test.dart` 状态机+Hive 组合）；新 UI → 参考 `test/single_key_test.dart` 的 `pumpPage` 骨架；
  新网络 → 参考 `test/reading_service_test.dart`；修 bug 必写防回归（参考 `test/timer_page_keyboard_test.dart`，
  顶部文档注释记录踩坑背景）。
