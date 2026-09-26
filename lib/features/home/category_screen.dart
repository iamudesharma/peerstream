import 'package:peerstream/core/gap_widgets.dart';
import 'package:dartnative/flutter_compat.dart' hide Badge;
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/media_card.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/media_item.dart';
import '../../providers/app_store.dart';

class CategoryScreen extends StatefulWidget {
  const CategoryScreen({
    required this.type,
    required this.genreId,
    required this.title,
    super.key,
  });
  final MediaType type;
  final int genreId;
  final String title;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  int _page = 1;
  final _items = <MediaItem>[];
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _pageError;

  @override
  void initState() {
    super.initState();
    _loadFirstPage();
  }

  CategoryRequest get _request =>
      (type: widget.type, genreId: widget.genreId, page: _page);

  Future<void> _loadFirstPage() async {
    setState(() {
      _page = 1;
      _items.clear();
      _hasMore = true;
      _pageError = null;
    });
    try {
      final first = await AppStore.instance.category(_request).future;
      if (!mounted) return;
      setState(() {
        _items.addAll(first);
        _hasMore = first.isNotEmpty;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _pageError = error);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _pageError != null) return;
    setState(() => _loadingMore = true);
    try {
      final next =
          await AppStore.instance
              .category(_request.copyWithPage(_page + 1))
              .future;
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll(next);
        _hasMore = next.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstPage = AppStore.instance.category((
      type: widget.type,
      genreId: widget.genreId,
      page: 1,
    ))..watch(context);
    return Scaffold(
      // The screen colour belongs on the Scaffold: with no backgroundColor the
      // route reports the white default and dark screens flash white.
      backgroundColor: DesignTokens.background,
      appBar: AppBar(
        title: firstPage.when(
          data: (media) => Text(
            media.isEmpty ? widget.title : '${widget.title} (${_items.isEmpty ? media.length : _items.length})',
          ),
          loading: () => Text(widget.title),
          error: (_, _) => Text(widget.title),
        ),
      ),
      body: firstPage.when(
        loading: () => const SkeletonGrid(),
        error: (error, _) => _CategoryError(
          error: error,
          onRetry: () {
            AppStore.instance.clearCategories();
            _loadFirstPage();
          },
        ),
        data: (_) {
          if (_pageError != null) {
            return _CategoryError(
              error: _pageError!,
              onRetry: () {
                AppStore.instance.clearCategories();
                _loadFirstPage();
              },
            );
          }
          if (_items.isEmpty) {
            return const AppEmpty(
              icon: Icons.grid_view_outlined,
              title: 'Nothing in this lane',
              hint: 'Try another genre or check back later.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              AppStore.instance.clearCategories();
              await _loadFirstPage();
            },
            child: GridView.builder(
                padding: const EdgeInsets.all(DesignTokens.pageGutter),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  // 170 * 1.5 (poster) + ~46 (title + meta + spacing) = 301.
                  // 278 overflowed by 16px at 165.5w; 300 fits max extent and
                  // keeps aspect intact. Expanded poster in MediaCard also
                  // prevents overflow under textScale.
                  mainAxisExtent: 300,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                ),
                itemCount: _items.length + (_loadingMore || _hasMore ? 1 : 0),
                itemBuilder: (_, index) {
                  if (index >= _items.length) {
                    if (_loadingMore) {
                      return const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                      );
                    }
                    return Center(
                      child: TextButton(
                        onPressed: _loadMore,
                        child: const Text('Load more'),
                      ),
                    );
                  }
                  return MediaCard(item: _items[index]);
                },
              ),
          );
        },
      ),
    );
  }
}

class _CategoryError extends StatelessWidget {
  const _CategoryError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppError(
      title: 'Could not load this lane',
      detail: friendlyError(error),
      onRetry: onRetry,
      retryLabel: 'Retry',
    );
  }
}

extension on CategoryRequest {
  CategoryRequest copyWithPage(int page) =>
      (type: type, genreId: genreId, page: page);
}
