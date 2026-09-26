import 'package:dartnative/dartnative.dart';

import 'core/navigation.dart';
import 'core/theme.dart';
import 'features/home/home_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';

/// Permanent root, and the only widget passed to `runApp`.
///
/// Extends [App] rather than returning one: [App] is what supplies the
/// [Theme] and the [Navigator], and `runApp` takes *any* widget as the root.
/// Handing it a bare screen (or nesting an [App] inside another widget) left
/// the tree with no theme and no navigator — every `Theme.of(context)` fell
/// back to the light default, and pushed routes had nowhere to go.
class PeerStreamApp extends App {
  PeerStreamApp({super.key})
    : super(
        title: 'PeerStream',
        theme: buildPeerStreamTheme(),
        // A const child: switching tabs rebuilds [_Shell], never the root, so
        // the native route stack is not torn down while a screen is pushed.
        home: const _Shell(),
      );
}

/// Tabs switch in place; pushed screens stack above this.
class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    final index = shellIndex.watch(context);
    return switch (index) {
      1 => const SearchScreen(),
      2 => const SettingsScreen(),
      _ => const HomeScreen(),
    };
  }
}
