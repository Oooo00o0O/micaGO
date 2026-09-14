import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android 12+ "Capture more" (scrolling screenshot) support.
///
/// Flutter renders into a single surface, so the system's scroll-capture search
/// finds no native scrollable view. `MainActivity` installs a
/// `ScrollCaptureCallback` on the FlutterView that calls into this service to
/// locate the active list, scroll it one tile at a time, and learn which pixels
/// each tile covers; the native side copies those pixels.
///
/// Vertical values on the channel are physical pixels relative to the capture
/// bounds' top at the moment the capture started (negative = above it).
@immutable
class ScrollCaptureTile {
  const ScrollCaptureTile({
    required this.capturedTop,
    required this.capturedBottom,
    required this.viewportTop,
  });

  static const empty = ScrollCaptureTile(
    capturedTop: 0,
    capturedBottom: 0,
    viewportTop: 0,
  );

  final int capturedTop;
  final int capturedBottom;

  /// Where the bounds' top currently sits, in the same capture-relative space.
  final int viewportTop;

  bool get isEmpty => capturedBottom <= capturedTop;

  Map<String, int> toMap() => {
    'capturedTop': capturedTop,
    'capturedBottom': capturedBottom,
    'viewportTop': viewportTop,
  };
}

/// Scroll offset that brings [requestTop] to the top of the capture bounds,
/// clamped to the scrollable range.
double scrollCaptureTargetPixels({
  required double initialPixels,
  required double minScrollExtent,
  required double maxScrollExtent,
  required bool reversed,
  required double devicePixelRatio,
  required int requestTop,
}) {
  final direction = reversed ? -1.0 : 1.0;
  final target = initialPixels + direction * requestTop / devicePixelRatio;
  return clampDouble(target, minScrollExtent, maxScrollExtent);
}

/// The part of the requested tile that is on screen once the list sits at
/// [pixels]. Empty when the list could not scroll far enough (content ended).
ScrollCaptureTile scrollCaptureTile({
  required double initialPixels,
  required double pixels,
  required bool reversed,
  required double devicePixelRatio,
  required int boundsHeight,
  required int requestTop,
  required int requestBottom,
}) {
  final direction = reversed ? -1.0 : 1.0;
  final viewportTop = ((pixels - initialPixels) * direction * devicePixelRatio)
      .round();
  final top = math.max(requestTop, viewportTop);
  final bottom = math.min(requestBottom, viewportTop + boundsHeight);
  if (bottom <= top) {
    return ScrollCaptureTile(
      capturedTop: 0,
      capturedBottom: 0,
      viewportTop: viewportTop,
    );
  }
  return ScrollCaptureTile(
    capturedTop: top,
    capturedBottom: bottom,
    viewportTop: viewportTop,
  );
}

/// A list that may be captured. Insets are logical pixels at the viewport's top
/// and bottom covered by overlays that must not repeat in every stitched tile.
class ScrollCaptureRegistration {
  ScrollCaptureRegistration._(this.controller, this._topInset, this._bottomInset);

  final ScrollController controller;
  final double Function()? _topInset;
  final double Function()? _bottomInset;

  void dispose() => ScrollCaptureService._targets.remove(this);
}

class ScrollCaptureService {
  ScrollCaptureService._();

  static const MethodChannel _channel = MethodChannel('micago/scroll_capture');

  /// True while a scrolling screenshot is in progress. Floating controls that
  /// would otherwise be stitched into every tile hide while this is set.
  static final ValueNotifier<bool> capturing = ValueNotifier<bool>(false);

  static final List<ScrollCaptureRegistration> _targets = [];
  static _CaptureSession? _session;
  static bool _started = false;

  /// The most recently registered visible list wins, so an open thread beats
  /// the chat list beside it in the two-pane layout.
  static ScrollCaptureRegistration register(
    ScrollController controller, {
    double Function()? topInset,
    double Function()? bottomInset,
  }) {
    _start();
    final registration = ScrollCaptureRegistration._(
      controller,
      topInset,
      bottomInset,
    );
    _targets.add(registration);
    return registration;
  }

  static void _start() {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler(_handle);
  }

  static Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'search':
        return _search();
      case 'start':
        return _beginSession();
      case 'request':
        return _request(call.arguments);
      case 'end':
        await _endSession();
        return null;
    }
    throw MissingPluginException(call.method);
  }

  static Map<String, int>? _search() {
    final viewport = _activeViewport();
    if (viewport == null) return null;
    final bounds = viewport.bounds;
    final dpr = viewport.devicePixelRatio;
    return {
      'left': (bounds.left * dpr).ceil(),
      'top': (bounds.top * dpr).ceil(),
      'right': (bounds.right * dpr).floor(),
      'bottom': (bounds.bottom * dpr).floor(),
    };
  }

  static Future<bool> _beginSession() async {
    final viewport = _activeViewport();
    if (viewport == null) return false;
    _session = _CaptureSession(
      registration: viewport.registration,
      position: viewport.position,
      initialPixels: viewport.position.pixels,
      devicePixelRatio: viewport.devicePixelRatio,
    );
    capturing.value = true;
    await WidgetsBinding.instance.endOfFrame;
    return true;
  }

  static Future<Map<String, int>> _request(Object? arguments) async {
    final session = _session;
    if (session == null || !session.isLive || arguments is! Map) {
      return ScrollCaptureTile.empty.toMap();
    }
    final requestTop = arguments['top'];
    final requestBottom = arguments['bottom'];
    final boundsHeight = arguments['height'];
    if (requestTop is! int || requestBottom is! int || boundsHeight is! int) {
      return ScrollCaptureTile.empty.toMap();
    }
    final position = session.position;
    final reversed = axisDirectionIsReversed(position.axisDirection);
    final target = scrollCaptureTargetPixels(
      initialPixels: session.initialPixels,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
      reversed: reversed,
      devicePixelRatio: session.devicePixelRatio,
      requestTop: requestTop,
    );
    if (target != position.pixels) position.jumpTo(target);
    await WidgetsBinding.instance.endOfFrame;
    if (!session.isLive) return ScrollCaptureTile.empty.toMap();
    return scrollCaptureTile(
      initialPixels: session.initialPixels,
      pixels: position.pixels,
      reversed: reversed,
      devicePixelRatio: session.devicePixelRatio,
      boundsHeight: boundsHeight,
      requestTop: requestTop,
      requestBottom: requestBottom,
    ).toMap();
  }

  static Future<void> _endSession() async {
    final session = _session;
    _session = null;
    if (session != null && session.isLive) {
      final position = session.position;
      position.jumpTo(
        clampDouble(
          session.initialPixels,
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    }
    capturing.value = false;
    await WidgetsBinding.instance.endOfFrame;
  }

  static _Viewport? _activeViewport() {
    for (final registration in _targets.reversed) {
      final viewport = _Viewport.of(registration);
      if (viewport != null) return viewport;
    }
    return null;
  }
}

class _CaptureSession {
  _CaptureSession({
    required this.registration,
    required this.position,
    required this.initialPixels,
    required this.devicePixelRatio,
  });

  final ScrollCaptureRegistration registration;
  final ScrollPosition position;
  final double initialPixels;
  final double devicePixelRatio;

  bool get isLive =>
      ScrollCaptureService._targets.contains(registration) &&
      registration.controller.positions.contains(position);
}

class _Viewport {
  _Viewport._(
    this.registration,
    this.position,
    this.bounds,
    this.devicePixelRatio,
  );

  final ScrollCaptureRegistration registration;
  final ScrollPosition position;

  /// Logical pixels in FlutterView coordinates, overlay insets removed.
  final Rect bounds;
  final double devicePixelRatio;

  static _Viewport? of(ScrollCaptureRegistration registration) {
    final controller = registration.controller;
    if (!controller.hasClients || controller.positions.length != 1) {
      return null;
    }
    final position = controller.position;
    if (position.axis != Axis.vertical ||
        !position.hasContentDimensions ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return null;
    }
    final context = position.context.notificationContext;
    if (context == null || !context.mounted) return null;
    // A list under a pushed route or dialog is still mounted but not on screen.
    if (ModalRoute.isCurrentOf(context) == false) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    final top = origin.dy + (registration._topInset?.call() ?? 0);
    final bottom =
        origin.dy +
        box.size.height -
        (registration._bottomInset?.call() ?? 0);
    if (bottom <= top) return null;
    return _Viewport._(
      registration,
      position,
      Rect.fromLTRB(origin.dx, top, origin.dx + box.size.width, bottom),
      View.of(context).devicePixelRatio,
    );
  }
}
