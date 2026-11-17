import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class RealtimeEvent {
  const RealtimeEvent(this.name, this.data);
  final String name;
  final dynamic data;
}

/// Koneksi WebSocket (Socket.IO) ke gateway real-time backend.
/// Backend meneruskan event dari Redis Pub/Sub ke room sesuai peran pengguna.
class SocketService {
  SocketService(this.baseUrl);

  final String baseUrl;
  io.Socket? _socket;
  final _events = StreamController<RealtimeEvent>.broadcast();
  final connected = ValueNotifier<bool>(false);

  static const eventNames = [
    'notification',
    'print.job.updated',
    'print.queue.updated',
    'stock.changed',
    'stock.alert',
    'order.updated',
    'invoice.updated',
    'sales.created',
  ];

  Stream<RealtimeEvent> get events => _events.stream;

  Stream<RealtimeEvent> on(String name) => events.where((e) => e.name == name);

  /// (Re)connect dengan token sesi; tanpa token hanya menerima event publik (monitor antrean).
  void connect(String? token) {
    _socket?.dispose();
    final socket = io.io(
      baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth(token == null ? <String, dynamic>{} : {'token': token})
          .disableAutoConnect()
          .enableForceNew()
          .enableReconnection()
          .build(),
    );
    socket.onConnect((_) => connected.value = true);
    socket.onDisconnect((_) => connected.value = false);
    for (final name in eventNames) {
      socket.on(name, (data) => _events.add(RealtimeEvent(name, data)));
    }
    socket.connect();
    _socket = socket;
  }

  void dispose() {
    _socket?.dispose();
    _events.close();
  }
}
