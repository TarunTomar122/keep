import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class JpegFrameParser {
  final List<int> _buffer = [];

  List<Uint8List> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final frames = <Uint8List>[];

    while (true) {
      final start = _startOfJpeg();
      if (start == -1) {
        if (_buffer.length > 1) {
          _buffer.removeRange(0, _buffer.length - 1);
        }
        break;
      }
      if (start > 0) _buffer.removeRange(0, start);

      final end = _endOfJpeg();
      if (end == -1) break;
      frames.add(Uint8List.fromList(_buffer.sublist(0, end + 2)));
      _buffer.removeRange(0, end + 2);
    }

    return frames;
  }

  int _startOfJpeg() {
    for (var i = 0; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 0xFF && _buffer[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  int _endOfJpeg() {
    for (var i = 2; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 0xFF && _buffer[i + 1] == 0xD9) return i;
    }
    return -1;
  }
}

class MjpegView extends StatefulWidget {
  const MjpegView({required this.url, this.enabled = true, super.key});

  final String url;
  final bool enabled;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  final _parser = JpegFrameParser();
  HttpClient? _client;
  Uint8List? _frame;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) unawaited(_listen());
  }

  @override
  void didUpdateWidget(covariant MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.enabled && widget.enabled) {
      unawaited(_listen());
    } else if (oldWidget.enabled && !widget.enabled) {
      _client?.close(force: true);
      _client = null;
    }
  }

  Future<void> _listen() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      _client = client;
      final request = await client.getUrl(Uri.parse(widget.url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      await for (final chunk in response) {
        for (final frame in _parser.add(chunk)) {
          if (!mounted) return;
          setState(() => _frame = frame);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _client?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_frame != null) {
      return Image.memory(_frame!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return ColoredBox(
      color: const Color(0xFFECEAE5),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _error == null
                ? widget.enabled
                      ? 'Waiting for the XIAO video stream…'
                      : 'Open Device to start the live preview.'
                : 'Join CLIPPY-XIAO Wi-Fi to start the preview.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF77736D)),
          ),
        ),
      ),
    );
  }
}
