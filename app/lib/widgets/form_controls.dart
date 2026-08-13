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
  });

  final TextEditingController controller;
  final String? placeholder;
  final int rows;
  final bool mono;

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

/// Dropdown matching the input styling. [placeholder] is the empty option.
class AppSelect extends StatelessWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.placeholder = 'Select…',
    this.mono = false,
  });

  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final String placeholder;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    // A value no longer present in the master list (e.g. a bus retired from
    // the fleet) must not crash the dropdown — fall back to no selection.
    final current =
        (value != null && value!.isNotEmpty && options.contains(value))
            ? value
            : null;

    final style = mono
        ? AppText.mono(size: 16, weight: FontWeight.w600)
        : AppText.input;

    // A plain DropdownButton inside an InputDecorator rather than a
    // DropdownButtonFormField: the latter only takes an *initial* value, and
    // this control has to stay fully driven by [value].
    return FocusRing(
      child: Container(
        constraints: const BoxConstraints(minHeight: T.minTouchTarget),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.controlShape,
          border: Border.all(color: T.inputBorder, width: 1.5),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: current,
            isExpanded: true,
            icon: const Icon(Icons.expand_more, color: T.secondary, size: 22),
            style: style,
            dropdownColor: T.card,
            borderRadius: T.controlShape,
            hint: Text(
              placeholder,
              style: AppText.sans(size: 16, color: T.muted),
            ),
            items: <DropdownMenuItem<String>>[
              for (final o in options)
                DropdownMenuItem<String>(
                  value: o,
                  child: Text(o, style: style, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged,
          ),
        ),
      ),
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
