import 'package:web_socket_channel/web_socket_channel.dart';

WebSocketChannel platformConnectWebSocket(Uri uri) => WebSocketChannel.connect(uri);
