import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/checklist.dart';
import 'providers.dart';
import 'schedule.dart';
import 'session.dart';

/// The site's inspection checklists — one per inspection type.
///
/// This is what makes a daily inspection and a ten-day service different data
/// entry rather than one shared form.
final checklistsProvider = FutureProvider<List<Checklist>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return Future<List<Checklist>>.value(const <Checklist>[]);
  return ref.watch(checklistRepositoryProvider).fetchChecklists(site);
});

/// One checklist by its work type, for the form to render.
/// Which checklist a given bus takes for a given inspection.
///
/// A work type can have more than one: MBMT's daily inspection is three
/// sheets, because a 9M, an air-conditioned 12M and a non-AC 12M are not
/// checked for the same things. The bus's own variant wins; a site running a
/// single checklist never sets one and always lands on the unscoped fallback.
final checklistForProvider =
    Provider.family<Checklist?, ({int workTypeId, String? variant})>((ref, q) {
  final all = ref.watch(checklistsProvider).valueOrNull ?? const <Checklist>[];
  final mine = all.where((c) => c.workTypeId == q.workTypeId);

  if (q.variant != null && q.variant!.isNotEmpty) {
    for (final c in mine) {
      if (c.variant == q.variant) return c;
    }
  }
  for (final c in mine) {
    if (c.variant == null || c.variant!.isEmpty) return c;
  }
  // Better the wrong-variant list than an empty form: every variant shares
  // most of its checks, and a mechanic can see which one they were given.
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
    checklistForProvider((workTypeId: workTypeId, variant: null)),
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
      results: results,
    );
    // A sweep discharges a booking and can move the odometer, so the calendar
    // and the fleet are both stale now.
    _ref.invalidate(todaysInspectionsProvider);
    _ref.invalidate(calendarProvider);
    _ref.invalidate(siteVehiclesProvider);
    return entry;
  }
}

final inspectionControllerProvider =
    Provider<InspectionController>(InspectionController.new);
