import 'dart:async';
import 'dart:io';

import 'frame_channel.dart';

/// How a peer can reach this device.
enum EndpointKind {
  /// Private IPv4 on the current Wi-Fi/hotspot: same network only.
  lan,

  /// Globally routable IPv6: works across the internet when the networks
  /// on both ends allow it.
  ipv6,

  /// Public IPv4 port opened on the home router via UPnP or NAT-PMP.
  mapped,
}

/// A `host:port` candidate. IPv6 hosts are written `[addr]:port`.
class Endpoint {
  const Endpoint(this.host, this.port, this.kind);
  final String host;
  final int port;
  final EndpointKind kind;

  bool get isInternet => kind != EndpointKind.lan;

  String encode() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  String toString() => encode();

  static Endpoint? parse(String s) {
    final v6 = RegExp(r'^\[([0-9a-fA-F:.]+)\]:(\d{1,5})$').firstMatch(s);
    final v4 = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})$').firstMatch(s);
    final m = v6 ?? v4;
    if (m == null) return null;
    final host = m.group(1)!;
    final port = int.parse(m.group(2)!);
    final addr = InternetAddress.tryParse(host);
    if (addr == null || port < 1 || port > 65535) return null;
    final kind = addr.type == InternetAddressType.IPv6
        ? EndpointKind.ipv6
        : (isPublicIPv4(host) ? EndpointKind.mapped : EndpointKind.lan);
    return Endpoint(host, port, kind);
  }
}

/// Global unicast IPv6 (2000::/3). Excludes link-local, unique-local and
/// loopback, which are not reachable from the internet.
bool isGlobalIPv6(InternetAddress a) =>
    a.type == InternetAddressType.IPv6 && (a.rawAddress[0] & 0xE0) == 0x20;

/// Public IPv4: not private, carrier-grade NAT (100.64/10), loopback or
/// link-local. A router reporting a non-public "external" address is itself
/// behind another NAT, so a port mapping on it is useless.
bool isPublicIPv4(String ip) {
  final a = InternetAddress.tryParse(ip);
  if (a == null || a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  if (b[0] == 10 || b[0] == 127 || b[0] == 0) return false;
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return false;
  if (b[0] == 192 && b[1] == 168) return false;
  if (b[0] == 169 && b[1] == 254) return false;
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false;
  if (b[0] >= 224) return false;
  return true;
}

/// This device's directly reachable endpoints for a listener on [port].
Future<List<Endpoint>> localEndpoints(int port, {bool includeIPv6 = true}) async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.any);
  final lan = <Endpoint>[];
  final v6 = <Endpoint>[];
  for (final i in interfaces) {
    for (final a in i.addresses) {
      if (a.type == InternetAddressType.IPv4 && !a.isLoopback && !a.isLinkLocal) {
        lan.add(Endpoint(a.address, port, EndpointKind.lan));
      } else if (includeIPv6 && isGlobalIPv6(a)) {
        // Strip any zone id; global addresses never need one.
        v6.add(Endpoint(a.address.split('%').first, port, EndpointKind.ipv6));
      }
    }
  }
  // Keep the code small: a phone often has several rotating IPv6 addresses.
  return [...lan, ...v6.take(2)];
}

/// Connects to every candidate at once and keeps the first that answers
/// ("happy eyeballs"). Returns the channel and the endpoint that worked.
Future<(FrameChannel, String)> dialAny(
  List<String> endpoints, {
  Duration timeout = const Duration(seconds: 8),
  Future<FrameChannel> Function(String host, int port, Duration timeout)? connect,
}) async {
  final dial = connect ??
      ((host, port, t) async => await TcpFrameChannel.connect(host, port, timeout: t));
  final parsed = endpoints.map(Endpoint.parse).whereType<Endpoint>().toList();
  if (parsed.isEmpty) throw TransportException('No usable address in the code');

  final winner = Completer<(FrameChannel, String)>();
  var failures = 0;
  for (final e in parsed) {
    // Same-network addresses get a short head start: they are fastest.
    final delay = e.kind == EndpointKind.lan ? Duration.zero : const Duration(milliseconds: 250);
    unawaited(Future<void>.delayed(delay).then((_) async {
      if (winner.isCompleted) return;
      try {
        final ch = await dial(e.host, e.port, timeout);
        if (winner.isCompleted) {
          await ch.close();
        } else {
          winner.complete((ch, e.encode()));
        }
      } catch (_) {
        failures++;
        if (failures == parsed.length && !winner.isCompleted) {
          winner.completeError(TransportException('unreachable'));
        }
      }
    }));
  }
  return winner.future;
}
