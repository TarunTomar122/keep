import 'package:flutter_test/flutter_test.dart';

import 'package:clippy_companion/mjpeg_stream.dart';

void main() {
  test('extracts JPEG frames split across network chunks', () {
    final parser = JpegFrameParser();

    expect(parser.add([0x2D, 0xFF, 0xD8, 0x01]), isEmpty);
    final frames = parser.add([0x02, 0xFF, 0xD9, 0xFF, 0xD8, 0x03, 0xFF, 0xD9]);

    expect(frames, hasLength(2));
    expect(frames.first, [0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]);
    expect(frames.last, [0xFF, 0xD8, 0x03, 0xFF, 0xD9]);
  });
}
