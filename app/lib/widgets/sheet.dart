import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Opens an editor — a bottom sheet below [T.mobileBreakpoint], a centred
/// dialog above it.
///
/// A sheet sliding up from the bottom is a phone's own idiom, built for a
/// thumb reaching the bottom edge; stretched full-width across a desktop
/// window it reads as an unfinished mobile screen rather than a considered
/// one. Above the breakpoint this opens a width-capped dialog instead —
/// [EditorSheet] hides the drag handle to match.
///
/// Every editor in the app goes through here, for a reason that is easy to
/// get wrong one screen at a time: the app is laid out under a `ShellRoute`,
/// so the nearest Navigator is the shell's, and a route pushed onto it is
/// bounded by the shell's content box rather than the window.
/// [useRootNavigator] puts it on the root overlay, which is the size of the
/// window, in both branches.
///
/// Prefer [EditorSheet] for the content — it keeps the save button reachable.
Future<R?> showEditorSheet<R>({
  required BuildContext context,
  required WidgetBuilder builder,
  /// Fraction of the window the editor may grow to before its body scrolls.
  double maxHeightFactor = 0.92,
}) {
  if (MediaQuery.sizeOf(context).width >= T.mobileBreakpoint) {
    return showDialog<R>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: T.maxFormWidth,
            maxHeight:
                MediaQuery.sizeOf(dialogContext).height * maxHeightFactor,
          ),
          child: Material(
            color: T.card,
            borderRadius: T.cardShape,
            clipBehavior: Clip.antiAlias,
            child: builder(dialogContext),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<R>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: T.card,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * maxHeightFactor,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: T.rCard),
    ),
    builder: builder,
  );
}

/// The frame for a form in a bottom sheet: heading, scrolling fields, and an
/// action pinned to the bottom.
///
/// The action is pinned rather than sitting at the end of the fields because a
/// form long enough to scroll is exactly the form whose save button goes
/// missing — and a button you cannot reach is the same as no button at all.
///
/// The fields sit in a [Flexible], not a bare scroll view: under the loose
/// height a bottom sheet hands down, a scroll view on its own sizes to its
/// content and simply runs off the bottom instead of scrolling. [Flexible] is
/// what gives it the leftover space to scroll within, while still letting a
/// short form make a short sheet.
class EditorSheet extends StatelessWidget {
  const EditorSheet({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.action,
    this.footnote,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  /// The primary action, kept in view however long the form is.
  final Widget? action;

  /// A line under the action — what saving will mean, usually.
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final action = this.action;
    final footnote = this.footnote;
    // The drag handle is a phone affordance — "swipe down to dismiss" means
    // nothing on the dialog `showEditorSheet` opens at this width.
    final isDialog = MediaQuery.sizeOf(context).width >= T.mobileBreakpoint;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (!isDialog)
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: T.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                if (!isDialog) const SizedBox(height: 14),
                Text(title, style: AppText.sectionTitle),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(subtitle, style: AppText.meta),
                ],
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
          if (action != null)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: const BoxDecoration(
                color: T.card,
                border: Border(top: BorderSide(color: T.border)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  action,
                  if (footnote != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      footnote,
                      textAlign: TextAlign.center,
                      style: AppText.meta,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
