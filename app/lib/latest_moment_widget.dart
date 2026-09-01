import 'dart:io';
import 'dart:typed_data';

import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';

/// Keeps the "latest moment" home-screen widget in sync. Matches the
/// Android `LatestMomentWidgetProvider` class name; see
/// android/app/src/main/kotlin/.../LatestMomentWidgetProvider.kt.
const _kWidgetProviderName = 'LatestMomentWidgetProvider';
const _kLatestImageKey = 'latest_image_path';

/// Pushes [bytes] to the home-screen widget as its new photo, or clears the
/// widget back to its empty state when [bytes] is null (no moments left).
Future<void> updateLatestMomentWidget(Uint8List? bytes) async {
  try {
    if (bytes == null) {
      await HomeWidget.saveWidgetData<String?>(_kLatestImageKey, null);
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/widget_latest.png');
      await file.writeAsBytes(bytes, flush: true);
      await HomeWidget.saveWidgetData<String>(_kLatestImageKey, file.path);
    }
    await HomeWidget.updateWidget(
      name: _kWidgetProviderName,
      androidName: _kWidgetProviderName,
    );
  } catch (_) {
    // Best-effort: the app works fine even if the widget can't be reached.
  }
}

/// Asks the launcher to let the user place the widget on their home screen
/// (Android 8+ launchers that support it; a no-op elsewhere).
Future<void> requestPinLatestMomentWidget() async {
  try {
    await HomeWidget.requestPinWidget(
      name: _kWidgetProviderName,
      androidName: _kWidgetProviderName,
    );
  } catch (_) {}
}
