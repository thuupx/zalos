import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_connect_web.dart' if (dart.library.io) 'ws_connect_io.dart';

/// Opens a platform WebSocket with keepalive pings where supported.
WebSocketChannel connectWebSocket(Uri uri) => platformConnectWebSocket(uri);
