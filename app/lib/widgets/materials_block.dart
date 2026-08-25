import 'package:flutter/material.dart';

import '../models/job_card.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'form_controls.dart';
import 'sub_tabs.dart';

/// "Parts used?" — off by default, at most 3 lines when on. Every material
/// is search-and-tap against the synced SAP catalog, never typed; presence
/// of any line here is what opens a job card and posts it to SAP once the
/// entry/inspection saves. This is the one control ground staff need for the
/// whole SAP PM flow, so it stays a single toggle plus a short bounded list
/// — not a dynamic add-forever editor.
class MaterialsBlock extends StatefulWidget {
  const MaterialsBlock({
    super.key,
    required this.catalog,
    required this.onChanged,
  });

  final List<SapMaterialOption> catalog;
  final ValueChanged<List<MaterialLine>> onChanged;

  static const int maxLines = 3;

  @override
  State<MaterialsBlock> createState() => _MaterialsBlockState();
}

class _MaterialsBlockState extends State<MaterialsBlock> {
  bool _open = false;
  final List<_Line> _lines = <_Line>[_Line()];

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  void _emit() {
    widget.onChanged(
      _lines
          .where((l) => l.material != null && l.qty.text.trim().isNotEmpty)
          .map(
            (l) => MaterialLine(
              sapMaterialNo: l.material!.sapMaterialNo,
              qtyRequired: l.qty.text.trim(),
            ),
          )
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() {
              _open = !_open;
              if (!_open) {
                for (final line in _lines) {
                  line.reset();
                }
                _emit();
              }
            }),
            child: Row(
              children: <Widget>[
                Icon(
                  _open ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 22,
                  color: _open ? T.green : T.secondary,
                ),
                const SizedBox(width: 10),
                Text('Parts used?', style: AppText.sans(size: 15, weight: FontWeight.w600)),
              ],
            ),
          ),
          if (_open) ...<Widget>[
            const SizedBox(height: 16),
            for (int i = 0; i < _lines.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 12),
              _MaterialLineRow(
                line: _lines[i],
                catalog: widget.catalog,
                onChanged: _emit,
                onRemove: _lines.length > 1
                    ? () => setState(() {
                          _lines[i].dispose();
                          _lines.removeAt(i);
                          _emit();
                        })
                    : null,
              ),
            ],
            if (_lines.length < MaterialsBlock.maxLines &&
                _lines.last.material != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: InkWell(
                  onTap: () => setState(() => _lines.add(_Line())),
                  child: Text(
                    '+ Add another part',
                    style: AppText.sans(size: 14, weight: FontWeight.w600, color: T.green),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Line {
  _Line() : qty = TextEditingController();

  SapMaterialOption? material;
  String search = '';
  final TextEditingController qty;

  void reset() {
    material = null;
    search = '';
    qty.clear();
  }

  void dispose() => qty.dispose();
}

class _MaterialLineRow extends StatefulWidget {
  const _MaterialLineRow({
    required this.line,
    required this.catalog,
    required this.onChanged,
    required this.onRemove,
  });

  final _Line line;
  final List<SapMaterialOption> catalog;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  State<_MaterialLineRow> createState() => _MaterialLineRowState();
}

class _MaterialLineRowState extends State<_MaterialLineRow> {
  @override
  Widget build(BuildContext context) {
    final needle = widget.line.search.trim().toLowerCase();
    final matches = needle.isEmpty
        ? widget.catalog
        : widget.catalog
            .where((m) => m.description.toLowerCase().contains(needle) || m.sapMaterialNo.toLowerCase().contains(needle))
            .toList();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                decoration: InputDecoration(
                  hintText: 'Search part…',
                  hintStyle: AppText.sans(size: 14, color: T.muted),
                  isDense: true,
                  border: const OutlineInputBorder(borderRadius: T.controlShape),
                ),
                onChanged: (v) => setState(() => widget.line.search = v),
              ),
              const SizedBox(height: 6),
              AppSelect(
                value: widget.line.material?.label,
                options: matches.map((m) => m.label).toList(),
                placeholder: matches.isEmpty ? 'No matches' : '${matches.length} part${matches.length == 1 ? '' : 's'}',
                onChanged: (label) {
                  setState(() {
                    widget.line.material =
                        matches.where((m) => m.label == label).firstOrNull;
                  });
                  widget.onChanged();
                },
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 1,
          child: UnitField(
            controller: widget.line.qty,
            unit: null,
            onChanged: (_) => widget.onChanged(),
          ),
        ),
        if (widget.onRemove != null) ...<Widget>[
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: T.secondary,
            onPressed: widget.onRemove,
          ),
        ],
      ],
    );
  }
}
