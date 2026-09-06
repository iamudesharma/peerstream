import 'package:flutter/material.dart';

import '../design_tokens.dart';

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    this.width,
    this.height,
    this.borderRadius = DesignTokens.radiusInput,
    super.key,
  });

  final double? width;
  final double? height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: DesignTokens.surface2,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: DesignTokens.line),
      ),
    );
  }
}

class PosterSkeleton extends StatelessWidget {
  const PosterSkeleton({this.width = DesignTokens.cardWidth, super.key});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: const AspectRatio(
        aspectRatio: 2 / 3,
        child: SkeletonBox(width: double.infinity, height: double.infinity),
      ),
    );
  }
}

class MediaCardSkeleton extends StatelessWidget {
  const MediaCardSkeleton({this.width = DesignTokens.cardWidth, super.key});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          PosterSkeleton(),
          SizedBox(height: DesignTokens.space2),
          SkeletonBox(width: 110, height: 12),
          SizedBox(height: DesignTokens.space1),
          SkeletonBox(width: 70, height: 10),
        ],
      ),
    );
  }
}

class MediaRowSkeleton extends StatelessWidget {
  const MediaRowSkeleton({this.count = 6, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 252,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.pageGutter,
        ),
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        separatorBuilder: (_, _) =>
            const SizedBox(width: DesignTokens.space3),
        itemBuilder: (_, _) => const MediaCardSkeleton(),
      ),
    );
  }
}

class _GridCellSkeleton extends StatelessWidget {
  const _GridCellSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SkeletonBox(width: double.infinity, height: double.infinity),
        ),
        SizedBox(height: DesignTokens.space2),
        SkeletonBox(width: 110, height: 12),
        SizedBox(height: DesignTokens.space1),
        SkeletonBox(width: 70, height: 10),
      ],
    );
  }
}

class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({this.count = 12, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(DesignTokens.pageGutter),
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: DesignTokens.gridMaxExtent,
        mainAxisExtent: 278,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: count,
      itemBuilder: (_, _) => const _GridCellSkeleton(),
    );
  }
}

class SliverSkeletonGrid extends StatelessWidget {
  const SliverSkeletonGrid({this.count = 12, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.all(DesignTokens.pageGutter),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: DesignTokens.gridMaxExtent,
          mainAxisExtent: 278,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        itemCount: count,
        itemBuilder: (_, _) => const _GridCellSkeleton(),
      ),
    );
  }
}

class BackdropSkeleton extends StatelessWidget {
  const BackdropSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const AspectRatio(
      aspectRatio: 16 / 7,
      child: SkeletonBox(
        width: double.infinity,
        height: double.infinity,
        borderRadius: 0,
      ),
    );
  }
}

class EpisodeListSkeleton extends StatelessWidget {
  const EpisodeListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        3,
        (_) => const Padding(
          padding: EdgeInsets.symmetric(vertical: DesignTokens.space2),
          child: Row(
            children: [
              SkeletonBox(width: 96, height: 54),
              SizedBox(width: DesignTokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 160, height: 12),
                    SizedBox(height: DesignTokens.space1),
                    SkeletonBox(width: double.infinity, height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SourceListSkeleton extends StatelessWidget {
  const SourceListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        2,
        (_) => Container(
          margin: const EdgeInsets.only(bottom: DesignTokens.space3),
          padding: const EdgeInsets.all(DesignTokens.space4),
          decoration: BoxDecoration(
            color: DesignTokens.surface,
            borderRadius:
                BorderRadius.circular(DesignTokens.radiusCard),
            border: Border.all(color: DesignTokens.line),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: 200, height: 14),
              SizedBox(height: DesignTokens.space2),
              SkeletonBox(width: 120, height: 10),
              SizedBox(height: DesignTokens.space3),
              SkeletonBox(width: double.infinity, height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
