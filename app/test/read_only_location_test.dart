import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/widgets/location_map.dart';

void main() {
  testWidgets('renders the map preview and coordinates when a location is captured',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReadOnlyLocation(
            latitude: 19.1197,
            longitude: 72.8468,
            source: 'gps',
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.textContaining('19.1197', findRichText: true), findsWidgets);
    expect(find.textContaining('GPS', findRichText: true), findsWidgets);
  });

  testWidgets('renders nothing (SizedBox.shrink) when no location was captured',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ReadOnlyLocation(latitude: null, longitude: null, source: null),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FlutterMap), findsNothing);
  });
}
