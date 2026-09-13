import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/chats/thread_controller.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/storage/local_cache_store.dart';
import 'package:mica_go/features/chats/models/message_model.dart';
import 'package:mica_go/features/chats/store/message_collection.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MessageModel pending(String id, {String chat = 'chat-a'}) =>
    MessageModel.optimistic(
      tempId: id,
      text: 'hello',
      dateCreated: 100000,
    ).copyWith(chatGuid: chat);
MessageModel server(String id) => MessageModel(
  guid: id,
  chatGuid: 'chat-a',
  text: 'hello',
  isFromMe: true,
  dateCreated: 100500,
);

class TestStore implements SecureStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestApp extends AppController {
  TestApp(this.client) : super(store: TestStore());
  final ApiClient client;
  @override
  ApiClient get api => client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('micago-send-tests-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  tearDownAll(() => directory.delete(recursive: true));
  test('manual text retry removes the original failed cache row', () async {
    var reject = true;
    final client = ApiClient(
      baseUrl: 'http://test',
      token: 'test',
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response('{"data":[],"hasMore":false}', 200);
        }
        if (reject) {
          return http.Response(
            '{"error":{"code":"send_failed","message":"Rejected"}}',
            500,
          );
        }
        return http.Response(
          jsonEncode({
            'guid': 'retry-confirmed',
            'chatGuid': 'chat-a',
            'text': 'hello',
            'isFromMe': true,
            'dateCreated': DateTime.now().millisecondsSinceEpoch,
          }),
          200,
        );
      }),
    );
    final app = TestApp(client);
    final controller = ThreadController(app: app, chatGuid: 'chat-a');
    await app.cache.open();
    await app.cache.clearAll();
    try {
      await controller.send('hello');
      final failed = controller.messages.single;
      expect(failed.localState, LocalSendState.failed);
      reject = false;
      await controller.retry(failed.tempId!);
      expect(controller.messages, hasLength(1));
      final cached = await app.cache.listMessages('chat-a');
      expect(cached, hasLength(1));
      expect(cached.single.guid, 'retry-confirmed');
    } finally {
      controller.dispose();
      client.close();
      await app.cache.clearAll();
      await app.cache.close();
      app.dispose();
    }
  });
  test(
    'transport uncertainty is distinct from rejection and server acceptance',
    () {
      for (final code in ['timeout', 'network_error', 'bad_response']) {
        expect(
          ApiException(code: code, message: '').sendState,
          LocalSendState.pending,
        );
      }
      expect(
        const ApiException(
          code: 'send_confirmation_timeout',
          message: '',
        ).sendState,
        LocalSendState.sentUnconfirmed,
      );
      expect(
        const ApiException(code: 'send_failed', message: '').sendState,
        LocalSendState.failed,
      );
    },
  );
  test(
    'late confirmation survives a stale cache snapshot and duplicate events',
    () {
      final col = MessageCollection()..addPending(pending('first'));
      col.setPendingState('first', LocalSendState.failed);
      col.upsertServer(server('confirmed'));
      col.mergeServerPage([
        pending('first').copyWith(localState: LocalSendState.failed),
      ]);
      expect(col.length, 1);
      col.addPending(pending('second'));
      col.upsertServer(server('confirmed'));
      expect(col.pendingByTempId('second'), isNotNull);
      expect(col.presentationKeyFor(server('confirmed')), 'first');
    },
  );
  test('failed sends only reconcile within their route', () {
    expect(
      shouldReconcileLocalWithServer(pending('a', chat: 'chat-b'), server('s')),
      false,
    );
  });
  test(
    'fresh REST confirmation can match a unique uncertain converted upload',
    () {
      final local = MessageModel.optimisticAttachment(
        tempId: 'upload',
        filename: 'clip.mov',
        totalBytes: 100,
        dateCreated: 100000,
      ).copyWith(localState: LocalSendState.pending);
      final confirmed = MessageModel(
        guid: 'video',
        isFromMe: true,
        dateCreated: 110000,
        attachments: [
          AttachmentModel(
            guid: 'video-file',
            downloadUrl: '/api/attachments/video-file',
            transferName: 'converted.mp4',
            totalBytes: 200,
          ),
        ],
      );
      final col = MessageCollection()..addPending(local);
      col.mergeServerPage([confirmed], allowNewAttachmentFallback: true);
      expect(col.length, 1);
      expect(col.presentationKeyFor(confirmed), 'upload');
    },
  );
  test(
    'cache confirms failed rows atomically and rejects a late failure write',
    () async {
      final cache = LocalCacheStore();
      await cache.open();
      await cache.clearAll();
      try {
        await cache.addPending('chat-a', pending('first'));
        await cache.setPendingState('first', LocalSendState.failed);
        await cache.mergeServerPage('chat-a', [server('confirmed')]);
        await cache.setPendingState('first', LocalSendState.failed);
        await cache.addPending('chat-a', pending('first'));
        await cache.close();
        await cache.open();
        final rows = await cache.listMessages('chat-a');
        expect(rows, hasLength(1));
        expect(rows.single.guid, 'confirmed');
        expect(rows.single.localState, LocalSendState.confirmed);
        await cache.addPending('chat-a', pending('second'));
        await cache.upsertMessage('chat-a', server('confirmed'));
        expect(await cache.listMessages('chat-a'), hasLength(2));
        await cache.upsertMessage('chat-a', server('second-server'));
        expect(
          (await cache.listMessages('chat-a')).every((m) => m.guid.isNotEmpty),
          true,
        );
      } finally {
        await cache.clearAll();
        await cache.close();
      }
    },
  );
}
