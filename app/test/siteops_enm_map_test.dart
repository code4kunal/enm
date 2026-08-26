import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/utils/siteops_enm_map.dart';

void main() {
  const mbmt = Site(
    code: 'MBMT',
    name: 'Mira Bhayandar',
    isActive: true,
  );
  const umt = Site(
    code: 'UMT',
    name: 'Ulhasnagar Municipal Transport',
    isActive: true,
  );

  group('enmCodeForSiteOpsRow', () {
    test('maps by explicit non-UUID code when it matches an E&M site', () {
      expect(
        enmCodeForSiteOpsRow(
          <String, dynamic>{'id': 'uuid-1', 'name': 'Other', 'code': 'MBMT'},
          <Site>[mbmt, umt],
        ),
        'MBMT',
      );
    });

    test('maps by exact name', () {
      expect(
        enmCodeForSiteOpsRow(
          <String, dynamic>{
            'id': 'uuid-2',
            'name': 'Ulhasnagar Municipal Transport',
          },
          <Site>[mbmt, umt],
        ),
        'UMT',
      );
    });

    test('maps known SiteOps aliases without collapsing unknowns', () {
      expect(
        enmCodeForSiteOpsRow(
          <String, dynamic>{'id': 'uuid-3', 'name': 'Ghodbandar Depot'},
          <Site>[mbmt],
        ),
        'MBMT',
      );
      expect(
        enmCodeForSiteOpsRow(
          <String, dynamic>{'id': 'uuid-4', 'name': 'Some Other Depot'},
          <Site>[mbmt],
        ),
        isEmpty,
      );
    });

    test('rejects UUID-shaped code fields', () {
      expect(
        enmCodeForSiteOpsRow(
          <String, dynamic>{
            'id': 'a',
            'name': 'Mystery',
            'code': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
          },
          <Site>[mbmt, umt],
        ),
        isEmpty,
      );
    });
  });
}
