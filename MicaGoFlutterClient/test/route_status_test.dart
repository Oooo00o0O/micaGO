import 'package:flutter_test/flutter_test.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/network/connection_candidate.dart';

const _lan = 'http://192.168.1.20:8787';
const _pub = 'https://mica.example.com';

RouteProbe _probe(bool reachable) => RouteProbe(
  reachable: reachable,
  latency: reachable ? const Duration(milliseconds: 38) : null,
  checkedAt: DateTime(2026, 9, 13),
);

RouteRowStatus _status({
  String baseUrl = _pub,
  String? switchingTo,
  String? active = _lan,
  bool realtimeConnected = true,
  bool probing = false,
  RouteProbe? probe,
}) => routeRowStatus(
  baseUrl: baseUrl,
  switchingTo: switchingTo,
  activeBaseUrl: active,
  realtimeConnected: realtimeConnected,
  probing: probing,
  probe: probe,
);

void main() {
  group('routeRowStatus', () {
    test('the route in use stays connected even if a check just failed', () {
      expect(
        _status(baseUrl: _lan, probe: _probe(false)),
        RouteRowStatus.connected,
      );
      expect(_status(baseUrl: _lan, probing: true), RouteRowStatus.connected);
    });

    test('the route in use is connecting until realtime is up', () {
      expect(
        _status(baseUrl: _lan, realtimeConnected: false),
        RouteRowStatus.connecting,
      );
      expect(
        _status(baseUrl: _lan, realtimeConnected: false, probe: _probe(true)),
        RouteRowStatus.connecting,
      );
    });

    test('the route in use shows unavailable once its check fails offline', () {
      expect(
        _status(baseUrl: _lan, realtimeConnected: false, probe: _probe(false)),
        RouteRowStatus.unavailable,
      );
    });

    test('other routes are checking while probed or never probed', () {
      expect(_status(), RouteRowStatus.checking);
      expect(
        _status(probing: true, probe: _probe(true)),
        RouteRowStatus.checking,
      );
    });

    test('other routes report their last check', () {
      expect(_status(probe: _probe(true)), RouteRowStatus.available);
      expect(_status(probe: _probe(false)), RouteRowStatus.unavailable);
    });

    test('a manual switch target shows switching before anything else', () {
      expect(
        _status(switchingTo: _pub, probe: _probe(true)),
        RouteRowStatus.switching,
      );
    });
  });

  group('connectionCandidatesForProfile pinFirst', () {
    final profile = ConnectionProfile(
      baseUrl: _lan,
      token: 't',
      lanRoutes: const [EndpointRef(baseUrl: _lan, wsUrl: '')],
      publicBaseUrl: _pub,
      selectedBaseUrl: _pub,
    );

    test('connect order puts the chosen route first', () {
      expect(connectionCandidatesForProfile(profile).map((c) => c.baseUrl), [
        _pub,
        _lan,
      ]);
    });

    test('Settings order stays stable regardless of the chosen route', () {
      expect(
        connectionCandidatesForProfile(
          profile,
          pinFirst: false,
        ).map((c) => c.baseUrl),
        [_lan, _pub],
      );
    });
  });
}
