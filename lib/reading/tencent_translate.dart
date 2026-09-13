import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

/// 腾讯云机器翻译（TMT）客户端：TC3-HMAC-SHA256 签名 + `TextTranslate`。
///
/// 免费额度 500 万字符/月（每月 1 日自动发放），远超 MyMemory 的 5 万字符/天；
/// 密钥放在 `assets/secrets.json`（已 gitignore），没配就自动回落到 MyMemory。
///
/// 协议要点：签名只覆盖 `content-type;host;x-tc-action` 三个头 + 请求体的哈希，
/// 时间戳必须是 **UTC**（签名里的 date 也取 UTC 日期，本地时区会签不过）。
class TencentTranslator {
  TencentTranslator({
    required this.secretId,
    required this.secretKey,
    this.region = 'ap-guangzhou',
  });

  static const String host = 'tmt.tencentcloudapi.com';
  static const String service = 'tmt';
  static const String version = '2018-03-21';
  static const String action = 'TextTranslate';

  /// 签名里参与计算、必须与请求头一致的头（顺序不能改）。
  static const String signedHeaders = 'content-type;host;x-tc-action';

  final String secretId;
  final String secretKey;
  final String region;

  /// 英译中：一篇文章按句分块后逐块调用（单块 450 字符，远低于单次上限）。
  Future<String> translate(
    String text, {
    required Dio dio,
    required Duration timeout,
  }) async {
    final String body = jsonEncode(<String, dynamic>{
      'SourceText': text,
      'Source': 'en',
      'Target': 'zh',
      'ProjectId': 0,
    });
    final int timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final Map<String, String> headers = <String, String>{
      'Authorization': buildAuthorization(
        secretId: secretId,
        secretKey: secretKey,
        timestamp: timestamp,
        body: body,
      ),
      'Content-Type': 'application/json; charset=utf-8',
      'Host': host,
      'X-TC-Action': action,
      'X-TC-Timestamp': '$timestamp',
      'X-TC-Version': version,
      'X-TC-Region': region,
    };

    final Response<String> response = await dio
        .post<String>(
          'https://$host',
          data: body,
          options: Options(
            headers: headers,
            responseType: ResponseType.plain,
            contentType: 'application/json; charset=utf-8',
          ),
        )
        .timeout(timeout);

    final Object? decoded = jsonDecode(response.data ?? '{}');
    if (decoded is! Map) throw const FormatException('腾讯云响应异常');
    final Object? resp = decoded['Response'];
    if (resp is! Map) throw const FormatException('腾讯云响应异常');
    final Object? error = resp['Error'];
    if (error != null) {
      final Object? message = error is Map ? error['Message'] : error;
      throw FormatException('腾讯云翻译失败: $message');
    }
    final Object? target = resp['TargetText'];
    if (target is! String || target.trim().isEmpty) {
      throw const FormatException('腾讯云翻译返回为空');
    }
    return target.trim();
  }

  /// 组装 `Authorization` 头（纯函数，可单测）。
  ///
  /// 步骤：规范请求串 → 待签名字符串 → 逐级派生签名密钥 → 拼接凭据。
  static String buildAuthorization({
    required String secretId,
    required String secretKey,
    required int timestamp,
    required String body,
    String hostName = host,
    String serviceName = service,
    String actionName = action,
  }) {
    final String date = _utcDate(timestamp);

    // 1) 规范请求串（method / uri / query / headers / signedHeaders / payloadHash）。
    final String canonicalRequest = <String>[
      'POST',
      '/',
      '',
      'content-type:application/json; charset=utf-8\n'
          'host:$hostName\n'
          'x-tc-action:${actionName.toLowerCase()}\n',
      signedHeaders,
      sha256.convert(utf8.encode(body)).toString(),
    ].join('\n');

    // 2) 待签名字符串。
    final String credentialScope = '$date/$serviceName/tc3_request';
    final String stringToSign = <String>[
      'TC3-HMAC-SHA256',
      '$timestamp',
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    // 3) 派生签名密钥：TC3 + secretKey → date → service → tc3_request。
    final List<int> secretDate =
        _hmac(utf8.encode('TC3$secretKey'), date);
    final List<int> secretService = _hmac(secretDate, serviceName);
    final List<int> secretSigning = _hmac(secretService, 'tc3_request');
    final String signature =
        Hmac(sha256, secretSigning).convert(utf8.encode(stringToSign)).toString();

    // 4) 拼 Authorization。
    return 'TC3-HMAC-SHA256 '
        'Credential=$secretId/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';
  }

  static List<int> _hmac(List<int> key, String message) =>
      Hmac(sha256, key).convert(utf8.encode(message)).bytes;

  /// 时间戳 → UTC 日期（`yyyy-MM-dd`）。本地时区会与腾讯云对不上。
  static String _utcDate(int timestamp) {
    final DateTime utc =
        DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }
}
