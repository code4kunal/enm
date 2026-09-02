import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/widgets/dashed.dart';

/// Hands back whatever [FilePicker.pickFiles] should return next — set it
/// per-test to simulate a cancel (`null`) or a real pick.
class _FakeFilePicker extends FilePicker {
  FilePickerResult? next;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      next;
}

void main() {
  late _FakeFilePicker fake;

  // No platform implementation is registered by default in `flutter test`
  // (there is no real OS to pick a file from), so there is nothing to save
  // and restore — each test just installs its own fake.
  setUp(() => FilePicker.platform = fake = _FakeFilePicker());

  testWidgets(
    'cancelling the picker does not attach a photo',
    (tester) async {
      fake.next = null; // the picker's own "cancelled" result
      var attachCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: PhotoAttachButton(
            attached: false,
            onAttach: (_, __) => attachCalls++,
            onRemove: () => fail('remove should not fire while unattached'),
          ),
        ),
      );

      await tester.tap(find.byType(PhotoAttachButton));
      await tester.pumpAndSettle();

      expect(attachCalls, 0);
      expect(find.textContaining('attached'), findsNothing);
    },
  );

  testWidgets(
    'picking a real file attaches it with its bytes and name',
    (tester) async {
      final bytes = Uint8List.fromList(<int>[1, 2, 3]);
      fake.next = FilePickerResult(<PlatformFile>[
        PlatformFile(name: 'leak.jpg', size: bytes.length, bytes: bytes),
      ]);
      String? gotName;
      List<int>? gotBytes;

      await tester.pumpWidget(
        MaterialApp(
          home: PhotoAttachButton(
            attached: false,
            onAttach: (name, b) {
              gotName = name;
              gotBytes = b;
            },
            onRemove: () => fail('remove should not fire while unattached'),
          ),
        ),
      );

      await tester.tap(find.byType(PhotoAttachButton));
      await tester.pumpAndSettle();

      expect(gotName, 'leak.jpg');
      expect(gotBytes, <int>[1, 2, 3]);
    },
  );

  testWidgets(
    'tapping an attached button removes rather than re-picking',
    (tester) async {
      var removeCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: PhotoAttachButton(
            attached: true,
            onAttach: (_, __) => fail('attach should not fire while attached'),
            onRemove: () => removeCalls++,
          ),
        ),
      );

      await tester.tap(find.byType(PhotoAttachButton));
      await tester.pumpAndSettle();

      expect(removeCalls, 1);
    },
  );
}
