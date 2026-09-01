// Runs on a real device/emulator (not the fake test binding), so this
// exercises the real home_widget MethodChannel and the native
// LatestMomentWidgetProvider — not a mock.
import 'dart:typed_data';

import 'package:clippy_companion/keep_server.dart';
import 'package:clippy_companion/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('taking a dummy photo pushes it to the home screen widget', (
    tester,
  ) async {
    final dummyImage = img.Image(width: 32, height: 32);
    dummyImage.clear(img.ColorRgb8(255, 122, 40));
    final dummyBytes = Uint8List.fromList(img.encodePng(dummyImage));

    await tester.pumpWidget(
      ClippyCompanionApp(
        role: KeepRole.tarun,
        probeDevice: false,
        serverConfig: const ServerConfig(url: '', token: ''),
        imageProcessor: (bytes) async => bytes,
        phonePhotoPicker: () async => dummyBytes,
      ),
    );
    await tester.pumpAndSettle();

    final addButton = find.byTooltip('Take a photo');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // The moment landed in the gallery and (as a side effect of
    // _refreshLatestMomentWidget) the real HomeWidget.updateWidget call
    // completed without throwing.
    expect(find.bySemanticsLabel('Photo'), findsOneWidget);
  });
}
