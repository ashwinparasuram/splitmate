import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'endpoints.dart';

/// A public IPv4 port forwarded to this device by the local router.
/// Only talks to the router on the local network: no third party involved.
class PortMapping {
  PortMapping(this.externalIp, this.externalPort, this.method, this._release);
  final String externalIp;
  final int externalPort;
  final String method;
  final Future<void> Function() _release;

  Endpoint get endpoint => Endpoint(externalIp, externalPort, EndpointKind.mapped);

  /// Removes the forwarding so the port is not left open.
  Future<void> release() async {
    try {
      await _release();
    } catch (_) {}
  }
}

const _lease = Duration(hours: 1);

/// Tries NAT-PMP, then UPnP IGD. Returns null when the router supports
/// neither, refuses, or is itself behind another NAT (carrier-grade NAT).
class PortMapper {
  static Future<PortMapping?> map({
    required int internalPort,
    required String? gatewayIp,
    required String? lanIp,
    bool useUpnp = true,
  }) async {
    if (gatewayIp != null) {
      final m = await NatPmpClient(gatewayIp).map(internalPort).catchError((_) => null);
      if (m != null) return m;
    }
    if (useUpnp && lanIp != null) {
      final m = await UpnpClient.discoverAndMap(internalPort, lanIp).catchError((_) => null);
      if (m != null) return m;
    }
    return null;
  }
}

// ----------------------------------------------------------------- NAT-PMP

/// RFC 6886 NAT Port Mapping Protocol (Apple and many other routers).
class NatPmpClient {
  NatPmpClient(this.gateway, {this.port = 5351});
  final String gateway;
  final int port;

  Future<Uint8List?> _request(List<int> body, int expectedOp, int minLen) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    Completer<Uint8List?>? pending;
    // A datagram socket stream allows a single listener for all attempts.
    final sub = socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null && d.data.length >= minLen && d.data[1] == expectedOp) {
        if (pending != null && !pending.isCompleted) pending.complete(d.data);
      }
    });
    try {
      final addr = InternetAddress(gateway);
      // RFC 6886: initial 250 ms timeout, doubling.
      for (var attempt = 0, wait = 250; attempt < 3; attempt++, wait *= 2) {
        final c = pending = Completer<Uint8List?>();
        socket.send(body, addr, port);
        final reply = await c.future.timeout(Duration(milliseconds: wait), onTimeout: () => null);
        if (reply != null) return reply;
      }
      return null;
    } finally {
      await sub.cancel();
      socket.close();
    }
  }

  Future<String?> externalAddress() async {
    final r = await _request(const [0, 0], 128, 12);
    if (r == null || ByteData.sublistView(r).getUint16(2) != 0) return null;
    return r.sublist(8, 12).join('.');
  }

  Future<int?> _mapTcp(int internalPort, int externalPort, int lifetimeSeconds) async {
    final req = ByteData(12)
      ..setUint8(0, 0)
      ..setUint8(1, 2) // map TCP
      ..setUint16(4, internalPort)
      ..setUint16(6, externalPort)
      ..setUint32(8, lifetimeSeconds);
    final r = await _request(req.buffer.asUint8List(), 130, 16);
    if (r == null) return null;
    final bd = ByteData.sublistView(r);
    if (bd.getUint16(2) != 0) return null;
    return bd.getUint16(10);
  }

  Future<PortMapping?> map(int internalPort) async {
    final ip = await externalAddress();
    if (ip == null || !isPublicIPv4(ip)) return null;
    final ext = await _mapTcp(internalPort, internalPort, _lease.inSeconds);
    if (ext == null || ext == 0) return null;
    return PortMapping(ip, ext, 'NAT-PMP', () => _mapTcp(internalPort, 0, 0));
  }
}

// -------------------------------------------------------------------- UPnP

/// UPnP Internet Gateway Device (most home routers, when UPnP is enabled).
class UpnpClient {
  UpnpClient(this.controlUrl, this.serviceType);
  final Uri controlUrl;
  final String serviceType;

  static const _searchTargets = [
    'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
    'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
  ];

  /// Sends SSDP M-SEARCH and returns the LOCATION URLs that answer.
  static Future<List<Uri>> discover({Duration wait = const Duration(milliseconds: 2500)}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final found = <Uri>{};
    try {
      for (final st in _searchTargets) {
        final msg = 'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
            'MAN: "ssdp:discover"\r\nMX: 2\r\nST: $st\r\n\r\n';
        socket.send(utf8.encode(msg), InternetAddress('239.255.255.250'), 1900);
      }
      final done = DateTime.now().add(wait);
      await for (final e in socket.timeout(wait, onTimeout: (s) => s.close())) {
        if (e == RawSocketEvent.read) {
          final d = socket.receive();
          if (d != null) {
            final loc = parseSsdpLocation(utf8.decode(d.data, allowMalformed: true));
            if (loc != null) found.add(loc);
          }
        }
        if (DateTime.now().isAfter(done)) break;
      }
    } finally {
      socket.close();
    }
    return found.toList();
  }

  static Uri? parseSsdpLocation(String response) {
    for (final line in const LineSplitter().convert(response)) {
      final i = line.indexOf(':');
      if (i > 0 && line.substring(0, i).trim().toLowerCase() == 'location') {
        return Uri.tryParse(line.substring(i + 1).trim());
      }
    }
    return null;
  }

  /// Finds the WAN connection service in a device description document.
  static UpnpClient? fromDescription(Uri location, String xml) {
    String? tag(String block, String name) =>
        RegExp('<(?:\\w+:)?$name>\\s*([^<]*?)\\s*</(?:\\w+:)?$name>').firstMatch(block)?.group(1);
    final base = tag(xml, 'URLBase');
    final baseUri = base != null && base.isNotEmpty ? Uri.parse(base) : location;
    for (final m in RegExp(r'<(?:\w+:)?service>([\s\S]*?)</(?:\w+:)?service>').allMatches(xml)) {
      final block = m.group(1)!;
      final type = tag(block, 'serviceType') ?? '';
      if (type.contains('WANIPConnection') || type.contains('WANPPPConnection')) {
        final control = tag(block, 'controlURL');
        if (control != null) return UpnpClient(baseUri.resolve(control), type);
      }
    }
    return null;
  }

  static Future<UpnpClient?> fromLocation(Uri location) async {
    final xml = await _http('GET', location, null, null);
    return xml == null ? null : fromDescription(location, xml);
  }

  static Future<String?> _http(String method, Uri url, String? body, String? soapAction) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.openUrl(method, url).timeout(const Duration(seconds: 3));
      if (soapAction != null) {
        req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
        req.headers.set('SOAPAction', '"$soapAction"');
      }
      if (body != null) req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 4));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
      return text;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _soap(String action, Map<String, Object> args) {
    final params = args.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join();
    final body = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:$action xmlns:u="$serviceType">$params</u:$action></s:Body></s:Envelope>';
    return _http('POST', controlUrl, body, '$serviceType#$action');
  }

  static bool _isFault(String? r) => r == null || r.contains('Fault>') || r.contains('errorCode');

  Future<String?> externalAddress() async {
    final r = await _soap('GetExternalIPAddress', const {});
    if (_isFault(r)) return null;
    return RegExp(r'<NewExternalIPAddress>\s*([^<]+?)\s*</NewExternalIPAddress>').firstMatch(r!)?.group(1);
  }

  Future<bool> _add(int external, int internal, String lanIp, int leaseSeconds) async {
    final r = await _soap('AddPortMapping', {
      'NewRemoteHost': '',
      'NewExternalPort': external,
      'NewProtocol': 'TCP',
      'NewInternalPort': internal,
      'NewInternalClient': lanIp,
      'NewEnabled': 1,
      'NewPortMappingDescription': 'SplitMate sync',
      'NewLeaseDuration': leaseSeconds,
    });
    return !_isFault(r);
  }

  Future<PortMapping?> map(int internalPort, String lanIp) async {
    final ip = await externalAddress();
    if (ip == null || !isPublicIPv4(ip)) return null;
    final candidates = [internalPort, 20000 + Random.secure().nextInt(40000)];
    for (final ext in candidates) {
      // Some routers only accept permanent leases (UPnP error 725).
      if (await _add(ext, internalPort, lanIp, _lease.inSeconds) ||
          await _add(ext, internalPort, lanIp, 0)) {
        return PortMapping(ip, ext, 'UPnP', () => _soap('DeletePortMapping', {
              'NewRemoteHost': '',
              'NewExternalPort': ext,
              'NewProtocol': 'TCP',
            }));
      }
    }
    return null;
  }

  static Future<PortMapping?> discoverAndMap(int internalPort, String lanIp) async {
    for (final loc in await discover()) {
      final client = await fromLocation(loc);
      final m = await client?.map(internalPort, lanIp);
      if (m != null) return m;
    }
    return null;
  }
}
