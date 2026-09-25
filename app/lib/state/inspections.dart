import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/registers.dart';
import '../data/repositories.dart';
import '../models/checklist.dart';
import 'providers.dart';
import '../utils/dates.dart';
import 'entries.dart';
import 'reports.dart';
import 'schedule.dart';
import 'session.dart';

/// The site's inspection checklists — one per inspection type.
///
/// This is what makes a daily inspection and a ten-day service different data
/// entry rather than one shared form.
///
/// Uses [sessionProvider].site (E&M code like `MBMT`), not SiteOps UUID —
/// `/sites/{code}/checklists` is keyed by depot code.
final checklistsProvider = FutureProvider<List<Checklist>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return Future<List<Checklist>>.value(const <Checklist>[]);
  return ref.watch(checklistRepositoryProvider).fetchChecklists(site);
});

/// Which checklist a given bus takes for a given inspection.
///
/// A work type can have more than one: MBMT's daily inspection is three
/// sheets, because a 9M, an air-conditioned 12M and a non-AC 12M are not
/// checked for the same things. Docking (P.M) further splits by KM rung —
/// pass [milestoneKm] when the booked slot has one.
final checklistForProvider = Provider.family<
    Checklist?,
    ({int workTypeId, String? variant, int? milestoneKm})>((ref, q) {
  final all = ref.watch(checklistsProvider).valueOrNull ?? const <Checklist>[];
  final mine = all.where((c) => c.workTypeId == q.workTypeId);

  Checklist? pick({String? variant, int? km, required bool allowEmpty}) {
    for (final c in mine) {
      final variantOk = variant == null
          ? (c.variant == null || c.variant!.isEmpty)
          : c.variant == variant;
      if (!variantOk) continue;
      if (km != null && c.milestoneKm != km) continue;
      if (km == null && c.milestoneKm != null) continue;
      if (!allowEmpty && c.isEmpty) continue;
      return c;
    }
    return null;
  }

  if (q.variant != null && q.variant!.isNotEmpty) {
    if (q.milestoneKm != null) {
      final byKm = pick(variant: q.variant, km: q.milestoneKm, allowEmpty: false);
      if (byKm != null) return byKm;
      // Explicit KM request: do not fall back to a different rung / supersheet.
      final emptyKm = pick(variant: q.variant, km: q.milestoneKm, allowEmpty: true);
      return emptyKm;
    }
    final byVariant = pick(variant: q.variant, km: null, allowEmpty: false);
    if (byVariant != null) return byVariant;
  }
  if (q.milestoneKm != null) {
    // Variant unknown — still try the KM sheet for any variant of this work type.
    for (final c in mine) {
      if (c.milestoneKm == q.milestoneKm && !c.isEmpty) return c;
    }
    return null;
  }
  final unscoped = pick(variant: null, km: null, allowEmpty: false);
  if (unscoped != null) return unscoped;

  final populated = mine.where((c) => !c.isEmpty);
  if (populated.isNotEmpty) return populated.first;
  return mine.isEmpty ? null : mine.first;
});

/// One entry per inspection type, whatever variants it has.
///
/// A work type with three checklists is still one thing a mechanic starts:
/// they tap "Daily inspection", pick a bus, and the bus decides which list
/// they get. Showing a card per template would offer the same job four times.
final inspectionTypesProvider = Provider<List<Checklist>>((ref) {
  final all = ref.watch(checklistsProvider).valueOrNull ?? const <Checklist>[];
  final byWorkType = <int, Checklist>{};
  for (final c in all) {
    final seen = byWorkType[c.workTypeId];
    // Prefer one that actually has lines, so a work type whose unscoped list
    // is empty but whose variants are written does not read as unwritten.
    if (seen == null || (seen.isEmpty && !c.isEmpty)) {
      byWorkType[c.workTypeId] = c;
    }
  }
  return byWorkType.values.toList()
    ..sort((a, b) => a.workTypeCode.compareTo(b.workTypeCode));
});

/// How many checklists a work type keeps, so a card can say "3 by bus model"
/// rather than a count that only describes one of them.
final variantCountProvider = Provider.family<int, int>((ref, workTypeId) {
  final all = ref.watch(checklistsProvider).valueOrNull ?? const <Checklist>[];
  return all
      .where((c) => c.workTypeId == workTypeId && !c.isEmpty)
      .length;
});

/// The unscoped checklist for a work type, for screens that are not about one
/// particular bus — the site's master data editor.
final checklistProvider = Provider.family<Checklist?, int>((ref, workTypeId) {
  return ref.watch(
    checklistForProvider(
      (workTypeId: workTypeId, variant: null, milestoneKm: null),
    ),
  );
});
/// Inspections already recorded today, for the Home feed.
final todaysInspectionsProvider =
    FutureProvider<List<InspectionEntry>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) {
    return Future<List<InspectionEntry>>.value(const <InspectionEntry>[]);
  }
  return ref.watch(checklistRepositoryProvider).todaysInspections(site);
});

/// Writing checklists and recording sweeps.
class InspectionController {
  InspectionController(this._ref);

  final Ref _ref;

  ChecklistRepository get _repo => _ref.read(checklistRepositoryProvider);

  String get _site => _ref.read(sessionProvider).site;

  Future<Checklist> saveChecklist(Checklist checklist) async {
    final saved = await _repo.saveChecklist(_site, checklist);
    _ref.invalidate(checklistsProvider);
    return saved;
  }

  Future<InspectionEntry> record({
    required String vehicleId,
    required int workTypeId,
    required String inspectedOn,
    String? entryTime,
    String? doneBy,
    String? supervisor,
    int? odometerKm,
    String? remarks,
    int? milestoneKm,
    required List<InspectionResult> results,
  }) async {
    final entry = await _repo.recordInspection(
      siteCode: _site,
      vehicleId: vehicleId,
      workTypeId: workTypeId,
      inspectedOn: inspectedOn,
      entryTime: entryTime,
      doneBy: doneBy,
      supervisor: supervisor,
      odometerKm: odometerKm,
      remarks: remarks,
      milestoneKm: milestoneKm,
      results: results,
    );
    // A sweep discharges a booking and can move the odometer, so the calendar
    // and the fleet are both stale now — and Registers → Inspections must
    // pick up the new row without a site switch.
    _ref.invalidate(todaysInspectionsProvider);
    _ref.invalidate(siteInspectionsProvider);
    _ref.invalidate(calendarProvider);
    _ref.invalidate(siteVehiclesProvider);
    // DI / 10-day / docking lines on the DMR + inspection charts.
    _ref.invalidate(dmrDayProvider);
    _ref.invalidate(dmrMonthProvider);
    _ref.invalidate(controlChartProvider);
    return entry;
  }

  /// Multiple Bus Inspection: one checklist/date/time/supervisor, several
  /// vehicles, one request.
  Future<List<InspectionEntry>> recordBatch({
    required int workTypeId,
    required String inspectedOn,
    String? entryTime,
    String? supervisor,
    required List<InspectionBatchItem> items,
  }) async {
    final entries = await _repo.recordInspectionBatch(
      siteCode: _site,
      workTypeId: workTypeId,
      inspectedOn: inspectedOn,
      entryTime: entryTime,
      supervisor: supervisor,
      items: items,
    );
    _ref.invalidate(todaysInspectionsProvider);
    _ref.invalidate(siteInspectionsProvider);
    _ref.invalidate(calendarProvider);
    _ref.invalidate(siteVehiclesProvider);
    _ref.invalidate(dmrDayProvider);
    _ref.invalidate(dmrMonthProvider);
    _ref.invalidate(controlChartProvider);
    return entries;
  }
}

final inspectionControllerProvider =
    Provider<InspectionController>(InspectionController.new);


/// Every inspection recorded at this site, newest first.
///
/// Inspections live beside the registers rather than in them — a checklist
/// sweep is not a defect noticed — but they are still the depot's record of
/// what was done, so the register screen lists them under their own filter.
final siteInspectionsProvider =
    FutureProvider<List<InspectionEntry>>((ref) async {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return const <InspectionEntry>[];
  final rows =
      await ref.watch(checklistRepositoryProvider).fetchInspections(site);
  return rows..sort((a, b) => b.inspectedOn.compareTo(a.inspectedOn));
});

/// The same list under the register screen's period and search filters, so
/// "last 7 days" and a bus number mean the same thing on either tab.
final filteredInspectionsProvider =
    Provider<List<InspectionEntry>>((ref) {
  final all =
      ref.watch(siteInspectionsProvider).valueOrNull ?? const <InspectionEntry>[];
  final f = ref.watch(entryFiltersProvider);
  final needle = f.query.trim().toLowerCase();

  bool inPeriod(InspectionEntry e) => switch (f.dateMode) {
        DateMode.all => true,
        DateMode.today => e.inspectedOn == Dates.today(),
        DateMode.week => e.inspectedOn.compareTo(Dates.today(-6)) >= 0 &&
            e.inspectedOn.compareTo(Dates.today()) <= 0,
        DateMode.month => e.inspectedOn.startsWith(
            f.month.isNotEmpty ? f.month : Dates.currentMonthPrefix(),
          ),
        DateMode.custom => (f.from.isEmpty ||
                e.inspectedOn.compareTo(f.from) >= 0) &&
            (f.to.isEmpty || e.inspectedOn.compareTo(f.to) <= 0),
      };

  bool matchesFilter(InspectionEntry e) {
    if (f.registerId == kInspectionsFilter || f.registerId == 'all') {
      return true;
    }
    final code = e.workTypeCode.toLowerCase();
    final name = e.workTypeName.toLowerCase();

    if (f.registerId == kPmDockingFilter) {
      return code.contains('p.m') || code.contains('pm') || name.contains('preventive');
    }
    if (f.registerId == kTenDayFilter) {
      return code.contains('10') || name.contains('10');
    }
    if (f.registerId == kDailyFilter) {
      return code.contains('d.i') || code.contains('daily') || name.contains('daily');
    }
    return true;
  }

  bool matches(InspectionEntry e) =>
      needle.isEmpty ||
      e.registrationNo.toLowerCase().contains(needle) ||
      e.workTypeCode.toLowerCase().contains(needle) ||
      e.workTypeName.toLowerCase().contains(needle) ||
      (e.doneBy ?? '').toLowerCase().contains(needle) ||
      (e.supervisor ?? '').toLowerCase().contains(needle);

  // An inspection failure is a ticket, same as a breakdown or driver
  // complaint -- it just has no register entry behind it, which is why
  // this can't be answered by pendingFilterEntriesProvider. "Pending" means
  // at least one result is still an open ticket; "Complete" means none are
  // (never failed, or every failure has been resolved through Work Done).
  bool matchesStatus(InspectionEntry e) {
    if (f.hasOpenTicket == null) return true;
    final hasOpen = e.results.any((r) => r.ticketStatus == 'open');
    return f.hasOpenTicket! ? hasOpen : !hasOpen;
  }

  return all
      .where((e) => inPeriod(e) && matchesFilter(e) && matches(e) && matchesStatus(e))
      .toList();
});
