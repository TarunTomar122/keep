import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path_provider/path_provider.dart';

import 'image_processor.dart';
import 'mjpeg_stream.dart';

typedef PhonePhotoPicker = Future<Uint8List?> Function();
typedef ImageProcessor = Future<Uint8List> Function(Uint8List input);

const _ink = Color(0xFF2B2823);
const _softSurface = Color(0xFFEDE7DC);
const _muted = Color(0xFF746D62);
const _burgundy = Color(0xFF786550);
const _page = Color(0xFFF7F2E8);

Future<Uint8List?> pickPhonePhoto() async {
  try {
    final file = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      imageQuality: 88,
    );
    return file?.readAsBytes();
  } catch (_) {
    return null;
  }
}

void main() {
  runApp(const ClippyCompanionApp());
}

class ClippyCompanionApp extends StatelessWidget {
  const ClippyCompanionApp({
    this.probeDevice = true,
    this.phonePhotoPicker,
    this.imageProcessor,
    super.key,
  });

  final bool probeDevice;
  final PhonePhotoPicker? phonePhotoPicker;
  final ImageProcessor? imageProcessor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Clippy',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _page,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _ink,
          brightness: Brightness.light,
          surface: _page,
        ),
        fontFamily: 'serif',
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _softSurface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _ink, width: 1.2),
          ),
          labelStyle: const TextStyle(color: _ink),
          hintStyle: const TextStyle(color: _muted),
        ),
      ),
      builder: (context, child) =>
          FTheme(data: FTheme.neutral.light.touch, child: child!),
      home: CompanionShell(
        probeDevice: probeDevice,
        phonePhotoPicker: phonePhotoPicker ?? pickPhonePhoto,
        imageProcessor: imageProcessor ?? const LocalImageProcessor().process,
      ),
    );
  }
}

class CompanionShell extends StatefulWidget {
  const CompanionShell({
    required this.probeDevice,
    required this.phonePhotoPicker,
    required this.imageProcessor,
    super.key,
  });

  final bool probeDevice;
  final PhonePhotoPicker phonePhotoPicker;
  final ImageProcessor imageProcessor;

  @override
  State<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends State<CompanionShell> {
  final DeviceController _device = DeviceController();
  final List<LocalMoment> _moments = _starterMoments();
  final LocalMomentStore _momentStore = LocalMomentStore();
  int _selectedTab = 0;
  bool _openingCamera = false;

  @override
  void initState() {
    super.initState();
    _device.addListener(_refresh);
    unawaited(_restoreMoments());
    if (widget.probeDevice) unawaited(_device.probeConnection());
  }

  @override
  void dispose() {
    _device
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _restoreMoments() async {
    try {
      final stored = await _momentStore.load();
      if (!mounted) return;
      final hasLegacyDemos = stored.any(
        (moment) =>
            moment.id.startsWith('demo-') &&
            !_currentDemoIds.contains(moment.id),
      );
      if (stored.isEmpty || hasLegacyDemos) {
        final prepared = await _prepareDemoMoments(_starterMoments());
        final captured = stored
            .where((moment) => !moment.id.startsWith('demo-'))
            .toList();
        if (!mounted) return;
        setState(() {
          _moments
            ..clear()
            ..addAll([...prepared, ...captured]);
        });
        await _momentStore.save(_moments);
        return;
      }
      setState(() {
        _moments
          ..clear()
          ..addAll(stored);
      });
    } catch (_) {
      // The bundled demo moments remain available if local storage is unavailable.
    }
  }

  void _persistMoments() => unawaited(_saveMoments());

  Future<void> _saveMoments() async {
    try {
      await _momentStore.save(_moments);
    } catch (_) {
      // The gallery remains usable when local storage is unavailable.
    }
  }

  Future<Uint8List> _treat(Uint8List bytes) async {
    try {
      return await widget.imageProcessor(bytes);
    } catch (_) {
      return bytes;
    }
  }

  Future<List<LocalMoment>> _prepareDemoMoments(
    List<LocalMoment> moments,
  ) async {
    final prepared = <LocalMoment>[];
    for (final moment in moments) {
      final asset = moment.originalAsset;
      if (asset == null || moment.treatedBytes != null) {
        prepared.add(moment);
        continue;
      }
      final source = await rootBundle.load(asset);
      final originalBytes = source.buffer.asUint8List(
        source.offsetInBytes,
        source.lengthInBytes,
      );
      prepared.add(
        LocalMoment(
          id: moment.id,
          capturedAt: moment.capturedAt,
          originalBytes: originalBytes,
          treatedBytes: await _treat(originalBytes),
          originalAsset: asset,
        ),
      );
    }
    return prepared;
  }

  Future<void> _takePhonePhoto() async {
    if (_openingCamera) return;
    setState(() => _openingCamera = true);
    try {
      final imageBytes = await widget.phonePhotoPicker();
      if (imageBytes == null) {
        if (mounted) setState(() => _openingCamera = false);
        return;
      }
      final treatedBytes = await _treat(imageBytes);
      if (!mounted) return;
      setState(() {
        _openingCamera = false;
        _moments.insert(
          0,
          LocalMoment(
            id: 'phone-${DateTime.now().microsecondsSinceEpoch}',
            originalBytes: imageBytes,
            treatedBytes: treatedBytes,
            capturedAt: DateTime.now(),
          ),
        );
      });
      _persistMoments();
    } catch (_) {
      if (mounted) setState(() => _openingCamera = false);
    }
  }

  Future<bool> _captureBoardPhoto() async {
    final imageBytes = await _device.capturePhoto();
    if (!mounted || imageBytes == null) return false;
    final treatedBytes = await _treat(imageBytes);
    if (!mounted) return false;
    setState(() {
      _moments.insert(
        0,
        LocalMoment(
          id: 'xiao-${DateTime.now().microsecondsSinceEpoch}',
          originalBytes: imageBytes,
          treatedBytes: treatedBytes,
          capturedAt: DateTime.now(),
        ),
      );
    });
    _persistMoments();
    return true;
  }

  Future<void> _openMoment(LocalMoment moment) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => MomentDetailPage(moment: moment)),
    );
    if (deleted != true || !mounted) return;
    setState(() => _moments.removeWhere((item) => item.id == moment.id));
    await _momentStore.delete(moment, _moments);
  }

  void _selectTab(int tab) => setState(() => _selectedTab = tab);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _page,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: SizedBox.expand(
          child: IndexedStack(
            sizing: StackFit.expand,
            index: _selectedTab,
            children: [
              HomeView(
                moments: _moments,
                openingCamera: _openingCamera,
                onAddPhoto: _takePhonePhoto,
                onSettings: () => _selectTab(1),
                onOpenMoment: _openMoment,
              ),
              SettingsView(
                device: _device,
                isActive: _selectedTab == 1,
                onBack: () => _selectTab(0),
                onCapture: _captureBoardPhoto,
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: _selectedTab == 0
          ? Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 32),
              child: SizedBox(
                width: 64,
                height: 64,
                child: FloatingActionButton(
                  onPressed: _openingCamera ? null : _takePhonePhoto,
                  tooltip: 'Take a photo',
                  backgroundColor: _softSurface,
                  foregroundColor: _ink,
                  elevation: 0,
                  shape: const CircleBorder(),
                  child: _openingCamera
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_rounded, size: 32),
                ),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}

class HomeView extends StatelessWidget {
  const HomeView({
    required this.moments,
    required this.openingCamera,
    required this.onAddPhoto,
    required this.onSettings,
    required this.onOpenMoment,
    super.key,
  });

  final List<LocalMoment> moments;
  final bool openingCamera;
  final VoidCallback onAddPhoto;
  final VoidCallback onSettings;
  final ValueChanged<LocalMoment> onOpenMoment;

  @override
  Widget build(BuildContext context) {
    final left = <LocalMoment>[];
    final right = <LocalMoment>[];
    for (var index = 0; index < moments.length; index++) {
      (index.isEven ? left : right).add(moments[index]);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
            child: _Greeting(onSettings: onSettings),
          ),
          if (moments.isEmpty)
            _EmptyGallery(onAddPhoto: onAddPhoto, openingCamera: openingCamera)
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _GalleryColumn(
                      moments: left,
                      onOpenMoment: onOpenMoment,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GalleryColumn(
                      moments: right,
                      onOpenMoment: onOpenMoment,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Hi, Tarun',
            style: TextStyle(
              color: _ink,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
        ),
        IconButton(
          onPressed: onSettings,
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined, color: _ink, size: 28),
        ),
      ],
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({required this.onAddPhoto, required this.openingCamera});

  final VoidCallback onAddPhoto;
  final bool openingCamera;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 96),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.photo_library_outlined, size: 42, color: _ink),
            const SizedBox(height: 16),
            const Text(
              'No photos yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Text(
              'Take the first one from your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: openingCamera ? null : onAddPhoto,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Take a photo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryColumn extends StatelessWidget {
  const _GalleryColumn({required this.moments, required this.onOpenMoment});

  final List<LocalMoment> moments;
  final ValueChanged<LocalMoment> onOpenMoment;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final moment in moments) ...[
          _GalleryTile(moment: moment, onTap: () => onOpenMoment(moment)),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _GalleryTile extends StatelessWidget {
  const _GalleryTile({required this.moment, required this.onTap});

  final LocalMoment moment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Photo',
      button: true,
      image: true,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 0.78,
            child: _MomentVisual(moment: moment),
          ),
        ),
      ),
    );
  }
}

class SettingsView extends StatefulWidget {
  const SettingsView({
    required this.device,
    required this.isActive,
    required this.onBack,
    required this.onCapture,
    super.key,
  });

  final DeviceController device;
  final bool isActive;
  final VoidCallback onBack;
  final Future<bool> Function() onCapture;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  static const _wifiSsidKey = 'board_wifi_ssid';
  static const _wifiPasswordKey = 'board_wifi_password';

  final _wifiName = TextEditingController();
  final _wifiPassword = TextEditingController();
  final _serverUrl = TextEditingController();
  final _wifiStorage = FlutterSecureStorage();
  bool _wifiSaved = false;
  bool _wifiSaving = false;
  bool _wifiResetting = false;
  String? _wifiMessage;
  bool _serverSaved = false;
  bool _liveCapture = false;
  bool _capturing = false;

  @override
  void dispose() {
    _wifiName.dispose();
    _wifiPassword.dispose();
    _serverUrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_restoreWifiCredentials());
  }

  Future<void> _restoreWifiCredentials() async {
    try {
      final values = await Future.wait([
        _wifiStorage.read(key: _wifiSsidKey),
        _wifiStorage.read(key: _wifiPasswordKey),
      ]);
      if (!mounted) return;
      _wifiName.text = values[0] ?? '';
      _wifiPassword.text = values[1] ?? '';
      setState(() {});
    } catch (_) {
      // The fields remain usable even if secure storage is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.device.isConnected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                tooltip: 'Back to Home',
                icon: const Icon(Icons.arrow_back_rounded, color: _ink),
              ),
              const SizedBox(width: 4),
              const Text(
                'Settings',
                style: TextStyle(
                  color: _ink,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const _SectionLabel('Device'),
          const SizedBox(height: 10),
          _OutlinedPanel(
            child: _SettingRow(
              icon: Icons.camera_alt_outlined,
              title: 'Keychain camera',
              detail: connected
                  ? '${widget.device.connectionMode == 'station' ? 'Wi-Fi' : 'Setup hotspot'} · ${widget.device.ipAddress ?? 'connected'}'
                  : 'No XIAO connection found',
              trailing: Text(
                connected ? 'ONLINE' : 'OFFLINE',
                style: TextStyle(
                  color: connected ? _ink : _burgundy,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: () => unawaited(widget.device.probeConnection()),
              style: _softButtonStyle(),
              child: Text(connected ? 'Check again' : 'Check connection'),
            ),
          ),
          const SizedBox(height: 24),
          _OutlinedPanel(
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _liveCapture,
              onChanged: (value) => setState(() => _liveCapture = value),
              title: const Text(
                'Live capture mode',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                connected
                    ? 'Show the XIAO camera feed while enabled.'
                    : 'Connect the board to preview its camera here.',
              ),
            ),
          ),
          if (_liveCapture && connected && widget.isActive) ...[
            const SizedBox(height: 10),
            _LivePreview(url: widget.device.streamUrl),
          ],
          if (connected && widget.isActive) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _capturing ? null : _capturePhoto,
                style: _softButtonStyle(),
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(_capturing ? 'Capturing…' : 'Take photo from XIAO'),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const _SectionLabel('Battery'),
          const SizedBox(height: 10),
          const _OutlinedPanel(
            child: _SettingRow(
              icon: Icons.battery_unknown_outlined,
              title: 'Board battery',
              detail: 'No voltage sensor or battery gauge is connected yet.',
              trailing: Text(
                'UNAVAILABLE',
                style: TextStyle(
                  color: _burgundy,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Board Wi-Fi'),
          const SizedBox(height: 10),
          TextField(
            controller: _wifiName,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi network',
              hintText: 'Network name',
            ),
            onChanged: (_) => setState(() {
              _wifiSaved = false;
              _wifiMessage = null;
            }),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _wifiPassword,
            decoration: const InputDecoration(
              labelText: 'Wi-Fi password',
              hintText: 'Password',
            ),
            onChanged: (_) => setState(() {
              _wifiSaved = false;
              _wifiMessage = null;
            }),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: _wifiName.text.trim().isEmpty || _wifiSaving
                  ? null
                  : _saveWifi,
              style: _softButtonStyle(),
              child: Text(
                _wifiSaving
                    ? 'Saving to board…'
                    : _wifiSaved
                    ? 'Saved on board'
                    : 'Save Wi-Fi details',
              ),
            ),
          ),
          if (_wifiMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _wifiMessage!,
              style: TextStyle(
                color: _wifiSaved ? _ink : _burgundy,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: !connected || _wifiSaving || _wifiResetting
                  ? null
                  : _resetWifi,
              icon: _wifiResetting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restart_alt_rounded),
              label: Text(
                _wifiResetting ? 'Resetting board Wi-Fi…' : 'Reset board Wi-Fi',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: _burgundy,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const _Hint(
            'The board will reboot and use these credentials next time. Reconnect your phone to the same Wi-Fi, then check the connection.',
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Server'),
          const SizedBox(height: 10),
          TextField(
            controller: _serverUrl,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://your-server.example',
            ),
            onChanged: (_) => setState(() => _serverSaved = false),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: _serverUrl.text.trim().isEmpty
                  ? null
                  : () => setState(() => _serverSaved = true),
              style: _softButtonStyle(),
              child: Text(
                _serverSaved ? 'Saved on this phone' : 'Save server URL',
              ),
            ),
          ),
          const SizedBox(height: 8),
          const _Hint(
            'Uploads stay local until we define the server contract together.',
          ),
        ],
      ),
    );
  }

  Future<void> _saveWifi() async {
    setState(() {
      _wifiSaving = true;
      _wifiSaved = false;
      _wifiMessage = null;
    });
    final saved = await widget.device.saveWifiCredentials(
      ssid: _wifiName.text.trim(),
      password: _wifiPassword.text,
    );
    var storedOnPhone = false;
    if (saved) {
      try {
        await Future.wait([
          _wifiStorage.write(key: _wifiSsidKey, value: _wifiName.text.trim()),
          _wifiStorage.write(key: _wifiPasswordKey, value: _wifiPassword.text),
        ]);
        storedOnPhone = true;
      } catch (_) {
        // Board provisioning still succeeded; report the local persistence issue.
      }
    }
    if (!mounted) return;
    setState(() {
      _wifiSaving = false;
      _wifiSaved = saved;
      _wifiMessage = !saved
          ? 'Could not save Wi-Fi credentials. Keep the phone connected to CLIPPY-XIAO and try again.'
          : storedOnPhone
          ? 'Saved on the board and this phone. The board will reboot now.'
          : 'Saved on the board, but this phone could not store the details.';
    });
  }

  Future<void> _resetWifi() async {
    setState(() {
      _wifiResetting = true;
      _wifiMessage = null;
    });
    final reset = await widget.device.resetWifiCredentials();
    var clearedOnPhone = false;
    if (reset) {
      try {
        await Future.wait([
          _wifiStorage.delete(key: _wifiSsidKey),
          _wifiStorage.delete(key: _wifiPasswordKey),
        ]);
        clearedOnPhone = true;
      } catch (_) {
        // Board reset still succeeded; report the local cleanup issue.
      }
    }
    if (!mounted) return;
    setState(() {
      _wifiResetting = false;
      _wifiSaved = false;
      if (reset) {
        _wifiName.clear();
        _wifiPassword.clear();
      }
      _wifiMessage = !reset
          ? 'Could not reset the board. Check the connection and try again.'
          : clearedOnPhone
          ? 'Board Wi-Fi was reset. It will restart in setup-hotspot mode.'
          : 'Board Wi-Fi was reset, but this phone could not clear its saved details.';
    });
  }

  Future<void> _capturePhoto() async {
    setState(() => _capturing = true);
    final captured = await widget.onCapture();
    if (!mounted) return;
    setState(() => _capturing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          captured
              ? 'Captured from XIAO and added to Home.'
              : 'Could not capture from the XIAO.',
        ),
      ),
    );
  }
}

ButtonStyle _softButtonStyle() {
  return FilledButton.styleFrom(
    backgroundColor: _softSurface,
    foregroundColor: _ink,
    disabledBackgroundColor: const Color(0xFFE8E1D5),
    minimumSize: const Size.fromHeight(48),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  );
}

class DeviceController extends ChangeNotifier {
  static const _accessPointUrl = 'http://192.168.4.1';
  String _baseUrl = _accessPointUrl;

  bool isConnected = false;
  String connectionMode = 'unknown';
  String? ipAddress;

  String get streamUrl =>
      Uri.parse(_baseUrl).replace(port: 82, path: '/stream').toString();

  Future<void> probeConnection() async {
    if (await _probe(_baseUrl)) {
      isConnected = true;
      notifyListeners();
      return;
    }

    final discoveredUrl = await _discoverBoard();
    if (discoveredUrl != null && await _probe(discoveredUrl)) {
      _baseUrl = discoveredUrl;
      isConnected = true;
      notifyListeners();
      return;
    }

    isConnected = false;
    connectionMode = 'unknown';
    ipAddress = null;
    notifyListeners();
  }

  Future<bool> saveWifiCredentials({
    required String ssid,
    required String password,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.postUrl(Uri.parse('$_baseUrl/wifi/config'));
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      final body = utf8.encode(
        Uri(queryParameters: {'ssid': ssid, 'password': password}).query,
      );
      request.headers.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> resetWifiCredentials() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.postUrl(Uri.parse('$_baseUrl/wifi/reset'));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List?> capturePhoto() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse('$_baseUrl/capture'));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      final image = bytes.takeBytes();
      if (image.length < 2 || image[0] != 0xFF || image[1] != 0xD8) {
        return null;
      }
      return image;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _probe(String baseUrl) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(Uri.parse('$baseUrl/status'));
      final response = await request.close();
      final payload = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return false;
      final status = jsonDecode(payload);
      if (status is! Map<String, dynamic>) return false;
      connectionMode = status['mode'] as String? ?? 'unknown';
      ipAddress = status['ip'] as String?;
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _discoverBoard() async {
    final client = MDnsClient();
    try {
      await client.start();
      await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_clippy._tcp.local'),
        timeout: const Duration(seconds: 2),
      )) {
        await for (final service in client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
          timeout: const Duration(seconds: 2),
        )) {
          await for (final address in client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(service.target),
            timeout: const Duration(seconds: 2),
          )) {
            return Uri(
              scheme: 'http',
              host: address.address.address,
              port: service.port,
            ).toString();
          }
        }
      }
    } catch (_) {
      // Some phone hotspots do not forward mDNS multicast.
    } finally {
      client.stop();
    }

    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? subscription;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final response = Completer<String?>();
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read || response.isCompleted) return;
        final packet = socket!.receive();
        if (packet == null) return;
        if (utf8.decode(packet.data, allowMalformed: true).trim() ==
            'CLIPPY_XIAO') {
          response.complete(
            Uri(
              scheme: 'http',
              host: packet.address.address,
              port: 80,
            ).toString(),
          );
        }
      });
      final query = utf8.encode('CLIPPY_DISCOVER');
      final broadcasts = <InternetAddress>{InternetAddress('255.255.255.255')};
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
          includeLinkLocal: false,
        );
        for (final networkInterface in interfaces) {
          for (final address in networkInterface.addresses) {
            final octets = address.address.split('.');
            if (octets.length == 4) {
              // ponytail: /24 is enough for current phone hotspots; replace
              // with prefix-aware broadcasts if we support arbitrary LANs.
              broadcasts.add(
                InternetAddress('${octets[0]}.${octets[1]}.${octets[2]}.255'),
              );
            }
          }
        }
      } catch (_) {
        // Keep the global broadcast fallback.
      }
      for (final broadcast in broadcasts) {
        socket.send(query, broadcast, 4210);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!response.isCompleted) {
        for (final broadcast in broadcasts) {
          socket.send(query, broadcast, 4210);
        }
      }
      return await response.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      await subscription?.cancel();
      socket?.close();
    }
  }
}

List<LocalMoment> _starterMoments() {
  final now = DateTime.now();
  return [
    LocalMoment(
      id: 'demo-v2-photo',
      capturedAt: now.subtract(const Duration(days: 2)),
      originalAsset: 'assets/demo/source-photo.png',
    ),
    LocalMoment(
      id: 'demo-v2-scene-1',
      capturedAt: now.subtract(const Duration(days: 1)),
      originalAsset: 'assets/demo/original-1.png',
    ),
    LocalMoment(
      id: 'demo-v2-scene-2',
      capturedAt: now,
      originalAsset: 'assets/demo/original-2.png',
    ),
  ];
}

const _currentDemoIds = {'demo-v2-photo', 'demo-v2-scene-1', 'demo-v2-scene-2'};

class LocalMoment {
  const LocalMoment({
    required this.id,
    required this.capturedAt,
    this.originalBytes,
    this.treatedBytes,
    this.originalAsset,
    this.treatedAsset,
    this.originalPath,
    this.treatedPath,
  });

  final String id;
  final DateTime capturedAt;
  final Uint8List? originalBytes;
  final Uint8List? treatedBytes;
  final String? originalAsset;
  final String? treatedAsset;
  final String? originalPath;
  final String? treatedPath;

  LocalMoment withPaths({
    required String? originalPath,
    required String? treatedPath,
  }) {
    return LocalMoment(
      id: id,
      capturedAt: capturedAt,
      originalAsset: originalAsset,
      treatedAsset: treatedAsset,
      originalPath: originalPath,
      treatedPath: treatedPath,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'capturedAt': capturedAt.toIso8601String(),
    if (originalAsset != null) 'originalAsset': originalAsset,
    if (treatedAsset != null) 'treatedAsset': treatedAsset,
    if (originalPath != null) 'originalPath': originalPath,
    if (treatedPath != null) 'treatedPath': treatedPath,
  };

  factory LocalMoment.fromJson(Map<String, dynamic> json) {
    return LocalMoment(
      id: json['id'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      originalAsset: json['originalAsset'] as String?,
      treatedAsset: json['treatedAsset'] as String?,
      originalPath: json['originalPath'] as String?,
      treatedPath: json['treatedPath'] as String?,
    );
  }
}

class LocalMomentStore {
  static const _indexName = 'moments.json';

  Future<List<LocalMoment>> load() async {
    final directory = await getApplicationDocumentsDirectory();
    final index = File('${directory.path}/$_indexName');
    if (!await index.exists()) return [];
    final decoded = jsonDecode(await index.readAsString());
    if (decoded is! List) return [];
    return [
      for (final item in decoded)
        if (item is Map<String, dynamic>) LocalMoment.fromJson(item),
    ];
  }

  Future<void> save(List<LocalMoment> moments) async {
    final directory = await getApplicationDocumentsDirectory();
    final persisted = <LocalMoment>[];
    for (final moment in moments) {
      var originalPath = moment.originalPath;
      var treatedPath = moment.treatedPath;
      if (moment.originalBytes != null) {
        originalPath = await _writeImage(
          directory,
          moment.id,
          'original',
          moment.originalBytes!,
        );
      }
      if (moment.treatedBytes != null) {
        treatedPath = identical(moment.treatedBytes, moment.originalBytes)
            ? originalPath
            : await _writeImage(
                directory,
                moment.id,
                'treated',
                moment.treatedBytes!,
              );
      }
      persisted.add(
        moment.withPaths(originalPath: originalPath, treatedPath: treatedPath),
      );
    }
    final index = File('${directory.path}/$_indexName');
    await index.writeAsString(
      jsonEncode([for (final moment in persisted) moment.toJson()]),
    );
  }

  Future<void> delete(LocalMoment moment, List<LocalMoment> remaining) async {
    final paths = {moment.originalPath, moment.treatedPath}..remove(null);
    for (final path in paths.cast<String>()) {
      try {
        await File(path).delete();
      } on FileSystemException {
        // The index is still authoritative if a file was already removed.
      }
    }
    await save(remaining);
  }

  Future<String> _writeImage(
    Directory directory,
    String id,
    String variant,
    Uint8List bytes,
  ) async {
    final extension = variant == 'treated' || _isPng(bytes) ? 'png' : 'jpg';
    final file = File('${directory.path}/$id-$variant.$extension');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  bool _isPng(Uint8List bytes) {
    return bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47;
  }
}

class MomentDetailPage extends StatefulWidget {
  const MomentDetailPage({required this.moment, super.key});

  final LocalMoment moment;

  @override
  State<MomentDetailPage> createState() => _MomentDetailPageState();
}

class _MomentDetailPageState extends State<MomentDetailPage> {
  bool _showTreated = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: IconButton(
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded, color: _ink),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('Original')),
                          ButtonSegment(value: true, label: Text('Treated')),
                        ],
                        selected: {_showTreated},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) {
                          setState(() => _showTreated = selection.first);
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: IconButton(
                      onPressed: _delete,
                      tooltip: 'Delete',
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: _ink,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _MomentVisual(
                    moment: widget.moment,
                    showTreated: _showTreated,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _showTreated ? 'Treated image' : 'Original image',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Uploaded ${_formatMomentDate(widget.moment.capturedAt)}',
                      style: const TextStyle(color: _muted),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Saved on this phone',
                      style: TextStyle(color: _muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this image?'),
        content: const Text('This removes it from the local gallery.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) Navigator.pop(context, true);
  }
}

String _formatMomentDate(DateTime value) {
  final local = value.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$day/$month/${local.year} · $hour:$minute';
}

class _MomentVisual extends StatelessWidget {
  const _MomentVisual({
    required this.moment,
    this.showTreated = true,
    this.fit = BoxFit.cover,
  });

  final LocalMoment moment;
  final bool showTreated;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final errorWidget = const ColoredBox(
      color: _softSurface,
      child: Center(child: Icon(Icons.broken_image_outlined, color: _muted)),
    );
    final bytes = showTreated
        ? moment.treatedBytes ?? moment.originalBytes
        : moment.originalBytes ?? moment.treatedBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => errorWidget,
      );
    }
    final path = showTreated
        ? moment.treatedPath ?? moment.originalPath
        : moment.originalPath ?? moment.treatedPath;
    if (path != null) {
      return Image.file(
        File(path),
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => errorWidget,
      );
    }
    final asset = showTreated
        ? moment.treatedAsset ?? moment.originalAsset
        : moment.originalAsset ?? moment.treatedAsset;
    if (asset == null) return errorWidget;
    return Image.asset(
      asset,
      fit: fit,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (context, error, stackTrace) => errorWidget,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: _muted,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _OutlinedPanel extends StatelessWidget {
  const _OutlinedPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _softSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(color: Colors.transparent, child: child),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _ink),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(detail, style: const TextStyle(color: _muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        trailing,
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(message, style: const TextStyle(color: _muted, fontSize: 13));
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: MjpegView(url: url, enabled: true),
      ),
    );
  }
}
