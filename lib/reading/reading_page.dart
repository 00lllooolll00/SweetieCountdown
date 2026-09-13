import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/translation_settings_sheet.dart';
import '../theme/sweetie_theme.dart';
import 'favorites_page.dart';
import 'reading_service.dart';

// 配色统一取全局主题（SweetieColors / SweetieTheme），本模块不再自带色值。
const String _serif = 'serif';

/// 来源色点：阅读页来源胶囊与收藏列表共用一套配色。
Color readingSourceColor(ReadingSource source) {
  switch (source) {
    case ReadingSource.wiki:
      return SweetieColors.green;
    case ReadingSource.jamesClear:
      return SweetieColors.yellow;
    case ReadingSource.dailyGood:
      return SweetieColors.pink;
    case ReadingSource.builtIn:
      return SweetieColors.textLight;
  }
}

/// 每日一读：英文原文 + 中文柔和卡片。
class ReadingPage extends ConsumerWidget {
  const ReadingPage({super.key});

  Future<void> _next(WidgetRef ref) async {
    ref.invalidate(readingArticleProvider);
    await ref.read(readingArticleProvider.future);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<ReadingArticle> asyncArticle =
        ref.watch(readingArticleProvider);
    final ReadingArticle? article = asyncArticle.asData?.value;

    return Scaffold(
      backgroundColor: SweetieColors.background,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            const _Header(),
            Expanded(
              child: RefreshIndicator(
                color: SweetieColors.pink,
                backgroundColor: Colors.white,
                onRefresh: () => _next(ref),
                child: article != null
                    ? Stack(
                        children: <Widget>[
                          _ArticleView(article: article),
                          if (asyncArticle.isLoading) const _FetchBar(),
                        ],
                      )
                    : asyncArticle.hasError
                        ? _ErrorView(
                            onRetry: () => ref.invalidate(readingArticleProvider),
                          )
                        : const _LoadingView(),
              ),
            ),
            _ActionBar(onNext: () => _next(ref)),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          const Text(
            '每日一读',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: SweetieColors.text,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              'read a little',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.4,
                color: SweetieColors.text.withAlpha(0x66),
              ),
            ),
          ),
          const Spacer(),
          const FavoritesEntryButton(),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '翻译设置',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            onPressed: () => showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const TranslationSettingsSheet(),
            ),
            icon: const Icon(
              Icons.settings_rounded,
              size: 22,
              color: SweetieColors.pink,
            ),
          ),
        ],
      ),
    );
  }
}

/// 在线抓取中的细进度条（有旧文章时叠加显示，不闪白）。
class _FetchBar extends StatelessWidget {
  const _FetchBar();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: LinearProgressIndicator(
        minHeight: 2.5,
        color: SweetieColors.pink,
        backgroundColor: SweetieColors.soft(SweetieColors.pink),
      ),
    );
  }
}

/// 收藏列表点进来的只读阅读页：直接复用 [_ArticleView]，不重新抓取。
class ArticleReaderPage extends StatelessWidget {
  const ArticleReaderPage({super.key, required this.article});

  final ReadingArticle article;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SweetieColors.background,
      appBar: AppBar(
        backgroundColor: SweetieColors.background,
        elevation: 0,
        centerTitle: true,
        title: Text(
          article.source.label,
          style: const TextStyle(
            color: SweetieColors.text,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _ArticleView(article: article),
      ),
    );
  }
}

class _ArticleView extends StatelessWidget {
  const _ArticleView({required this.article});

  final ReadingArticle article;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
      children: <Widget>[
        _SourceChip(article: article),
        const SizedBox(height: 16),
        Text(
          article.title,
          style: const TextStyle(
            fontFamily: _serif,
            fontSize: 26,
            height: 1.34,
            fontWeight: FontWeight.w600,
            color: SweetieColors.text,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          article.author.isEmpty
              ? 'A little English, every day.'
              : '${article.author} · A little English, every day.',
          style: const TextStyle(
            fontSize: 11.5,
            letterSpacing: 1.2,
            color: SweetieColors.textLight,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          article.body,
          style: const TextStyle(
            fontFamily: _serif,
            fontSize: 18.5,
            height: 1.86,
            color: SweetieColors.text,
            letterSpacing: 0.15,
          ),
        ),
        const SizedBox(height: 28),
        _ChineseCard(article: article),
      ],
    )
        .animate(key: ValueKey<String>(article.id))
        .fadeIn(duration: const Duration(milliseconds: 420))
        .slideY(
          begin: 0.06,
          end: 0,
          duration: const Duration(milliseconds: 480),
          curve: Curves.easeOutBack,
        );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.article});

  final ReadingArticle article;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: SweetieTheme.cardRadius,
            boxShadow: SweetieTheme.cardShadow(),
          ),
          child: Row(
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
                article.source.label,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: SweetieColors.text,
                ),
              ),
            ],
          ),
        ),
        if (article.isOffline) ...<Widget>[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: SweetieColors.yellow.withAlpha(0x59),
              borderRadius: SweetieTheme.cardRadius,
            ),
            child: const Text(
              '离线内容',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: SweetieColors.text,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 中文译文：柔和卡片；翻译失败时保留英文原文 + 提示 + 重试。
class _ChineseCard extends ConsumerStatefulWidget {
  const _ChineseCard({required this.article});

  final ReadingArticle article;

  @override
  ConsumerState<_ChineseCard> createState() => _ChineseCardState();
}

class _ChineseCardState extends ConsumerState<_ChineseCard> {
  ReadingArticle? _retried;
  bool _busy = false;

  ReadingArticle get _article => _retried ?? widget.article;

  @override
  void didUpdateWidget(_ChineseCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article.id != widget.article.id) {
      _retried = null;
      _busy = false;
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    final ReadingArticle result =
        await ref.read(readingServiceProvider).retranslate(_article);
    if (!mounted) return;
    setState(() {
      _retried = result;
      _busy = false;
    });
    if (!result.hasTranslation) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('翻译还没恢复，先读原文吧～'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: SweetieColors.text,
          duration: Duration(milliseconds: 1400),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: SweetieTheme.cardRadius,
        boxShadow: <BoxShadow>[
          ...SweetieTheme.cardShadow(SweetieColors.yellow),
          ...SweetieTheme.cardShadow(),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.auto_awesome,
                size: 15,
                color: SweetieColors.pink,
              ),
              const SizedBox(width: 6),
              Text(
                '中文译文',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: SweetieColors.pink.withAlpha(0xE6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_article.hasTranslation) ...<Widget>[
            if (_article.translatedTitle.isNotEmpty) ...<Widget>[
              Text(
                _article.translatedTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                  color: SweetieColors.text,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text(
              _article.translatedBody,
              style: const TextStyle(
                fontSize: 16,
                height: 1.9,
                color: SweetieColors.text,
              ),
            ),
          ] else ...<Widget>[
            const Text(
              '翻译接口开小差了，已为你保留英文原文。',
              style: TextStyle(
                fontSize: 15,
                height: 1.7,
                fontWeight: FontWeight.w600,
                color: SweetieColors.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '原文同样好读，也可以稍后再试一次翻译。',
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: SweetieColors.textLight,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _retry,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: SweetieColors.pink,
                        ),
                      )
                    : const Icon(
                        Icons.translate,
                        size: 16,
                        color: SweetieColors.pink,
                      ),
                label: const Text(
                  '再试一次翻译',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SweetieColors.pink,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  shape: const RoundedRectangleBorder(
                    borderRadius: SweetieTheme.cardRadius,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionBar extends ConsumerStatefulWidget {
  const _ActionBar({required this.onNext});

  final VoidCallback onNext;

  @override
  ConsumerState<_ActionBar> createState() => _ActionBarState();
}

class _ActionBarState extends ConsumerState<_ActionBar> {
  String? _articleId;
  bool _favorite = false;

  /// 文章换了 → 重新同步收藏态（幂等，仅 id 变化时触发）。
  void _syncFavorite(ReadingArticle article) {
    if (article.id == _articleId) return;
    _articleId = article.id;
    _favorite = false;
    unawaited(_refreshFavorite(article.id));
  }

  Future<void> _refreshFavorite(String id) async {
    final bool value = await ref.read(readingServiceProvider).isFavorite(id);
    if (!mounted || _articleId != id) return;
    if (value != _favorite) setState(() => _favorite = value);
  }

  Future<void> _toggleFavorite(ReadingArticle article) async {
    // 直接用切换结果更新按钮：不绕 provider 二次读取，点击后图标立即可信。
    final bool nowFavorite =
        await ref.read(readingServiceProvider).toggleFavorite(article);
    if (!mounted) return;
    setState(() => _favorite = nowFavorite);
    ref.invalidate(favoritesProvider); // 顶部入口的收藏数量跟着变
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFavorite ? '已收藏，随时回看' : '已取消收藏'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: SweetieColors.text,
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  /// 在收藏页里取消了收藏 → 当前这篇的心形也回到真实状态。
  void _onFavoritesChanged(AsyncValue<List<ReadingArticle>>? previous,
      AsyncValue<List<ReadingArticle>> next) {
    final List<ReadingArticle>? list = next.asData?.value;
    final String? id = _articleId;
    if (list == null || id == null) return;
    final bool nowFavorite = list.any((ReadingArticle a) => a.id == id);
    if (nowFavorite != _favorite) setState(() => _favorite = nowFavorite);
  }

  @override
  Widget build(BuildContext context) {
    final ReadingArticle? article =
        ref.watch(readingArticleProvider).asData?.value;
    if (article != null) _syncFavorite(article);
    ref.listen<AsyncValue<List<ReadingArticle>>>(
      favoritesProvider,
      _onFavoritesChanged,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ElevatedButton.icon(
              onPressed: widget.onNext,
              icon: const Icon(Icons.auto_stories_outlined, size: 18),
              label: const Text('换一篇'),
              style: ElevatedButton.styleFrom(
                backgroundColor: SweetieColors.pink,
                foregroundColor: Colors.white,
                elevation: 8,
                shadowColor: SweetieColors.soft(SweetieColors.pink),
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: const RoundedRectangleBorder(
                  borderRadius: SweetieTheme.cardRadius,
                ),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          _FavoriteButton(
            favorite: _favorite,
            onTap: article == null ? null : () => _toggleFavorite(article),
          ),
        ],
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({required this.favorite, this.onTap});

  final bool? favorite;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool isFavorite = favorite ?? false;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: SweetieTheme.cardRadius,
          boxShadow: <BoxShadow>[
            BoxShadow(
              // 未选中也给同调粉影（低透明），不再用灰黑投影。
              color: isFavorite
                  ? SweetieColors.pink.withValues(alpha: 0.20)
                  : SweetieColors.soft(SweetieColors.pink),
              blurRadius: isFavorite ? 20 : 12,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(
          isFavorite ? Icons.favorite : Icons.favorite_border,
          color: isFavorite ? SweetieColors.pink : SweetieColors.textLight,
          size: 24,
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: SweetieColors.pink,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '正在为你取一篇好文章…',
                    style: TextStyle(
                      fontSize: 13,
                      letterSpacing: 0.8,
                      color: SweetieColors.text.withAlpha(0x99),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Text(
                    '网络开小差了',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: SweetieColors.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '稍后重试，或先读读收藏里的文章。',
                    style: TextStyle(
                      fontSize: 13,
                      color: SweetieColors.textLight,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: SweetieColors.pink,
                      shape: const RoundedRectangleBorder(
                        borderRadius: SweetieTheme.cardRadius,
                      ),
                    ),
                    child: const Text(
                      '重试',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
