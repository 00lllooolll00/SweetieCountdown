import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/sweetie_theme.dart';
import 'reading_page.dart';
import 'reading_service.dart';

/// 收藏数据：阅读页入口徽标与收藏页共用；收藏发生变化后 invalidate 重查。
final FutureProvider<List<ReadingArticle>> favoritesProvider =
    FutureProvider<List<ReadingArticle>>((Ref ref) {
  return ref.watch(readingServiceProvider).favoriteArticles();
});

/// 阅读页顶部的心形入口：右上角徽标显示收藏数量，点开收藏列表。
class FavoritesEntryButton extends ConsumerWidget {
  const FavoritesEntryButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int count = ref.watch(favoritesProvider).asData?.value.length ?? 0;
    return IconButton(
      tooltip: '我的收藏',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 38),
      onPressed: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const FavoritesPage()),
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        backgroundColor: SweetieColors.pink,
        textColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: const Icon(
          Icons.favorite_rounded,
          size: 22,
          color: SweetieColors.pink,
        ),
      ),
    );
  }
}

/// 收藏列表：展示已收藏文章，点条目回原文阅读，左滑或点心形取消收藏。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage> {
  /// null = 加载中；空表 = 还没有收藏。
  List<ReadingArticle>? _articles;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final List<ReadingArticle> list =
        await ref.read(readingServiceProvider).favoriteArticles();
    if (!mounted) return;
    // 最近收藏的排在最前（Hive 按插入顺序给出）。
    setState(() => _articles = list.reversed.toList(growable: false));
  }

  void _open(ReadingArticle article) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ArticleReaderPage(article: article),
      ),
    );
  }

  Future<void> _removeByButton(ReadingArticle article) async {
    await ref.read(readingServiceProvider).toggleFavorite(article);
    if (!mounted) return;
    _removeLocally(article);
  }

  /// 取消收藏后只动本地列表：不等 provider 重查，Dismissible 动画不会被打断。
  void _removeLocally(ReadingArticle article) {
    setState(() {
      _articles = _articles
          ?.where((ReadingArticle a) => a.id != article.id)
          .toList(growable: false);
    });
    ref.invalidate(favoritesProvider); // 阅读页入口的数量徽标跟着变
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已取消收藏'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: SweetieColors.text,
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<ReadingArticle>? articles = _articles;
    return Scaffold(
      backgroundColor: SweetieColors.background,
      appBar: AppBar(
        backgroundColor: SweetieColors.background,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '我的收藏',
          style: TextStyle(
            color: SweetieColors.text,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: articles == null
            ? const _LoadingView()
            : articles.isEmpty
                ? const _EmptyView()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                    itemCount: articles.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (BuildContext context, int index) {
                      final ReadingArticle article = articles[index];
                      return Dismissible(
                        key: ValueKey<String>(article.id),
                        direction: DismissDirection.endToStart,
                        background: const _RemoveBackground(),
                        // 先落盘再放行动画：取消收藏失败就不会假装删掉。
                        confirmDismiss: (DismissDirection _) async {
                          await ref
                              .read(readingServiceProvider)
                              .toggleFavorite(article);
                          return true;
                        },
                        onDismissed: (DismissDirection _) =>
                            _removeLocally(article),
                        child: _FavoriteTile(
                          article: article,
                          onTap: () => _open(article),
                          onRemove: () => _removeByButton(article),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

/// 一条收藏：标题 + 来源 + 阅读时长 + 取消收藏心形。
class _FavoriteTile extends StatelessWidget {
  const _FavoriteTile({
    required this.article,
    required this.onTap,
    required this.onRemove,
  });

  final ReadingArticle article;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  /// 阅读时长估计（英文按 200 词/分钟），列表里的时间信息。
  String get _readingTime {
    final int words = article.body
        .split(RegExp(r'\s+'))
        .where((String word) => word.isNotEmpty)
        .length;
    final int minutes = (words / 200).ceil().clamp(1, 60);
    return '约 $minutes 分钟';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: SweetieTheme.cardRadius,
        boxShadow: SweetieTheme.cardShadow(),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: SweetieTheme.cardRadius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        article.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'serif',
                          fontSize: 16.5,
                          height: 1.36,
                          fontWeight: FontWeight.w600,
                          color: SweetieColors.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: readingSourceColor(article.source),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            '${article.source.label} · $_readingTime',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.6,
                              color: SweetieColors.textLight,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '取消收藏',
                  onPressed: onRemove,
                  icon: const Icon(
                    Icons.favorite,
                    size: 20,
                    color: SweetieColors.pink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 左滑露出的取消收藏底色。
class _RemoveBackground extends StatelessWidget {
  const _RemoveBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 22),
      decoration: BoxDecoration(
        color: SweetieColors.soft(SweetieColors.pink),
        borderRadius: SweetieTheme.cardRadius,
      ),
      child: const Icon(
        Icons.heart_broken_rounded,
        size: 22,
        color: SweetieColors.pink,
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          color: SweetieColors.pink,
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.favorite_border,
            size: 46,
            color: SweetieColors.pink.withAlpha(0x59),
          ),
          const SizedBox(height: 14),
          const Text(
            '还没有收藏，去读点暖心短文吧～',
            style: TextStyle(
              fontSize: 13.5,
              letterSpacing: 0.6,
              color: SweetieColors.textLight,
            ),
          ),
        ],
      ),
    );
  }
}
