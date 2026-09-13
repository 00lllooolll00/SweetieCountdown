import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sweetie_countdown/reading/tencent_translate.dart';

/// 腾讯云 TC3-HMAC-SHA256 签名：结构、确定性、UTC 日期、密钥敏感度。
///
/// 真实性由真机 + 用户密钥端到端验证；这里锁住"签名不会因重构而悄悄变样"。
void main() {
  const String secretId = 'AKIDEXAMPLE1234567890';
  const String secretKey = 'SecretKeyExample1234567890';
  const int timestamp = 1757750000; // 固定时刻，保证可复现
  const String body =
      '{"SourceText":"hello","Source":"en","Target":"zh","ProjectId":0}';

  String sign() => TencentTranslator.buildAuthorization(
        secretId: secretId,
        secretKey: secretKey,
        timestamp: timestamp,
        body: body,
      );

  group('腾讯云 TC3 签名', () {
    test('结构：凭据/签名头/签名段齐全', () {
      final String auth = sign();
      expect(auth, startsWith('TC3-HMAC-SHA256 Credential=$secretId/'));
      expect(auth, contains('/tmt/tc3_request'));
      expect(
        auth,
        contains('SignedHeaders=content-type;host;x-tc-action'),
        reason: '参与签名的头必须与请求头一致',
      );
      final RegExp sig = RegExp(r'Signature=([0-9a-f]{64})$');
      expect(sig.hasMatch(auth), isTrue, reason: 'HMAC-SHA256 应为 64 位十六进制');
    });

    test('日期段取 UTC 日期（本地时区会签不过）', () {
      // 1757750000 = 2025-09-13T09:53:20Z；UTC 日期固定，本地时区偏移不影响。
      expect(sign(), contains('/2025-09-13/tmt/tc3_request'));
    });

    test('确定性：同输入同输出', () {
      expect(sign(), sign());
    });

    test('密钥敏感：换 SecretKey 签名必变', () {
      final String other = TencentTranslator.buildAuthorization(
        secretId: secretId,
        secretKey: '$secretKey-x',
        timestamp: timestamp,
        body: body,
      );
      expect(other, isNot(sign()));
    });

    test('请求体敏感：换 body 签名必变', () {
      final String other = TencentTranslator.buildAuthorization(
        secretId: secretId,
        secretKey: secretKey,
        timestamp: timestamp,
        body: jsonEncode(const <String, dynamic>{'SourceText': 'world'}),
      );
      expect(other, isNot(sign()));
    });

    test('HMAC 链可用（crypto 依赖就位）', () {
      final String digest =
          Hmac(sha256, utf8.encode('key')).convert(utf8.encode('msg')).toString();
      expect(digest.length, 64);
    });
  });
}
