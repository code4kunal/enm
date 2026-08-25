import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/registers.dart';
import '../models/entry.dart';
import '../models/job_card.dart';
import '../utils/dates.dart';
import 'providers.dart';
import 'session.dart';

/// Period selector on the Registers view.
enum DateMode {
  today('Today'),
  week('Last 7 days'),
  month('This month'),
  custom('Custom range'),
  all('All');

  const DateMode(this.label);

  final String label;
}

@immutable
class EntryFilters {
  const EntryFilters({
    this.query = '',
    this.registerId = 'all',
    this.dateMode = DateMode.month,
    this.from = '',
    this.to = '',
  });

  final String query;

  /// Register id, or `all`.
  final String registerId;
  final DateMode dateMode;

  /// `yyyy-MM-dd` bounds, only meaningful when [dateMode] is
  /// [DateMode.custom]. Empty means unbounded on that side.
  final String from;
  final String to;

  EntryFilters copyWith({
    String? query,
    String? registerId,
    DateMode? dateMode,
    String? from,
    String? to,
  }) {
    return EntryFilters(
      query: query ?? this.query,
      registerId: registerId ?? this.registerId,
      dateMode: dateMode ?? this.dateMode,
      from: from ?? this.from,
      to: to ?? this.to,
    );
  }
}

class EntryFiltersController extends Notifier<EntryFilters> {
  @override
  EntryFilters build() => EntryFilters(from: Dates.today(-7), to: Dates.today());

  void setQuery(String q) => state = state.copyWith(query: q);

  void setRegister(String id) => state = state.copyWith(registerId: id);

  void setDateMode(DateMode m) => state = state.copyWith(dateMode: m);

  void setFrom(String d) => state = state.copyWith(from: d);

  void setTo(String d) => state = state.copyWith(to: d);
}

final entryFiltersProvider =
    NotifierProvider<EntryFiltersController, EntryFilters>(
  EntryFiltersController.new,
);

/// All entries for the active site, newest first.
class EntriesController extends AsyncNotifier<List<RegisterEntry>> {
  @override
  Future<List<RegisterEntry>> build() async {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    if (site.isEmpty) return const <RegisterEntry>[];
    return ref.watch(entryRepositoryProvider).fetchEntries(site: site);
  }

  /// Saves a new entry. Breakdowns open; everything else is done on save.
  ///
  /// Any [materials] line opens a job card and posts it to SAP once the
  /// entry saves; an empty list (the default) never touches SAP.
  Future<RegisterEntry> create({
    required String registerId,
    required Map<String, String> data,
    List<MaterialLine> materials = const <MaterialLine>[],
  }) async {
    final session = ref.read(sessionProvider);
    final normalised = _normalise(data);

    final draft = RegisterEntry(
      id: '',
      registerId: registerId,
      date: normalised['date'] ?? Dates.today(),
      time: Dates.nowClock(),
      site: session.site,
      enteredBy: _attribution(normalised, fallback: session.user?.name ?? 'You'),
      data: normalised,
      status: registerId == kBreakdownRegisterId
          ? EntryStatus.open
          : EntryStatus.done,
    );

    final created = await ref
        .read(entryRepositoryProvider)
        .createEntry(draft, materials: materials);
    _replaceAll((list) => <RegisterEntry>[created, ...list]);
    return created;
  }

  /// Updates an existing entry in place, preserving its capture time and
  /// open/resolved status.
  ///
  /// Named `edit` rather than `update` because `AsyncNotifier` already defines
  /// an `update` with an incompatible signature.
  Future<RegisterEntry> edit({
    required RegisterEntry original,
    required Map<String, String> data,
  }) async {
    final normalised = _normalise(data);
    final next = original.copyWith(
      date: normalised['date'] ?? original.date,
      data: normalised,
      enteredBy: _attribution(normalised, fallback: original.enteredBy),
    );
    final saved = await ref.read(entryRepositoryProvider).updateEntry(next);
    _replaceAll(
      (list) => list.map((e) => e.id == saved.id ? saved : e).toList(),
    );
    return saved;
  }

  /// Any [materials] line opens a job card and posts it to SAP once the
  /// breakdown resolves; an empty list (the default) never touches SAP.
  Future<RegisterEntry> resolveBreakdown(
    String entryId, {
    Map<String, String> data = const <String, String>{},
    List<MaterialLine> materials = const <MaterialLine>[],
  }) async {
    final saved = await ref
        .read(entryRepositoryProvider)
        .resolveBreakdown(entryId, data: data, materials: materials);
    _replaceAll(
      (list) => list.map((e) => e.id == saved.id ? saved : e).toList(),
    );
    return saved;
  }

  void _replaceAll(
    List<RegisterEntry> Function(List<RegisterEntry>) transform,
  ) {
    final current = state.valueOrNull ?? const <RegisterEntry>[];
    state = AsyncData<List<RegisterEntry>>(transform(current));
  }

  /// Bus numbers are stored uppercase with no whitespace (MH40LY1894).
  Map<String, String> _normalise(Map<String, String> data) {
    final out = Map<String, String>.of(data);
    final bus = out['bus'];
    if (bus != null) {
      out['bus'] = bus.toUpperCase().replaceAll(RegExp(r'\s+'), '');
    }
    return out;
  }

  /// Registers name their operator differently — `employee` on work/coolant/PM,
  /// `mechanic` on driver complaints. Whichever is filled attributes the entry.
  String _attribution(Map<String, String> data, {required String fallback}) {
    final employee = data['employee']?.trim();
    if (employee != null && employee.isNotEmpty) return employee;
    final mechanic = data['mechanic']?.trim();
    if (mechanic != null && mechanic.isNotEmpty) return mechanic;
    return fallback;
  }
}

final entriesProvider =
    AsyncNotifierProvider<EntriesController, List<RegisterEntry>>(
  EntriesController.new,
);

// ─── Derived views ────────────────────────────────────────────────────────

/// Entries captured today, for the Home feed.
final todayEntriesProvider = Provider<List<RegisterEntry>>((ref) {
  final all = ref.watch(entriesProvider).valueOrNull ?? const <RegisterEntry>[];
  final today = Dates.today();
  return all.where((e) => e.date == today).toList();
});

/// Every breakdown at the active site, newest first.
final breakdownsProvider = Provider<List<RegisterEntry>>((ref) {
  final all = ref.watch(entriesProvider).valueOrNull ?? const <RegisterEntry>[];
  return all.where((e) => e.registerId == kBreakdownRegisterId).toList();
});

/// Unresolved breakdowns — drives the Home banner and the tab badge.
final openBreakdownsProvider = Provider<List<RegisterEntry>>((ref) {
  return ref.watch(breakdownsProvider).where((e) => e.isOpen).toList();
});

/// The Registers view's result set: site-scoped, then register, period and
/// free-text filtered, sorted newest first.
final filteredEntriesProvider = Provider<List<RegisterEntry>>((ref) {
  final all = ref.watch(entriesProvider).valueOrNull ?? const <RegisterEntry>[];
  final f = ref.watch(entryFiltersProvider);
  final needle = f.query.trim().toLowerCase();

  bool inPeriod(RegisterEntry e) {
    switch (f.dateMode) {
      case DateMode.all:
        return true;
      case DateMode.today:
        return e.date == Dates.today();
      case DateMode.week:
        return e.date.compareTo(Dates.today(-6)) >= 0 &&
            e.date.compareTo(Dates.today()) <= 0;
      case DateMode.month:
        return e.date.startsWith(Dates.currentMonthPrefix());
      case DateMode.custom:
        final afterFrom = f.from.isEmpty || e.date.compareTo(f.from) >= 0;
        final beforeTo = f.to.isEmpty || e.date.compareTo(f.to) <= 0;
        return afterFrom && beforeTo;
    }
  }

  bool matchesQuery(RegisterEntry e) {
    if (needle.isEmpty) return true;
    if (e.enteredBy.toLowerCase().contains(needle)) return true;
    // Search across every captured column, matching the prototype's behaviour.
    return jsonEncode(e.data).toLowerCase().contains(needle);
  }

  final out = all
      .where((e) => f.registerId == 'all' || e.registerId == f.registerId)
      .where(inPeriod)
      .where(matchesQuery)
      .toList()
    ..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.time.compareTo(a.time);
    });
  return out;
});

/// One-line summary shown on entry rows and in the CSV export.
String entrySummary(RegisterEntry e) {
  final d = e.data;
  String at(String k) => (d[k] ?? '').trim();

  if (e.registerId == 'coolant') {
    final bcs = at('bcs').isEmpty ? '0' : at('bcs');
    final tcs = at('tcs').isEmpty ? '0' : at('tcs');
    return 'BCS $bcs L · TCS $tcs L';
  }

  if (e.registerId == kBreakdownRegisterId) {
    final parts = <String>[
      if (at('loc').isNotEmpty) at('loc'),
      if (at('complaint').isNotEmpty) at('complaint'),
    ];
    final head = parts.join(' — ');
    final attended = at('attended');
    return attended.isEmpty ? head : '$head · $attended';
  }

  final reported = at('defects').isNotEmpty ? at('defects') : at('complaint');
  final action = at('attended').isNotEmpty ? at('attended') : at('action');
  if (action.isEmpty) return reported;
  return reported.isEmpty ? action : '$reported · $action';
}
