import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Opens an editor as a bottom sheet.
///
/// Every sheet in the app goes through here, for a reason that is easy to get
/// wrong one screen at a time: the app is laid out under a `ShellRoute`, so the
/// nearest Navigator is the shell's, and a sheet pushed onto it is bounded by
/// the shell's content box rather than the window. [useRootNavigator] puts it
/// on the root overlay, which is the size of the window.
///
/// Prefer [EditorSheet] for the content — it keeps the save button reachable.
Future<R?> showEditorSheet<R>({
  required BuildContext context,
  required WidgetBuilder builder,
  /// Fraction of the window the sheet may grow to before its body scrolls.
  double maxHeightFactor = 0.92,
}) {
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
                const SizedBox(height: 14),
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
