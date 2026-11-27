import 'ws_uri_web.dart' if (dart.library.io) 'ws_uri_io.dart';

Uri resolveTunnelUri({
  required String host,
  required int port,
  required String path,
  Uri? pageBase,
}) {
  if (pageBase != null &&
      pageBase.scheme == 'https' &&
      pageBase.host.isNotEmpty) {
    return Uri(
      scheme: 'wss',
      host: pageBase.host,
      port: pageBase.hasPort ? pageBase.port : 443,
      path: path,
    );
  }
  return Uri(scheme: 'ws', host: host, port: port, path: path);
}

Uri tunnelUri(String host, int port, String path) => resolveTunnelUri(
      host: host,
      port: port,
      path: path,
      pageBase: platformPageBase(),
    );
