import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/network/connection_candidate.dart';

void main() {
  group('routeConnectionState', () {
    test('connected once a route is active and realtime is up', () {
      expect(
        routeConnectionState(
          hasActiveRoute: true,
          realtimeConnected: true,
          problemConfirmed: false,
        ),
        RouteConnectionState.connected,
      );
    });

    test('still connecting without an active route or a live socket', () {
      expect(
        routeConnectionState(
          hasActiveRoute: false,
          realtimeConnected: false,
          problemConfirmed: false,
        ),
        RouteConnectionState.connecting,
      );
      expect(
        routeConnectionState(
          hasActiveRoute: true,
          realtimeConnected: false,
          problemConfirmed: false,
        ),
        RouteConnectionState.connecting,
      );
    });

    test('a confirmed connection problem wins over everything else', () {
      expect(
        routeConnectionState(
          hasActiveRoute: true,
          realtimeConnected: true,
          problemConfirmed: true,
        ),
        RouteConnectionState.unreachable,
      );
    });
  });
}
