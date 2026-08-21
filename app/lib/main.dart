import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path_provider/path_provider.dart';

import 'design/oa.dart';
import 'image_processor.dart';
import 'keep_server.dart';
import 'mjpeg_stream.dart';

typedef PhonePhotoPicker = Future<Uint8List?> Function();
typedef ImageProcessor = Future<Uint8List> Function(Uint8List input);
typedef PhotoSubmitter = Future<ProcessedPhoto> Function(Uint8List input);

class ProcessedPhoto {
  const ProcessedPhoto({required this.bytes, this.remoteId});

  final Uint8List bytes;
  final String? remoteId;
}

Future<Uint8List?> pickPhonePhoto() async {
  try {
    final file = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      imageQuality: 88,
    );
    return file == null ? null : await file.readAsBytes();
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
    this.serverConfig,
    this.photoSubmitter,
    super.key,
  });

  final bool probeDevice;
  final PhonePhotoPicker? phonePhotoPicker;
  final ImageProcessor? imageProcessor;
  final ServerConfig? serverConfig;
  final PhotoSubmitter? photoSubmitter;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Keep',
        theme: oaTheme(),
        home: CompanionShell(
          probeDevice: probeDevice,
          phonePhotoPicker: phonePhotoPicker ?? pickPhonePhoto,
          imageProcessor: imageProcessor ?? const LocalImageProcessor().process,
          serverConfig: serverConfig,
          photoSubmitter: photoSubmitter,
        ),
      ),
    );
  }
}

class CompanionShell extends StatefulWidget {
  const CompanionShell({
    required this.probeDevice,
    required this.phonePhotoPicker,
    required this.imageProcessor,
    this.serverConfig,
    this.photoSubmitter,
    super.key,
  });

  final bool probeDevice;
  final PhonePhotoPicker phonePhotoPicker;
  final ImageProcessor imageProcessor;
  final ServerConfig? serverConfig;
  final PhotoSubmitter? photoSubmitter;

  @override
  State<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends State<CompanionShell> {
  final DeviceController _device = DeviceController();
  final List<LocalMoment> _moments = [];
  final LocalMomentStore _momentStore = LocalMomentStore();
  final ServerConfigStore _serverConfigStore = ServerConfigStore();
  final ServerImageCache _imageCache = ServerImageCache();
  late ServerConfig _serverConfig = widget.serverConfig ??
      const ServerConfig(url: kDefaultServerUrl, token: kDefaultServerToken);
  late final PhotoSubmitter _submitPhoto =
      widget.photoSubmitter ?? _defaultSubmit;
  bool _syncing = false;
  String? _galleryError;
  final Set<String> _deletingIds = {};
  int _selectedTab = 0;
  bool _openingCamera = false;

  @override
  void initState() {
    super.initState();
    _device.addListener(_refresh);
    if (widget.serverConfig == null) unawaited(_restoreServerConfig());
    unawaited(_initialLoad());
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

  Future<void> _restoreServerConfig() async {
    final config = await _serverConfigStore.load();
    if (!mounted) return;
    setState(() => _serverConfig = config);
    unawaited(_syncFromServer());
  }

  Future<void> _saveServerConfig(ServerConfig config) async {
    _serverConfig = config;
    try {
      await _serverConfigStore.save(config);
    } catch (_) {}
    unawaited(_syncFromServer());
  }

  Future<void> _initialLoad() async {
    try {
      final stored = await _momentStore.load();
      if (!mounted || stored.isEmpty) return;
      setState(() => _moments.addAll(stored));
    } catch (_) {}
    await _syncFromServer();
  }

  bool get _serverReady => _serverConfig.isConfigured;

  Future<void> _syncFromServer() async {
    if (_syncing || !_serverReady) return;
    _syncing = true;
    if (mounted) setState(() => _galleryError = null);
    try {
      final client = KeepServerClient(config: _serverConfig);
      final remote = await client.listPhotos();
      final synced = <LocalMoment>[];
      for (final moment in remote) {
        synced.add(await _loadRemoteMoment(client, moment));
      }
      if (!mounted) return;
      setState(() {
        _moments
          ..clear()
          ..addAll(synced);
      });
      await _momentStore.save(_moments);
    } catch (_) {
      if (mounted && _galleryError == null) {
        setState(() => _galleryError = 'Could not reach the server.');
      }
    } finally {
      _syncing = false;
      if (mounted) setState(() {});
    }
  }

  Future<LocalMoment> _loadRemoteMoment(
    KeepServerClient client,
    RemoteMoment moment,
  ) async {
    final processedKey = '${moment.id}-treated.png';
    var treatedPath = await _imageCache.pathFor(processedKey);
    if (treatedPath == null) {
      try {
        treatedPath = await _imageCache.put(
          processedKey,
          await client.fetchBytes(moment.processedUrl),
        );
      } catch (_) {
        treatedPath = null;
      }
    }
    return LocalMoment(
      id: moment.id,
      capturedAt: moment.createdAt,
      treatedPath: treatedPath,
      remoteId: moment.id,
    );
  }

  void _persistMoments() => unawaited(_saveMoments());

  Future<void> _saveMoments() async {
    try {
      await _momentStore.save(_moments);
    } catch (_) {}
  }

  Future<ProcessedPhoto> _defaultSubmit(Uint8List bytes) async {
    if (_serverReady) {
      final uploaded =
          await KeepServerClient(config: _serverConfig).upload(bytes);
      return ProcessedPhoto(
        bytes: uploaded.processedBytes,
        remoteId: uploaded.id,
      );
    }
    try {
      return ProcessedPhoto(bytes: await widget.imageProcessor(bytes));
    } catch (_) {
      return ProcessedPhoto(bytes: bytes);
    }
  }

  Future<void> _takePhonePhoto() async {
    if (_openingCamera || _syncing) return;
    setState(() => _openingCamera = true);
    try {
      final imageBytes = await widget.phonePhotoPicker();
      if (imageBytes == null) {
        if (mounted) setState(() => _openingCamera = false);
        return;
      }
      final treated = await _submitPhoto(imageBytes);
      if (!mounted) return;
      setState(() {
        _moments.insert(
          0,
          LocalMoment(
            id: treated.remoteId ??
                'phone-${DateTime.now().microsecondsSinceEpoch}',
            originalBytes: imageBytes,
            treatedBytes: treated.bytes,
            remoteId: treated.remoteId,
            capturedAt: DateTime.now(),
          ),
        );
      });
      _persistMoments();
      await _syncFromServer();
    } catch (_) {
      if (mounted) {
        OaToast.show(
          context,
          good: false,
          message: _serverReady
              ? 'Upload failed — check the server in Settings.'
              : 'Could not process the photo.',
        );
      }
    } finally {
      if (mounted) setState(() => _openingCamera = false);
    }
  }

  Future<bool> _captureBoardPhoto() async {
    final imageBytes = await _device.capturePhoto();
    if (!mounted || imageBytes == null) return false;
    try {
      final treated = await _submitPhoto(imageBytes);
      if (!mounted) return false;
      setState(() {
        _moments.insert(
          0,
          LocalMoment(
            id: treated.remoteId ?? 'xiao-${DateTime.now().microsecondsSinceEpoch}',
            originalBytes: imageBytes,
            treatedBytes: treated.bytes,
            remoteId: treated.remoteId,
            capturedAt: DateTime.now(),
          ),
        );
      });
      _persistMoments();
      await _syncFromServer();
      return true;
    } catch (_) {
      if (mounted) {
        OaToast.show(
          context,
          good: false,
          message: _serverReady
              ? 'Upload failed — check the server in Settings.'
              : 'Could not process the photo.',
        );
      }
      return false;
    }
  }

  Future<void> _openMoment(LocalMoment moment) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => MomentDetailPage(moment: moment)),
    );
    if (deleted != true || !mounted) return;
    final remoteId = moment.remoteId;
    if (remoteId != null && _serverReady) {
      setState(() => _deletingIds.add(remoteId));
      try {
        await KeepServerClient(config: _serverConfig).deletePhoto(remoteId);
      } catch (_) {
        if (!mounted) return;
        setState(() => _deletingIds.remove(remoteId));
        OaToast.show(
          context,
          good: false,
          message: 'Could not delete on the server.',
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _deletingIds.remove(remoteId);
        _moments.removeWhere((item) => item.id == moment.id);
      });
      await _imageCache.removeForId(remoteId);
      await _momentStore.delete(moment, _moments);
      return;
    }
    setState(() => _moments.removeWhere((item) => item.id == moment.id));
    await _momentStore.delete(moment, _moments);
  }

  void _selectTab(int tab) => setState(() => _selectedTab = tab);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Text(
                      'Keep',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: Oa.ink,
                      ),
                    ),
                    const Spacer(),
                    OaIconButton(
                      icon: Icons.settings_outlined,
                      tooltip: 'Settings',
                      onPressed: () => _selectTab(1),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                sizing: StackFit.expand,
                index: _selectedTab,
                children: [
                  HomeView(
                    moments: _moments,
                    openingCamera: _openingCamera,
                    cameraConnected: _device.isConnected,
                    syncing: _syncing,
                    galleryError: _galleryError,
                    serverReady: _serverReady,
                    deletingIds: _deletingIds,
                    onRefresh: _syncFromServer,
                    onAddPhoto: _takePhonePhoto,
                    onOpenConnection: () => _selectTab(1),
                    onOpenMoment: _openMoment,
                  ),
                  SettingsView(
                    device: _device,
                    isActive: _selectedTab == 1,
                    onBack: () => _selectTab(0),
                    onCapture: _captureBoardPhoto,
                    serverConfig: _serverConfig,
                    onSaveServerConfig: (config) =>
                        unawaited(_saveServerConfig(config)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeView extends StatelessWidget {
  const HomeView({
    required this.moments,
    required this.openingCamera,
    required this.cameraConnected,
    required this.syncing,
    required this.galleryError,
    required this.serverReady,
    required this.deletingIds,
    required this.onRefresh,
    required this.onAddPhoto,
    required this.onOpenConnection,
    required this.onOpenMoment,
    super.key,
  });

  final List<LocalMoment> moments;
  final bool openingCamera;
  final bool cameraConnected;
  final bool syncing;
  final String? galleryError;
  final bool serverReady;
  final Set<String> deletingIds;
  final Future<void> Function() onRefresh;
  final VoidCallback onAddPhoto;
  final VoidCallback onOpenConnection;
  final ValueChanged<LocalMoment> onOpenMoment;

  @override
  Widget build(BuildContext context) {
    final left = <LocalMoment>[];
    final right = <LocalMoment>[];
    for (var index = 0; index < moments.length; index++) {
      (index.isEven ? left : right).add(moments[index]);
    }

    return RefreshIndicator(
      color: Oa.ink,
      backgroundColor: Colors.white,
      onRefresh: onRefresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Moments',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.3,
                    color: Oa.ink,
                  ),
                ),
                const Spacer(),
                if (syncing) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                OaButton(
                  label: '+ Photo',
                  tooltip: 'Take a photo',
                  loading: openingCamera,
                  onPressed: onAddPhoto,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!cameraConnected)
              OaNoticeStrip(
                claim: 'No camera connected.',
                sentence: 'Capture from the XIAO once it joins your Wi-Fi.',
                actionLabel: 'Check connection',
                onAction: onOpenConnection,
              ),
            if (!serverReady && !syncing)
              OaNoticeStrip(
                claim: 'Server not set up.',
                sentence: 'Add the URL and token in Settings to sync photos.',
                actionLabel: 'Open Settings',
                onAction: onOpenConnection,
              )
            else if (galleryError != null)
              OaNoticeStrip(
                claim: galleryError!,
                sentence: 'Showing photos from the last successful sync.',
                actionLabel: 'Retry',
                onAction: () => onRefresh(),
              ),
            if (moments.isEmpty)
              syncing
                  ? const _GallerySkeleton()
                  : _EmptyGallery(onAddPhoto: onAddPhoto)
            else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _GalleryColumn(
                      moments: left,
                      deletingIds: deletingIds,
                      onOpenMoment: onOpenMoment,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GalleryColumn(
                      moments: right,
                      deletingIds: deletingIds,
                      onOpenMoment: onOpenMoment,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({required this.onAddPhoto});

  final VoidCallback onAddPhoto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 96),
      child: Center(
        child: Column(
          children: [
            const Text(
              'No photos yet.',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Oa.ink,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Take the first one from your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Oa.mutedFg),
            ),
            const SizedBox(height: 20),
            OaButton(
              label: 'Take a photo',
              onPressed: onAddPhoto,
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryColumn extends StatelessWidget {
  const _GalleryColumn({
    required this.moments,
    required this.deletingIds,
    required this.onOpenMoment,
  });

  final List<LocalMoment> moments;
  final Set<String> deletingIds;
  final ValueChanged<LocalMoment> onOpenMoment;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final moment in moments) ...[
          _GalleryTile(
            moment: moment,
            deleting: deletingIds.contains(moment.remoteId ?? moment.id),
            onTap: () => onOpenMoment(moment),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.moment,
    required this.deleting,
    required this.onTap,
  });

  final LocalMoment moment;
  final bool deleting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Photo',
      button: true,
      image: true,
      child: GestureDetector(
        onTap: deleting ? null : onTap,
        child: Container(
          decoration: ShapeDecoration(
            color: Oa.card,
            shadows: Oa.restingShadows,
            shape: const SquircleBorder(side: BorderSide(color: Oa.border)),
          ),
          padding: const EdgeInsets.all(4),
          child: ClipPath(
            clipper: const OaSquircleClipper(),
            child: AspectRatio(
              aspectRatio: 0.78,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _MomentVisual(moment: moment),
                  if (deleting) ...[
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0xA6FFFFFF),
                      ),
                    ),
                    const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GallerySkeleton extends StatelessWidget {
  const _GallerySkeleton();

  @override
  Widget build(BuildContext context) {
    Widget tile() => AspectRatio(
          aspectRatio: 0.78,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: Oa.card,
              shape: const SquircleBorder(side: BorderSide(color: Oa.border)),
            ),
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [
              tile(),
              const SizedBox(height: 12),
              tile(),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              const SizedBox(height: 48),
              tile(),
              const SizedBox(height: 12),
              tile(),
            ],
          ),
        ),
      ],
    );
  }
}

class SettingsView extends StatefulWidget {
  const SettingsView({
    required this.device,
    required this.isActive,
    required this.onBack,
    required this.onCapture,
    required this.serverConfig,
    required this.onSaveServerConfig,
    super.key,
  });

  final DeviceController device;
  final bool isActive;
  final VoidCallback onBack;
  final Future<bool> Function() onCapture;
  final ServerConfig serverConfig;
  final ValueChanged<ServerConfig> onSaveServerConfig;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  static const _wifiSsidKey = 'board_wifi_ssid';
  static const _wifiPasswordKey = 'board_wifi_password';

  final _wifiName = TextEditingController();
  final _wifiPassword = TextEditingController();
  final _serverUrl = TextEditingController();
  final _serverToken = TextEditingController();
  final _wifiStorage = FlutterSecureStorage();
  bool _wifiSaved = false;
  bool _wifiSaving = false;
  bool _wifiResetting = false;
  String? _wifiMessage;
  bool? _wifiGood;
  bool _serverSaved = false;
  bool _liveCapture = false;
  bool _capturing = false;

  @override
  void dispose() {
    _wifiName.dispose();
    _wifiPassword.dispose();
    _serverUrl.dispose();
    _serverToken.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _serverUrl.text = widget.serverConfig.url;
    _serverToken.text = widget.serverConfig.token;
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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.device.isConnected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OaIconButton(
                icon: Icons.arrow_back_outlined,
                tooltip: 'Back to Home',
                onPressed: widget.onBack,
              ),
              const SizedBox(width: 4),
              const Text(
                'Settings',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.3,
                  color: Oa.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const OaSectionHeading('Device', 'The keychain camera and its live feed.'),
          const SizedBox(height: 10),
          OaPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: ShapeDecoration(
                        color: connected ? Oa.successText : Oa.dangerText,
                        shape: const CircleBorder(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Keychain camera',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Oa.fg80,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            connected
                                ? '${widget.device.connectionMode == 'station' ? 'Wi-Fi' : 'Setup hotspot'} · ${widget.device.ipAddress ?? 'connected'}'
                                : 'No XIAO connection found',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Oa.mutedFg,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      connected ? 'ONLINE' : 'OFFLINE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                        color: connected ? Oa.successText : Oa.dangerText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                OaButton(
                  label: connected ? 'Check again' : 'Check connection',
                  variant: OaButtonVariant.secondary,
                  expand: true,
                  onPressed: () => unawaited(widget.device.probeConnection()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OaPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Live capture mode',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Oa.fg80,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Show the XIAO camera feed while enabled.',
                            style: TextStyle(fontSize: 12, color: Oa.mutedFg),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OaSwitch(
                      value: _liveCapture,
                      onChanged: (value) =>
                          setState(() => _liveCapture = value),
                    ),
                  ],
                ),
                if (_liveCapture && connected && widget.isActive) ...[
                  const SizedBox(height: 12),
                  _LivePreview(url: widget.device.streamUrl),
                ],
                if (connected && widget.isActive) ...[
                  const SizedBox(height: 12),
                  OaButton(
                    label: 'Take photo from XIAO',
                    loading: _capturing,
                    expand: true,
                    onPressed: _capturing ? null : _capturePhoto,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          const OaSectionHeading('Battery', 'Board power reporting is not wired up yet.'),
          const SizedBox(height: 10),
          const OaPanel(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Board battery',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Oa.fg80,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'No voltage sensor or battery gauge is connected yet.',
                        style: TextStyle(fontSize: 12, color: Oa.mutedFg),
                      ),
                    ],
                  ),
                ),
                Text(
                  'UNAVAILABLE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5,
                    color: Oa.mutedFg,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const OaSectionHeading('Board Wi-Fi', 'Provision the board onto your home network.'),
          const SizedBox(height: 10),
          if (_wifiMessage != null) ...[
            OaNoticeStrip(
              claim: _wifiMessage!,
              sentence: _wifiSentence,
            ),
            const SizedBox(height: 10),
          ],
          OaPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Wi-Fi password',
                    hintText: 'Password',
                  ),
                  onChanged: (_) => setState(() {
                    _wifiSaved = false;
                    _wifiMessage = null;
                  }),
                ),
                const SizedBox(height: 12),
                OaButton(
                  label: _wifiSaving
                      ? 'Saving to board…'
                      : _wifiSaved
                          ? 'Saved on board'
                          : 'Save Wi-Fi details',
                  loading: _wifiSaving,
                  expand: true,
                  onPressed:
                      _wifiName.text.trim().isEmpty || _wifiSaving || _wifiSaved
                          ? null
                          : _saveWifi,
                ),
                const SizedBox(height: 8),
                OaButton(
                  label: 'Reset board Wi-Fi',
                  variant: OaButtonVariant.secondary,
                  loading: _wifiResetting,
                  expand: true,
                  onPressed: !connected || _wifiSaving || _wifiResetting
                      ? null
                      : _resetWifi,
                ),
                const SizedBox(height: 8),
                const Text(
                  'The board will reboot and use these credentials next time. Reconnect your phone to the same Wi-Fi, then check the connection.',
                  style: TextStyle(fontSize: 12, height: 1.45, color: Oa.mutedFg),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const OaSectionHeading('Server', 'Photos upload here right after capture.'),
          const SizedBox(height: 10),
          OaPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _serverUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'http://your-server:8400',
                  ),
                  onChanged: (_) => setState(() => _serverSaved = false),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _serverToken,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Access token',
                    hintText: 'Shared secret',
                  ),
                  onChanged: (_) => setState(() => _serverSaved = false),
                ),
                const SizedBox(height: 12),
                OaButton(
                  label: _serverSaved ? 'Saved on this phone' : 'Save server details',
                  expand: true,
                  onPressed: _serverUrl.text.trim().isEmpty ||
                          _serverToken.text.trim().isEmpty ||
                          _serverSaved
                      ? null
                      : () {
                          widget.onSaveServerConfig(
                            ServerConfig(
                              url: _serverUrl.text.trim(),
                              token: _serverToken.text.trim(),
                            ),
                          );
                          setState(() => _serverSaved = true);
                        },
                ),
                const SizedBox(height: 8),
                Text(
                  _serverConfigStatus,
                  style: const TextStyle(
                      fontSize: 12, height: 1.45, color: Oa.mutedFg),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _serverConfigStatus {
    final configured =
        _serverUrl.text.trim().isNotEmpty && _serverToken.text.trim().isNotEmpty;
    return configured
        ? 'New captures are processed on the server and shown as Treated.'
        : 'Add a URL and token to upload captures for processing.';
  }

  String get _wifiSentence {
    switch ('$_wifiMessage|$_wifiGood') {
      case _saveFail:
        return 'Keep the phone connected to CLIPPY-XIAO and try again.';
      case _saveOkBoth:
        return 'The board will reboot now.';
      case _saveOkBoard:
        return 'This phone could not store the details.';
      case _resetFail:
        return 'Check the connection and try again.';
      case _resetOkBoth:
        return 'It will restart in setup-hotspot mode.';
      default:
        return 'This phone could not clear its saved details.';
    }
  }

  static const _saveFail = 'Could not save Wi-Fi credentials.|false';
  static const _saveOkBoth = 'Saved on the board and this phone.|true';
  static const _saveOkBoard = 'Saved on the board.|false';
  static const _resetFail = 'Could not reset the board.|false';
  static const _resetOkBoth = 'Board Wi-Fi was reset.|true';

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
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _wifiSaving = false;
      _wifiSaved = saved;
      _wifiGood = saved;
      _wifiMessage = !saved
          ? 'Could not save Wi-Fi credentials.'
          : storedOnPhone
              ? 'Saved on the board and this phone.'
              : 'Saved on the board.';
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
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _wifiResetting = false;
      _wifiSaved = false;
      if (reset) {
        _wifiName.clear();
        _wifiPassword.clear();
      }
      _wifiGood = reset;
      _wifiMessage = !reset
          ? 'Could not reset the board.'
          : clearedOnPhone
              ? 'Board Wi-Fi was reset.'
              : 'Board Wi-Fi was reset.';
    });
  }

  Future<void> _capturePhoto() async {
    setState(() => _capturing = true);
    final captured = await widget.onCapture();
    if (!mounted) return;
    setState(() => _capturing = false);
    OaToast.show(
      context,
      good: captured,
      message: captured
          ? 'Captured from XIAO and added to Home.'
          : 'Could not capture from the XIAO.',
    );
  }
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
    this.remoteId,
  });

  final String id;
  final DateTime capturedAt;
  final Uint8List? originalBytes;
  final Uint8List? treatedBytes;
  final String? originalAsset;
  final String? treatedAsset;
  final String? originalPath;
  final String? treatedPath;
  final String? remoteId;

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
      remoteId: remoteId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'capturedAt': capturedAt.toIso8601String(),
        if (originalAsset != null) 'originalAsset': originalAsset,
        if (treatedAsset != null) 'treatedAsset': treatedAsset,
        if (originalPath != null) 'originalPath': originalPath,
        if (treatedPath != null) 'treatedPath': treatedPath,
        if (remoteId != null) 'remoteId': remoteId,
      };

  factory LocalMoment.fromJson(Map<String, dynamic> json) {
    return LocalMoment(
      id: json['id'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String),
      originalAsset: json['originalAsset'] as String?,
      treatedAsset: json['treatedAsset'] as String?,
      originalPath: json['originalPath'] as String?,
      treatedPath: json['treatedPath'] as String?,
      remoteId: json['remoteId'] as String?,
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
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Column(
            children: [
              Row(
                children: [
                  OaIconButton(
                    icon: Icons.arrow_back_outlined,
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: OaSegmented(
                      labels: const ['Original', 'Treated'],
                      index: _showTreated ? 1 : 0,
                      onChanged: (index) =>
                          setState(() => _showTreated = index == 1),
                    ),
                  ),
                  const SizedBox(width: 4),
                  OaIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete',
                    danger: true,
                    onPressed: _delete,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  decoration: ShapeDecoration(
                    color: Oa.card,
                    shadows: Oa.restingShadows,
                    shape: const SquircleBorder(
                      side: BorderSide(color: Oa.border),
                    ),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: ClipPath(
                    clipper: const OaSquircleClipper(),
                    child: Container(
                      color: Oa.stage,
                      width: double.infinity,
                      child: _MomentVisual(
                        moment: widget.moment,
                        showTreated: _showTreated,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _showTreated ? 'Treated image' : 'Original image',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: Oa.fg80,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Uploaded ${_formatMomentDate(widget.moment.capturedAt)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Oa.mutedFg,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.moment.remoteId == null
                          ? 'Processed on this phone'
                          : 'Processed on server · ${widget.moment.remoteId}',
                      style: const TextStyle(fontSize: 12, color: Oa.mutedFg),
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
    final confirmed = await OaModal.show(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Delete this photo?',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.2,
              color: Oa.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.moment.remoteId == null
                ? 'This removes it from this phone.'
                : 'This removes it from the server and every device.',
            style: const TextStyle(fontSize: 13, height: 1.45, color: Oa.mutedFg),
          ),
          OaModalFooter(
            backLabel: 'Back',
            actionLabel: 'Delete photo',
            destructive: true,
            onBack: () => Navigator.pop(context, false),
            onAction: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed && mounted) Navigator.pop(context, true);
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
    final errorWidget = Center(
      child: Icon(Icons.broken_image_outlined, color: Oa.mutedFg),
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

class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          color: Oa.stage,
          shadows: Oa.restingShadows,
          shape: SquircleBorder(radius: Oa.insetRadius, handle: Oa.insetHandle),
        ),
        child: ClipPath(
          clipper: const OaSquircleClipper(),
          child: MjpegView(url: url, enabled: true),
        ),
      ),
    );
  }
}
