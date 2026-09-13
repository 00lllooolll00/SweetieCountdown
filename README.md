# SweetieCountdown 甜系番茄钟

甜系治愈风格的 Android 番茄时钟（Flutter + Material 3）：马卡龙配色、果冻动效，
倒计时/正计时双模式、Tag 标签、多尺度统计图表、英文暖心短文、启动页每日一言。

## 功能

- **专注计时**：倒计时（默认 25 分钟，可调）/ 正计时；绝对时间戳对齐，后台锁屏不漂移
- **Tag 标签**：历史胶囊横滑复用，`+ 自定义` 即时新建；计时前必选 Tag
- **统计图表**：6h / 12h / 1d / 1w / 1m / 1y 六档，饼图 + 条形图 + 折线图（fl_chart）
- **暖心阅读**：Wiki 每日摘要 / James Clear 3-2-1 / Daily Good，下拉刷新 + Hive 离线缓存 + 收藏
- **启动一言**：本地名句库，Fade-in 动效，2 秒进主界面，可点跳过
- **甜系视觉**：柔白 `#FFFDF9` + 草莓粉 + 布丁黄 + 薄荷绿，大圆角，弹性进度条，归零撒花 + 轻震动

## 快速开始

```bash
flutter pub get
flutter run
```

测试与静态检查：

```bash
flutter analyze lib test
flutter test
```

## 发布 APK

在 GitHub 点 **Releases → Draft a new release → Publish**，Actions 会自动编译
debug 签名 APK 并挂到该 Release 附件（`app-debug.apk`），直接下载安装。

正式上架包请本地签名后编译：

```bash
# android/key.properties（已忽略，永不进仓库）填好 storePassword/keyPassword/keyAlias/storeFile，
# storeFile 建议放仓库外的绝对路径
flutter build apk --release
```

## 工程说明

- 技术栈：Flutter 3.47 Material 3 / Riverpod / hive_flutter（手写 adapter）/ fl_chart /
  dio + xml / flutter_animate / intl / uuid
- 本机开发使用 `./@env` 沙箱（Flutter SDK、Pub 缓存、Gradle、Android SDK 全在里面，
  `source @env/env.sh` 后再跑 flutter/dart/gradle 命令）；`@env/`、`build/`、
  `android/local.properties`、`*.hive` 均不进仓库，CI 不需要它们
- 分支流：`feat/*` → 测试全绿 → review → `--no-ff` 合 `main`
