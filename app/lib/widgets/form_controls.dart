import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'chips.dart';

/// Field label row: text, red asterisk when required, blue MASTER badge when
/// the value comes from master data.
class FieldLabel extends StatelessWidget {
  const FieldLabel({
    super.key,
    required this.label,
    this.required = false,
    this.master = false,
    this.hint,
  });

  final String label;
  final bool required;
  final bool master;

  /// Trailing muted note, e.g. "— select one or more".
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: <Widget>[
          RichText(
            text: TextSpan(
              text: label,
              style: AppText.label,
              children: <InlineSpan>[
                if (required)
                  TextSpan(
                    text: ' *',
                    style: AppText.label.copyWith(color: T.red),
                  ),
                if (hint != null)
                  TextSpan(
                    text: ' $hint',
                    style: AppText.sans(size: 13, color: T.muted),
                  ),
              ],
            ),
          ),
          if (master) const TagBadge.master(),
        ],
      ),
    );
  }
}

/// Wraps a control in the 3px green focus ring the design specifies.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child, this.radius = 10});

  final Widget child;
  final double radius;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (has) => setState(() => _focused = has),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          boxShadow: _focused
              ? const <BoxShadow>[
                  BoxShadow(color: T.focusRing, blurRadius: 0, spreadRadius: 3),
                ]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Single-line or multi-line text input.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.rows = 1,
    this.mono = false,
    this.uppercase = false,
    this.numeric = false,
    this.obscure = false,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String? placeholder;
  final int rows;
  final bool mono;

  /// A read-only field still shows its value; it just cannot be changed.
  final bool enabled;

  /// User IDs and bus numbers are entered uppercase.
  final bool uppercase;
  final bool numeric;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? AppText.mono(size: numeric ? 17 : 16, weight: FontWeight.w600)
        : AppText.input;

    return FocusRing(
      child: TextField(
        controller: controller,
        style: style,
        enabled: enabled,
        obscureText: obscure,
        maxLines: obscure ? 1 : rows,
        minLines: obscure ? 1 : rows,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: textInputAction,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : (rows > 1 ? TextInputType.multiline : TextInputType.text),
        textCapitalization:
            uppercase ? TextCapitalization.characters : TextCapitalization.none,
        inputFormatters: <TextInputFormatter>[
          if (uppercase) _UpperCaseFormatter(),
          if (numeric)
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
        ],
        decoration: InputDecoration(hintText: placeholder),
      ),
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

/// Numeric input with a trailing unit label (litres, km).
class UnitField extends StatelessWidget {
  const UnitField({
    super.key,
    required this.controller,
    required this.unit,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? unit;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: AppTextField(
            controller: controller,
            placeholder: '0',
            mono: true,
            numeric: true,
            onChanged: onChanged,
          ),
        ),
        if (unit != null) ...<Widget>[
          const SizedBox(width: 8),
          Text(
            unit!,
            style: AppText.sans(
              size: 14,
              weight: FontWeight.w600,
              color: T.secondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Dropdown matching the input styling. Type to filter; opens on focus/tap.
class AppSelect extends StatefulWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.placeholder = 'Select…',
    this.emptyHint = 'No options loaded',
    this.mono = false,
  });

  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final String placeholder;
  final String emptyHint;
  final bool mono;

  @override
  State<AppSelect> createState() => _AppSelectState();
}

class _AppSelectState extends State<AppSelect> {
  final LayerLink _link = LayerLink();
  final FocusNode _focus = FocusNode();
  final OverlayPortalController _portal = OverlayPortalController();
  late final TextEditingController _controller;
  final GlobalKey _fieldKey = GlobalKey();

  String? get _selected {
    final v = widget.value;
    if (v == null || v.isEmpty) return null;
    return widget.options.contains(v) ? v : null;
  }

  List<String> get _filtered {
    final needle = _controller.text.trim().toLowerCase();
    if (needle.isEmpty) return widget.options;
    // Keep the selected value visible while the field still shows it.
    if (_selected != null && needle == _selected!.toLowerCase()) {
      return widget.options;
    }
    return widget.options
        .where((o) => o.toLowerCase().contains(needle))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _selected ?? '');
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant AppSelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus) {
      final next = _selected ?? '';
      if (_controller.text != next) {
        _controller.text = next;
      }
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _open();
    } else {
      // Let option onTapDown land before we tear the overlay down.
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || _focus.hasFocus) return;
        _close();
        final cur = _selected ?? '';
        if (_controller.text != cur) {
          _controller.text = cur;
        }
      });
    }
  }

  void _open() {
    if (widget.options.isEmpty) return;
    if (!_portal.isShowing) _portal.show();
    setState(() {});
  }

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  void _pick(String? option) {
    widget.onChanged(option);
    _controller.text = option ?? '';
    _focus.unfocus();
    _close();
  }

  Size _fieldSize() {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size ?? const Size(240, T.minTouchTarget);
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.options.isEmpty;
    final style = widget.mono
        ? AppText.mono(size: 16, weight: FontWeight.w600)
        : AppText.input;

    return FocusRing(
      child: CompositedTransformTarget(
        link: _link,
        child: Container(
          key: _fieldKey,
          constraints: const BoxConstraints(minHeight: T.minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: T.card,
            borderRadius: T.controlShape,
            border: Border.all(color: T.inputBorder, width: 1.5),
          ),
          child: empty
              ? Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  child: Text(
                    widget.emptyHint,
                    style: AppText.sans(size: 16, color: T.muted),
                  ),
                )
              : OverlayPortal(
                  controller: _portal,
                  overlayChildBuilder: (context) {
                    final size = _fieldSize();
                    final list = _filtered;
                    return CompositedTransformFollower(
                      link: _link,
                      showWhenUnlinked: false,
                      offset: Offset(0, size.height + 4),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 6,
                          color: T.card,
                          borderRadius: T.controlShape,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: 240,
                              minWidth: size.width,
                              maxWidth: size.width.clamp(200, 480),
                            ),
                            child: list.isEmpty
                                ? Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      'No matches',
                                      style: AppText.sans(
                                        size: 14,
                                        color: T.muted,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: EdgeInsets.zero,
                                    shrinkWrap: true,
                                    itemCount: list.length,
                                    itemBuilder: (_, i) {
                                      final o = list[i];
                                      final selected = o == _selected;
                                      return InkWell(
                                        onTapDown: (_) => _pick(o),
                                        child: Container(
                                          color: selected
                                              ? T.greenTint
                                              : Colors.transparent,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                          child: Text(
                                            o,
                                            style: style,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      ),
                    );
                  },
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    style: style,
                    onTap: _open,
                    onChanged: (text) {
                      if (text.trim().isEmpty && _selected != null) {
                        widget.onChanged(null);
                      }
                      _open();
                      setState(() {});
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: widget.placeholder,
                      hintStyle: AppText.sans(size: 16, color: T.muted),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _portal.isShowing
                              ? Icons.expand_less
                              : Icons.expand_more,
                          color: T.secondary,
                          size: 22,
                        ),
                        onPressed: () {
                          if (_portal.isShowing) {
                            _focus.unfocus();
                            _close();
                          } else {
                            _focus.requestFocus();
                            _open();
                          }
                        },
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Multi-select searchable list — used for Done By (SiteOps staff).
class AppMultiSelect extends StatefulWidget {
  const AppMultiSelect({
    super.key,
    required this.values,
    required this.options,
    required this.onChanged,
    this.placeholder = 'Search and select…',
    this.emptyHint = 'No options loaded',
  });

  final List<String> values;
  final List<String> options;
  final ValueChanged<List<String>> onChanged;
  final String placeholder;
  final String emptyHint;

  @override
  State<AppMultiSelect> createState() => _AppMultiSelectState();
}

class _AppMultiSelectState extends State<AppMultiSelect> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    final needle = _query.text.trim().toLowerCase();
    final pool = widget.options
        .where((o) => !widget.values.contains(o))
        .toList();
    if (needle.isEmpty) return pool;
    return pool.where((o) => o.toLowerCase().contains(needle)).toList();
  }

  void _toggle(String name) {
    final next = List<String>.from(widget.values);
    if (next.contains(name)) {
      next.remove(name);
    } else {
      next.add(name);
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.options.isEmpty;
    final filtered = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.values.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final v in widget.values)
                  InputChip(
                    label: Text(v, style: AppText.sans(size: 13)),
                    onDeleted: () => _toggle(v),
                    backgroundColor: T.greenTint,
                    deleteIconColor: T.greenInk,
                  ),
              ],
            ),
          ),
        FocusRing(
          child: Container(
            constraints: const BoxConstraints(minHeight: T.minTouchTarget),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: T.controlShape,
              border: Border.all(color: T.inputBorder, width: 1.5),
            ),
            child: TextField(
              controller: _query,
              enabled: !empty,
              style: AppText.input,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: empty ? widget.emptyHint : widget.placeholder,
                hintStyle: AppText.sans(size: 16, color: T.muted),
                suffixIcon: const Icon(Icons.search, color: T.secondary, size: 20),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        if (_query.text.isNotEmpty || filtered.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: T.controlShape,
              border: Border.all(color: T.inputBorder, width: 1),
            ),
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'No matches',
                      style: AppText.sans(size: 14, color: T.muted),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length.clamp(0, 40),
                    itemBuilder: (_, i) {
                      final o = filtered[i];
                      return ListTile(
                        dense: true,
                        title: Text(o, style: AppText.input),
                        onTap: () {
                          _toggle(o);
                          _query.clear();
                          setState(() {});
                        },
                      );
                    },
                  ),
          ),
        ],
      ],
    );
  }
}

/// Segmented toggle — Shift A / B / C. Selected option is solid green.
class SegmentedField extends StatelessWidget {
  const SegmentedField({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<String> options;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (var i = 0; i < options.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _SegButton(
              label: options[i],
              selected: value == options[i],
              onTap: () => onChanged(options[i]),
            ),
          ),
        ],
      ],
    );
  }
}

class _SegButton extends StatelessWidget {
  const _SegButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: T.controlShape,
        child: Container(
          constraints: const BoxConstraints(minHeight: T.minTouchTarget),
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? T.green : T.card,
            borderRadius: T.controlShape,
            border: Border.all(
              color: selected ? T.green : T.inputBorder,
              width: 1.5,
            ),
          ),
          child: Text(
            label,
            style: AppText.sans(
              size: 16,
              weight: FontWeight.w700,
              color: selected ? T.white : T.body,
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-only field that opens the platform date or time picker on tap.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.display,
    required this.placeholder,
    required this.onTap,
    this.mono = true,
  });

  final String display;
  final String placeholder;
  final Future<void> Function() onTap;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final empty = display.isEmpty;
    final style = mono
        ? AppText.mono(
            size: 16,
            weight: FontWeight.w600,
            color: empty ? T.muted : T.ink,
          )
        : AppText.sans(size: 16, color: empty ? T.muted : T.ink);

    return InkWell(
      onTap: () => onTap(),
      borderRadius: T.controlShape,
      child: Container(
        constraints: const BoxConstraints(minHeight: T.minTouchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.controlShape,
          border: Border.all(color: T.inputBorder, width: 1.5),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                empty ? placeholder : display,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.expand_more, color: T.secondary, size: 20),
          ],
        ),
      ),
    );
  }
}
