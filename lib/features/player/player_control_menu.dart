import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// Owns popups for the lifetime of the video, independently of media_kit's
/// toolbar, which removes its buttons after the controls fade out.
class PlayerMenuOverlay extends StatefulWidget {
  const PlayerMenuOverlay({required this.child, super.key});

  final Widget child;

  static Future<T?> showChoices<T>({
    required BuildContext context,
    required String title,
    required Widget Function(BuildContext, ValueChanged<T>) builder,
  }) {
    final video = context.findAncestorStateOfType<_PlayerMenuOverlayState>();
    return video?._showChoices(title, builder) ?? Future<T?>.value();
  }

  @override
  State<PlayerMenuOverlay> createState() => _PlayerMenuOverlayState();
}

class _PlayerMenuOverlayState extends State<PlayerMenuOverlay> {
  final _menuFocus = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  String? _tooltip;
  Rect _anchor = Rect.zero;
  Widget Function(BuildContext, VoidCallback)? _menuBuilder;
  VoidCallback? _onClose;

  void _cancelSelection() {
    final cancel = _onClose;
    _onClose = null;
    cancel?.call();
  }

  void _close() {
    _cancelSelection();
    if (mounted) setState(() => _menuBuilder = null);
  }

  void _toggle(PlayerControlMenu menu, BuildContext buttonContext) {
    if (_menuBuilder != null && _tooltip == menu.tooltip) {
      _close();
      return;
    }
    final video = context.findRenderObject()! as RenderBox;
    final button = buttonContext.findRenderObject()! as RenderBox;
    final origin = video.globalToLocal(button.localToGlobal(Offset.zero));
    _cancelSelection();
    setState(() {
      _anchor = origin & button.size;
      _tooltip = menu.tooltip;
      _menuBuilder = menu.menuBuilder;
    });
  }

  Future<T?> _showChoices<T>(
    String title,
    Widget Function(BuildContext, ValueChanged<T>) builder,
  ) {
    _cancelSelection();
    final result = Completer<T?>();
    setState(() {
      _tooltip = title;
      _onClose = () {
        if (!result.isCompleted) result.complete();
      };
      _menuBuilder = (context, close) => builder(context, (value) {
        if (!result.isCompleted) result.complete(value);
        close();
      });
    });
    return result.future;
  }

  @override
  void dispose() {
    _cancelSelection();
    _menuFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final builder = _menuBuilder;
        final padding = constraints.maxWidth < 16 || constraints.maxHeight < 16
            ? 0.0
            : 8.0;
        final width = (constraints.maxWidth - padding * 2)
            .clamp(0, 256)
            .toDouble();
        // A video can resize while its toolbar is hidden. Keep the saved
        // anchor within the current video rather than the old dimensions.
        final anchorTop = _anchor.top
            .clamp(padding, constraints.maxHeight - padding)
            .toDouble();
        final anchorBottom = _anchor.bottom
            .clamp(padding, constraints.maxHeight - padding)
            .toDouble();
        final above = (anchorTop - padding * 2)
            .clamp(0, constraints.maxHeight - padding * 2)
            .toDouble();
        final below = (constraints.maxHeight - anchorBottom - padding * 2)
            .clamp(0, constraints.maxHeight)
            .toDouble();
        final showAbove = above >= below;
        final height = showAbove ? above : below;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (builder != null) ...[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _close,
                ),
              ),
              Positioned(
                right: (constraints.maxWidth - _anchor.right)
                    .clamp(padding, constraints.maxWidth - width - padding)
                    .toDouble(),
                bottom: showAbove
                    ? constraints.maxHeight - anchorTop + padding
                    : null,
                top: showAbove ? null : anchorBottom + padding,
                child: FocusScope(
                  node: _menuFocus,
                  autofocus: true,
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.escape): _close,
                    },
                    child: Focus(
                      autofocus: true,
                      child: Material(
                        key: ValueKey('player-menu-$_tooltip'),
                        color: const Color(0xf2232328),
                        elevation: 8,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          width: width,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: height),
                            child: SingleChildScrollView(
                              child: ListTileTheme(
                                dense: true,
                                minVerticalPadding: 8,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                textColor: Colors.white,
                                iconColor: Colors.white,
                                child: builder(context, _close),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    ),
  );
}

/// Anchors a compact popup to a control without pushing an external route.
class PlayerControlMenu extends StatelessWidget {
  const PlayerControlMenu({
    required this.tooltip,
    required this.icon,
    required this.menuBuilder,
    super.key,
  });

  final String tooltip;
  final Widget icon;
  final Widget Function(BuildContext, VoidCallback close) menuBuilder;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: icon,
    onPressed: () {
      final video = context.findAncestorStateOfType<_PlayerMenuOverlayState>();
      assert(
        video != null,
        'Player menus require a video-scoped PlayerMenuOverlay.',
      );
      video?._toggle(this, context);
    },
  );
}
