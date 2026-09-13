import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sweetie_countdown/settings/translation_settings.dart';

// 用真实 Hive（Hive.init(临时目录) + openBox）而不是手写 fake Box：
// 要验证的正是箱子的真实行为（JSON 字符串落盘、关箱后读写报错、泛型校验），
// fake 只会测到自己那份实现，测不到 hive 的坑；沙箱在临时目录，不留痕。

void main() {
  late Directory tempDir;
  late Box<dynamic> box;
  late TranslationSettingsStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sweetie_settings_');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>(kSettingsBoxName);
    store = TranslationSettingsStore(box);
  });

  tearDown(() async {
    // 先关箱再删目录，避免用例之间串味。
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('默认值与纯函数', () {
    test('出厂默认：自动档 + 空密钥', () {
      const TranslationSettings settings = TranslationSettings();

      expect(settings.vendor, TranslationVendor.auto);
      expect(settings.tencentSecretId, isEmpty);
      expect(settings.tencentSecretKey, isEmpty);
      expect(settings.hasTencentKeys, isFalse);
      expect(settings.label, '自动');
    });

    test('厂商中文名', () {
      expect(const TranslationSettings(vendor: TranslationVendor.tencent).label,
          '腾讯云');
      expect(const TranslationSettings(vendor: TranslationVendor.mymemory).label,
          'MyMemory');
      expect(const TranslationSettings(vendor: TranslationVendor.google).label,
          'Google');
    });

    test('hasTencentKeys：两个密钥 trim 后都非空才算配好', () {
      // 只有空白 = 没配。
      expect(
        const TranslationSettings(
          tencentSecretId: '   ',
          tencentSecretKey: '\t\n',
        ).hasTencentKeys,
        isFalse,
      );

      // 只填一半 = 没配。
      expect(
        const TranslationSettings(tencentSecretId: 'AKIDxxxx').hasTencentKeys,
        isFalse,
      );

      // 首尾空白不影响判定。
      expect(
        const TranslationSettings(
          tencentSecretId: '  AKIDxxxx  ',
          tencentSecretKey: '  SECRETxxxx  ',
        ).hasTencentKeys,
        isTrue,
      );

      // 大小写不归一：密钥原样算已配置。
      expect(
        const TranslationSettings(
          tencentSecretId: 'akidXXXX',
          tencentSecretKey: 'sEcretKey123',
        ).hasTencentKeys,
        isTrue,
      );
    });

    test('copyWith 只改传入的字段，原对象不变', () {
      const TranslationSettings origin = TranslationSettings(
        vendor: TranslationVendor.mymemory,
        tencentSecretId: 'AKIDxxxx',
        tencentSecretKey: 'SECRETxxxx',
      );

      final TranslationSettings switched =
          origin.copyWith(vendor: TranslationVendor.tencent);

      expect(switched.vendor, TranslationVendor.tencent);
      expect(switched.tencentSecretId, 'AKIDxxxx');
      expect(switched.tencentSecretKey, 'SECRETxxxx');
      // 原对象三个字段都没被改写。
      expect(origin.vendor, TranslationVendor.mymemory);
      expect(origin.tencentSecretId, 'AKIDxxxx');
      expect(origin.tencentSecretKey, 'SECRETxxxx');
    });

    test('toJson/fromJson 往返；厂商名大小写不敏感，认不出的回落 auto', () {
      const TranslationSettings origin = TranslationSettings(
        vendor: TranslationVendor.tencent,
        tencentSecretId: 'AKIDxxxx',
        tencentSecretKey: 'SECRETxxxx',
      );

      final TranslationSettings back = TranslationSettings.fromJson(
        jsonDecode(jsonEncode(origin.toJson())) as Map<String, dynamic>,
      );

      expect(back.vendor, TranslationVendor.tencent);
      expect(back.tencentSecretId, 'AKIDxxxx');
      expect(back.tencentSecretKey, 'SECRETxxxx');

      expect(
        TranslationSettings.fromJson(<String, dynamic>{'vendor': 'Tencent'})
            .vendor,
        TranslationVendor.tencent,
      );
      expect(
        TranslationSettings.fromJson(<String, dynamic>{'vendor': 'no-such'})
            .vendor,
        TranslationVendor.auto,
      );
      // 老记录缺字段：退化为默认值而不是抛。
      final TranslationSettings legacy = TranslationSettings.fromJson(
        <String, dynamic>{},
      );
      expect(legacy.vendor, TranslationVendor.auto);
      expect(legacy.tencentSecretId, isEmpty);
    });
  });

  group('TranslationSettingsStore（真实 Hive 沙箱）', () {
    test('save → read 原样往返，落盘是 JSON 字符串', () async {
      const TranslationSettings settings = TranslationSettings(
        vendor: TranslationVendor.tencent,
        tencentSecretId: 'AKIDxxxx',
        tencentSecretKey: 'SECRETxxxx',
      );

      await store.save(settings);

      // 免 TypeAdapter 的存储契约：箱里躺的是 jsonEncode 字符串。
      expect(box.get(kTranslationSettingsKey), isA<String>());

      final TranslationSettings got = store.read();
      expect(got.vendor, TranslationVendor.tencent);
      expect(got.tencentSecretId, 'AKIDxxxx');
      expect(got.tencentSecretKey, 'SECRETxxxx');

      // 再写一次覆盖旧值：切厂商后密钥必须原样留着。
      await store.save(settings.copyWith(vendor: TranslationVendor.google));
      final TranslationSettings switched = store.read();
      expect(switched.vendor, TranslationVendor.google);
      expect(switched.tencentSecretId, 'AKIDxxxx');
      expect(switched.tencentSecretKey, 'SECRETxxxx');
    });

    test('空箱 / 损坏 JSON / 非字符串值 / 类型不符 → 默认值且不抛', () async {
      expect(store.read().vendor, TranslationVendor.auto); // 空箱

      await box.put(kTranslationSettingsKey, '{不是 json');
      expect(store.read().vendor, TranslationVendor.auto); // 截断的 JSON

      await box.put(kTranslationSettingsKey, 42);
      expect(store.read().hasTencentKeys, isFalse); // 值不是字符串

      await box.put(kTranslationSettingsKey, '["tencent"]');
      expect(store.read().vendor, TranslationVendor.auto); // 是 JSON 但不是对象
    });

    test('箱子已关闭：read 返回默认值、save 静默失败（不抛）', () async {
      await store.save(
        const TranslationSettings(vendor: TranslationVendor.google),
      );
      await box.close();

      expect(store.read().vendor, TranslationVendor.auto);
      // 关箱后的写入只该被丢掉，不该抛给调用方。
      await store.save(
        const TranslationSettings(vendor: TranslationVendor.tencent),
      );
    });
  });

  group('translationSettingsProvider', () {
    test('箱已打开：build 读落盘值，update 落盘并刷新状态', () async {
      await store.save(
        const TranslationSettings(
          vendor: TranslationVendor.tencent,
          tencentSecretId: 'AKIDxxxx',
          tencentSecretKey: 'SECRETxxxx',
        ),
      );
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(translationSettingsProvider).vendor,
          TranslationVendor.tencent);
      expect(container.read(translationSettingsProvider).hasTencentKeys, isTrue);

      await container
          .read(translationSettingsProvider.notifier)
          .update(const TranslationSettings(vendor: TranslationVendor.google));

      expect(container.read(translationSettingsProvider).vendor,
          TranslationVendor.google);
      expect(store.read().vendor, TranslationVendor.google); // 真的落盘了
    });

    test('箱未打开：读默认值、update 只在内存生效，且不偷偷开箱', () async {
      await box.close(); // 模拟 main.dart 还没接线（或开箱失败）
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      final TranslationSettings initial =
          container.read(translationSettingsProvider);
      expect(initial.vendor, TranslationVendor.auto);
      expect(initial.hasTencentKeys, isFalse);

      await container
          .read(translationSettingsProvider.notifier)
          .update(const TranslationSettings(vendor: TranslationVendor.mymemory));

      expect(container.read(translationSettingsProvider).vendor,
          TranslationVendor.mymemory); // 内存兜底：本次会话内可用
      expect(Hive.isBoxOpen(kSettingsBoxName), isFalse);
    });
  });
}
