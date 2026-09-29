import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/services/location_service.dart';
import 'package:transvolt_em/widgets/location_capture.dart';

class _FakeLocationService implements LocationService {
  _FakeLocationService(this.fix);
  final ({double latitude, double longitude})? fix;

  @override
  Future<({double latitude, double longitude})?> currentPosition() async => fix;
}

void main() {
  testWidgets('never captures automatically -- manual entry shows on first build, GPS is not called',
      (tester) async {
    var gpsCalled = false;
    final service = _FakeLocationService((latitude: 19.1197, longitude: 72.8468));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: service,
            onCaptured: (_, __, ___) => gpsCalled = true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Latitude'), findsOneWidget);
    expect(find.text('Longitude'), findsOneWidget);
    expect(gpsCalled, isFalse);
  });

  testWidgets('offers explicit "Use my location" and "Pick on map" actions',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: _FakeLocationService(null),
            onCaptured: (_, __, ___) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(OutlinedButton, 'Use my location'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Pick on map'), findsOneWidget);
  });

  testWidgets('saving a manual entry calls onCaptured with source manual',
      (tester) async {
    double? gotLat;
    String? gotSource;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: _FakeLocationService(null),
            onCaptured: (lat, lng, source) {
              gotLat = lat;
              gotSource = source;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '19.03');
    await tester.enterText(find.byType(TextField).last, '73.0297');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(gotLat, 19.03);
    expect(gotSource, 'manual');
    expect(find.textContaining('captured'), findsOneWidget);
  });

  testWidgets('tapping "Use my location" calls onCaptured with source gps only on that tap',
      (tester) async {
    double? gotLat;
    String? gotSource;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: _FakeLocationService((latitude: 19.1197, longitude: 72.8468)),
            onCaptured: (lat, lng, source) {
              gotLat = lat;
              gotSource = source;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(gotSource, isNull);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Use my location'));
    await tester.pump();

    expect(gotLat, 19.1197);
    expect(gotSource, 'gps');
  });

  testWidgets('tapping "Pick on map" shows the map instead of a crash',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: _FakeLocationService(null),
            onCaptured: (_, __, ___) {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Pick on map'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Back to manual entry'), findsOneWidget);
  });

  testWidgets('editing an already-captured entry pre-fills the manual fields',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: _FakeLocationService(null),
            onCaptured: (_, __, ___) {},
            initialLatitude: 19.03,
            initialLongitude: 73.0297,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('19.03'), findsWidgets);
  });
}
