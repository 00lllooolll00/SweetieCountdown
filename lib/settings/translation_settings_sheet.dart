import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../reading/tencent_translate.dart';
import '../theme/sweetie_theme.dart';
import 'translation_settings.dart';

/// 厂商选项：顺序与 [TranslationVendor] 一致，各带一句选型说明。
const List<(TranslationVendor, String, String)> _vendorOptions =
    <(TranslationVendor, String, String)>[
  (TranslationVendor.auto, '自动', '腾讯云 → MyMemory → Google 依次尝试'),
  (TranslationVendor.tencent, '腾讯云', '500 万字符/月，需 SecretId / SecretKey'),
  (TranslationVendor.mymemory, 'MyMemory', '免注册，5 万字符/天'),
  (TranslationVendor.google, 'Google', '需可直连海外网络'),
];

/// 翻译服务设置面板：`showModalBottomSheet` 的底部弹窗内容。
///
/// 保存成功时 `pop(true)` 并弹一条 SnackBar；关闭按钮/下滑退出返回 null，
/// 调用方用 `result == true` 判断是否需要刷新。
class TranslationSettingsSheet extends ConsumerStatefulWidget {
  const TranslationSettingsSheet({super.key});

  @override
  ConsumerState<TranslationSettingsSheet> createState() =>
      _TranslationSettingsSheetState();
}

class _TranslationSettingsSheetState
    extends ConsumerState<TranslationSettingsSheet> {
  /// 连通性测试状态：进行中禁用按钮，结果用文字留在面板里（比 SnackBar 持久）。
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  /// 输入先落在本地字段，点「保存」才写回 store。
  late TranslationVendor _vendor;
  late String _secretId;
  late String _secretKey;

  late final TextEditingController _secretIdCtrl;
  late final TextEditingController _secretKeyCtrl;

  bool _obscureId = true;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    final TranslationSettings current = ref.read(translationSettingsProvider);
    _vendor = current.vendor;
    _secretId = current.tencentSecretId;
    _secretKey = current.tencentSecretKey;
    _secretIdCtrl = TextEditingController(text: _secretId);
    _secretKeyCtrl = TextEditingController(text: _secretKey);
  }

  @override
  void dispose() {
    _secretIdCtrl.dispose();
    _secretKeyCtrl.dispose();
    super.dispose();
  }

  /// 腾讯云与自动模式都会用到密钥，选中时把输入区展开。
  bool get _needsKeys =>
      _vendor == TranslationVendor.auto || _vendor == TranslationVendor.tencent;

  /// 用当前输入框里的密钥真实调一次腾讯云 TextTranslate（译一句问候语），
  /// 把结果（成功译文 / 失败原因）留在面板上——让用户自己判断密钥是否可用。
  Future<void> _testConnection() async {
    final String id = _secretIdCtrl.text.trim();
    final String key = _secretKeyCtrl.text.trim();
    if (id.isEmpty || key.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = '先填好 SecretId 和 SecretKey 再测';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final Dio dio = Dio();
    try {
      final String translated = await TencentTranslator(
        secretId: id,
        secretKey: key,
      ).translate(
        'Hello, sweetie.',
        dio: dio,
        timeout: const Duration(seconds: 12),
      );
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testResult = '连接成功，译文：$translated';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '连接失败：${_friendlyError(error)}';
      });
    } finally {
      dio.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 把底层异常压成一句人话（超时/密钥错/配额尽是最常见的三类）。
  String _friendlyError(Object error) {
    final String raw = error.toString().replaceFirst('Exception: ', '');
    if (raw.contains('SocketException') || raw.contains('TimeoutException')) {
      return '网络不通或超时（检查手机网络或代理）';
    }
    if (raw.contains('AuthFailure') || raw.contains('UnauthorizedOperation')) {
      return '密钥无效或无权限（检查 SecretId/SecretKey 与控制台开通状态）';
    }
    if (raw.contains('RequestLimitExceeded') || raw.contains('LimitExceeded')) {
      return '请求超限（免费额度可能已用尽）';
    }
    return raw.length > 60 ? '${raw.substring(0, 60)}…' : raw;
  }

  Future<void> _save() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await ref.read(translationSettingsProvider.notifier).update(
          TranslationSettings(
            vendor: _vendor,
            tencentSecretId: _secretId.trim(),
            tencentSecretKey: _secretKey.trim(),
          ),
        );
    if (!mounted) return;
    Navigator.of(context).pop(true);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('翻译设置已保存'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: SweetieColors.text,
        duration: Duration(milliseconds: 1400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        // 软键盘弹出时把内容顶上去，避免输入框被键盘盖住。
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(),
              const SizedBox(height: 2),
              RadioGroup<TranslationVendor>(
                groupValue: _vendor,
                onChanged: (TranslationVendor? next) {
                  if (next == null) return;
                  setState(() => _vendor = next);
                },
                child: Column(
                  children: <Widget>[
                    for (final (TranslationVendor vendor, String title,
                            String desc)
                        in _vendorOptions)
                      RadioListTile<TranslationVendor>(
                        value: vendor,
                        title: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          desc,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: SweetieColors.textLight,
                          ),
                        ),
                        activeColor: SweetieColors.pink,
                        selected: _vendor == vendor,
                        selectedTileColor: SweetieColors.soft(
                          SweetieColors.pink,
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        shape: const RoundedRectangleBorder(
                          borderRadius: SweetieTheme.cardRadius,
                        ),
                      ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: SweetieTheme.animationDuration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _needsKeys
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _keyInputs(),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 12),
              _localOnlyNote(),
              const SizedBox(height: 12),
              _testConnectionRow(),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: SweetieColors.pink,
                    foregroundColor: SweetieColors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: SweetieTheme.cardRadius,
                    ),
                  ),
                  onPressed: () => unawaited(_save()),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: <Widget>[
        const Expanded(
          child: Text(
            '翻译服务',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded, color: SweetieColors.textLight),
        ),
      ],
    );
  }

  /// 腾讯云密钥：两个本地输入框，默认打码、可点小眼睛查看。
  Widget _keyInputs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '腾讯云密钥',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
        _secretField(
          controller: _secretIdCtrl,
          hint: 'SecretId',
          obscure: _obscureId,
          onToggle: () => setState(() => _obscureId = !_obscureId),
          onChanged: (String value) => setState(() => _secretId = value),
        ),
        const SizedBox(height: 10),
        _secretField(
          controller: _secretKeyCtrl,
          hint: 'SecretKey',
          obscure: _obscureKey,
          onToggle: () => setState(() => _obscureKey = !_obscureKey),
          onChanged: (String value) => setState(() => _secretKey = value),
        ),
      ],
    );
  }

  Widget _secretField({
    required TextEditingController controller,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 15, letterSpacing: 0.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: SweetieColors.textLight),
        isDense: true,
        filled: true,
        fillColor: SweetieColors.background,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SweetieTheme.radius),
          borderSide: BorderSide.none,
        ),
        suffixIcon: IconButton(
          onPressed: onToggle,
          tooltip: obscure ? '显示' : '隐藏',
          icon: Icon(
            obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
            size: 20,
            color: SweetieColors.textLight,
          ),
        ),
      ),
    );
  }

  /// 「测试连接」按钮 + 结果文字（成功浅绿 / 失败浅红）。
  Widget _testConnectionRow() {
    final Color tone =
        _testOk ? const Color(0xFF2E7D63) : const Color(0xFFB3544B);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _testing ? null : () => unawaited(_testConnection()),
            style: OutlinedButton.styleFrom(
              foregroundColor: SweetieColors.pink,
              side: BorderSide(
                color: SweetieColors.pink.withValues(alpha: 0.45),
                width: 1.2,
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: const RoundedRectangleBorder(
                borderRadius: SweetieTheme.cardRadius,
              ),
            ),
            icon: _testing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering_rounded, size: 18),
            label: Text(_testing ? '测试中…' : '测试连接'),
          ),
        ),
        if (_testResult != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _testResult!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ],
      ],
    );
  }

  Widget _localOnlyNote() {
    return const Row(
      children: <Widget>[
        Icon(
          Icons.lock_outline_rounded,
          size: 14,
          color: SweetieColors.textLight,
        ),
        SizedBox(width: 6),
        Expanded(
          child: Text(
            '密钥只存在本机，不会上传',
            style: TextStyle(fontSize: 12, color: SweetieColors.textLight),
          ),
        ),
      ],
    );
  }
}
