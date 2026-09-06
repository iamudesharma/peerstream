import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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

  void _navigate(BuildContext context, int index) {
    if (index == 0) context.go('/');
    if (index == 1) context.go('/search');
    if (index == 2) context.go('/storage');
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final extended = width >= 1200;
    final content = Scaffold(
      appBar: wide ? null : AppBar(title: Text(title ?? 'PeerStream')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DesignTokens.contentMaxWidth,
          ),
          child: body,
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: (index) => _navigate(context, index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
                NavigationDestination(
                  icon: Icon(Icons.storage_outlined),
                  selectedIcon: Icon(Icons.storage),
                  label: 'Storage',
                ),
              ],
            ),
    );
    if (!wide) return content;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: extended,
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) => _navigate(context, index),
            leading: extended
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_circle_fill,
                          color: DesignTokens.accent,
                        ),
                        SizedBox(width: 8),
                        Text('PeerStream'),
                      ],
                    ),
                  )
                : const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Icon(
                      Icons.play_circle_fill,
                      color: DesignTokens.accent,
                    ),
                  ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: Text('Home'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.search),
                label: Text('Search'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.storage_outlined),
                selectedIcon: Icon(Icons.storage),
                label: Text('Storage'),
              ),
            ],
          ),
          const VerticalDivider(
            width: 1,
            thickness: 1,
            color: DesignTokens.line,
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: DesignTokens.contentMaxWidth,
                ),
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
