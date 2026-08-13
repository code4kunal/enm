import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/report.dart';
import '../utils/dates.dart';
import 'providers.dart';
import 'session.dart';

/// The day every report is showing. One selection across all three, because a
/// supervisor reads them together: what happened, what is still down, what has
/// not been explained.
final reportDateProvider = StateProvider<String>((ref) => Dates.today());

/// The month the DMR grid is showing, as `yyyy-MM`.
final reportMonthProvider = StateProvider<String>(
  (ref) => Dates.today().substring(0, 7),
);

final dmrDayProvider = FutureProvider<DmrDay>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final date = ref.watch(reportDateProvider);
  if (site.isEmpty) return Future<DmrDay>.value(DmrDay.empty);
  return ref
      .watch(reportRepositoryProvider)
      .fetchDmr(siteCode: site, date: date);
});

final dmrMonthProvider = FutureProvider<DmrMonth>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final month = ref.watch(reportMonthProvider);
  if (site.isEmpty) return Future<DmrMonth>.value(DmrMonth.empty);
  return ref
      .watch(reportRepositoryProvider)
      .fetchDmrMonth(siteCode: site, month: month);
});

final offRoadProvider = FutureProvider<List<OffRoadCase>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final date = ref.watch(reportDateProvider);
  if (site.isEmpty) return Future<List<OffRoadCase>>.value(const <OffRoadCase>[]);
  return ref
      .watch(reportRepositoryProvider)
      .fetchOffRoad(siteCode: site, date: date);
});

final investigationsProvider = FutureProvider<List<Investigation>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final date = ref.watch(reportDateProvider);
  if (site.isEmpty) {
    return Future<List<Investigation>>.value(const <Investigation>[]);
  }
  return ref
      .watch(reportRepositoryProvider)
      .fetchInvestigations(siteCode: site, date: date);
});

/// Breakdowns that day with nothing written against them yet — the badge on
/// the tab, because an unexplained breakdown is the thing that gets forgotten.
final outstandingInvestigationsProvider = Provider<int>((ref) {
  final all = ref.watch(investigationsProvider).valueOrNull ??
      const <Investigation>[];
  return all.where((i) => !i.isComplete).length;
});

/// Writing to the reports.
class ReportController {
  ReportController(this._ref);

  final Ref _ref;

  ReportRepository get _repo => _ref.read(reportRepositoryProvider);

  String get _site => _ref.read(sessionProvider).site;

  String get _date => _ref.read(reportDateProvider);

  Future<void> saveEntered(Map<String, int?> values, {String? notes}) async {
    await _repo.saveDmrEntered(
      siteCode: _site,
      date: _date,
      values: values,
      notes: notes,
    );
    _ref.invalidate(dmrDayProvider);
    _ref.invalidate(dmrMonthProvider);
  }

  Future<DmrDay> snapshot() async {
    final day = await _repo.snapshotDmr(siteCode: _site, date: _date);
    _ref.invalidate(dmrDayProvider);
    _ref.invalidate(dmrMonthProvider);
    return day;
  }

  Future<void> putOffRoad({
    required String vehicleId,
    required String issue,
    required DefectCategory category,
    String? offRoadSince,
    String? actionTaken,
    int? expectedDays,
    String? spareParts,
    String? remarks,
    bool awaitingVendor = false,
  }) async {
    await _repo.saveOffRoad(
      siteCode: _site,
      vehicleId: vehicleId,
      issue: issue,
      category: category,
      offRoadSince: offRoadSince,
      actionTaken: actionTaken,
      expectedDays: expectedDays,
      spareParts: spareParts,
      remarks: remarks,
      awaitingVendor: awaitingVendor,
    );
    _refresh();
  }

  Future<void> closeOffRoad(OffRoadCase item, String returnedOn) async {
    await _repo.closeOffRoad(caseId: item.id, returnedOn: returnedOn);
    _refresh();
  }

  Future<Investigation> openInvestigation(String entryId) =>
      _repo.openInvestigation(entryId);

  Future<void> saveInvestigation(
    String entryId, {
    String? findings,
    String? investigationAction,
    String? lastPmFindings,
    String? relatedComplaints,
  }) async {
    await _repo.saveInvestigation(
      entryId,
      findings: findings,
      investigationAction: investigationAction,
      lastPmFindings: lastPmFindings,
      relatedComplaints: relatedComplaints,
    );
    _ref.invalidate(investigationsProvider);
  }

  void _refresh() {
    // An off-road change moves DMR lines 4, 5-9 and 12, so the report is stale
    // the moment the list changes.
    _ref.invalidate(offRoadProvider);
    _ref.invalidate(dmrDayProvider);
    _ref.invalidate(dmrMonthProvider);
  }
}

final reportControllerProvider =
    Provider<ReportController>(ReportController.new);
