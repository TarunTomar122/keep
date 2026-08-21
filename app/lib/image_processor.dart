import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class LocalImageProcessor {
  const LocalImageProcessor();

  Future<Uint8List> process(Uint8List input) {
    return Isolate.run(() => _processImage(input));
  }
}

Uint8List _processImage(Uint8List input) {
  final decoded = img.decodeImage(input);
  if (decoded == null) throw const FormatException('Unsupported image');

  var source = img.bakeOrientation(decoded);
  source = img.copyResize(
    source,
    width: 420,
    interpolation: img.Interpolation.average,
  );
  source = img.adjustColor(
    source,
    saturation: 0.72,
    contrast: 1.08,
    brightness: 1.03,
  );

  final treated = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 4,
  );
  var randomState = 0x2f6e2b1;
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final pixel = source.getPixel(x, y);
      final left = source.getPixel(max(0, x - 1), y);
      final right = source.getPixel(min(source.width - 1, x + 1), y);
      final top = source.getPixel(x, max(0, y - 1));
      final bottom = source.getPixel(x, min(source.height - 1, y + 1));

      final base = _themeColor(pixel.r, pixel.g, pixel.b);
      final edge =
          ((_luminance(left) - _luminance(right)).abs() +
              (_luminance(top) - _luminance(bottom)).abs()) /
          2;
      final outline = ((edge - 42) / 150).clamp(0.0, 0.32);

      randomState = (randomState * 1664525 + 1013904223) & 0x7fffffff;
      final grain = (randomState % 9) - 4;
      final r = _channel(base[0] * (1 - outline) + 42 * outline + grain);
      final g = _channel(base[1] * (1 - outline) + 49 * outline + grain);
      final b = _channel(base[2] * (1 - outline) + 52 * outline + grain);
      treated.setPixelRgba(x, y, r, g, b, pixel.a);
    }
  }

  final quantized = img.quantize(
    treated,
    numberOfColors: 24,
    method: img.QuantizeMethod.neuralNet,
    dither: img.DitherKernel.floydSteinberg,
    ditherScanOrder: img.DitherScanOrder.serpentine,
    ditherStrength: 0.42,
  );
  return img.encodePng(quantized, singleFrame: true);
}

List<double> _themeColor(num red, num green, num blue) {
  final r = red.toDouble();
  final g = green.toDouble();
  final b = blue.toDouble();
  final maximum = max(r, max(g, b));
  final minimum = min(r, min(g, b));
  final lightness = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  final spread = maximum - minimum;

  late List<double> dark;
  late List<double> light;
  if (spread < 22) {
    dark = [57, 71, 74];
    light = [231, 220, 202];
  } else if (b >= r * 1.08 && b >= g * 0.98) {
    dark = [57, 82, 94];
    light = [166, 187, 188];
  } else if (g >= r * 1.04 && g >= b * 0.86) {
    dark = [54, 79, 65];
    light = [178, 192, 163];
  } else if (r >= b * 1.18 && g >= b * 0.92) {
    dark = [126, 77, 72];
    light = [235, 207, 181];
  } else {
    dark = [77, 77, 75];
    light = [221, 207, 187];
  }

  final amount = (lightness * 1.18 - 0.08).clamp(0.0, 1.0);
  return [
    dark[0] + (light[0] - dark[0]) * amount,
    dark[1] + (light[1] - dark[1]) * amount,
    dark[2] + (light[2] - dark[2]) * amount,
  ];
}

double _luminance(img.Pixel pixel) {
  return 0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b;
}

int _channel(num value) => value.round().clamp(0, 255);
