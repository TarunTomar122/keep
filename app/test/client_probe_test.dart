import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:clippy_companion/keep_server.dart';

void main() {
  test('KeepServerClient.upload round-trips against a local server',
      () async {
    HttpOverrides.global = null;
    final processed = Uint8List.fromList(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST' && request.uri.path == '/upload') {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'id': 'srv-9',
          'processed_url': '/photos/srv-9/processed.png',
        }));
        await request.response.close();
      } else {
        request.response.add(processed);
        await request.response.close();
      }
    });
    addTearDown(() => server.close(force: true));

    final client = KeepServerClient(
      config: ServerConfig(
        url: 'http://127.0.0.1:${server.port}',
        token: 'tok',
      ),
    );
    final result = await client.upload(
      Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 3))),
    );
    expect(result.id, 'srv-9');
    expect(result.processedBytes.length, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('listPhotos and deletePhoto round-trip against a local server',
      () async {
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var deleted = false;
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer tok',
      );
      if (request.method == 'GET' && request.uri.path == '/photos') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode([
          {
            'id': '20260821-101010-abc123',
            'created_at': 1755775000,
            'original_url': '/photos/20260821-101010-abc123/original.jpg',
            'processed_url': '/photos/20260821-101010-abc123/processed.png',
          },
          {
            'id': '20260821-102020-def456',
            'created_at': 1755775320,
            'original_url': '/photos/20260821-102020-def456/original.jpg',
            'processed_url': '/photos/20260821-102020-def456/processed.png',
          },
        ]));
        await request.response.close();
      } else if (request.method == 'DELETE' &&
          request.uri.path == '/photos/20260821-101010-abc123') {
        deleted = true;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'deleted': request.uri.path}));
        await request.response.close();
      } else {
        fail('unexpected ${request.method} ${request.uri}');
      }
    });
    addTearDown(() => server.close(force: true));

    final client = KeepServerClient(
      config: ServerConfig(
        url: 'http://127.0.0.1:${server.port}',
        token: 'tok',
      ),
    );

    final photos = await client.listPhotos();
    expect(photos, hasLength(2));
    expect(photos[0].id, '20260821-101010-abc123');
    expect(photos[1].processedUrl, '/photos/20260821-102020-def456/processed.png');
    expect(photos[1].createdAt.isBefore(DateTime.now()), isTrue);

    await client.deletePhoto('20260821-101010-abc123');
    expect(deleted, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
