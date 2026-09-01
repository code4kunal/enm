import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/repositories.dart';
import '../state/providers.dart';
import '../state/session.dart';
import '../state/toast.dart';
import 'buttons.dart';

/// "Download PDF" for one report.
///
/// The server renders it — the same rule as the import parsing, so there is
/// exactly one implementation of each depot layout rather than one per client.
/// Delivery goes through the platform share sheet, which is a download on web
/// and "save to Files" on mobile, and is already how the CSV export ships.
class ReportDownloadButton extends ConsumerStatefulWidget {
  const ReportDownloadButton({
    super.key,
    required this.doc,
    this.label = 'Download PDF',
    this.date,
    this.month,
    this.chartKind,
    this.fromDate,
    this.toDate,
    this.vehicleId,
    this.enabled = true,
    this.format = 'pdf',
  });

  final ReportDoc doc;
  final String label;

  /// Whichever of these the report is scoped by; the rest are ignored.
  final String? date;
  final String? month;
  final String? chartKind;
  final String? fromDate;
  final String? toDate;
  final String? vehicleId;

  /// False when there is nothing to print yet — no bus picked, say.
  final bool enabled;

  /// 'pdf' or 'xlsx' — only [ReportDoc.dmrMonth] honours anything but pdf.
  final String format;

  @override
  ConsumerState<ReportDownloadButton> createState() =>
      _ReportDownloadButtonState();
}

class _ReportDownloadButtonState extends ConsumerState<ReportDownloadButton> {
  bool _busy = false;

  Future<void> _download() async {
    final site = ref.read(sessionProvider).site;
    if (site.isEmpty) return;

    setState(() => _busy = true);
    try {
      final file = await ref.read(reportRepositoryProvider).downloadReport(
            widget.doc,
            siteCode: site,
            date: widget.date,
            month: widget.month,
            chartKind: widget.chartKind,
            fromDate: widget.fromDate,
            toDate: widget.toDate,
            vehicleId: widget.vehicleId,
            format: widget.format,
          );

      final mimeType = widget.format == 'xlsx'
          ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          : 'application/pdf';
      await Share.shareXFiles(
        <XFile>[
          XFile.fromData(
            file.bytes,
            mimeType: mimeType,
            name: file.name,
          ),
        ],
        fileNameOverrides: <String>[file.name],
        subject: 'Transvolt E&M — ${file.name}',
      );
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlineActionButton(
      label: _busy ? 'Preparing…' : widget.label,
      onPressed: _busy || !widget.enabled ? null : _download,
    );
  }
}
