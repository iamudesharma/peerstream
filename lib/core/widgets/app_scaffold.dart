import 'package:peerstream/core/navigation.dart';
import 'package:peerstream/core/gap_widgets.dart';
import 'package:dartnative/dartnative.dart';
import 'package:peerstream/core/icons.dart';

import '../design_tokens.dart';

class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.body,
    required this.selectedIndex,
    this.title,
    super.key,
  });
  final Widget body;
  final int selectedIndex;
  final String? title;

  void _navigate(BuildContext context, int index) =>
      context.go(const ['/', '/search', '/settings'][index]);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final extended = width >= 1200;
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: DesignTokens.contentMaxWidth,
        ),
        child: body,
      ),
    );
    return Scaffold(
      appBar: wide
          ? null
          : AppBar(
              title: const PeerStreamBrand(),
              actions: [
                if (selectedIndex != 1)
                  IconButton(
                    onPressed: () => _navigate(context, 1),
                    icon: const Icon(Icons.search),
                  ),
                const SizedBox(width: 8),
              ],
            ),
      body: SafeArea(
        top: wide,
        bottom: false,
        child: wide
            ? Row(
                children: [
                  SizedBox(
                    width: extended ? 224 : 88,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: extended ? 24 : 20,
                            vertical: 32,
                          ),
                          child: PeerStreamBrand(compact: !extended),
                        ),
                        if (extended)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(28, 24, 24, 12),
                            child: Text(
                              'YOUR CINEMA',
                              style: TextStyle(
                                color: DesignTokens.textTertiary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        for (var i = 0; i < 3; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: _NavigationItem(
                              label: const [
                                'Discover',
                                'Search',
                                'Settings',
                              ][i],
                              icon: const [
                                Icons.home,
                                Icons.search,
                                Icons.tune,
                              ][i],
                              selected: selectedIndex == i,
                              extended: extended,
                              onTap: () => _navigate(context, i),
                            ),
                          ),
                        const Spacer(),
                        if (extended)
                          const Padding(
                            padding: EdgeInsets.all(28),
                            child: Text(
                              'Your next great watch.\nYour own way.',
                              style: TextStyle(
                                color: DesignTokens.textTertiary,
                                fontSize: 12,
                                height: 1.7,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: (index) => _navigate(context, index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home),
                  selectedIcon: Icon(Icons.home),
                  label: 'Discover',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune),
                  label: 'Settings',
                ),
              ],
            ),
    );
  }
}

class PeerStreamBrand extends StatelessWidget {
  const PeerStreamBrand({this.compact = false, super.key});
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: DesignTokens.accent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: const Icon(
          Icons.play_arrow,
          color: Colors.white,
          size: 26,
        ),
      ),
      if (!compact) ...[
        const SizedBox(width: 10),
        const Flexible(
          child: Text(
            'PeerStream',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
        ),
      ],
    ],
  );
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.extended,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: extended ? '' : label,
    child: Container(
      decoration: BoxDecoration(
        color: selected ? DesignTokens.surface2 : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            mainAxisAlignment: extended
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 23,
                color: selected
                    ? DesignTokens.accent
                    : DesignTokens.textSecondary,
              ),
              if (extended) ...[
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: selected
                          ? DesignTokens.textPrimary
                          : DesignTokens.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
