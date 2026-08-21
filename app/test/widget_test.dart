import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:clippy_companion/design/oa.dart';
import 'package:clippy_companion/main.dart';

void main() {
  testWidgets('home add button adds a phone photo to the gallery', (
    tester,
  ) async {
    var pickerCalls = 0;
    await tester.pumpWidget(
      ClippyCompanionApp(
        probeDevice: false,
        imageProcessor: (bytes) async => bytes,
        phonePhotoPicker: () async {
          pickerCalls++;
          final image = img.Image(width: 4, height: 4);
          image.clear(img.ColorRgb8(120, 140, 150));
          return Uint8List.fromList(img.encodePng(image));
        },
      ),
    );

    final addButton = find.byTooltip('Take a photo');
    await tester.ensureVisible(addButton);
    tester
        .widget<OaButton>(
          find.ancestor(
            of: addButton,
            matching: find.byType(OaButton),
          ).first,
        )
        .onPressed!
        .call();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(pickerCalls, 1);
    expect(find.bySemanticsLabel('Photo'), findsNWidgets(1));
    expect(find.byTooltip('Search'), findsNothing);
    expect(find.byTooltip('Saved'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
  });

  testWidgets('settings shows device and setup controls', (tester) async {
    await tester.pumpWidget(const ClippyCompanionApp(probeDevice: false));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Board battery'), findsOneWidget);
    expect(find.text('Board Wi-Fi', skipOffstage: false), findsOneWidget);
    expect(find.text('Server URL', skipOffstage: false), findsOneWidget);
    expect(find.text('Live capture mode', skipOffstage: false), findsOneWidget);
    expect(find.byTooltip('Back to Home'), findsOneWidget);
  });

  testWidgets('gallery opens a moment detail view after capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      ClippyCompanionApp(
        probeDevice: false,
        imageProcessor: (bytes) async => bytes,
        phonePhotoPicker: () async =>
            Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3))),
      ),
    );

    final addButton = find.byTooltip('Take a photo');
    tester
        .widget<OaButton>(
          find.ancestor(
            of: addButton,
            matching: find.byType(OaButton),
          ).first,
        )
        .onPressed!
        .call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.bySemanticsLabel('Photo').first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Treated'), findsOneWidget);
    expect(find.text('Treated image'), findsOneWidget);
  });

  testWidgets('captured photo shows server-processed result', (tester) async {
    final processed = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    var submissions = 0;
    await tester.pumpWidget(
      ClippyCompanionApp(
        probeDevice: false,
        imageProcessor: (bytes) async => bytes,
        phonePhotoPicker: () async =>
            Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3))),
        photoSubmitter: (bytes) async {
          submissions++;
          return ProcessedPhoto(bytes: processed, remoteId: 'srv-1');
        },
      ),
    );

    final addButton = find.byTooltip('Take a photo');
    tester
        .widget<OaButton>(
          find.ancestor(
            of: addButton,
            matching: find.byType(OaButton),
          ).first,
        )
        .onPressed!
        .call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(submissions, 1);
    expect(find.bySemanticsLabel('Photo'), findsNWidgets(1));

    await tester.tap(find.bySemanticsLabel('Photo').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Processed on server'), findsOneWidget);
    expect(find.textContaining('srv-1'), findsOneWidget);
  });
}
