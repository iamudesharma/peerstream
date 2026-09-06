import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/format.dart';
import '../../core/widgets/app_empty.dart';
import '../../core/widgets/app_error.dart';
import '../../core/widgets/media_card.dart';
import '../../core/widgets/skeletons.dart';
import '../../models/media_item.dart';
import '../../providers/app_providers.dart';

class CategoryScreen extends ConsumerStatefulWidget {
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
  ConsumerState<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends ConsumerState<CategoryScreen> {
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
      final first = await ref.read(categoryProvider(_request).future);
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
          await ref.read(categoryProvider(_request.copyWithPage(_page + 1)).future);
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
    final firstPage = ref.watch(categoryProvider((type: widget.type, genreId: widget.genreId, page: 1)));
    return Scaffold(
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
            ref.invalidate(categoryProvider);
            _loadFirstPage();
          },
        ),
        data: (_) {
          if (_pageError != null) {
            return _CategoryError(
              error: _pageError!,
              onRetry: () {
                ref.invalidate(categoryProvider);
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
              ref.invalidate(categoryProvider);
              await _loadFirstPage();
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.pixels >=
                    notification.metrics.maxScrollExtent - 400) {
                  _loadMore();
                }
                return false;
              },
              child: GridView.builder(
                padding: const EdgeInsets.all(DesignTokens.pageGutter),
                gridDelegate:
                    const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: DesignTokens.gridMaxExtent,
                  mainAxisExtent: 278,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                ),
                itemCount: _items.length + (_loadingMore || _hasMore ? 1 : 0),
                itemBuilder: (_, index) {
                  if (index >= _items.length) {
                    return const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    );
                  }
                  return MediaCard(item: _items[index]);
                },
              ),
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
