import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:clippy_companion/image_processor.dart';

void main() {
  test('converts an image into a treated PNG at the preview size', () async {
    final source = img.Image(width: 8, height: 8, numChannels: 4);
    for (final pixel in source) {
      pixel.setRgba(88, 132, 148, 255);
    }

    final output = await const LocalImageProcessor().process(
      Uint8List.fromList(img.encodePng(source)),
    );
    final treated = img.decodePng(output);

    expect(treated, isNotNull);
    expect(treated!.width, 420);
    expect(treated.height, 420);
  });
}
