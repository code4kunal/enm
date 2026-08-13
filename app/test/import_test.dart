import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/fake/csv_source.dart';
import 'package:transvolt_em/data/fake/seed.dart';
import 'package:transvolt_em/data/import_targets.dart';
import 'package:transvolt_em/models/site_import.dart';
import 'package:transvolt_em/state/imports.dart';
import 'package:transvolt_em/state/providers.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/state/sites.dart';

Uint8List csv(String text) => Uint8List.fromList(utf8.encode(text));

Future<ProviderContainer> signedIn([String userId = 'TV4021']) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container
      .read(sessionProvider.notifier)
      .signInWithCredentials(userId, kSeedPassword);
  container.read(sessionProvider.notifier).enterApp();
  return container;
}

void main() {
  group('CsvSource', () {
    test('reads a plain table', () {
      final t = CsvSource.table(csv('a,b\n1,2\n3,4\n'));
      expect(t.columns, <String>['a', 'b']);
      expect(t.rows, hasLength(2));
      expect(t.rows.first['a'], '1');
    });

    test('honours quoted fields containing commas', () {
      final t = CsvSource.table(csv('a,b\n"x, y",2\n'));
      expect(t.rows.first['a'], 'x, y');
    });

    test('unescapes doubled quotes', () {
      final t = CsvSource.table(csv('a\n"he said ""hi"""\n'));
      expect(t.rows.first['a'], 'he said "hi"');
    });

    test('keeps newlines inside quoted fields on one row', () {
      final t = CsvSource.table(csv('a,b\n"line1\nline2",2\n'));
      expect(t.rows, hasLength(1));
      expect(t.rows.first['a'], 'line1\nline2');
    });

    test('strips a UTF-8 BOM', () {
      final t = CsvSource.table(csv('\u{FEFF}a,b\n1,2\n'));
      expect(t.columns.first, 'a');
    });

    test('makes duplicate and blank headers addressable', () {
      final t = CsvSource.table(csv('a,a,\n1,2,3\n'));
      expect(t.columns, <String>['a', 'a (2)', 'Column 3']);
    });

    test('respects a header row further down the sheet', () {
      final t = CsvSource.table(
        csv('Site report\n\nreg,make\nMH1,EKA\n'),
        headerRow: 3,
      );
      expect(t.columns, <String>['reg', 'make']);
      expect(t.rows.first['reg'], 'MH1');
    });

    test('skips sub-header rows', () {
      final t = CsvSource.table(csv('a,b\nunits,units\n1,2\n'), skipRows: 1);
      expect(t.rows, hasLength(1));
      expect(t.rows.first['a'], '1');
    });

    test('reports the source row number so errors are findable', () {
      final t = CsvSource.table(csv('a\n1\n2\n'));
      expect(t.rows.first[r'$row'], '2');
      expect(t.rows.last[r'$row'], '3');
    });
  });

  group('target fields', () {
    test('register targets derive their columns from the register', () {
      final fields = targetFieldsFor(ImportTarget.coolant);
      final keys = fields.map((f) => f.key).toList();
      expect(keys, containsAll(<String>['date', 'bus', 'bcs', 'tcs']));
      // Historical rows carry their own author.
      expect(keys, contains('entered_by'));
    });

    test('vehicle import requires only the registration', () {
      final required = targetFieldsFor(ImportTarget.vehicles)
          .where((f) => f.required)
          .map((f) => f.key)
          .toList();
      expect(required, <String>['registration_no']);
    });
  });

  group('import flow', () {
    test('auto-maps columns whose names match, then imports', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);
      await container.read(vehiclesProvider.future);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.vehicles, 'MBMT fleet'),
      );
      await controller.attachFile(
        'fleet.csv',
        csv('Registration No,Make,Model\nMH40LY5001,EKA,E9\nMH40LY5002,EKA,E9\n'),
      );

      final session = container.read(importControllerProvider);
      expect(session.stage, ImportStage.mapping);
      // "Registration No" matched the target label without the user touching it.
      expect(
        session.profile!.mappingFor('registration_no')!.sourceColumn,
        'Registration No',
      );
      expect(session.mappingComplete, isTrue);

      await controller.runPreview();
      final preview = container.read(importControllerProvider).preview!;
      expect(preview.acceptedCount, 2);
      expect(preview.newCount, 2);
      expect(preview.hasErrors, isFalse);

      await controller.commit();
      expect(
        container.read(importControllerProvider).stage,
        ImportStage.done,
      );

      // The fleet — and therefore the entry dropdown — actually changed.
      final master = await container.read(masterDataProvider.future);
      expect(master.vehicles, containsAll(<String>['MH40LY5001', 'MH40LY5002']));
    });

    test('rejects rows missing a required value, keeping the rest', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.vehicles, 'Partial'),
      );
      await controller.attachFile(
        'fleet.csv',
        csv('Registration No,Make\nMH40LY6001,EKA\n,EKA\nMH40LY6003,EKA\n'),
      );
      await controller.runPreview();

      final preview = container.read(importControllerProvider).preview!;
      expect(preview.acceptedCount, 2);
      expect(preview.rejectedCount, 1);
      // Row 3 of the sheet, as Excel numbers it.
      expect(preview.errors.first.rowNumber, 3);
    });

    test('a register import refuses a bus that is not on the fleet', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);
      await container.read(vehiclesProvider.future);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.coolant, 'Coolant backfill'),
      );
      await controller.attachFile(
        'coolant.csv',
        csv('Date,Bus No,BCS Topping,TCS Topping\n'
            '2026-01-05,MH40LY1894,1.5,0.5\n'
            '2026-01-05,MH99XX0000,2,1\n'),
      );
      await controller.runPreview();

      final preview = container.read(importControllerProvider).preview!;
      expect(preview.acceptedCount, 1);
      expect(preview.errors.single.message, contains('not on the MBMT fleet'));
    });

    test('a bad date is reported against its row', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);
      await container.read(vehiclesProvider.future);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.coolant, 'Bad dates'),
      );
      await controller.attachFile(
        'coolant.csv',
        csv('Date,Bus No\n05/01/2026,MH40LY1894\n'),
      );
      await controller.runPreview();

      final preview = container.read(importControllerProvider).preview!;
      expect(preview.acceptedCount, 0);
      expect(preview.errors.single.message, contains('yyyy-MM-dd'));
    });

    test('re-importing the same fleet sheet updates rather than duplicates',
        () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);
      await container.read(vehiclesProvider.future);
      final before = container.read(vehiclesProvider).requireValue.length;

      const sheet = 'Registration No,Make\nMH40LY1894,EKA\n';
      for (var i = 0; i < 2; i++) {
        controller.chooseProfile(
          controller.newProfile(ImportTarget.vehicles, 'Repeat'),
        );
        await controller.attachFile('fleet.csv', csv(sheet));
        await controller.runPreview();
        await controller.commit();
      }

      container.invalidate(vehiclesProvider);
      final after = await container.read(vehiclesProvider.future);
      // MH40LY1894 is already seeded, so nothing should have been added.
      expect(after, hasLength(before));
    });

    test('a constant binding fills a column the sheet omits', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.defectTypes, 'Types'),
      );
      await controller.attachFile('types.csv', csv('Label\nGearbox\n'));

      // The sheet has no "Name" column; bind it by hand.
      controller.bind('name', 'Label');
      await controller.runPreview();

      final preview = container.read(importControllerProvider).preview!;
      expect(preview.acceptedCount, 1);
      expect(preview.rows.first['name'], 'Gearbox');

      await controller.commit();
      final master = await container.read(masterDataProvider.future);
      expect(master.defectTypes, contains('Gearbox'));
    });

    test('preview refuses to run while a required field is unmapped', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.vehicles, 'Unmapped'),
      );
      await controller.attachFile('x.csv', csv('Foo,Bar\n1,2\n'));
      await controller.runPreview();

      final session = container.read(importControllerProvider);
      expect(session.preview, isNull);
      expect(session.error, contains('Registration No'));
    });

    test('a saved profile is listed for reuse', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.vehicles, 'Monthly fleet'),
      );
      await controller.attachFile(
        'fleet.csv',
        csv('Registration No\nMH40LY8001\n'),
      );
      await controller.saveProfile();

      final profiles = await container.read(importProfilesProvider.future);
      expect(profiles.map((p) => p.name), contains('Monthly fleet'));
    });

    test('a committed service sheet lands in the site config', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.serviceSchedule, 'Service ladder'),
      );
      await controller.attachFile(
        'services.csv',
        csv('Service code,Service name,Interval (km),Interval (days)\n'
            'S9,Brake overhaul,60000,540\n'),
      );
      await controller.runPreview();
      await controller.commit();

      container.invalidate(siteConfigProvider);
      final config = await container.read(siteConfigProvider.future);
      final plan = config.planByCode('S9')!;
      expect(plan.name, 'Brake overhaul');
      expect(plan.intervalKm, 60000);
      expect(plan.intervalDays, 540);
    });

    test('an odometer sheet updates the fleet, never backwards', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);
      final before = await container.read(vehiclesProvider.future);
      final target = before.firstWhere((v) => v.registrationNo == 'MH40LY1650');

      controller.chooseProfile(
        controller.newProfile(ImportTarget.odometers, 'Monthly odometers'),
      );
      await controller.attachFile(
        'odo.csv',
        csv('Registration No,Odometer\n'
            'MH40LY1650,${target.odometerKm + 900}\n'
            'MH40LY1721,1\n'),
      );
      await controller.runPreview();
      await controller.commit();

      container.invalidate(vehiclesProvider);
      final after = await container.read(vehiclesProvider.future);
      expect(
        after.firstWhere((v) => v.registrationNo == 'MH40LY1650').odometerKm,
        target.odometerKm + 900,
      );
      // A lower reading is a stale sheet, not a correction.
      expect(
        after.firstWhere((v) => v.registrationNo == 'MH40LY1721').odometerKm,
        greaterThan(1),
      );
    });

    test('the offline demo rejects xlsx with a clear message', () async {
      final container = await signedIn();
      final controller = container.read(importControllerProvider.notifier);

      controller.chooseProfile(
        controller.newProfile(ImportTarget.vehicles, 'Excel'),
      );
      await controller.attachFile('fleet.xlsx', csv('anything'));

      expect(
        container.read(importControllerProvider).error,
        contains('.csv only'),
      );
    });
  });

  group('ImportProfile', () {
    test('reports which required fields are still unbound', () {
      const profile = ImportProfile(
        id: 'p',
        siteCode: 'MBMT',
        name: 'x',
        target: ImportTarget.vehicles,
      );
      final fields = targetFieldsFor(ImportTarget.vehicles);
      expect(profile.missingRequired(fields).single.key, 'registration_no');
      expect(profile.isComplete(fields), isFalse);

      final bound = profile.withMapping(
        const ColumnMapping(targetKey: 'registration_no', sourceColumn: 'Reg'),
      );
      expect(bound.isComplete(fields), isTrue);
    });

    test('a constant counts as bound', () {
      const mapping = ColumnMapping(
        targetKey: 'is_active',
        sourceColumn: '',
        constantValue: 'yes',
      );
      expect(mapping.isBound, isTrue);
      expect(mapping.isConstant, isTrue);
    });

    test('rebinding replaces rather than duplicates', () {
      const profile = ImportProfile(
        id: 'p',
        siteCode: 'MBMT',
        name: 'x',
        target: ImportTarget.vehicles,
      );
      final once = profile.withMapping(
        const ColumnMapping(targetKey: 'make', sourceColumn: 'A'),
      );
      final twice = once.withMapping(
        const ColumnMapping(targetKey: 'make', sourceColumn: 'B'),
      );
      expect(twice.mappings.where((m) => m.targetKey == 'make'), hasLength(1));
      expect(twice.mappingFor('make')!.sourceColumn, 'B');
    });
  });
}
