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

final investigationsProvider = FutureProvider<InvestigationDay>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final date = ref.watch(reportDateProvider);
  if (site.isEmpty) {
    return Future<InvestigationDay>.value(InvestigationDay.empty);
  }
  return ref
      .watch(reportRepositoryProvider)
      .fetchInvestigations(siteCode: site, date: date);
});

/// Breakdowns that day with nothing written against them yet — the badge on
/// the tab, because an unexplained breakdown is the thing that gets forgotten.
final outstandingInvestigationsProvider = Provider<int>((ref) {
  final day = ref.watch(investigationsProvider).valueOrNull;
  return (day?.items ?? const <Investigation>[])
      .where((i) => !i.isComplete)
      .length;
});

// ─── Annexure-IV control charts ───────────────────────────────────────────

/// The chart on screen. The wire value, not the index — the list is served.
final chartKindProvider = StateProvider<String>((ref) => 'pmSchedule');

/// The window the chart covers, as `yyyy-MM`. A control chart is read a month
/// at a time; that is the shape the depot files.
final chartMonthProvider = StateProvider<String>(
  (ref) => Dates.today().substring(0, 7),
);

final chartKindsProvider = FutureProvider<List<ChartKind>>((ref) {
  return ref.watch(reportRepositoryProvider).fetchChartKinds();
});

final controlChartProvider = FutureProvider<ControlChart>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final kind = ref.watch(chartKindProvider);
  final month = ref.watch(chartMonthProvider);
  if (site.isEmpty || kind.isEmpty) {
    return Future<ControlChart>.value(ControlChart.empty);
  }
  return ref.watch(reportRepositoryProvider).fetchControlChart(
        siteCode: site,
        kind: kind,
        fromDate: '$month-01',
        toDate: Dates.lastOfMonth(month),
      );
});

// ─── Fitted units: the statement and the history card ─────────────────────

/// The month the Unit Failure Statement is showing, as `yyyy-MM`.
final unitMonthProvider = StateProvider<String>(
  (ref) => Dates.today().substring(0, 7),
);

/// The bus whose history card is open. Empty until one is picked — a card is
/// per-bus, so there is no sensible default.
final historyVehicleProvider = StateProvider<String>((ref) => '');

/// The month the history card runs to, as `yyyy-MM`.
final historyMonthProvider = StateProvider<String>(
  (ref) => Dates.today().substring(0, 7),
);

final unitTypesProvider = FutureProvider<List<UnitType>>((ref) {
  return ref.watch(reportRepositoryProvider).fetchUnitTypes();
});

final unitFailuresProvider = FutureProvider<List<FittedUnit>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final month = ref.watch(unitMonthProvider);
  if (site.isEmpty) return Future<List<FittedUnit>>.value(const <FittedUnit>[]);
  return ref
      .watch(reportRepositoryProvider)
      .fetchUnitFailures(siteCode: site, month: month);
});

/// What is on the bus whose card is open — the list a removal is picked from.
final fittedUnitsProvider = FutureProvider<List<FittedUnit>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final vehicleId = ref.watch(historyVehicleProvider);
  if (site.isEmpty || vehicleId.isEmpty) {
    return Future<List<FittedUnit>>.value(const <FittedUnit>[]);
  }
  return ref
      .watch(reportRepositoryProvider)
      .fetchFittedUnits(siteCode: site, vehicleId: vehicleId);
});

final busHistoryProvider = FutureProvider<BusHistory>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final vehicleId = ref.watch(historyVehicleProvider);
  final month = ref.watch(historyMonthProvider);
  if (site.isEmpty || vehicleId.isEmpty) {
    return Future<BusHistory>.value(BusHistory.empty);
  }
  return ref.watch(reportRepositoryProvider).fetchBusHistory(
        siteCode: site,
        vehicleId: vehicleId,
        toMonth: month,
      );
});

/// Writing to the reports.
class ReportController {
  ReportController(this._ref);

  final Ref _ref;

  ReportRepository get _repo => _ref.read(reportRepositoryProvider);

  String get _site => _ref.read(sessionProvider).site;

  String get _date => _ref.read(reportDateProvider);

  /// Put a component on a bus. Refreshes both views it feeds.
  Future<void> fitUnit({
    required String vehicleId,
    required int unitTypeId,
    required String fittedOn,
    String? unitNo,
    int? fittedOdometerKm,
    String? remarks,
  }) async {
    await _repo.fitUnit(
      siteCode: _site,
      vehicleId: vehicleId,
      unitTypeId: unitTypeId,
      fittedOn: fittedOn,
      unitNo: unitNo,
      fittedOdometerKm: fittedOdometerKm,
      remarks: remarks,
    );
    _refreshUnits();
  }

  /// Take it off, which is what puts it on the failure statement.
  Future<void> removeUnit(
    String unitId, {
    required String removedOn,
    int? removedOdometerKm,
    String? removalReason,
    String? remarks,
  }) async {
    await _repo.removeUnit(
      unitId,
      removedOn: removedOn,
      removedOdometerKm: removedOdometerKm,
      removalReason: removalReason,
      remarks: remarks,
    );
    _refreshUnits();
  }

  /// A fitting or a removal moves the statement, the card, and the DMR line
  /// that counts HV packs — so all three are invalidated together.
  void _refreshUnits() {
    _ref.invalidate(unitFailuresProvider);
    _ref.invalidate(fittedUnitsProvider);
    _ref.invalidate(busHistoryProvider);
    _ref.invalidate(dmrDayProvider);
  }

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
