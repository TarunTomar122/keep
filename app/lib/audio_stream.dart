import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AudioPlaybackButton extends StatefulWidget {
  const AudioPlaybackButton({required this.url, super.key});

  final String url;

  @override
  State<AudioPlaybackButton> createState() => _AudioPlaybackButtonState();
}

class _AudioPlaybackButtonState extends State<AudioPlaybackButton> {
  static const _channel = MethodChannel('clippy.audio');
  bool _playing = false;
  String? _error;

  Future<void> _toggle() async {
    try {
      await _channel.invokeMethod<void>(
        _playing ? 'stop' : 'start',
        _playing ? null : {'url': widget.url},
      );
      if (mounted) {
        setState(() {
          _playing = !_playing;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    if (_playing) _channel.invokeMethod<void>('stop');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Audio playback',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: _toggle,
              tooltip: _playing ? 'Stop playback' : 'Play microphone stream',
              icon: Icon(
                _playing ? Icons.stop_rounded : Icons.volume_up_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _error ??
              (_playing
                  ? 'Playing the live microphone stream.'
                  : 'Play the live microphone stream from the XIAO.'),
          style: const TextStyle(color: Color(0xFF77736D)),
        ),
      ],
    );
  }
}
