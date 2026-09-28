import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/entry_photo.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Paints a dashed rounded-rect border. Used by empty states and the photo
/// attach dropzone, both of which the design draws with `border: dashed`.
class DashedBorder extends StatelessWidget {
  const DashedBorder({
    super.key,
    required this.child,
    this.color = T.inputBorder,
    this.radius = 12,
    this.strokeWidth = 1.5,
    this.dash = 6,
    this.gap = 4,
    this.fill,
  });

  final Widget child;
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRectPainter(
        color: color,
        radius: radius,
        strokeWidth: strokeWidth,
        dash: dash,
        gap: gap,
        fill: fill,
      ),
      child: child,
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  const _DashedRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dash,
    required this.gap,
    required this.fill,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );

    if (fill != null) {
      canvas.drawRRect(rect, Paint()..color = fill!);
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Walk the rounded-rect outline, alternating dash and gap segments.
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.dash != dash ||
      old.gap != gap;
}

/// Dashed-border "nothing here" panel.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DashedBorder(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        alignment: Alignment.center,
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: AppText.sans(size: 14, color: T.muted),
        ),
      ),
    );
  }
}

/// Photo attach toggle on the entry form. Turns green-tinted once attached.
class PhotoAttachButton extends StatefulWidget {
  const PhotoAttachButton({
    super.key,
    required this.attached,
    required this.onAttach,
    required this.onRemove,
  });

  final bool attached;

  /// Fires once a file was actually picked — never on a cancelled picker,
  /// which is how "tap did nothing but somehow attached a photo" happened.
  final void Function(String filename, List<int> bytes) onAttach;
  final VoidCallback onRemove;

  @override
  State<PhotoAttachButton> createState() => _PhotoAttachButtonState();
}

class _PhotoAttachButtonState extends State<PhotoAttachButton> {
  bool _hovered = false;
  bool _picking = false;

  Future<void> _tap() async {
    if (widget.attached) {
      widget.onRemove();
      return;
    }
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        // The web picker only hands back bytes when asked.
        withData: true,
      );
      // Cancelled — nothing picked, so nothing is attached.
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;
      widget.onAttach(file.name, bytes);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final attached = widget.attached;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _tap,
        child: DashedBorder(
          radius: 10,
          color: _hovered ? T.green : T.dashed,
          fill: attached ? T.greenTint : T.dropzoneFill,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: T.minTouchTarget),
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
            alignment: Alignment.center,
            child: Text(
              attached
                  ? '1 photo attached ✓ (tap to remove)'
                  : _picking
                      ? 'Choosing…'
                      : '+ Attach photo (optional)',
              textAlign: TextAlign.center,
              style: AppText.sans(
                size: 14.5,
                weight: FontWeight.w600,
                color: attached ? T.greenInk : T.secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The multi-photo gallery for Breakdown/Driver Complaint/Work Done —
/// [PhotoAttachButton] generalized from a single on/off toggle to a list.
/// Every other register keeps using [PhotoAttachButton] itself, unchanged.
class PhotoGalleryPicker extends StatefulWidget {
  const PhotoGalleryPicker({
    super.key,
    required this.existingPhotos,
    required this.pendingCount,
    required this.onAdd,
    required this.onRemoveExisting,
    required this.onRemoveNew,
  });

  final List<EntryPhoto> existingPhotos;

  /// Newly picked, not-yet-uploaded photos already held by the caller — this
  /// widget only needs the count to render a placeholder tile per one; the
  /// bytes themselves stay with the form until save.
  final int pendingCount;

  final void Function(String filename, List<int> bytes) onAdd;
  final void Function(String photoId) onRemoveExisting;
  final void Function(int index) onRemoveNew;

  @override
  State<PhotoGalleryPicker> createState() => _PhotoGalleryPickerState();
}

class _PhotoGalleryPickerState extends State<PhotoGalleryPicker> {
  bool _picking = false;

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) return;
      widget.onAdd(file.name, bytes);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Widget _tile({required Widget child, required VoidCallback? onRemove}) {
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Container(
          width: 96,
          height: 96,
          padding: const EdgeInsets.all(6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: T.dropzoneFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: T.dashed),
          ),
          child: child,
        ),
        if (onRemove != null)
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: T.secondary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final photo in widget.existingPhotos)
          _tile(
            onRemove: () => widget.onRemoveExisting(photo.id),
            child: Text(
              photo.url.split('/').last,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.sans(size: 11, color: T.secondary),
            ),
          ),
        for (var i = 0; i < widget.pendingCount; i++)
          _tile(
            onRemove: () => widget.onRemoveNew(i),
            child: Text(
              'New photo',
              textAlign: TextAlign.center,
              style: AppText.sans(
                size: 11,
                weight: FontWeight.w600,
                color: T.greenInk,
              ),
            ),
          ),
        GestureDetector(
          onTap: _pick,
          child: DashedBorder(
            radius: 10,
            child: Container(
              width: 96,
              height: 96,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(6),
              child: Text(
                _picking ? 'Choosing…' : '+ Add photo',
                textAlign: TextAlign.center,
                style: AppText.sans(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: T.secondary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
