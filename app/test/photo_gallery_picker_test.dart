import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry_photo.dart';
import 'package:transvolt_em/widgets/dashed.dart';

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

  setUp(() => FilePicker.platform = fake = _FakeFilePicker());

  testWidgets('shows a thumbnail per existing photo plus an add tile',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoGalleryPicker(
          existingPhotos: const <EntryPhoto>[
            EntryPhoto(id: 'p1', url: 'http://x/a.jpg'),
            EntryPhoto(id: 'p2', url: 'http://x/b.jpg'),
          ],
          pendingCount: 0,
          onAdd: (_, __) {},
          onRemoveExisting: (_) {},
          onRemoveNew: (_) {},
        ),
      ),
    );

    expect(find.textContaining('a.jpg'), findsOneWidget);
    expect(find.textContaining('b.jpg'), findsOneWidget);
    expect(find.textContaining('Add photo'), findsOneWidget);
  });

  testWidgets('picking a photo calls onAdd with its name and bytes',
      (tester) async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    fake.next = FilePickerResult(<PlatformFile>[
      PlatformFile(name: 'new.jpg', size: bytes.length, bytes: bytes),
    ]);
    String? gotName;
    List<int>? gotBytes;

    await tester.pumpWidget(
      MaterialApp(
        home: PhotoGalleryPicker(
          existingPhotos: const <EntryPhoto>[],
          pendingCount: 0,
          onAdd: (name, b) {
            gotName = name;
            gotBytes = b;
          },
          onRemoveExisting: (_) {},
          onRemoveNew: (_) {},
        ),
      ),
    );

    await tester.tap(find.textContaining('Add photo'));
    await tester.pumpAndSettle();

    expect(gotName, 'new.jpg');
    expect(gotBytes, <int>[1, 2, 3]);
  });

  testWidgets('removing an existing photo calls onRemoveExisting with its id',
      (tester) async {
    String? removedId;

    await tester.pumpWidget(
      MaterialApp(
        home: PhotoGalleryPicker(
          existingPhotos: const <EntryPhoto>[
            EntryPhoto(id: 'p1', url: 'http://x/a.jpg'),
          ],
          pendingCount: 0,
          onAdd: (_, __) {},
          onRemoveExisting: (id) => removedId = id,
          onRemoveNew: (_) {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(removedId, 'p1');
  });
}
