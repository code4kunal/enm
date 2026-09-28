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
  testWidgets('a successful GPS fix reports captured and calls onCaptured with gps',
      (tester) async {
    double? gotLat;
    double? gotLng;
    String? gotSource;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocationCaptureField(
            service: _FakeLocationService((latitude: 19.1197, longitude: 72.8468)),
            onCaptured: (lat, lng, source) {
              gotLat = lat;
              gotLng = lng;
              gotSource = source;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(gotLat, 19.1197);
    expect(gotLng, 72.8468);
    expect(gotSource, 'gps');
    expect(find.textContaining('captured'), findsOneWidget);
  });

  testWidgets('a denied/unavailable GPS fix falls back to manual entry, not a crash',
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

    expect(find.text('Latitude'), findsOneWidget);
    expect(find.text('Longitude'), findsOneWidget);
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
  });
}
