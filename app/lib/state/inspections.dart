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
final checklistProvider = Provider.family<Checklist?, int>((ref, workTypeId) {
  final all = ref.watch(checklistsProvider).valueOrNull ?? const <Checklist>[];
  for (final c in all) {
    if (c.workTypeId == workTypeId) return c;
  }
  return null;
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
