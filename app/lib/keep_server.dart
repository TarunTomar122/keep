import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

const kDefaultServerUrl = String.fromEnvironment(
  'KEEP_SERVER_URL',
  defaultValue: 'http://144.217.6.112:8400',
);
const kDefaultServerToken = String.fromEnvironment('KEEP_SERVER_TOKEN');

class ServerConfig {
  const ServerConfig({required this.url, required this.token});

  final String url;
  final String token;

  bool get isConfigured => url.trim().isNotEmpty && token.trim().isNotEmpty;
}

class ServerConfigStore {
  static const _urlKey = 'server_url';
  static const _tokenKey = 'server_token';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<ServerConfig> load() async {
    try {
      final values = await Future.wait([
        _storage.read(key: _urlKey),
        _storage.read(key: _tokenKey),
      ]);
      return ServerConfig(
        url: values[0]?.trim().isNotEmpty == true ? values[0]! : kDefaultServerUrl,
        token: values[1] ?? kDefaultServerToken,
      );
    } catch (_) {
      return ServerConfig(url: kDefaultServerUrl, token: kDefaultServerToken);
    }
  }

  Future<void> save(ServerConfig config) async {
    await _storage.write(key: _urlKey, value: config.url.trim());
    await _storage.write(key: _tokenKey, value: config.token.trim());
  }
}

class UploadedMoment {
  const UploadedMoment({required this.id, required this.processedBytes});

  final String id;
  final Uint8List processedBytes;
}

class RemoteMoment {
  const RemoteMoment({
    required this.id,
    required this.createdAt,
    required this.originalUrl,
    required this.processedUrl,
  });

  final String id;
  final DateTime createdAt;
  final String originalUrl;
  final String processedUrl;
}

class ServerImageCache {
  Directory? _cacheDir;

  Future<String?> pathFor(String key) async {
    try {
      final directory = await _ensureDir();
      final file = File('${directory.path}/$key');
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> put(String key, Uint8List bytes) async {
    final directory = await _ensureDir();
    final file = File('${directory.path}/$key');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> removeForId(String id) async {
    final prefix = '$id-';
    try {
      final directory = await _ensureDir();
      await for (final entity in directory.list()) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith(prefix)) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}
  }

  Future<Directory> _ensureDir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/server_images');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _cacheDir = dir;
  }
}

class KeepServerClient {
  KeepServerClient({required this.config});

  final ServerConfig config;

  Uri _uri(String path) => Uri.parse(config.url.trim()).replace(path: path);

  Future<List<RemoteMoment>> listPhotos() async {
    final payload = await _requestJson('GET', _uri('/photos'));
    if (payload is! List) {
      throw const FormatException('Unexpected photos response');
    }
    final photos = <RemoteMoment>[];
    for (final item in payload) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id'] as String?;
      final originalUrl = item['original_url'] as String?;
      final processedUrl = item['processed_url'] as String?;
      if (id == null || originalUrl == null || processedUrl == null) continue;
      final createdAtRaw = item['created_at'];
      photos.add(
        RemoteMoment(
          id: id,
          createdAt: createdAtRaw is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  (createdAtRaw * 1000).round(),
                )
              : DateTime.now(),
          originalUrl: originalUrl,
          processedUrl: processedUrl,
        ),
      );
    }
    return photos;
  }

  Future<void> deletePhoto(String momentId) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl('DELETE', _uri('/photos/$momentId'));
      request.headers.set(HttpHeaders.authorizationHeader,
          'Bearer ${config.token.trim()}');
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Delete failed (${response.statusCode})');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> fetchBytes(String path) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final base = Uri.parse(config.url.trim());
      final relative = path.startsWith('/') ? path.substring(1) : path;
      final request = await client.getUrl(base.resolve(relative));
      request.headers.set(HttpHeaders.authorizationHeader,
          'Bearer ${config.token.trim()}');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download failed (${response.statusCode})');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<dynamic> _requestJson(String method, Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.authorizationHeader,
          'Bearer ${config.token.trim()}');
      final response = await request.close();
      final payload = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('$method ${uri.path} failed (${response.statusCode})');
      }
      return jsonDecode(payload);
    } finally {
      client.close(force: true);
    }
  }

  Future<UploadedMoment> upload(Uint8List imageBytes) async {
    final boundary = 'keep-boundary-${DateTime.now().microsecondsSinceEpoch}';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(_uri('/upload'));
      request.headers.set(HttpHeaders.authorizationHeader,
          'Bearer ${config.token.trim()}');
      request.headers.set(HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary');
      final header = utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="photo"; filename="capture.jpg"\r\n'
        'Content-Type: image/jpeg\r\n\r\n',
      );
      final footer = utf8.encode('\r\n--$boundary--\r\n');
      request.headers.contentLength =
          header.length + imageBytes.length + footer.length;
      request.add(header);
      request.add(imageBytes);
      request.add(footer);

      final response = await request.close();
      final payload = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Upload failed (${response.statusCode})');
      }
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected upload response');
      }
      final processedUrl = decoded['processed_url'] as String?;
      final id = decoded['id'] as String? ?? '';
      if (processedUrl == null) {
        throw const FormatException('Missing processed_url');
      }
      final processedBytes = await fetchBytes(processedUrl);
      return UploadedMoment(id: id, processedBytes: processedBytes);
    } finally {
      client.close(force: true);
    }
  }
}
