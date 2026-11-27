import 'package:flutter_test/flutter_test.dart';
import 'package:zalos/src/data/protocol/ws_uri.dart';

void main() {
  test('a null page base uses the pairing host and port', () {
    final uri =
        resolveTunnelUri(host: '10.0.0.5', port: 7443, path: '/v1/control');
    expect(uri.toString(), 'ws://10.0.0.5:7443/v1/control');
  });

  test('an http page base uses the pairing host and port', () {
    final uri = resolveTunnelUri(
      host: '10.0.0.5',
      port: 7443,
      path: '/v1/control',
      pageBase: Uri.parse('http://127.0.0.1:18934/'),
    );
    expect(uri.toString(), 'ws://10.0.0.5:7443/v1/control');
  });

  test('an https page without a port uses same-origin wss on port 443', () {
    final uri = resolveTunnelUri(
      host: '10.0.0.5',
      port: 7443,
      path: '/v1/control',
      pageBase: Uri.parse('https://nas.example.ts.net/'),
    );
    expect(uri.toString(), 'wss://nas.example.ts.net:443/v1/control');
  });

  test('an https page with a port uses same-origin wss on that port', () {
    final uri = resolveTunnelUri(
      host: '10.0.0.5',
      port: 7443,
      path: '/v1/control',
      pageBase: Uri.parse('https://h:8443/x'),
    );
    expect(uri.toString(), 'wss://h:8443/v1/control');
  });
}
