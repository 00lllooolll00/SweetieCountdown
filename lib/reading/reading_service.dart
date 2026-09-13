import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'tencent_translate.dart';
import '../settings/translation_settings.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:xml/xml.dart';

/// 每日一读：抓几个英文站点的短文 → 翻译成中文 → Hive 缓存 + 收藏。
///
/// 降级链条（任何一环挂掉都不会让页面白屏）：
///   1. 在线源：Wikipedia 随机摘要 / James Clear 3-2-1 / DailyGood RSS；
///   2. Hive 缓存（缓存命中的文章离线可读）；
///   3. 内置 3 篇离线精选（中英双语，零网络也能读）。
///
/// 翻译失败时保留英文原文，并置位 [ReadingArticle.translationFailed]，
/// 由 UI 显示“翻译暂不可用，先看原文”的柔和提示，绝不空屏。

/// 一篇文章的来源。
enum ReadingSource {
  wiki('Wikipedia', const [
    'https://en.wikipedia.org/api/rest_v1/page/random/summary',
  ]),
  jamesClear('James Clear 3-2-1', const ['https://jamesclear.com/feed']),
  dailyGood('DailyGood', const [
    'https://www.dailygood.org/rss.php',
    'https://www.dailygood.org/feed/',
  ]),
  builtIn('离线精选', const []);

  const ReadingSource(this.label, this.uris);

  /// 展示给用户看的来源名。
  final String label;

  /// 抓取地址（RSS 源按顺序尝试，第一个成功的生效）。
  final List<String> uris;

  /// 可在线抓取的源。
  static const List<ReadingSource> online = [wiki, jamesClear, dailyGood];
}

/// 一篇文章（英文原文 + 中文译文 + 兜底标记）。
class ReadingArticle {
  const ReadingArticle({
    required this.id,
    required this.source,
    required this.title,
    required this.body,
    this.url = '',
    this.author = '',
    this.translatedTitle = '',
    this.translatedBody = '',
    this.translationFailed = false,
    this.fromCache = false,
  });

  /// 稳定 id（由 url/标题做 FNV-1a 哈希），缓存和收藏都靠它。
  final String id;
  final ReadingSource source;

  /// 英文原文标题。
  final String title;

  /// 英文原文正文。
  final String body;
  final String url;
  final String author;

  /// 中文译文（失败时为空）。
  final String translatedTitle;
  final String translatedBody;

  /// 翻译接口失败：UI 显示提示并保留英文原文。
  final bool translationFailed;

  /// 来自 Hive 缓存（弱网降级）。
  final bool fromCache;

  bool get isBuiltIn => source == ReadingSource.builtIn;

  /// 离线内容（缓存或内置兜底）。
  bool get isOffline => fromCache || isBuiltIn;

  bool get hasTranslation =>
      translatedTitle.trim().isNotEmpty || translatedBody.trim().isNotEmpty;

  ReadingArticle copyWith({
    String? translatedTitle,
    String? translatedBody,
    bool? translationFailed,
    bool? fromCache,
  }) {
    return ReadingArticle(
      id: id,
      source: source,
      title: title,
      body: body,
      url: url,
      author: author,
      translatedTitle: translatedTitle ?? this.translatedTitle,
      translatedBody: translatedBody ?? this.translatedBody,
      translationFailed: translationFailed ?? this.translationFailed,
      fromCache: fromCache ?? this.fromCache,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'source': source.name,
        'title': title,
        'body': body,
        'url': url,
        'author': author,
        'translatedTitle': translatedTitle,
        'translatedBody': translatedBody,
        'translationFailed': translationFailed,
        'fromCache': fromCache,
      };

  factory ReadingArticle.fromJson(Map<String, dynamic> json) {
    return ReadingArticle(
      id: json['id'] as String? ?? '',
      source: ReadingSource.values.firstWhere(
        (ReadingSource s) => s.name == json['source'],
        orElse: () => ReadingSource.builtIn,
      ),
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      url: json['url'] as String? ?? '',
      author: json['author'] as String? ?? '',
      translatedTitle: json['translatedTitle'] as String? ?? '',
      translatedBody: json['translatedBody'] as String? ?? '',
      translationFailed: json['translationFailed'] as bool? ?? false,
      fromCache: json['fromCache'] as bool? ?? false,
    );
  }
}

// ---------------------------------------------------------------------------
// 纯函数：解析 + 文本清洗（可直接单测，不碰网络）
// ---------------------------------------------------------------------------

/// 去掉 HTML 标签、还原常见实体，得到可读纯文本。
String stripHtmlTags(String raw) {
  if (raw.isEmpty) return '';
  var text = raw.replaceAll(
    RegExp(r'<(script|style)\b[^>]*>.*?</\1\s*>',
        caseSensitive: false, dotAll: true),
    ' ',
  );
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(
    RegExp(r'</(p|div|li|h[1-6]|blockquote|tr)>', caseSensitive: false),
    '\n',
  );
  text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
  text = _decodeEntities(text);
  text = text.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ');
  text = text.replaceAll(RegExp(r' *\n *'), '\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 解析 RSS 2.0 / Atom feed，返回文章列表（无有效项时返回空表）。
///
/// 覆盖 `<item>` 与 `<entry>`，正文按 `content:encoded > description >
/// summary > content` 优先级取第一段非空内容，并剥掉 HTML。
List<ReadingArticle> parseFeedArticles(String xmlText, ReadingSource source) {
  final XmlDocument document = XmlDocument.parse(xmlText);
  final XmlElement root = document.rootElement;
  final Iterable<XmlElement> nodes = <XmlElement>[
    root,
    ...root.descendantElements,
  ];
  final List<ReadingArticle> articles = <ReadingArticle>[];
  final Set<String> seen = <String>{};

  for (final XmlElement node in nodes) {
    final String local = node.name.local.toLowerCase();
    if (local != 'item' && local != 'entry') continue;

    final String title = stripHtmlTags(_elementText(node, const ['title']));
    final String url = _feedLink(node);
    final String body = _capBody(stripHtmlTags(
      _elementText(node, const ['encoded', 'description', 'summary', 'content']),
    ));
    if (title.isEmpty || body.isEmpty) continue;

    final String id = _articleId(url.isEmpty ? '$title|$body' : url);
    if (!seen.add(id)) continue;

    articles.add(ReadingArticle(
      id: id,
      source: source,
      title: title,
      body: body,
      url: url,
      author: stripHtmlTags(_elementText(node, const ['creator', 'author'])),
    ));
  }
  return articles;
}

/// 解析 Wikipedia `/page/random/summary` 的 JSON；内容太薄时返回 null。
ReadingArticle? parseWikiSummary(String jsonText) {
  final Object? decoded = jsonDecode(jsonText);
  if (decoded is! Map) return null;
  final String title = (decoded['title'] ?? '').toString().trim();
  final String extract = stripHtmlTags((decoded['extract'] ?? '').toString());
  if (title.isEmpty || extract.length < 80) return null;

  var url = '';
  final Object? urls = decoded['content_urls'];
  if (urls is Map) {
    final Object? desktop = urls['desktop'];
    if (desktop is Map) url = (desktop['page'] ?? '').toString().trim();
  }
  return ReadingArticle(
    id: _articleId(url.isEmpty ? title : url),
    source: ReadingSource.wiki,
    title: title,
    body: _capBody(extract),
    url: url,
    author: 'Wikipedia',
  );
}

/// 解析 Google 翻译端点(client=gtx)的响应;结构不符或译文为空时抛 [FormatException]。
///
/// 响应形如:[[["译文片段","原文片段",...],[...]], null, "en", ...]
/// —— 取第一层数组里每个片段的第 0 项拼起来。
String parseGoogleTranslate(String jsonText) {
  final Object? decoded = jsonDecode(jsonText);
  if (decoded is! List || decoded.isEmpty) {
    throw const FormatException('翻译响应异常');
  }
  final Object? segments = decoded[0];
  if (segments is! List) throw const FormatException('翻译响应异常');
  final StringBuffer buffer = StringBuffer();
  for (final Object? seg in segments) {
    if (seg is List && seg.isNotEmpty && seg[0] is String) {
      buffer.write(seg[0] as String);
    }
  }
  final String result = buffer.toString().trim();
  if (result.isEmpty) throw const FormatException('翻译返回为空');
  return result;
}

/// 把长文切成翻译接口友好的小块（按句子边界，单块不超过 [maxChars]）。
List<String> splitForTranslation(String text, [int maxChars = 420]) {
  final String clean = text.trim();
  if (clean.isEmpty) return const <String>[];
  if (clean.length <= maxChars) return <String>[clean];

  final List<String> chunks = <String>[];
  final StringBuffer buffer = StringBuffer();
  for (final String piece in clean.split(RegExp(r'(?<=[.!?。！？])\s+'))) {
    var sentence = piece.trim();
    if (sentence.isEmpty) continue;
    while (sentence.length > maxChars) {
      if (buffer.length > 0) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      chunks.add(sentence.substring(0, maxChars).trim());
      sentence = sentence.substring(maxChars);
    }
    if (buffer.length > 0 && buffer.length + sentence.length + 1 > maxChars) {
      chunks.add(buffer.toString().trim());
      buffer.clear();
    }
    if (buffer.length > 0) buffer.write(' ');
    buffer.write(sentence);
  }
  if (buffer.length > 0) chunks.add(buffer.toString().trim());
  return chunks.isEmpty ? <String>[clean] : chunks;
}

/// 内置离线精选 3 篇（中英双语，零网络也能读）。
const List<ReadingArticle> builtInArticles = <ReadingArticle>[
  ReadingArticle(
    id: 'builtin-focus',
    source: ReadingSource.builtIn,
    title: 'Focus Is a Decision, Not a Talent',
    body: 'Focus is not a talent. It is a decision you make again and again, '
        'twenty-five minutes at a time. Close the extra tabs, put the phone '
        'face down, and let one small thing get your whole attention. The '
        'world will still be there when the timer rings.',
    author: 'Sweetie Daily',
    translatedTitle: '专注是一次次的决定，不是天赋',
    translatedBody: '专注不是天赋，而是一次又一次的决定——每次二十五分钟。'
        '关掉多余的标签页，把手机扣在桌上，让一件小事获得你全部的关注。'
        '计时器响起时，世界依旧在。',
  ),
  ReadingArticle(
    id: 'builtin-rest',
    source: ReadingSource.builtIn,
    title: 'Rest Is Part of the Work',
    body: 'Rest is not the reward for finished work; it is part of the work. '
        'Your best ideas rarely arrive at the desk. They arrive on the walk, '
        'in the shower, in the quiet minute after you close the laptop. Take '
        'the break before you think you need it.',
    author: 'Sweetie Daily',
    translatedTitle: '休息不是奖励，是工作的一部分',
    translatedBody: '休息不是完成工作后的奖励，而是工作本身的一部分。'
        '最好的灵感很少出现在书桌前，而是在散步时、淋浴时、'
        '合上电脑后安静的一分钟里。在你觉得需要之前，就去休息。',
  ),
  ReadingArticle(
    id: 'builtin-small-steps',
    source: ReadingSource.builtIn,
    title: 'Small Steps, Quiet Interest',
    body: 'Small steps look like nothing on the day you take them. A page '
        'read, a minute of stretching, one honest paragraph written. But '
        'habits are interest that compounds quietly. Keep the step so small '
        'that skipping it would feel silly.',
    author: 'Sweetie Daily',
    translatedTitle: '小步前进，悄悄复利',
    translatedBody: '小步前进，在迈出的当天看起来微不足道：读一页书、拉伸一分钟、'
        '写一段诚实的文字。但习惯是悄悄复利的利息。把步子迈得足够小——'
        '小到跳过它都会显得可笑。',
  ),
];

// ---------------------------------------------------------------------------
// 启动语录（splash 用；main 启动时 preloadQuotes() 预热，失败不抛）
// ---------------------------------------------------------------------------

/// assets/quotes.json 路径（与 pubspec 声明一致）。
const String quotesAssetPath = 'assets/quotes.json';

/// 一句中英双语语录。
class DailyQuote {
  const DailyQuote({required this.en, this.zh = '', this.author = ''});

  final String en;
  final String zh;
  final String author;
}

/// 内置兜底台词：quotes.json 缺失时 splash 也不至于空屏。
const List<DailyQuote> fallbackQuotes = <DailyQuote>[
  DailyQuote(
    en: 'Small steps still move you forward.',
    zh: '小步，也在前进。',
    author: 'Sweetie',
  ),
  DailyQuote(
    en: 'Focus is a decision you make again and again.',
    zh: '专注，是一次又一次的决定。',
    author: 'James Clear',
  ),
  DailyQuote(
    en: 'Rest is part of the work, not a reward for it.',
    zh: '休息不是奖励，而是工作的一部分。',
    author: 'Sweetie',
  ),
];

List<DailyQuote> _quoteCache = const <DailyQuote>[];

/// 解析 quotes.json：主格式 `[{"en","zh","author"}]`，
/// 同时容错 `text`/`quote` 字段与纯字符串数组。
List<DailyQuote> parseQuotes(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (_) {
    return const <DailyQuote>[];
  }
  if (decoded is! List) return const <DailyQuote>[];
  final List<DailyQuote> quotes = <DailyQuote>[];
  for (final Object? item in decoded) {
    if (item is String) {
      final String text = item.trim();
      if (text.isNotEmpty) quotes.add(DailyQuote(en: text));
      continue;
    }
    if (item is Map) {
      final String en =
          (item['en'] ?? item['text'] ?? item['quote'] ?? '').toString().trim();
      final String zh =
          (item['zh'] ?? item['cn'] ?? item['translation'] ?? '')
              .toString()
              .trim();
      final String author =
          (item['author'] ?? item['from'] ?? '').toString().trim();
      if (en.isNotEmpty) quotes.add(DailyQuote(en: en, zh: zh, author: author));
    }
  }
  return quotes;
}

/// 启动预热：读取并缓存语录；任何失败都不抛（splash 有内置兜底）。
Future<void> preloadQuotes() async {
  try {
    final List<DailyQuote> quotes = parseQuotes(
      await rootBundle.loadString(quotesAssetPath),
    );
    if (quotes.isNotEmpty) _quoteCache = quotes;
  } catch (_) {
    // 资源缺失 / 解析失败：保持内置兜底，绝不阻塞启动。
  }
}

/// 已预热的语录（未预热或失败时为空）。
List<DailyQuote> get preloadedQuotes => _quoteCache;

/// 随机一句：优先预热结果，其次内置兜底——永远拿得到。
DailyQuote randomQuote([Random? random]) {
  final List<DailyQuote> pool =
      _quoteCache.isNotEmpty ? _quoteCache : fallbackQuotes;
  return pool[(random ?? Random()).nextInt(pool.length)];
}

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

/// 阅读抓取 / 翻译 / 缓存 / 收藏。
///
/// 依赖全部可注入（[dio]、[translate]、[random]），单测里全 mock、不碰真网。
class ReadingService {
  ReadingService({
    Dio? dio,
    Future<String> Function(String text)? translate,
    TranslationSettings Function()? readSettings,
    Duration httpTimeout = const Duration(seconds: 8),
    Random? random,
  })  : _dio = dio ?? Dio(),
        _translate = translate,
        _readSettings = readSettings,
        _httpTimeout = httpTimeout,
        _random = random ?? Random();

  /// Hive box：缓存最近抓到的文章（JSON 字符串，免 TypeAdapter）。
  static const String cacheBoxName = 'reading_cache';

  /// 缓存淘汰索引键（与文章同箱的保留键）：值是 `[[id, 写入毫秒时间戳], …]`，
  /// 按写入先后排列、最旧在前；箱里除它以外的键都是文章。
  static const String cacheIndexKey = '__reading_cache_index__';

  /// Hive box：收藏（JSON 字符串）。
  static const String favoriteBoxName = 'reading_favorites';

  static const String _myMemoryEndpoint =
      'https://api.mymemory.translated.net/get';
  static const String _userAgent = 'SweetieCountdown/1.0 (daily reading)';
  static const int _maxCached = 30;
  /// 单块字符上限:实测 MyMemory 在 ~500 字符以上会「静默只翻前半段」,
  /// 450 留出安全余量,保证每块都完整译出。
  static const int _translationChunkChars = 450;

  /// MyMemory 的联系邮箱:带有效邮箱的请求配额从 5k 提到 50k 字符/天,
  /// 不带的话每天看两三篇就会耗尽(表现为「翻译暂时不可用」)。
  /// 用 GitHub noreply 格式,不会打扰到具体的人;换成自己的邮箱也行。
  static const String _mymemoryContact = 'sweetie-countdown@users.noreply.github.com';

  /// Google 免费翻译端点(client=gtx):无 key、质量与稳定性都优于 MyMemory,
  /// 作为首选;失败再回退 MyMemory。
  static const String _googleEndpoint =
      'https://translate.googleapis.com/translate_a/single';

  final Dio _dio;
  final Future<String> Function(String text)? _translate;

  /// 翻译设置（厂商 + 腾讯云密钥）；null 视为 auto（旧行为）。
  final TranslationSettings Function()? _readSettings;
  final Duration _httpTimeout;

  /// 可选密钥文件（不进仓库）:{"tencentSecretId":"...","tencentSecretKey":"..."}
  static const String _secretsAsset = 'assets/secrets.json';

  /// 腾讯云客户端惰性解析结果;[_tencentResolved] 保证只读一次资源。
  TencentTranslator? _tencentClientCache;
  bool _tencentResolved = false;
  final Random _random;
  final Map<String, String> _memoryCache = <String, String>{};
  final Map<String, String> _memoryFavorites = <String, String>{};
  String? _lastId;
  ReadingSource? _lastSource;

  /// 最近一次返回的文章 id（“换一篇”用它避免重复）。
  String? get lastArticleId => _lastId;

  /// 取下一篇：在线源 → 缓存 → 内置兜底，永不抛错、永不返回空。
  Future<ReadingArticle> fetchNext() async {
    for (final ReadingSource source in _sourceOrder()) {
      final ReadingArticle? fetched = await _fetchSource(source);
      if (fetched == null) continue;
      final ReadingArticle localized = await _localize(fetched);
      _lastId = localized.id;
      _lastSource = source;
      await _remember(localized);
      return localized;
    }

    // 弱网 / 断网：先缓存。
    final ReadingArticle? cached = await _cachedArticle();
    if (cached != null) {
      _lastId = cached.id;
      return cached;
    }

    // 最后兜底：内置精选（中英双语，翻译都不用调）。
    final List<ReadingArticle> fresh = builtInArticles
        .where((ReadingArticle a) => a.id != _lastId)
        .toList(growable: false);
    final List<ReadingArticle> pool =
        fresh.isEmpty ? builtInArticles : fresh;
    final ReadingArticle article = pool[_random.nextInt(pool.length)];
    _lastId = article.id;
    return article;
  }

  /// 对已展示的文章重试翻译（UI 上“再试一次”按钮用）。
  Future<ReadingArticle> retranslate(ReadingArticle article) async {
    final ReadingArticle localized = await _localize(article, force: true);
    await _remember(localized);
    return localized.copyWith(fromCache: article.fromCache);
  }

  /// 是否已收藏。
  Future<bool> isFavorite(String id) async {
    final Box<String>? box = await _box(favoriteBoxName);
    if (box != null) return box.containsKey(id);
    return _memoryFavorites.containsKey(id);
  }

  /// 收藏 / 取消收藏，返回操作后的状态。
  Future<bool> toggleFavorite(ReadingArticle article) async {
    final bool next = !(await isFavorite(article.id));
    final String raw = jsonEncode(article.toJson());
    final Box<String>? box = await _box(favoriteBoxName);
    if (box == null) {
      if (next) {
        _memoryFavorites[article.id] = raw;
      } else {
        _memoryFavorites.remove(article.id);
      }
    } else if (next) {
      await box.put(article.id, raw);
    } else {
      await box.delete(article.id);
    }
    return next;
  }

  /// 全部收藏（离线可读）。
  Future<List<ReadingArticle>> favoriteArticles() async {
    final Map<String, String> raw = <String, String>{..._memoryFavorites};
    final Box<String>? box = await _box(favoriteBoxName);
    if (box != null) {
      for (final String key in box.keys) {
        final String? value = box.get(key);
        if (value != null) raw[key] = value;
      }
    }
    final List<ReadingArticle> articles = <ReadingArticle>[];
    for (final String value in raw.values) {
      try {
        articles.add(
          ReadingArticle.fromJson(jsonDecode(value) as Map<String, dynamic>),
        );
      } catch (_) {
        // 坏数据跳过，不影响其它收藏。
      }
    }
    return articles;
  }

  // --- 抓取 ---------------------------------------------------------------

  List<ReadingSource> _sourceOrder() {
    final List<ReadingSource> sources =
        List<ReadingSource>.from(ReadingSource.online)..shuffle(_random);
    final ReadingSource? last = _lastSource;
    if (last != null && sources.length > 1 && sources.first == last) {
      sources
        ..remove(last)
        ..add(last);
    }
    return sources;
  }

  Future<ReadingArticle?> _fetchSource(ReadingSource source) async {
    for (final String uri in source.uris) {
      try {
        final Response<String> response = await _dio
            .get<String>(
              uri,
              options: Options(
                responseType: ResponseType.plain,
                headers: const <String, String>{'User-Agent': _userAgent},
              ),
            )
            .timeout(_httpTimeout);
        final String text = response.data ?? '';
        if (text.trim().isEmpty) continue;

        final ReadingArticle? article = source == ReadingSource.wiki
            ? parseWikiSummary(text)
            : _pickFromFeed(text, source);
        if (article != null) return article;
      } catch (_) {
        // 超时 / 断网 / 解析失败：换下一个地址或下一个源，绝不把异常抛给 UI。
      }
    }
    return null;
  }

  ReadingArticle? _pickFromFeed(String xmlText, ReadingSource source) {
    final List<ReadingArticle> articles = parseFeedArticles(xmlText, source);
    if (articles.isEmpty) return null;
    final List<ReadingArticle> fresh = articles
        .where((ReadingArticle a) => a.id != _lastId)
        .toList(growable: false);
    final List<ReadingArticle> pool =
        fresh.isEmpty ? articles : fresh;
    return pool[_random.nextInt(pool.length)];
  }

  // --- 翻译 ---------------------------------------------------------------

  /// 翻译标题 + 正文；任何失败都降级为“保留英文 + 提示”。
  Future<ReadingArticle> _localize(
    ReadingArticle article, {
    bool force = false,
  }) async {
    if (article.isBuiltIn) return article;
    if (!force && article.hasTranslation) return article;
    try {
      final String zhBody = (await _translateLongText(article.body)).trim();
      if (zhBody.isEmpty) throw const FormatException('翻译返回为空');
      final String zhTitle = article.title.trim().isEmpty
          ? ''
          : (await _translateText(article.title.trim())).trim();
      return article.copyWith(
        translatedTitle: zhTitle,
        translatedBody: zhBody,
        translationFailed: false,
      );
    } catch (_) {
      return article.copyWith(translationFailed: true);
    }
  }

  Future<String> _translateLongText(String text) async {
    final List<String> chunks =
        splitForTranslation(text, _translationChunkChars);
    final List<String> translated = <String>[];
    for (final String chunk in chunks) {
      translated.add((await _translateText(chunk)).trim());
    }
    return translated.join('\n\n');
  }

  /// 翻译单块：测试注入优先 → 按「翻译设置」选厂商 → 逐级兜底。
  /// 全失败时把异常抛给上层，由 [_localize] 降级为「保留英文 + 提示」。
  ///
  /// 链：
  ///  - auto / 腾讯云：Hive 密钥 → assets/secrets.json 密钥 → MyMemory → Google；
  ///  - MyMemory：MyMemory → Google；Google：Google → MyMemory（互兜底，不白屏）。
  Future<String> _translateText(String text) async {
    final Future<String> Function(String)? injected = _translate;
    if (injected != null) return injected(text);
    final TranslationSettings settings =
        _readSettings?.call() ?? const TranslationSettings();
    switch (settings.vendor) {
      case TranslationVendor.mymemory:
        return _myMemoryThenGoogle(text);
      case TranslationVendor.google:
        return _googleThenMyMemory(text);
      case TranslationVendor.tencent:
      case TranslationVendor.auto:
        final TencentTranslator? tencent = settings.hasTencentKeys
            ? TencentTranslator(
                secretId: settings.tencentSecretId.trim(),
                secretKey: settings.tencentSecretKey.trim(),
              )
            // Hive 未配密钥：次选 assets/secrets.json（老配置照旧生效）。
            : await _tencentClient();
        if (tencent != null) {
          try {
            return await tencent.translate(
              text,
              dio: _dio,
              timeout: _httpTimeout,
            );
          } catch (_) {
            // 配额用尽 / 密钥失效 / 网络异常：继续往下走，不让整篇翻译失败。
          }
        }
        return _myMemoryThenGoogle(text);
    }
  }

  /// MyMemory 优先、Google 兜底（两个免费端点互备）。
  Future<String> _myMemoryThenGoogle(String text) async {
    try {
      return await _translateByMyMemory(text);
    } catch (_) {
      return await _translateByGoogle(text);
    }
  }

  /// Google 优先、MyMemory 兜底（用户手选 Google 时的备胎）。
  Future<String> _googleThenMyMemory(String text) async {
    try {
      return await _translateByGoogle(text);
    } catch (_) {
      return await _translateByMyMemory(text);
    }
  }

  /// 读取可选的腾讯云密钥（`assets/secrets.json`，已 gitignore）。
  /// 仅在用户没在 Hive 里配密钥时作为次选；没配 / 读不到 / 字段为空 → 返回
  /// null，翻译自动走免费链。
  Future<TencentTranslator?> _tencentClient() async {
    if (_tencentResolved) return _tencentClientCache;
    _tencentResolved = true;
    try {
      final String raw = await rootBundle.loadString(_secretsAsset);
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        final String id = (decoded['tencentSecretId'] ?? '').toString().trim();
        final String key =
            (decoded['tencentSecretKey'] ?? '').toString().trim();
        if (id.isNotEmpty && key.isNotEmpty) {
          _tencentClientCache = TencentTranslator(secretId: id, secretKey: key);
        }
      }
    } catch (_) {
      // 资源缺失(未配置密钥)是最常见情况:静默走免费链。
    }
    return _tencentClientCache;
  }

  /// Google 免费端点(首选):响应形如 [[["译文","原文",...],...],...]。
  Future<String> _translateByGoogle(String text) async {
    final Response<String> response = await _dio
        .get<String>(
          _googleEndpoint,
          queryParameters: <String, String>{
            'client': 'gtx',
            'sl': 'en',
            'tl': 'zh-CN',
            'dt': 't',
            'q': text,
          },
          options: Options(responseType: ResponseType.plain),
        )
        .timeout(_httpTimeout);
    return parseGoogleTranslate(response.data ?? '');
  }

  /// 免费翻译接口（MyMemory），失败即抛，由 [_localize] 兜底。
  Future<String> _translateByMyMemory(String text) async {
    final Response<String> response = await _dio
        .get<String>(
          _myMemoryEndpoint,
          queryParameters: <String, String>{
            'q': text,
            'langpair': 'en|zh-CN',
            'de': _mymemoryContact,
          },
          options: Options(responseType: ResponseType.plain),
        )
        .timeout(_httpTimeout);
    final Object? decoded = jsonDecode(response.data ?? '{}');
    if (decoded is! Map) throw const FormatException('翻译响应异常');
    final int status = int.tryParse('${decoded['responseStatus']}') ?? 200;
    final Object? data = decoded['responseData'];
    final Object? translated = data is Map ? data['translatedText'] : null;
    if (status != 200 || translated is! String || translated.trim().isEmpty) {
      throw const FormatException('翻译服务暂不可用');
    }
    return translated.trim();
  }

  // --- 存储 ---------------------------------------------------------------

  /// 打开 Hive box；Hive 未初始化时返回 null（走内存兜底，UI 不崩）。
  ///
  /// 泛型必须与 main.dart 的开箱一致（`Box<String>`）：hive 2.x 的
  /// `Hive.box<E>` 会校验 `box.valueType == E`，用 `dynamic` 读 String 箱子
  /// 会抛 HiveError（“already open and of type Box<String>”）——拿不到箱子时
  /// 收藏/缓存会静默失效，所以这里固定用 `String`。
  Future<Box<String>?> _box(String name) async {
    try {
      if (Hive.isBoxOpen(name)) return Hive.box<String>(name);
      return await Hive.openBox<String>(name);
    } catch (_) {
      return null;
    }
  }

  Future<void> _remember(ReadingArticle article) async {
    final String raw = jsonEncode(article.toJson());
    // 内存兜底与 Hive 箱同一套规则：重写视为最新（先删再插保序），
    // 超过 [_maxCached] 篇从最旧开始淘汰。
    _memoryCache.remove(article.id);
    _memoryCache[article.id] = raw;
    while (_memoryCache.length > _maxCached) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    final Box<String>? box = await _box(cacheBoxName);
    if (box == null) return;
    await box.put(article.id, raw);
    await _trimCache(box, article.id);
  }

  /// 按写入时间淘汰最旧的文章，缓存最多保留 [_maxCached] 篇。
  ///
  /// 写入时间记在独立的索引键 [cacheIndexKey] 里（文章值的结构不变，旧缓存
  /// 照读）；升级前写入的老缓存没有索引记录、没有时间，一律按最旧优先淘汰。
  Future<void> _trimCache(Box<String> box, String latestId) async {
    final List<List<Object?>> index = _readCacheIndex(box)
      ..removeWhere((List<Object?> row) => row.first == latestId)
      ..add(<Object?>[latestId, DateTime.now().millisecondsSinceEpoch]);

    final Set<String> ids = box.keys
        .cast<String>()
        .where((String key) => key != cacheIndexKey)
        .toSet();
    // 索引里指向的文章已经不在箱里：这条索引记录一并删掉。
    index.removeWhere((List<Object?> row) => !ids.contains(row.first));
    // 箱里有、索引没记录的老条目：时间戳记 0，排在最前面等淘汰。
    final List<List<Object?>> legacy = ids
        .where((String id) =>
            !index.any((List<Object?> row) => row.first == id))
        .map((String id) => <Object?>[id, 0])
        .toList(growable: false);
    index.insertAll(0, legacy);

    while (index.length > _maxCached) {
      await box.delete(index.removeAt(0).first);
    }
    await box.put(cacheIndexKey, jsonEncode(index));
  }

  /// 读缓存淘汰索引；缺失或坏数据时返回空表（等价于全部按老缓存处理）。
  List<List<Object?>> _readCacheIndex(Box<String> box) {
    final String? raw = box.get(cacheIndexKey);
    if (raw == null) return <List<Object?>>[];
    final List<List<Object?>> index = <List<Object?>>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final Object? row in decoded) {
          if (row is! List || row.length < 2) continue;
          final Object? id = row[0];
          final Object? stamp = row[1];
          if (id is String && stamp is int) index.add(<Object?>[id, stamp]);
        }
      }
    } catch (_) {
      return <List<Object?>>[];
    }
    return index;
  }

  /// 从缓存里随机拿一篇（排除刚看过的那篇），并补一次翻译（若之前失败）。
  Future<ReadingArticle?> _cachedArticle() async {
    final Map<String, String> entries = <String, String>{..._memoryCache};
    final Box<String>? box = await _box(cacheBoxName);
    if (box != null) {
      for (final String key in box.keys) {
        if (key == cacheIndexKey) continue; // 保留键存的是淘汰索引，不是文章。
        final String? value = box.get(key);
        if (value != null) entries[key] = value;
      }
    }
    entries.remove(_lastId);
    if (entries.isEmpty) return null;

    final List<String> keys = entries.keys.toList()..shuffle(_random);
    for (final String key in keys) {
      try {
        final ReadingArticle article = ReadingArticle.fromJson(
          jsonDecode(entries[key]!) as Map<String, dynamic>,
        ).copyWith(fromCache: true);
        return await _localize(article);
      } catch (_) {
        // 坏数据跳过。
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

const Map<String, String> _entities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'ndash': '–',
  'mdash': '—',
  'hellip': '…',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'middot': '·',
  'bull': '•',
  'copy': '©',
  'eacute': 'é',
};

String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(
    RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'),
    (Match match) {
      final String body = match.group(1)!;
      if (body.startsWith('#')) {
        final bool hex = body.startsWith('#x') || body.startsWith('#X');
        final int? code =
            int.tryParse(body.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
        if (code == null || code <= 0 || code > 0x10FFFF) {
          return match.group(0)!;
        }
        return String.fromCharCode(code);
      }
      return _entities[body.toLowerCase()] ?? match.group(0)!;
    },
  );
}

/// 取指定名字（按优先级）的第一个非空直接子元素文本。
String _elementText(XmlElement node, List<String> priorityNames) {
  for (final String name in priorityNames) {
    for (final XmlElement child in node.childElements) {
      if (child.name.local.toLowerCase() != name) continue;
      final String text = child.innerText.trim();
      if (text.isNotEmpty) return text;
    }
  }
  return '';
}

/// RSS 的 `<link>文本</link>` 或 Atom 的 `<link href="..."/>`。
String _feedLink(XmlElement node) {
  for (final XmlElement child in node.childElements) {
    if (child.name.local.toLowerCase() != 'link') continue;
    final String? href = child.getAttribute('href');
    if (href != null && href.trim().isNotEmpty) return href.trim();
    final String text = child.innerText.trim();
    if (text.isNotEmpty) return text;
  }
  return _elementText(node, const <String>['guid', 'id']);
}

String _capBody(String text, {int maxChars = 2400}) {
  final String clean = text.trim();
  if (clean.length <= maxChars) return clean;
  // 尽量在句子边界收尾:硬切在词中会有"话说到一半被砍"的观感。
  final int softEnd = _lastSentenceEnd(clean, maxChars);
  final String clipped = clean.substring(0, softEnd).trimRight();
  return '$clipped…';
}

/// 在 [limit] 之前找最后一个句子结束符的位置;找不到就退回硬边界。
int _lastSentenceEnd(String text, int limit) {
  for (int i = limit - 1; i > limit ~/ 2; i--) {
    final String ch = text[i];
    if (ch == '.' || ch == '!' || ch == '?' || ch == '\n' || ch == '。') {
      return i + 1;
    }
  }
  return limit;
}

/// FNV-1a：稳定、无依赖的文章 id（重启后收藏/缓存仍能对上）。
String _articleId(String seed) {
  var hash = 0x811c9dc5;
  for (final int unit in seed.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// 全局阅读服务；翻译厂商与腾讯云密钥从「翻译设置」实时读取。
final Provider<ReadingService> readingServiceProvider =
    Provider<ReadingService>((Ref ref) => ReadingService(
          readSettings: () => ref.read(translationSettingsProvider),
        ));

/// 当前展示的文章；“换一篇 / 下拉刷新”只需 invalidate 本 provider。
final FutureProvider<ReadingArticle> readingArticleProvider =
    FutureProvider<ReadingArticle>((Ref ref) async {
  return ref.watch(readingServiceProvider).fetchNext();
});
