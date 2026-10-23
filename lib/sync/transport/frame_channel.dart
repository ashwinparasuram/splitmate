import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

const int kMaxFrameBytes = 4 * 1024 * 1024;

class TransportException implements Exception {
  TransportException(this.message);
  final String message;
  @override
  String toString() => 'TransportException: $message';
}

/// A full-duplex, message-oriented byte channel between two devices.
/// Transports (TCP, in-memory, future BLE/Wi-Fi Direct) implement this; the
/// secure channel and sync protocol never depend on the concrete transport.
abstract class FrameChannel {
  /// Waits for the next frame. Throws [TransportException] on close/timeout.
  Future<Uint8List> receive({Duration timeout = const Duration(seconds: 30)});
  Future<void> send(Uint8List frame);
  Future<void> close();
  String get description;
}

/// Buffers incoming frames from a stream and serves them via [receive].
mixin _FrameQueue {
  final _queue = <Uint8List>[];
  Completer<void>? _waiter;
  Object? _error;
  bool _closed = false;

  void _push(Uint8List f) {
    _queue.add(f);
    _waiter?.complete();
    _waiter = null;
  }

  void _fail(Object error) {
    _error ??= error;
    _closed = true;
    _waiter?.complete();
    _waiter = null;
  }

  Future<Uint8List> _pop(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_queue.isEmpty) {
      if (_closed) throw TransportException(_error?.toString() ?? 'channel closed');
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TransportException('timed out waiting for peer');
      _waiter ??= Completer<void>();
      await _waiter!.future.timeout(left, onTimeout: () {});
    }
    return _queue.removeAt(0);
  }
}

// ------------------------------------------------------------------ memory

/// In-process channel pair for tests. [dropAfter] simulates a connection
/// that dies after that many frames have been sent by this side.
class MemoryChannel with _FrameQueue implements FrameChannel {
  MemoryChannel._(this.description);

  late MemoryChannel _peer;
  int sent = 0;
  int? dropAfter;

  @override
  final String description;

  static (MemoryChannel, MemoryChannel) pair() {
    final a = MemoryChannel._('memory:a');
    final b = MemoryChannel._('memory:b');
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  Future<Uint8List> receive({Duration timeout = const Duration(seconds: 30)}) => _pop(timeout);

  @override
  Future<void> send(Uint8List frame) async {
    if (_closed) throw TransportException('channel closed');
    if (dropAfter != null && sent >= dropAfter!) {
      await close();
      throw TransportException('connection lost');
    }
    sent++;
    // Copy: the receiver must never observe later mutation by the sender.
    final copy = Uint8List.fromList(frame);
    scheduleMicrotask(() => _peer._push(copy));
  }

  /// Delivers a raw frame to the peer, bypassing normal sending (tests).
  void inject(Uint8List frame) => _peer._push(Uint8List.fromList(frame));

  @override
  Future<void> close() async {
    if (_closed) return;
    _fail('channel closed');
    _peer._fail('peer closed the connection');
  }
}

// --------------------------------------------------------------------- TCP

/// Length-prefixed frames over a TCP socket (LAN, hotspot, ad-hoc Wi-Fi).
class TcpFrameChannel with _FrameQueue implements FrameChannel {
  TcpFrameChannel(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket.listen(_onData,
        onError: (Object e) => _fail(e), onDone: () => _fail('peer closed the connection'));
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  @override
  String get description => 'tcp:${_socket.remoteAddress.address}:${_socket.remotePort}';

  static Future<TcpFrameChannel> connect(String host, int port,
      {Duration timeout = const Duration(seconds: 6)}) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return TcpFrameChannel(socket);
  }

  void _onData(Uint8List data) {
    _buffer.add(_pending);
    _buffer.add(data);
    var bytes = _buffer.takeBytes();
    while (bytes.length >= 4) {
      final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (len > kMaxFrameBytes) {
        _fail('frame too large');
        _socket.destroy();
        return;
      }
      if (bytes.length < 4 + len) break;
      _push(Uint8List.sublistView(bytes, 4, 4 + len));
      bytes = Uint8List.sublistView(bytes, 4 + len);
    }
    _pending = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> receive({Duration timeout = const Duration(seconds: 30)}) => _pop(timeout);

  @override
  Future<void> send(Uint8List frame) async {
    if (_closed) throw TransportException('channel closed');
    if (frame.length > kMaxFrameBytes) throw TransportException('frame too large');
    final header = ByteData(4)..setUint32(0, frame.length);
    _socket.add(header.buffer.asUint8List());
    _socket.add(frame);
    await _socket.flush();
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _sub.cancel();
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
  }
}

/// Listens for incoming TCP sync connections on both IPv4 and IPv6, so
/// LAN peers and internet (IPv6 / router-mapped) peers reach one port.
class TcpListener {
  TcpListener._(this._server);
  final ServerSocket _server;

  int get port => _server.port;

  static Future<TcpListener> bind({int port = 0}) async {
    try {
      return TcpListener._(await ServerSocket.bind(InternetAddress.anyIPv6, port, v6Only: false));
    } on SocketException {
      // No IPv6 stack on this network: fall back to IPv4 only.
      return TcpListener._(await ServerSocket.bind(InternetAddress.anyIPv4, port));
    }
  }

  Stream<TcpFrameChannel> get connections => _server.map(TcpFrameChannel.new);

  Future<void> close() => _server.close();
}
