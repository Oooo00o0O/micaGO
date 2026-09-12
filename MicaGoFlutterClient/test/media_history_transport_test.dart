import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/features/chats/attachment_panel.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

void main() {
  test(
    'merged history sends repeated routes and opaque cursor unchanged',
    () async {
      final api = ApiClient(
        baseUrl: 'http://localhost',
        token: 'test',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/messages/history');
          expect(request.url.queryParametersAll['chatGuid'], [
            'route-a',
            'route-b',
          ]);
          expect(request.url.queryParameters['before'], 'abc+/=');
          return http.Response(
            jsonEncode({
              'data': [
                {'guid': 'm', 'chatGuid': 'route-b'},
              ],
              'nextCursor': 'next',
              'hasMore': true,
            }),
            200,
          );
        }),
      );
      final page = await api.getMessageHistory([
        'route-a',
        'route-b',
        'route-a',
      ], before: 'abc+/=');
      expect(page.messages.single.chatGuid, 'route-b');
      expect(page.nextCursor, 'next');
      expect(page.hasMore, isTrue);
    },
  );

  test('history rejects a missing continuation cursor', () async {
    final api = ApiClient(
      baseUrl: 'http://localhost',
      token: 'test',
      httpClient: MockClient(
        (_) async => http.Response('{"data":[],"hasMore":true}', 200),
      ),
    );
    await expectLater(
      api.getMessageHistory(['route']),
      throwsA(isA<ApiException>()),
    );
  });

  test('text accepted without DB confirmation stays pending', () async {
    final api = ApiClient(
      baseUrl: 'http://localhost',
      token: 'test',
      httpClient: MockClient(
        (_) async => http.Response('{"state":"sent_unconfirmed"}', 202),
      ),
    );
    await expectLater(
      api.sendText(chatGuid: 'route', tempGuid: 'temp', message: 'hello'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'send_confirmation_timeout',
        ),
      ),
    );
  });

  test(
    'file-backed attachment sends multipart without staging original bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'micago-upload-test-',
      );
      try {
        final file = File('${directory.path}/document.txt');
        await file.writeAsString('streamed content');
        final staged = StagedAttachment.file(
          path: file.path,
          size: await file.length(),
          filename: 'document.txt',
        );
        expect(staged.bytes, isNull);
        final api = ApiClient(
          baseUrl: 'http://localhost',
          token: 'test',
          httpClient: MockClient((request) async {
            expect(
              request.headers['content-type'],
              startsWith('multipart/form-data'),
            );
            expect(request.body, contains('streamed content'));
            expect(request.body, contains('filename="document.txt"'));
            return http.Response('{"filename":"document.txt"}', 202);
          }),
        );
        expect(
          await api.sendAttachment(
            chatGuid: 'route',
            tempGuid: 'temp',
            filePath: staged.path,
            filename: staged.filename,
          ),
          'document.txt',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('failed thumbnail never triggers original download', () async {
    final seen = <Uri>[];
    final api = ApiClient(
      baseUrl: 'http://localhost',
      token: 'test',
      httpClient: MockClient((request) async {
        seen.add(request.url);
        return http.Response('unavailable', 503);
      }),
    );
    await expectLater(
      api.getAttachmentThumbnailBytes(
        const AttachmentModel(
          guid: 'photo',
          downloadUrl: '/api/attachments/photo',
          filename: 'photo.jpg',
        ),
      ),
      throwsA(isA<ApiException>()),
    );
    expect(seen, hasLength(1));
    expect(seen.single.queryParameters['thumbnail'], '1');
  });

  test('local preview and original have separate sources', () async {
    final cache = MediaCache.instance;
    final preview = Uint8List.fromList([1]);
    final original = Uint8List.fromList([2, 3]);
    var reads = 0;
    cache.registerLocal(
      'local-test-source',
      preview: preview,
      loadPreview: () async => preview,
      loadOriginal: () async {
        reads++;
        return original;
      },
    );
    final api = ApiClient(
      baseUrl: 'http://localhost',
      token: 'test',
      httpClient: MockClient(
        (_) async => throw StateError('must not fetch local guid'),
      ),
    );
    expect(cache.memoryHit('local-test-source'), same(preview));
    expect(
      await cache.attachmentFull(api, 'local-test-source'),
      same(original),
    );
    expect(reads, 1);
    cache.unpinLocal('local-test-source');
    await expectLater(
      cache.attachmentFull(api, 'local-test-source'),
      throwsStateError,
    );
  });

  test('viewer requests run before queued background previews', () async {
    final cache = MediaCache.instance;
    final blockers = List.generate(4, (_) => Completer<Uint8List>());
    final entered = Completer<void>();
    var active = 0;
    final running = List.generate(
      4,
      (i) => cache.load('queue-blocker-$i', () {
        if (++active == 4) entered.complete();
        return blockers[i].future;
      }),
    );
    await entered.future;
    final order = <String>[];
    final background = cache.load('queue-background', () async {
      order.add('background');
      return Uint8List.fromList([1]);
    });
    final foreground = cache.load('queue-viewer', () async {
      order.add('viewer');
      return Uint8List.fromList([1]);
    }, urgent: true);
    for (final blocker in blockers) {
      blocker.complete(Uint8List.fromList([1]));
    }
    await Future.wait([...running, background, foreground]);
    expect(order, ['viewer', 'background']);
  });
}
