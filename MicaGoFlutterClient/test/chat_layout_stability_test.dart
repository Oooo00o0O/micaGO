import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mica_go/core/network/api_client.dart';
import 'package:mica_go/core/storage/media_cache.dart';
import 'package:mica_go/features/chats/attachment_views.dart';
import 'package:mica_go/features/chats/chat_composer_input.dart';
import 'package:mica_go/features/chats/message_transfer_frame.dart';
import 'package:mica_go/features/chats/models/message_model.dart';

Future<Uint8List> _portrait() async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 40, 80), Paint()..color = Colors.red);
  final picture = recorder.endRecording();
  final image = await picture.toImage(40, 80);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('pending image keeps its frame throughout server confirmation', (
    tester,
  ) async {
    late Uint8List bytes;
    await tester.runAsync(() async {
      bytes = await _portrait();
    });
    final cache = MediaCache.instance;
    cache.pinLocal('local-layout', bytes);
    cache.rememberAspectRatio('local-layout', 0.5);
    final response = Completer<http.Response>();
    final api = ApiClient(
      baseUrl: 'http://localhost',
      token: 'test',
      httpClient: MockClient((_) => response.future),
    );
    Widget host(String guid, {bool uploading = false}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: MessageTransferFrame(
            overlay: uploading ? const SizedBox(width: 500, height: 500) : null,
            child: AttachmentView(
              key: const ValueKey('same-message-media'),
              api: api,
              attachment: AttachmentModel(
                guid: guid,
                downloadUrl: '/api/attachments/$guid',
                filename: 'photo.png',
                mimeType: 'image/png',
                attachmentKind: 'image',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host('local-layout', uploading: true));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final original = tester.getSize(find.byType(AttachmentView));
    expect(original, const Size(153, 306));
    expect(tester.getSize(find.byType(MessageTransferFrame)), original);
    final element = tester.element(find.byType(AttachmentView));
    await tester.pumpWidget(host('local-layout'));
    expect(tester.element(find.byType(AttachmentView)), same(element));
    expect(tester.getSize(find.byType(MessageTransferFrame)), original);
    await tester.pumpWidget(host('confirmed-layout'));
    expect(tester.element(find.byType(AttachmentView)), same(element));
    expect(tester.getSize(find.byType(AttachmentView)), original);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    expect(cache.memoryHit('thumb:v1:confirmed-layout'), isNull);
    response.complete(http.Response.bytes(bytes, 200));
    for (final delay in [0, 16, 80, 220]) {
      await tester.pump(Duration(milliseconds: delay));
      expect(tester.getSize(find.byType(AttachmentView)), original);
    }
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedSize), findsNothing);
    expect(tester.takeException(), isNull);
    cache.unpinLocal('local-layout');
  });

  testWidgets(
    'known image ratio reserves the final frame before bytes arrive',
    (tester) async {
      late Uint8List bytes;
      await tester.runAsync(() async {
        bytes = await _portrait();
      });
      final response = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: 'http://localhost',
        token: 'test',
        httpClient: MockClient((_) => response.future),
      );
      MediaCache.instance.rememberAspectRatio('thumb:v1:known-layout', 0.5);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AttachmentView(
                api: api,
                attachment: const AttachmentModel(
                  guid: 'known-layout',
                  downloadUrl: '/api/attachments/known-layout',
                  filename: 'portrait.png',
                  mimeType: 'image/png',
                  attachmentKind: 'image',
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AttachmentView)), const Size(153, 306));
      response.complete(http.Response.bytes(bytes, 200));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(AttachmentView)), const Size(153, 306));
      expect(tester.takeException(), isNull);
    },
  );

  for (final height in [48.0, 52.0]) {
    testWidgets('composer line is centered in a $height pill', (tester) async {
      final controller = TextEditingController(text: '测试 Hello');
      final focus = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const ValueKey('pill'),
                width: 300,
                height: height,
                child: Row(
                  children: [
                    Expanded(
                      child: ChatComposerInput(
                        controller: controller,
                        focusNode: focus,
                        textColor: Colors.black,
                        hintColor: Colors.grey,
                        cursorColor: Colors.blue,
                        hint: 'iMessage',
                        onContentInserted: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final caret = editable.getLocalRectForCaret(
        const TextPosition(offset: 0),
      );
      final caretCenter = editable.localToGlobal(caret.center).dy;
      final pillCenter = tester
          .getCenter(find.byKey(const ValueKey('pill')))
          .dy;
      expect(caretCenter, closeTo(pillCenter, 2));
      await tester.enterText(find.byType(TextField), '第一行\n第二行');
      await tester.pump();
      expect(controller.text, '第一行\n第二行');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      focus.dispose();
    });
  }
}
