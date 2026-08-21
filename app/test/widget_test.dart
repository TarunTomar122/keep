import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

    final addButton = find.byType(FloatingActionButton);
    await tester.ensureVisible(addButton);
    tester.widget<FloatingActionButton>(addButton).onPressed!.call();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    expect(pickerCalls, 1);
    expect(find.bySemanticsLabel('Photo'), findsNWidgets(4));
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

  testWidgets('gallery opens a local moment detail view', (tester) async {
    await tester.pumpWidget(const ClippyCompanionApp(probeDevice: false));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Photo').first);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
    expect(find.text('Treated'), findsOneWidget);
    expect(find.text('Treated image'), findsOneWidget);
  });
}
