import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/ticket.dart';
import 'package:transvolt_em/models/ticket_detail.dart';
import 'package:transvolt_em/screens/register_form_screen.dart';
import 'package:transvolt_em/state/entries.dart';
import 'package:transvolt_em/state/providers.dart';
import 'package:transvolt_em/state/session.dart';

import 'support/fake_store.dart';
import 'support/harness.dart';
import 'support/seed.dart';

/// Serves a fixed picker result set — the ticket search is a network call and
/// the only external this screen has; everything else (entries, master data,
/// fleet, staff) runs on the shared fake store, unmocked.
class _StubTicketRepository implements TicketRepository {
  _StubTicketRepository(this.results);

  final List<TicketSearchResult> results;
  final List<({String site, String? register, String? q, String status})> calls =
      <({String site, String? register, String? q, String status})>[];

  @override
  Future<List<TicketSearchResult>> search({
    required String site,
    String? register,
    String? q,
    String status = 'open',
  }) async {
    calls.add((site: site, register: register, q: q, status: status));
    return results;
  }

  @override
  Future<RegisterEntry> raiseTicket(String entryId) =>
      throw UnimplementedError();

  @override
  Future<TicketDetail> get(String ticketId) => throw UnimplementedError();
}

/// An open breakdown ticket, exactly as `/tickets/search` describes it.
TicketSearchResult _breakdownTicket() => const TicketSearchResult(
      ticketId: 'tkt-bd-1',
      displayId: 'BD-2026-000002',
      title: 'Ticket BD-2026-000002',
      entryDate: '2026-09-29',
      status: 'open',
      sourceKind: 'breakdown',
      busNo: 'MH40LY1721',
      driverName: 'Test Driver',
      route: '7',
      defectText: 'Brake pressure low, vehicle stopped for technical attention',
      defectType: 'Brakes & air system',
    );

/// The same shape, sourced from a Driver Complaint — ticket_context() already
/// fills these uniformly, so one auto-fill path has to serve both.
TicketSearchResult _complaintTicket() => const TicketSearchResult(
      ticketId: 'tkt-dc-1',
      displayId: 'DC-2026-000004',
      title: 'Ticket DC-2026-000004',
      entryDate: '2026-09-29',
      status: 'open',
      sourceKind: 'driver_complaint',
      busNo: 'MH40LY1650',
      driverName: 'Test Driver',
      defectText: 'AC not cooling on the rear half',
      defectType: 'AC & HVAC',
    );

class _Harness {
  _Harness(this.store, this.container, this.tickets);

  final FakeStore store;
  final ProviderContainer container;
  final _StubTicketRepository tickets;

  /// The most recently created entry — what the form actually submitted.
  RegisterEntry get lastCreated => store.entries.first;
}

Future<_Harness> _signedIn(
  WidgetTester tester,
  List<TicketSearchResult> results,
) async {
  final store = FakeStore();
  final tickets = _StubTicketRepository(results);
  final container = ProviderContainer(
    overrides: <Override>[
      ...fakeOverrides(store),
      ticketRepositoryProvider.overrideWithValue(tickets),
    ],
  );
  addTearDown(container.dispose);

  // The fakes answer on a real 220ms delay, and the widget-test clock does
  // not advance before the first pump — sign in on the real clock.
  await tester.runAsync(() async {
    await container
        .read(sessionProvider.notifier)
        .signInWithCredentials('TV4021', kSeedPassword);
    container.read(sessionProvider.notifier).enterApp();
    await container.read(entriesProvider.future);
  });

  return _Harness(store, container, tickets);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpForm(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RegisterFormScreen(registerId: 'work', onClose: () {}),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  // With runtime fetching disabled (see setUpAll), resolving this form's
  // bold-weight text throws an "asset not found" fallback exception --
  // drain it here so it doesn't fail the test. No-op once already drained
  // for an earlier pumpForm in the same test.
  tester.takeException();
}

/// A form control currently holding [text] — an [AppTextField]'s or an
/// [AppSelect]'s own editable, not the read-only linked-ticket echo block
/// (which renders as RichText and would happily pass a text search while the
/// form fields behind it stayed empty).
Finder _fieldHolding(String text) => find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text == text,
      description: 'form field holding "$text"',
    );

/// The ticket-link search box, distinguished from every other [TextField]
/// on this form (Attendees' own among them) by its hint text.
final Finder _ticketSearchField = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText?.startsWith('Search by title or ID') == true,
  description: 'ticket search field',
);

Future<void> _pickTicket(WidgetTester tester, TicketSearchResult ticket) async {
  // Floats as an overlay, like every other dropdown on this form -- shown
  // only while focused (an empty query otherwise matches every open ticket
  // at the site, so an unfocused field would show them all, unprompted).
  await tester.tap(_ticketSearchField);
  await _settle(tester);

  final option = find.text(ticket.title);
  expect(option, findsOneWidget, reason: 'the picker should list the ticket');
  await tester.ensureVisible(option);
  await tester.tap(option);
  await _settle(tester);
}

Future<void> _save(WidgetTester tester) async {
  final button = find.text('Save entry');
  await tester.ensureVisible(button);
  await tester.tap(button);
  // The submit path runs a real 220ms fake-repository delay
  // (test/support/fake_repositories.dart's `_latency`) -- same reason
  // `_signedIn` above escapes to the real clock for sign-in/entries-load.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await _settle(tester);
  // A successful save shows a toast that auto-dismisses via a real Timer
  // (ToastController, T.toastDuration = 2600ms). flutter_test's own
  // teardown asserts no timer is left pending when the test ends, and that
  // check runs before this test's `addTearDown(container.dispose)` -- so
  // let the timer actually fire here rather than leaving it to disposal.
  await tester.pump(const Duration(milliseconds: 2700));
}

void main() {
  // This is the first widget test file in the suite to render this form's
  // bold-weight text (`_TicketLinkSection`'s "Link to" header). Left at its
  // default, google_fonts kicks off a real, unawaited network fetch for
  // that weight, which flutter_test's mocked HttpClient always rejects --
  // and that rejection surfaces asynchronously, detached from whichever
  // test triggered it (observed landing on the *next* test, not the one
  // that built the text), so no amount of in-test draining or waiting
  // catches it reliably. Disabling runtime fetching removes the network
  // attempt entirely; `_pumpForm` below drains the synchronous "asset not
  // found" fallback exception that replaces it.
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets(
    'test_ac4_picking_a_breakdown_ticket_fills_the_work_done_fields',
    (tester) async {
      final h = await _signedIn(tester, <TicketSearchResult>[_breakdownTicket()]);
      await _pumpForm(tester, h);
      await _pickTicket(tester, _breakdownTicket());

      // The form's own controls now hold the ticket's data — not just the
      // read-only context block underneath the picker.
      expect(_fieldHolding('MH40LY1721'), findsOneWidget);
      expect(_fieldHolding('Brakes & air system'), findsOneWidget);
      expect(
        _fieldHolding(
          'Brake pressure low, vehicle stopped for technical attention',
        ),
        findsOneWidget,
      );

      // …and that is what gets submitted, without a single keystroke.
      await _save(tester);
      final saved = h.lastCreated;
      expect(saved.registerId, 'work');
      expect(saved.data['bus'], 'MH40LY1721');
      expect(saved.data['defectType'], 'Brakes & air system');
      expect(
        saved.data['defects'],
        'Brake pressure low, vehicle stopped for technical attention',
      );
      expect(saved.data['ticketId'], 'tkt-bd-1');
    },
  );

  testWidgets(
    'test_ac5_picking_a_driver_complaint_ticket_fills_the_same_fields',
    (tester) async {
      final h = await _signedIn(tester, <TicketSearchResult>[_complaintTicket()]);
      await _pumpForm(tester, h);
      await _pickTicket(tester, _complaintTicket());

      expect(_fieldHolding('MH40LY1650'), findsOneWidget);
      expect(_fieldHolding('AC & HVAC'), findsOneWidget);
      expect(_fieldHolding('AC not cooling on the rear half'), findsOneWidget);

      await _save(tester);
      final saved = h.lastCreated;
      expect(saved.data['bus'], 'MH40LY1650');
      expect(saved.data['defectType'], 'AC & HVAC');
      expect(saved.data['defects'], 'AC not cooling on the rear half');
      expect(saved.data['ticketId'], 'tkt-dc-1');
    },
  );

  testWidgets(
    'test_ac6_an_auto_filled_defect_text_is_still_editable',
    (tester) async {
      final h = await _signedIn(tester, <TicketSearchResult>[_breakdownTicket()]);
      await _pumpForm(tester, h);
      await _pickTicket(tester, _breakdownTicket());

      final defects = _fieldHolding(
        'Brake pressure low, vehicle stopped for technical attention',
      );
      expect(defects, findsOneWidget);
      await tester.enterText(
        defects,
        'Brake pressure low — air dryer cartridge replaced',
      );
      await _settle(tester);

      await _save(tester);
      // Auto-fill is a starting value, not a lock.
      expect(
        h.lastCreated.data['defects'],
        'Brake pressure low — air dryer cartridge replaced',
      );
    },
  );

  testWidgets(
    'test_ac7_removing_the_ticket_keeps_the_work_already_described',
    (tester) async {
      final h = await _signedIn(tester, <TicketSearchResult>[_breakdownTicket()]);
      await _pumpForm(tester, h);
      await _pickTicket(tester, _breakdownTicket());

      final remove = find.text('Remove');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await _settle(tester);

      // The link itself is gone…
      expect(_fieldHolding('MH40LY1721'), findsOneWidget);
      await _save(tester);
      final saved = h.lastCreated;
      expect(saved.data['ticketId'], isNull);
      expect(saved.data['completesTicket'], isNull);
      // …but unlinking must not erase the job description.
      expect(saved.data['bus'], 'MH40LY1721');
      expect(saved.data['defectType'], 'Brakes & air system');
      expect(
        saved.data['defects'],
        'Brake pressure low, vehicle stopped for technical attention',
      );
    },
  );

  testWidgets(
    'test_ac4_repicking_a_different_ticket_overwrites_the_first_cleanly',
    (tester) async {
      final h = await _signedIn(
        tester,
        <TicketSearchResult>[_breakdownTicket(), _complaintTicket()],
      );
      await _pumpForm(tester, h);
      await _pickTicket(tester, _breakdownTicket());

      final remove = find.text('Remove');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await _settle(tester);

      await _pickTicket(tester, _complaintTicket());
      await _save(tester);

      final saved = h.lastCreated;
      expect(saved.data['bus'], 'MH40LY1650');
      expect(saved.data['defectType'], 'AC & HVAC');
      expect(saved.data['defects'], 'AC not cooling on the rear half');
      expect(saved.data['ticketId'], 'tkt-dc-1');
    },
  );

  testWidgets(
    'test_ac4_a_bus_that_left_the_active_fleet_still_carries_through',
    (tester) async {
      // The ticket was raised before the bus was deactivated, so its
      // registration is no longer in the Bus No dropdown's options. The
      // select renders blank (see AppSelect._selected) — it must not throw,
      // and the value must still reach the submission.
      const gone = TicketSearchResult(
        ticketId: 'tkt-bd-2',
        displayId: 'BD-2026-000009',
        title: 'Ticket BD-2026-000009',
        entryDate: '2026-09-29',
        status: 'open',
        sourceKind: 'breakdown',
        busNo: 'MH04LQ5736',
        defectText: 'HV contactor tripped, bus immobile',
        defectType: 'Brakes & air system',
      );
      final h = await _signedIn(tester, <TicketSearchResult>[gone]);
      await _pumpForm(tester, h);
      await _pickTicket(tester, gone);

      expect(tester.takeException(), isNull);
      await _save(tester);
      expect(h.lastCreated.data['bus'], 'MH04LQ5736');
      expect(
        h.lastCreated.data['defects'],
        'HV contactor tripped, bus immobile',
      );
    },
  );

  testWidgets(
    'test_ac4_a_defect_type_outside_work_dones_master_list_does_not_break_the_pick',
    (tester) async {
      // A different source register may have used a value Work Done's own
      // defect-type list doesn't carry. The other two fields still fill.
      const odd = TicketSearchResult(
        ticketId: 'tkt-bd-3',
        displayId: 'BD-2026-000010',
        title: 'Ticket BD-2026-000010',
        entryDate: '2026-09-29',
        status: 'open',
        sourceKind: 'breakdown',
        busNo: 'MH40LY1721',
        defectText: 'Brake pressure low, vehicle stopped',
        defectType: 'Brake',
      );
      final h = await _signedIn(tester, <TicketSearchResult>[odd]);
      await _pumpForm(tester, h);
      await _pickTicket(tester, odd);

      expect(tester.takeException(), isNull);
      expect(_fieldHolding('MH40LY1721'), findsOneWidget);
      expect(
        _fieldHolding('Brake pressure low, vehicle stopped'),
        findsOneWidget,
      );
    },
  );
}
