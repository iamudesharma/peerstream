import 'package:dartnative/dartnative.dart';

import 'core/navigation.dart';
import 'features/home/home_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';

/// Permanent root. Tabs switch in place; pushed screens stack above this.
class PeerStreamApp extends StatelessWidget {
  const PeerStreamApp({super.key});

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
