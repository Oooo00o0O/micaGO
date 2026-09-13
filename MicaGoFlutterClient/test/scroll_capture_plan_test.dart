import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/platform/scroll_capture_service.dart';

ScrollCaptureTile tileFor({
  required double initialPixels,
  required double maxScrollExtent,
  required bool reversed,
  required double devicePixelRatio,
  required int boundsHeight,
  required int requestTop,
}) {
  final pixels = scrollCaptureTargetPixels(
    initialPixels: initialPixels,
    minScrollExtent: 0,
    maxScrollExtent: maxScrollExtent,
    reversed: reversed,
    devicePixelRatio: devicePixelRatio,
    requestTop: requestTop,
  );
  return scrollCaptureTile(
    initialPixels: initialPixels,
    pixels: pixels,
    reversed: reversed,
    devicePixelRatio: devicePixelRatio,
    boundsHeight: boundsHeight,
    requestTop: requestTop,
    requestBottom: requestTop + boundsHeight,
  );
}

void main() {
  group('scroll capture tiles', () {
    test('the tile at the start position needs no scroll', () {
      final tile = tileFor(
        initialPixels: 100,
        maxScrollExtent: 5000,
        reversed: false,
        devicePixelRatio: 2,
        boundsHeight: 1000,
        requestTop: 0,
      );
      expect(tile.toMap(), {
        'capturedTop': 0,
        'capturedBottom': 1000,
        'viewportTop': 0,
      });
    });

    test('a forward list scrolls down for tiles below the start', () {
      final pixels = scrollCaptureTargetPixels(
        initialPixels: 100,
        minScrollExtent: 0,
        maxScrollExtent: 5000,
        reversed: false,
        devicePixelRatio: 2,
        requestTop: 1000,
      );
      expect(pixels, 600);
      final tile = tileFor(
        initialPixels: 100,
        maxScrollExtent: 5000,
        reversed: false,
        devicePixelRatio: 2,
        boundsHeight: 1000,
        requestTop: 1000,
      );
      expect(tile.capturedTop, 1000);
      expect(tile.capturedBottom, 2000);
    });

    test('a reversed thread scrolls toward older messages for tiles above', () {
      final pixels = scrollCaptureTargetPixels(
        initialPixels: 0,
        minScrollExtent: 0,
        maxScrollExtent: 5000,
        reversed: true,
        devicePixelRatio: 2,
        requestTop: -1000,
      );
      expect(pixels, 500);
      final tile = tileFor(
        initialPixels: 0,
        maxScrollExtent: 5000,
        reversed: true,
        devicePixelRatio: 2,
        boundsHeight: 1000,
        requestTop: -1000,
      );
      expect(tile.toMap(), {
        'capturedTop': -1000,
        'capturedBottom': 0,
        'viewportTop': -1000,
      });
    });

    test('content running out gives a partial tile, then an empty one', () {
      final partial = tileFor(
        initialPixels: 0,
        maxScrollExtent: 300,
        reversed: false,
        devicePixelRatio: 2,
        boundsHeight: 1000,
        requestTop: 1000,
      );
      expect((partial.capturedTop, partial.capturedBottom), (1000, 1600));

      final done = tileFor(
        initialPixels: 0,
        maxScrollExtent: 300,
        reversed: false,
        devicePixelRatio: 2,
        boundsHeight: 1000,
        requestTop: 1600,
      );
      expect(done.isEmpty, isTrue);

      final oldestPartial = tileFor(
        initialPixels: 0,
        maxScrollExtent: 250,
        reversed: true,
        devicePixelRatio: 2,
        boundsHeight: 1000,
        requestTop: -1000,
      );
      expect((oldestPartial.capturedTop, oldestPartial.capturedBottom), (
        -500,
        0,
      ));
    });

    test('adjacent tiles meet exactly at a fractional device pixel ratio', () {
      const dpr = 2.625;
      final first = tileFor(
        initialPixels: 0,
        maxScrollExtent: 20000,
        reversed: true,
        devicePixelRatio: dpr,
        boundsHeight: 2000,
        requestTop: -2000,
      );
      final second = tileFor(
        initialPixels: 0,
        maxScrollExtent: 20000,
        reversed: true,
        devicePixelRatio: dpr,
        boundsHeight: 2000,
        requestTop: -4000,
      );
      expect((first.capturedTop, first.capturedBottom), (-2000, 0));
      expect((second.capturedTop, second.capturedBottom), (-4000, -2000));
    });
  });
}
