import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// 应用设置所在 Hive box 名（全项目统一，与 main.dart 的开箱名一致）。
const String kSettingsBoxName = 'app_settings';

/// 翻译设置在 [kSettingsBoxName] 里的键；值是 jsonEncode 后的字符串（免 TypeAdapter）。
const String kTranslationSettingsKey = 'translation_settings';

/// 翻译服务厂商。
///
/// [auto] 是出厂档：按「腾讯云（配了密钥）→ MyMemory → Google」依次回退，
/// 其余三档表示用户指定单一厂商。
enum TranslationVendor { auto, tencent, mymemory, google }

/// 翻译服务设置：厂商 + 各厂商自己的密钥（目前只有腾讯云需要密钥）。
class TranslationSettings {
  const TranslationSettings({
    this.vendor = TranslationVendor.auto,
    this.tencentSecretId = '',
    this.tencentSecretKey = '',
  });

  /// 宽松解析：字段缺失 / 类型不对 / 厂商名不认识（含大小写不符）都退化为默认值，
  /// 手工改坏的设置不该让设置页打不开。
  factory TranslationSettings.fromJson(Map<String, dynamic> json) {
    final String rawVendor =
        (json['vendor'] ?? '').toString().trim().toLowerCase();
    return TranslationSettings(
      vendor: TranslationVendor.values.firstWhere(
        (TranslationVendor value) => value.name == rawVendor,
        orElse: () => TranslationVendor.auto,
      ),
      tencentSecretId: (json['tencentSecretId'] ?? '').toString(),
      tencentSecretKey: (json['tencentSecretKey'] ?? '').toString(),
    );
  }

  final TranslationVendor vendor;

  /// 腾讯云 API 密钥（SecretId / SecretKey），未配置为空串。
  final String tencentSecretId;
  final String tencentSecretKey;

  /// 两个密钥 trim 后都非空才算配置好；不做大小写归一（密钥本身就是大小写敏感串）。
  bool get hasTencentKeys =>
      tencentSecretId.trim().isNotEmpty && tencentSecretKey.trim().isNotEmpty;

  /// 厂商中文名，设置页直接展示。
  String get label => switch (vendor) {
        TranslationVendor.auto => '自动',
        TranslationVendor.tencent => '腾讯云',
        TranslationVendor.mymemory => 'MyMemory',
        TranslationVendor.google => 'Google',
      };

  TranslationSettings copyWith({
    TranslationVendor? vendor,
    String? tencentSecretId,
    String? tencentSecretKey,
  }) =>
      TranslationSettings(
        vendor: vendor ?? this.vendor,
        tencentSecretId: tencentSecretId ?? this.tencentSecretId,
        tencentSecretKey: tencentSecretKey ?? this.tencentSecretKey,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'vendor': vendor.name,
        'tencentSecretId': tencentSecretId,
        'tencentSecretKey': tencentSecretKey,
      };

  @override
  String toString() =>
      'TranslationSettings(${vendor.name}, keys: ${hasTencentKeys ? '已配置' : '未配置'})';
}

/// 翻译设置的读写：只认 [kSettingsBoxName] 箱里 [kTranslationSettingsKey] 的 JSON 字符串。
///
/// 不管是箱被关掉还是记录损坏，读一律退化为默认值、写一律静默放弃 —— 设置读不到
/// 只该表现为「回到自动档」，不该把异常抛到页面上。
class TranslationSettingsStore {
  TranslationSettingsStore(this.box);

  /// 由 main.dart 打开的 `Box<dynamic>`（泛型必须与开箱一致，否则 Hive 会抛类型错误）。
  final Box<dynamic> box;

  TranslationSettings read() {
    try {
      final Object? raw = box.get(kTranslationSettingsKey);
      if (raw is! String) return const TranslationSettings();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const TranslationSettings();
      return TranslationSettings.fromJson(decoded);
    } catch (_) {
      // 箱已关 / 不是合法 JSON：当作没配过。
      return const TranslationSettings();
    }
  }

  Future<void> save(TranslationSettings settings) async {
    try {
      await box.put(kTranslationSettingsKey, jsonEncode(settings.toJson()));
    } catch (_) {
      // 箱未打开（或被关闭）：写不进去就算了，设置只在本次会话内生效。
    }
  }
}

/// 翻译设置（App 内可改，落盘在 [kSettingsBoxName]）。
final translationSettingsProvider =
    NotifierProvider<TranslationSettingsNotifier, TranslationSettings>(
  TranslationSettingsNotifier.new,
);

class TranslationSettingsNotifier extends Notifier<TranslationSettings> {
  @override
  TranslationSettings build() => _store()?.read() ?? const TranslationSettings();

  /// 落盘并刷新状态；箱不可用时（未打开 / 单测里没初始化 Hive）只刷新内存状态。
  Future<void> update(TranslationSettings next) async {
    await _store()?.save(next);
    state = next;
  }

  /// 当前可用的读写器；`app_settings` 没打开 → null（内存兜底）。
  TranslationSettingsStore? _store() {
    try {
      if (!Hive.isBoxOpen(kSettingsBoxName)) return null;
      return TranslationSettingsStore(Hive.box<dynamic>(kSettingsBoxName));
    } catch (_) {
      return null;
    }
  }
}
