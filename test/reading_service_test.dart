import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:sweetie_countdown/reading/reading_service.dart';

// 全部 mock：不碰真网、不碰真设备，只验证降级与持久化契约。

const String _wikiJson = '{"title":"Deep work","extract":"Deep work is the '
    'ability to focus without distraction on a cognitively demanding task. '
    'It is becoming increasingly rare and increasingly valuable in our '
    'economy, which makes it a superpower for those who can cultivate it.",'
    '"content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Deep_work"}}}';

const String _jamesClearXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>James Clear</title>
    <item>
      <title>3-2-1: On focus</title>
      <link>https://jamesclear.com/3-2-1/on-focus</link>
      <description><![CDATA[<p>Focus is the art of <strong>knowing</strong> what to ignore &amp; what to chase.</p><p>Do it today.</p>]]></description>
      <pubDate>Thu, 11 Sep 2025 10:00:00 +0000</pubDate>
    </item>
    <item>
      <title>3-2-1: On rest</title>
      <link>https://jamesclear.com/3-2-1/on-rest</link>
      <content:encoded><![CDATA[<p>Rest is part of the work, not a reward for it.</p>]]></content:encoded>
      <dc:creator>James Clear</dc:creator>
    </item>
  </channel>
</rss>
''';

const String _atomXml = '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>A small kindness</title>
    <link href="https://www.dailygood.org/story/kindness" />
    <summary type="html">&lt;p&gt;Kindness is a muscle. &lt;em&gt;Train it&lt;/em&gt; daily.&lt;/p&gt;</summary>
  </entry>
</feed>
''';

ResponseBody _jsonBody(String body) => ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json; charset=utf-8'],
      },
    );

ResponseBody _xmlBody(String body) => ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/rss+xml; charset=utf-8'],
      },
    );

/// 把 [unit] 重复 [times] 次（Dart 没有 `'a' * n`）。
String _repeat(String unit, int times) =>
    List<String>.filled(times, unit).join();

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handle);

  final Future<ResponseBody> Function(RequestOptions options) _handle;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handle(options);
  }
}

/// 在线：Wikipedia 返回合法 JSON，其余地址返回空 feed（无 item → 源被跳过），
/// 所以随机选源的顺序不影响结果——文章必定来自 wiki。
Dio _wikiDio() => Dio()
  ..httpClientAdapter = _FakeAdapter((RequestOptions options) async {
    return options.uri.toString().contains('wikipedia')
        ? _jsonBody(_wikiJson)
        : _xmlBody('<rss><channel></channel></rss>');
  });

/// 断网 / 超时：请求永不返回（由服务里的 timeout 兜底）。
Dio _deadDio() => Dio()
  ..httpClientAdapter = _FakeAdapter(
    (RequestOptions options) => Completer<ResponseBody>().future,
  );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sweetie_reading_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    // 每个用例独立目录：先关箱再删目录，避免缓存/收藏串味。
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('feed 解析（纯函数，不联网）', () {
    test('RSS 2.0：标题 / 正文 / 链接 / 作者 + HTML 与实体清洗', () {
      final List<ReadingArticle> articles =
          parseFeedArticles(_jamesClearXml, ReadingSource.jamesClear);

      expect(articles, hasLength(2));
      final ReadingArticle first = articles.first;
      expect(first.title, '3-2-1: On focus');
      expect(first.url, 'https://jamesclear.com/3-2-1/on-focus');
      expect(first.body, contains('knowing'));
      expect(first.body, contains('&')); // &amp; 已还原
      expect(first.body, contains('\n')); // </p> 转成段落换行
      expect(first.body, isNot(contains('<'))); // 标签已剥离
      expect(first.id, isNotEmpty);

      final ReadingArticle second = articles[1];
      expect(second.title, '3-2-1: On rest');
      expect(second.body, 'Rest is part of the work, not a reward for it.');
      expect(second.author, 'James Clear'); // content:encoded 与 dc:creator
      expect(second.id, isNot(first.id));
    });

    test('Atom：entry / link href / 转义 HTML 的 summary', () {
      final List<ReadingArticle> articles =
          parseFeedArticles(_atomXml, ReadingSource.dailyGood);

      expect(articles, hasLength(1));
      expect(articles.single.title, 'A small kindness');
      expect(articles.single.url, 'https://www.dailygood.org/story/kindness');
      expect(articles.single.body, 'Kindness is a muscle. Train it daily.');
    });

    test('脏数据不炸：无 item 的 feed 返回空表', () {
      expect(
        parseFeedArticles('<rss><channel></channel></rss>',
            ReadingSource.dailyGood),
        isEmpty,
      );
    });
  });

  group('翻译分块（纯函数）', () {
    // 200 个 focus 拼成的超长单句（无句末标点），长 1199。
    final String longSentence = _repeat('focus ', 200).trimRight();

    test('超长单句硬切：单块不超上限，拼回原文一字不丢', () {
      expect(longSentence.length, 1199);

      final List<String> chunks = splitForTranslation(longSentence);

      expect(chunks.map((String chunk) => chunk.length), <int>[419, 419, 359]);
      expect(chunks.every((String chunk) => chunk.length <= 420), isTrue);
      expect(chunks.join(' '), longSentence);
    });

    test('多句拼块：每块 <= 420，拼回原文一字不丢', () {
      final String sentence = '${_repeat('focus ', 20).trimRight()}.';
      expect(sentence.length, 120);
      final String text = List<String>.filled(4, sentence).join(' ');
      expect(text.length, 483);

      final List<String> chunks = splitForTranslation(text);

      expect(chunks.map((String chunk) => chunk.length), <int>[362, 120]);
      expect(chunks.every((String chunk) => chunk.length <= 420), isTrue);
      expect(chunks.join(' '), text);
      expect(chunks.first.endsWith('.'), isTrue);
      expect(chunks.last.endsWith('.'), isTrue);
    });

    test('空文本返回空表；短文本原样返回', () {
      expect(splitForTranslation('   '), isEmpty);
      expect(
        splitForTranslation('Deep work is focus.'),
        <String>['Deep work is focus.'],
      );
    });
  });

  group('Wikipedia 摘要解析（纯函数）', () {
    test('内容太薄（extract < 80 字）返回 null，交给下一个源', () {
      const String thinJson =
          '{"title":"Too thin","extract":"Deep work is focus."}';
      expect(parseWikiSummary(thinJson), isNull);
      // 79 字仍算薄内容；80 字达标。
      expect(
        parseWikiSummary('{"title":"Edge","extract":"${_repeat('a', 79)}"}'),
        isNull,
      );
      final ReadingArticle? edge =
          parseWikiSummary('{"title":"Edge","extract":"${_repeat('a', 80)}"}');
      expect(edge, isNotNull);
      expect(edge!.body, _repeat('a', 80));
      expect(edge.source, ReadingSource.wiki);
    });

    test('HTML 标签不计入内容长度', () {
      final String html =
          '${_repeat('<p>', 30)}short text${_repeat('</p>', 30)}';
      expect(parseWikiSummary('{"title":"Thin","extract":"$html"}'), isNull);
    });

    test('坏数据：非 JSON 抛 FormatException（服务层兜住换源），空标题返回 null', () {
      expect(() => parseWikiSummary('not json'), throwsFormatException);
      expect(
        parseWikiSummary('{"title":"","extract":"${_repeat('a', 200)}"}'),
        isNull,
      );
    });
  });

  group('降级与缓存', () {
    test('断网 / 超时：降级到内置兜底文章，不抛错、不空手', () async {
      final ReadingService service = ReadingService(
        dio: _deadDio(),
        httpTimeout: const Duration(milliseconds: 40),
        translate: (String text) async => throw StateError('offline'),
      );

      final ReadingArticle article = await service.fetchNext();

      expect(article.source, ReadingSource.builtIn);
      expect(article.isBuiltIn, isTrue);
      expect(article.body.trim(), isNotEmpty);
      // 内置文章自带中文，无需翻译也不该被标记失败。
      expect(article.translatedBody.trim(), isNotEmpty);
      expect(article.translationFailed, isFalse);
      expect(builtInArticles, hasLength(3));
    });

    test('在线成功→写缓存；换实例走弱网时命中缓存', () async {
      final ReadingService online = ReadingService(
        dio: _wikiDio(),
        httpTimeout: const Duration(seconds: 1),
        translate: (String text) async => '中文译文',
      );
      final ReadingArticle first = await online.fetchNext();
      expect(first.source, ReadingSource.wiki);
      expect(first.fromCache, isFalse);
      expect(first.translatedBody, '中文译文');

      final ReadingService offline = ReadingService(
        dio: _deadDio(),
        httpTimeout: const Duration(milliseconds: 40),
        translate: (String text) async => throw StateError('offline'),
      );
      final ReadingArticle second = await offline.fetchNext();

      expect(second.fromCache, isTrue);
      expect(second.id, first.id);
      expect(second.body, first.body);
      // 缓存里已带译文，命中时不再请求翻译接口。
      expect(second.translatedBody, '中文译文');
      expect(second.translationFailed, isFalse);
    });

    test('翻译失败：保留英文原文 + 提示标记；恢复后 retranslate 补译文', () async {
      var down = true;
      final ReadingService service = ReadingService(
        dio: _wikiDio(),
        httpTimeout: const Duration(seconds: 1),
        translate: (String text) async {
          if (down) throw StateError('翻译服务挂了');
          return '译文';
        },
      );

      final ReadingArticle article = await service.fetchNext();
      expect(article.translationFailed, isTrue);
      expect(article.translatedBody, isEmpty);
      expect(article.body, contains('Deep work'));

      down = false;
      final ReadingArticle retried = await service.retranslate(article);
      expect(retried.translationFailed, isFalse);
      expect(retried.translatedBody, '译文');
      expect(retried.title, article.title);
      expect(retried.id, article.id);
    });

    test('同源多地址：首地址空 feed 时自动换次地址', () async {
      const String rss = 'https://www.dailygood.org/rss.php';
      const String feed = 'https://www.dailygood.org/feed/';
      final List<String> requested = <String>[];
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeAdapter((RequestOptions options) async {
          final String uri = options.uri.toString();
          requested.add(uri);
          return uri == feed
              ? _xmlBody(_atomXml)
              : _xmlBody('<rss><channel></channel></rss>');
        });
      final ReadingService service = ReadingService(
        dio: dio,
        httpTimeout: const Duration(seconds: 1),
        translate: (String text) async => '译文',
      );

      final ReadingArticle article = await service.fetchNext();

      expect(article.source, ReadingSource.dailyGood);
      expect(article.title, 'A small kindness'); // 只有次地址有文章
      expect(article.url, 'https://www.dailygood.org/story/kindness');
      expect(article.translatedBody, '译文');
      expect(requested, containsAll(<String>[rss, feed]));
      expect(requested.indexOf(rss), lessThan(requested.indexOf(feed)));
    });

    test('Wikipedia 摘要太薄 → 换成下一个源，不返回半篇', () async {
      final Dio dio = Dio()
        ..httpClientAdapter = _FakeAdapter((RequestOptions options) async {
          final String uri = options.uri.toString();
          if (uri.contains('wikipedia')) {
            return _jsonBody(
              '{"title":"Too thin","extract":"Deep work is focus."}',
            );
          }
          return uri == 'https://jamesclear.com/feed'
              ? _xmlBody(_jamesClearXml)
              : _xmlBody('<rss><channel></channel></rss>');
        });
      final ReadingService service = ReadingService(
        dio: dio,
        httpTimeout: const Duration(seconds: 1),
        translate: (String text) async => '译文',
      );

      final ReadingArticle article = await service.fetchNext();

      expect(article.source, ReadingSource.jamesClear);
      expect(article.title, isNotEmpty);
      expect(article.body, isNotEmpty);
      expect(article.translatedBody, '译文');
    });
  });

  group('缓存淘汰', () {
    ReadingService reader() => ReadingService(
          dio: _deadDio(),
          httpTimeout: const Duration(milliseconds: 20),
          translate: (String text) async => '译文',
        );

    // retranslate 是公开的写缓存路径（内部走 _remember）。
    ReadingArticle newArticle(int i) => ReadingArticle(
          id: 'cache-$i',
          source: ReadingSource.wiki,
          title: 'Title $i',
          body: 'Body $i',
        );

    Set<String> articleKeys(Box<String> box) => box.keys
        .cast<String>()
        .where((String key) => key != ReadingService.cacheIndexKey)
        .toSet();

    test('超过 30 篇删最旧：第 31 篇写入后最早那篇被淘汰', () async {
      final ReadingService service = reader();
      for (int i = 0; i < 31; i++) {
        await service.retranslate(newArticle(i));
      }

      final Box<String> box =
          await Hive.openBox<String>(ReadingService.cacheBoxName);
      final Set<String> ids = articleKeys(box);

      expect(ids, hasLength(30));
      expect(ids, isNot(contains('cache-0'))); // 最旧
      expect(ids, contains('cache-1'));
      expect(ids, contains('cache-30')); // 最新
    });

    test('升级前写入的老缓存（索引里没记录）优先被淘汰', () async {
      final Box<String> box =
          await Hive.openBox<String>(ReadingService.cacheBoxName);
      await box.put(
        'legacy-0',
        jsonEncode(<String, String>{
          'id': 'legacy-0',
          'source': 'wiki',
          'title': 'Old cache',
          'body': 'Written before the eviction index existed.',
        }),
      );

      final ReadingService service = reader();
      for (int i = 0; i < 30; i++) {
        await service.retranslate(newArticle(i));
      }

      final Set<String> ids = articleKeys(box);
      expect(ids, hasLength(30));
      expect(ids, isNot(contains('legacy-0')));
      expect(ids, contains('cache-29'));
    });
  });

  group('收藏', () {
    test('收藏往返：跨服务实例读回，取消后移除', () async {
      final ReadingService service = ReadingService(
        dio: _deadDio(),
        httpTimeout: const Duration(milliseconds: 20),
      );
      final ReadingArticle article = builtInArticles.first;

      expect(await service.isFavorite(article.id), isFalse);
      expect(await service.toggleFavorite(article), isTrue);
      expect(await service.isFavorite(article.id), isTrue);

      final ReadingService reopened = ReadingService(
        dio: _deadDio(),
        httpTimeout: const Duration(milliseconds: 20),
      );
      expect(await reopened.isFavorite(article.id), isTrue);
      final List<ReadingArticle> favorites = await reopened.favoriteArticles();
      expect(favorites.map((ReadingArticle a) => a.id), contains(article.id));
      expect(favorites.single.title, article.title);
      expect(favorites.single.translatedBody, article.translatedBody);

      expect(await reopened.toggleFavorite(article), isFalse);
      expect(await service.isFavorite(article.id), isFalse);
      expect(await service.favoriteArticles(), isEmpty);
    });
  });

  group('启动语录', () {
    test('解析：en/zh/author 主格式，容错纯字符串与非法 JSON', () {
      final List<DailyQuote> quotes = parseQuotes(
        '[{"en":"A","zh":"甲","author":"X"},"Only english",{"text":"B"},{"en":""}]',
      );
      expect(quotes, hasLength(3));
      expect(quotes[0].en, 'A');
      expect(quotes[0].zh, '甲');
      expect(quotes[0].author, 'X');
      expect(quotes[1].en, 'Only english');
      expect(quotes[2].en, 'B');
      expect(parseQuotes('not json'), isEmpty);
      expect(randomQuote().en, isNotEmpty); // 未预热时也永远拿得到台词
    });
  });
}
