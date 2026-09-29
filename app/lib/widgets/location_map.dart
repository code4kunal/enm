import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/tokens.dart';

/// A small OpenStreetMap view centered on [center] with one marker there.
///
/// Read-only (a Ticket Detail preview) when [onTap] is null. Interactive
/// (a form's "pick on map" picker) when [onTap] is given -- the caller owns
/// the picked point as state and passes the updated [center] back in, so
/// this widget stays stateless.
class LocationMapView extends StatelessWidget {
  const LocationMapView({
    super.key,
    required this.center,
    this.onTap,
    this.height = 220,
  });

  final LatLng center;
  final void Function(double latitude, double longitude)? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: height,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15,
            onTap: onTap == null
                ? null
                : (_, point) => onTap!(point.latitude, point.longitude),
          ),
          children: <Widget>[
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'in.transvolt.em',
            ),
            MarkerLayer(
              markers: <Marker>[
                Marker(
                  point: center,
                  width: 32,
                  height: 32,
                  child: const Icon(Icons.location_on, color: T.red, size: 32),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
