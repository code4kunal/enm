import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/inspection.dart';
import '../utils/dates.dart';
import 'providers.dart';
import 'session.dart';

/// The window the calendar is showing.
///
/// Held as a start date plus a span rather than two dates so paging is one
/// operation and can never invert the range.
class CalendarWindow {
  const CalendarWindow({required this.start, this.days = 28});

  /// `yyyy-MM-dd` of the first column.
  final String start;
  final int days;

  String get end => Dates.addDays(start, days - 1);

  CalendarWindow shift(int by) =>
      CalendarWindow(start: Dates.addDays(start, by), days: days);

  CalendarWindow withSpan(int span) =>
      CalendarWindow(start: start, days: span);

  /// A window anchored a few days back, so what was just missed is still on
  /// screen next to what is coming.
  static CalendarWindow around(String today, {int lookBack = 3, int days = 28}) =>
      CalendarWindow(start: Dates.addDays(today, -lookBack), days: days);
}

final calendarWindowProvider = StateProvider<CalendarWindow>(
  (ref) => CalendarWindow.around(Dates.today()),
);

/// The schedule for the active site and window.
final calendarProvider = FutureProvider<InspectionCalendar>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final window = ref.watch(calendarWindowProvider);
  if (site.isEmpty) {
    return Future<InspectionCalendar>.value(InspectionCalendar.empty);
  }
  return ref.watch(inspectionRepositoryProvider).fetchCalendar(
        siteCode: site,
        from: window.start,
        to: window.end,
      );
});

/// The site's inspection cycles.
final inspectionPlansProvider = FutureProvider<List<InspectionPlan>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) {
    return Future<List<InspectionPlan>>.value(const <InspectionPlan>[]);
  }
  return ref.watch(inspectionRepositoryProvider).fetchPlans(site);
});

/// Which alerts the log is showing.
final alertFilterProvider = StateProvider<String>((ref) => 'open');

final alertsProvider = FutureProvider<List<SiteAlert>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final status = ref.watch(alertFilterProvider);
  if (site.isEmpty) return Future<List<SiteAlert>>.value(const <SiteAlert>[]);
  return ref
      .watch(inspectionRepositoryProvider)
      .fetchAlerts(site, status: status);
});

/// Open alerts, for the nav badge. Reads the same cache as the alert list.
final openAlertCountProvider = Provider<int>((ref) {
  final alerts = ref.watch(alertsProvider).valueOrNull ?? const <SiteAlert>[];
  return alerts.where((a) => a.isOpen).length;
});

/// Actions on the schedule. Each one refreshes what it changed rather than
/// mutating a local copy, because the generator can move more than one slot.
class ScheduleController {
  ScheduleController(this._ref);

  final Ref _ref;

  InspectionRepository get _repo => _ref.read(inspectionRepositoryProvider);

  String get _site => _ref.read(sessionProvider).site;

  Future<GenerationResult> generate() async {
    final result = await _repo.generate(_site);
    _refresh();
    return result;
  }

  Future<void> move(InspectionSlot slot, String date) async {
    await _repo.updateSlot(slot, scheduledOn: date);
    _refresh();
  }

  Future<void> setStatus(InspectionSlot slot, SlotStatus status) async {
    await _repo.updateSlot(slot, status: status);
    _refresh();
  }

  Future<void> annotate(InspectionSlot slot, String notes) async {
    await _repo.updateSlot(slot, notes: notes);
    _refresh();
  }

  Future<void> remove(InspectionSlot slot) async {
    await _repo.deleteSlot(slot.id);
    _refresh();
  }

  Future<void> book({
    required String vehicleId,
    required int workTypeId,
    required String date,
    String notes = '',
  }) async {
    await _repo.createSlot(
      siteCode: _site,
      vehicleId: vehicleId,
      workTypeId: workTypeId,
      scheduledOn: date,
      notes: notes,
    );
    _refresh();
  }

  Future<void> acknowledge(SiteAlert alert) async {
    await _repo.acknowledgeAlert(alert.id);
    _ref.invalidate(alertsProvider);
  }

  void _refresh() {
    _ref.invalidate(calendarProvider);
    _ref.invalidate(alertsProvider);
  }
}

final scheduleControllerProvider =
    Provider<ScheduleController>(ScheduleController.new);
