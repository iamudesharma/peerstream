import 'package:dartnative/dartnative.dart';
import 'package:dartnative/flutter_compat.dart' hide Badge;

/// Pull-to-refresh is not a native view in this runtime. The child still
/// builds, and [onRefresh] runs from an explicit control when one exists.
class RefreshIndicator extends StatelessWidget {
  const RefreshIndicator({
    required this.child,
    required this.onRefresh,
    super.key,
  });

  final Widget child;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => child;
}

class Tooltip extends StatelessWidget {
  const Tooltip({required this.child, this.message, super.key});

  final Widget child;
  final String? message;

  @override
  Widget build(BuildContext context) => child;
}

class AlertDialog extends StatelessWidget {
  const AlertDialog({
    this.title,
    this.content,
    this.actions,
    super.key,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) title!,
          if (content != null) ...[
            const SizedBox(height: 12),
            content!,
          ],
          if (actions != null) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final action in actions!) ...[
                  action,
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class SwitchListTile extends StatelessWidget {
  const SwitchListTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.secondary,
    super.key,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: secondary,
      title: title,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

abstract class PopupMenuEntry<T> implements Widget {}

class PopupMenuItem<T> extends StatelessWidget implements PopupMenuEntry<T> {
  const PopupMenuItem({
    required this.child,
    this.value,
    this.enabled = true,
    super.key,
  });

  final T? value;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class PopupMenuDivider extends StatelessWidget implements PopupMenuEntry<Never> {
  const PopupMenuDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(height: 1);
}

class PopupMenuButton<T> extends StatelessWidget {
  const PopupMenuButton({
    required this.itemBuilder,
    this.onSelected,
    this.child,
    this.initialValue,
    super.key,
  });

  final List<Widget> Function(BuildContext context) itemBuilder;
  final ValueChanged<T>? onSelected;
  final Widget? child;
  final T? initialValue;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        final entries = itemBuilder(context);
        final selected = await showDialog<T>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in entries)
                    if (entry is PopupMenuItem<T>)
                      Opacity(
                        opacity: entry.enabled ? 1 : 0.4,
                        child: GestureDetector(
                          onTap: !entry.enabled || entry.value == null
                              ? null
                              : () => Navigator.pop(dialogContext, entry.value),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: entry.child,
                          ),
                        ),
                      )
                    else
                      const Divider(height: 1),
                ],
              ),
            );
          },
        );
        if (selected != null) onSelected?.call(selected);
      },
      child: child ?? const Icon(MaterialSymbolsOutlined.more_vert),
    );
  }
}

class NavigationDestination {
  const NavigationDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
  });

  final Widget icon;
  final Widget? selectedIcon;
  final String label;
}

class NavigationBar extends StatelessWidget {
  const NavigationBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  });

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: selectedIndex,
      onTap: onDestinationSelected,
      items: [
        for (final destination in destinations)
          BottomNavigationBarItem(
            label: destination.label,
            icon: selectedIndex == destinations.indexOf(destination)
                ? (destination.selectedIcon ?? destination.icon)
                : destination.icon,
          ),
      ],
    );
  }
}

class NavigationRailDestination {
  const NavigationRailDestination({
    required this.icon,
    required this.label,
    this.selectedIcon,
  });

  final Widget icon;
  final Widget? selectedIcon;
  final Widget label;
}

class NavigationRail extends StatelessWidget {
  const NavigationRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.extended = false,
    this.leading,
    super.key,
  });

  final List<NavigationRailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool extended;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: extended ? 200 : 72,
      color: const Color(0xFF10141D),
      child: Column(
        children: [
          if (leading != null) leading!,
          for (var i = 0; i < destinations.length; i++)
            GestureDetector(
              onTap: () => onDestinationSelected(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                child: Row(
                  children: [
                    i == selectedIndex
                        ? (destinations[i].selectedIcon ?? destinations[i].icon)
                        : destinations[i].icon,
                    if (extended) ...[
                      const SizedBox(width: 8),
                      destinations[i].label,
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ActionChip extends StatelessWidget {
  const ActionChip({
    required this.label,
    this.onPressed,
    this.avatar,
    super.key,
  });

  final Widget label;
  final VoidCallback? onPressed;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF171D28),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (avatar != null) ...[avatar!, const SizedBox(width: 6)],
            label,
          ],
        ),
      ),
    );
  }
}

class FilterChip extends StatelessWidget {
  const FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onSelected == null ? null : () => onSelected!(!selected),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF24473E) : const Color(0xFF171D28),
          borderRadius: BorderRadius.circular(8),
        ),
        child: label,
      ),
    );
  }
}

class ChoiceChip extends StatelessWidget {
  const ChoiceChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: label,
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class Chip extends StatelessWidget {
  const Chip({required this.label, super.key});

  final Widget label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF171D28),
        borderRadius: BorderRadius.circular(8),
      ),
      child: label,
    );
  }
}

class StatefulBuilder extends StatefulWidget {
  const StatefulBuilder({required this.builder, super.key});

  final Widget Function(BuildContext context, void Function(void Function()) setState)
      builder;

  @override
  State<StatefulBuilder> createState() => _StatefulBuilderState();
}

class _StatefulBuilderState extends State<StatefulBuilder> {
  @override
  Widget build(BuildContext context) => widget.builder(context, setState);
}

/// Tappable row of [icon] + [label].
///
/// Built from GestureDetector + Container rather than FilledButton: the
/// native Button renders only Text, Icon or imageAsset children and silently
/// drops a Row, so `FilledButton(child: Row(...))` produced a blank control.
Widget _iconLabelButton({
  required VoidCallback? onPressed,
  required Widget icon,
  required Widget label,
  required Color background,
  required Color foreground,
  Color? border,
}) {
  if (onPressed == null) {
    background = background.withValues(alpha: 0.4);
    foreground = foreground.withValues(alpha: 0.4);
  }
  return GestureDetector(
    onTap: onPressed,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: border == null ? null : Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // DartNative has no IconTheme, so recolour the icon by rebuilding it
          // with the button's foreground instead of inheriting one.
          if (icon is Icon)
            Icon(icon.icon, size: icon.size, color: foreground)
          else
            icon,
          const SizedBox(width: 8),
          DefaultTextStyle(
            style: TextStyle(
              color: foreground,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            child: label,
          ),
        ],
      ),
    ),
  );
}

Widget filledIconButton({
  required VoidCallback? onPressed,
  required Widget icon,
  required Widget label,
}) {
  return _iconLabelButton(
    onPressed: onPressed,
    icon: icon,
    label: label,
    background: const Color(0xFF1E7F5C),
    foreground: Colors.white,
  );
}

Widget outlinedIconButton({
  required VoidCallback? onPressed,
  required Widget icon,
  required Widget label,
}) {
  return _iconLabelButton(
    onPressed: onPressed,
    icon: icon,
    label: label,
    background: Colors.transparent,
    foreground: const Color(0xFFEDEFF2),
    border: const Color(0xFF2C3542),
  );
}

Widget textIconButton({
  required VoidCallback? onPressed,
  required Widget icon,
  required Widget label,
}) {
  return _iconLabelButton(
    onPressed: onPressed,
    icon: icon,
    label: label,
    background: Colors.transparent,
    foreground: const Color(0xFF1E7F5C),
  );
}

ListView separatedListView({
  Key? key,
  required int itemCount,
  required Widget Function(BuildContext context, int index) itemBuilder,
  required Widget Function(BuildContext context, int index) separatorBuilder,
  EdgeInsetsGeometry? padding,
  Axis scrollDirection = Axis.vertical,
  bool shrinkWrap = false,
}) {
  return ListView.builder(
    key: key,
    padding: padding,
    scrollDirection: scrollDirection,
    shrinkWrap: shrinkWrap,
    itemCount: itemCount == 0 ? 0 : itemCount * 2 - 1,
    itemBuilder: (context, index) {
      if (index.isEven) return itemBuilder(context, index ~/ 2);
      return separatorBuilder(context, index ~/ 2);
    },
  );
}
