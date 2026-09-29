import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:transvolt_em/widgets/location_map.dart';

void main() {
  testWidgets('read-only (no onTap) renders without throwing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LocationMapView(center: LatLng(19.1197, 72.8468)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets(
    'an interactive map wires its onTap through to MapOptions.onTap, converting LatLng to lat/lng',
    (tester) async {
      // flutter_map's own tap-recognition pipeline (fling/double-tap-zoom
      // gesture arena) is third-party internals, not something this test
      // should drive via a simulated tap -- it verifies the wiring this
      // widget owns: that a real point tapped on the map reaches the
      // caller's callback as (latitude, longitude).
      double? gotLat;
      double? gotLng;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationMapView(
              center: const LatLng(19.1197, 72.8468),
              onTap: (lat, lng) {
                gotLat = lat;
                gotLng = lng;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), const LatLng(19.03, 73.0297));

      expect(gotLat, 19.03);
      expect(gotLng, 73.0297);
    },
  );

  testWidgets('a read-only map has no onTap wired at all', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LocationMapView(center: LatLng(19.1197, 72.8468)),
        ),
      ),
    );
    await tester.pump();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.options.onTap, isNull);
  });
}
