import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/registers.dart';
import '../models/entry.dart';
import '../utils/dates.dart';
import 'providers.dart';
import 'reports.dart';
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
  EntryFilters({
    this.query = '',
    this.registerId = 'all',
    this.dateMode = DateMode.month,
    this.from = '',
    this.to = '',
    String? month,
    this.hasOpenTicket,
  }) : month = month ?? Dates.currentMonthPrefix();

  final String query;

  /// Register id, or `all`.
  final String registerId;
  final DateMode dateMode;

  /// `yyyy-MM-dd` bounds, only meaningful when [dateMode] is
  /// [DateMode.custom]. Empty means unbounded on that side.
  final String from;
  final String to;

  /// `yyyy-MM`, only meaningful when [dateMode] is [DateMode.month] — which
  /// month, not just "the current one". Defaults to the current month so a
  /// fresh session shows what "This month" already implies.
  final String month;

  /// Complete/Pending chips: `null` means unfiltered, `true` is "Pending"
  /// (an open ticket), `false` is "Complete". Ticket status isn't on the
  /// cached [RegisterEntry] page, so a non-null value always asks the
  /// server directly — see [pendingFilterEntriesProvider].
  ///
  /// "Complete" deliberately means "not pending" (never raised a ticket, or
  /// its ticket is resolved), not "was once open and got resolved" — most
  /// entries (a routine coolant topping, a Work Done session with nothing
  /// to follow up) never raise a ticket at all, and there is nothing for a
  /// depot user to have "completed" about them; grouping them under
  /// Complete rather than adding a third "never applicable" state matches
  /// how the physical register's own Complete/Pending column works.
  final bool? hasOpenTicket;

  EntryFilters copyWith({
    String? query,
    String? registerId,
    DateMode? dateMode,
    String? from,
    String? to,
    String? month,
  }) {
    return EntryFilters(
      query: query ?? this.query,
      registerId: registerId ?? this.registerId,
      dateMode: dateMode ?? this.dateMode,
      from: from ?? this.from,
      to: to ?? this.to,
      month: month ?? this.month,
      hasOpenTicket: hasOpenTicket,
    );
  }

  /// Separate from [copyWith] since that method's `??` fallback can never
  /// set a field back to `null` — needed here to clear the filter.
  EntryFilters withHasOpenTicket(bool? value) => EntryFilters(
        query: query,
        registerId: registerId,
        dateMode: dateMode,
        from: from,
        to: to,
        month: month,
        hasOpenTicket: value,
      );

  /// `dateMode` as a `(dateFrom, dateTo)` pair the server understands --
  /// same bounds [filteredEntriesProvider]'s `inPeriod` checks client-side,
  /// for callers (like [pendingFilterEntriesProvider]) that ask the server
  /// directly instead of filtering the cached page. Either side is `null`
  /// for "unbounded".
  (String?, String?) get serverDateBounds {
    switch (dateMode) {
      case DateMode.all:
        return (null, null);
      case DateMode.today:
        return (Dates.today(), Dates.today());
      case DateMode.week:
        return (Dates.today(-6), Dates.today());
      case DateMode.month:
        return ('$month-01', Dates.lastOfMonth(month));
      case DateMode.custom:
        return (from.isEmpty ? null : from, to.isEmpty ? null : to);
    }
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

  void setMonth(String m) => state = state.copyWith(month: m);

  void setHasOpenTicket(bool? value) => state = state.withHasOpenTicket(value);
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
  Future<RegisterEntry> create({
    required String registerId,
    required Map<String, String> data,
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

    final created = await ref.read(entryRepositoryProvider).createEntry(draft);
    _replaceAll((list) => <RegisterEntry>[created, ...list]);

    // A Work Done session that completes a ticket resolves whatever raised
    // it (a breakdown, most visibly) as a side effect on the server -- but
    // the response above is this new session, not that other entry. Without
    // re-fetching it, the cached list here (and anything reading it, like
    // the Breakdowns screen's open-count) would keep showing it as open
    // until the next full reload.
    if (normalised['completesTicket'] == 'true') {
      final ticketId = normalised['ticketId'];
      if (ticketId != null && ticketId.isNotEmpty) {
        final resolved = await ref.read(entryRepositoryProvider).fetchEntry(ticketId);
        _replaceAll(
          (list) => list.map((e) => e.id == resolved.id ? resolved : e).toList(),
        );
      }
    }

    // DMR / charts / investigations read these registers.
    ref.invalidate(dmrDayProvider);
    ref.invalidate(dmrMonthProvider);
    ref.invalidate(controlChartProvider);
    ref.invalidate(investigationsProvider);
    ref.invalidate(pendingFilterEntriesProvider);
    return created;
  }

  /// Coolant Topping's day-based entry: one date, one submitting supervisor,
  /// every bus in one request.
  Future<List<RegisterEntry>> createCoolantDay({
    required String entryDate,
    String? supervisor,
    required List<Map<String, dynamic>> rows,
  }) async {
    final session = ref.read(sessionProvider);
    final created = await ref.read(entryRepositoryProvider).createCoolantDay(
          site: session.site,
          entryDate: entryDate,
          supervisor: supervisor,
          rows: rows,
        );
    _replaceAll((list) => <RegisterEntry>[...created, ...list]);
    ref.invalidate(dmrDayProvider);
    ref.invalidate(dmrMonthProvider);
    ref.invalidate(controlChartProvider);
    ref.invalidate(investigationsProvider);
    ref.invalidate(pendingFilterEntriesProvider);
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
    ref.invalidate(dmrDayProvider);
    ref.invalidate(dmrMonthProvider);
    ref.invalidate(controlChartProvider);
    ref.invalidate(investigationsProvider);
    ref.invalidate(pendingFilterEntriesProvider);
    return saved;
  }

  Future<void> raiseTicket(String entryId) async {
    final saved = await ref.read(ticketRepositoryProvider).raiseTicket(entryId);
    _replaceAll((list) => list.map((e) => e.id == saved.id ? saved : e).toList());
    ref.invalidate(pendingFilterEntriesProvider);
  }

  Future<String> attachPhoto({
    required String entryId,
    required String filename,
    required List<int> bytes,
  }) async {
    final url = await ref
        .read(entryRepositoryProvider)
        .attachPhoto(entryId, filename: filename, bytes: bytes);
    _replaceAll(
      (list) => list
          .map((e) => e.id == entryId ? e.withPhotoUrl(url) : e)
          .toList(),
    );
    return url;
  }

  Future<void> removePhoto(String entryId) async {
    await ref.read(entryRepositoryProvider).removePhoto(entryId);
    _replaceAll(
      (list) => list
          .map((e) => e.id == entryId ? e.withPhotoUrl(null) : e)
          .toList(),
    );
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

/// One entry with its full detail — [RegisterEntry.linkedSessions] included,
/// which the bulk [entriesProvider] fetch never carries (the server only
/// computes it on the single-entry response). Used by the Breakdowns screen,
/// whose cards are few enough that one fetch per card is proportionate.
final entryDetailProvider =
    FutureProvider.family<RegisterEntry, String>((ref, entryId) {
  return ref.watch(entryRepositoryProvider).fetchEntry(entryId);
});

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
        return e.date.startsWith(f.month);
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

/// Key for [registerMonthEntriesProvider]: which site, which register
/// (`all` included), which `yyyy-MM`.
typedef MonthEntriesKey = ({String site, String registerId, String month});

/// One month's entries for the Registers view, fetched directly rather than
/// filtered from [entriesProvider]'s capped cache.
///
/// [filteredEntriesProvider] answers "this month" by filtering a page of the
/// site's newest ~200 entries — fine for the current month on a quiet site,
/// wrong the moment a picked month is older than that page, where it would
/// come back empty instead of just old. Query filtering still happens after,
/// same as the cached path, so a month's search results stay correct too.
final registerMonthEntriesProvider =
    FutureProvider.family<List<RegisterEntry>, MonthEntriesKey>((
  ref,
  key,
) async {
  if (key.site.isEmpty) return const <RegisterEntry>[];
  final entries = await ref.watch(entryRepositoryProvider).fetchEntries(
        site: key.site,
        registerId: key.registerId == 'all' ? null : key.registerId,
        dateFrom: '${key.month}-01',
        dateTo: Dates.lastOfMonth(key.month),
      );
  final needle = ref.watch(
    entryFiltersProvider.select((f) => f.query.trim().toLowerCase()),
  );
  return entries.where((e) => _matchesQuery(e, needle)).toList()
    ..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.time.compareTo(a.time);
    });
});

/// Key for [pendingFilterEntriesProvider]: which site, which register
/// (`all` included), Complete (`false`) or Pending (`true`).
typedef PendingFilterKey = ({
  String site,
  String registerId,
  bool hasOpenTicket,
  String? dateFrom,
  String? dateTo,
});

/// Entries matching a Complete/Pending chip, fetched directly from the
/// server — ticket status isn't part of the cached [entriesProvider] page,
/// so it can never be answered by filtering that cache client-side the way
/// register/date/query are. Same reasoning as [registerMonthEntriesProvider].
final pendingFilterEntriesProvider =
    FutureProvider.family<List<RegisterEntry>, PendingFilterKey>((
  ref,
  key,
) async {
  if (key.site.isEmpty) return const <RegisterEntry>[];
  final entries = await ref.watch(entryRepositoryProvider).fetchEntries(
        site: key.site,
        registerId: key.registerId == 'all' ? null : key.registerId,
        hasOpenTicket: key.hasOpenTicket,
        dateFrom: key.dateFrom,
        dateTo: key.dateTo,
      );
  final needle = ref.watch(
    entryFiltersProvider.select((f) => f.query.trim().toLowerCase()),
  );
  return entries.where((e) => _matchesQuery(e, needle)).toList()
    ..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.time.compareTo(a.time);
    });
});

bool _matchesQuery(RegisterEntry e, String needle) {
  if (needle.isEmpty) return true;
  if (e.enteredBy.toLowerCase().contains(needle)) return true;
  return jsonEncode(e.data).toLowerCase().contains(needle);
}

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
