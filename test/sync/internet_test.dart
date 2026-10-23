import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitmate/domain/models.dart';
import 'package:splitmate/domain/split_calculator.dart';
import 'package:splitmate/sync/pairing.dart';
import 'package:splitmate/sync/secure_channel.dart';
import 'package:splitmate/sync/sync_session.dart';
import 'package:splitmate/sync/transport/endpoints.dart';
import 'package:splitmate/sync/transport/frame_channel.dart';
import 'package:splitmate/sync/transport/port_mapping.dart';
import 'package:splitmate/ui/screens/pair_screen.dart' show extractCode;

import '../support/harness.dart';

void main() {
  group('endpoints', () {
    test('encode and parse IPv4, IPv6 and classify reachability', () {
      expect(Endpoint.parse('192.168.1.5:4000')!.kind, EndpointKind.lan);
      expect(Endpoint.parse('8.8.4.4:4000')!.kind, EndpointKind.mapped);
      final v6 = Endpoint.parse('[2401:4900:1c3a::5]:4000')!;
      expect(v6.kind, EndpointKind.ipv6);
      expect(v6.encode(), '[2401:4900:1c3a::5]:4000');
      expect(Endpoint.parse('2401::1:4000'), isNull, reason: 'IPv6 must be bracketed');
      expect(Endpoint.parse('example.com:80'), isNull);
      expect(Endpoint.parse('1.2.3.4:70000'), isNull);
    });

    test('public IPv4 excludes private, CGNAT and special ranges', () {
      for (final ip in ['10.1.2.3', '172.20.0.1', '192.168.0.1', '100.64.0.1', '100.127.255.255', '127.0.0.1', '169.254.1.1']) {
        expect(isPublicIPv4(ip), isFalse, reason: ip);
      }
      for (final ip in ['49.36.10.1', '100.128.0.1', '172.32.0.1', '8.8.8.8']) {
        expect(isPublicIPv4(ip), isTrue, reason: ip);
      }
    });

    test('global IPv6 detection', () {
      expect(isGlobalIPv6(InternetAddress('2001:db8::1')), isTrue);
      expect(isGlobalIPv6(InternetAddress('fe80::1')), isFalse);
      expect(isGlobalIPv6(InternetAddress('fd00::1')), isFalse);
      expect(isGlobalIPv6(InternetAddress('::1')), isFalse);
    });

    test('codes are extracted from pasted messages', () {
      expect(extractCode('Connect with me:\n\nsplitmate:pair:v1:abc_DEF-123 thanks'),
          'splitmate:pair:v1:abc_DEF-123');
      expect(extractCode('hello'), isNull);
    });
  });

  group('dual-stack listener and racing dial', () {
    late TcpListener listener;
    setUp(() async => listener = await TcpListener.bind());
    tearDown(() => listener.close());

    test('accepts IPv4 and IPv6 on one port; dead candidates are skipped', () async {
      final accepted = <TcpFrameChannel>[];
      final sub = listener.connections.listen(accepted.add);
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      final (ch4, ep4) = await dialAny(['127.0.0.1:$deadPort', '127.0.0.1:${listener.port}']);
      expect(ep4, '127.0.0.1:${listener.port}');
      final (ch6, ep6) = await dialAny(['[::1]:${listener.port}']);
      expect(ep6, '[::1]:${listener.port}');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted.length, 2);
      for (final c in [ch4, ch6, ...accepted]) {
        await c.close();
      }
      await sub.cancel();
    });

    test('fails cleanly when nothing is reachable', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = dead.port;
      await dead.close();
      await expectLater(dialAny(['127.0.0.1:$port'], timeout: const Duration(seconds: 2)),
          throwsA(isA<TransportException>()));
      await expectLater(dialAny(['not-an-endpoint']), throwsA(isA<TransportException>()));
    });

    test('full pairing and sync over a real TCP socket (IPv6 loopback)', () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      final pa = PairingService(alice.repo);
      final pb = PairingService(bob.repo);
      final g = await alice.repo.createGroup('Remote trip', 'INR');
      await alice.repo.addExpense(ExpenseDraft(
        groupId: g,
        description: 'Hotel',
        amountMinor: 900000,
        currency: 'INR',
        payerId: alice.userId,
        splitType: SplitType.equal,
        participants: [SplitInput(alice.userId)],
        expenseDate: 0,
      ));
      final inv = await pa.createInvitation(endpoints: ['[::1]:${listener.port}'], groupId: g);
      final scanned = Invitation.decode(inv.encode());

      final responder = listener.connections.first.then((raw) async {
        final hs = await Handshake.respond(
          raw: raw,
          me: alice.identity,
          inviteSecretFor: pa.secretFor,
          isKnownPeer: pa.isKnownPeer,
          allowedModes: {HandshakeMode.pair, HandshakeMode.sync},
        );
        await pa.confirm(hs: hs, localApproval: Future.value(true), inviteId: hs.inviteId);
        return SyncSession(channel: hs.channel, peer: hs.peer, log: alice.log).run();
      });
      final (raw, _) = await PairingService.dial(scanned.endpoints);
      final hs = await Handshake.initiate(
        raw: raw,
        me: bob.identity,
        mode: HandshakeMode.pair,
        expectedPeerKey: scanned.ed25519Pub,
        inviteId: scanned.id,
        inviteSecret: scanned.secret,
      );
      await pb.confirm(hs: hs, localApproval: Future.value(true), scannedInvitation: scanned);
      final result = await SyncSession(channel: hs.channel, peer: hs.peer, log: bob.log).run();
      await responder;

      expect(result.received.rejected, 0);
      expect((await bob.repo.expenses(groupId: g)).single.description, 'Hotel');
      await alice.dispose();
      await bob.dispose();
    });
  });

  group('NAT-PMP', () {
    test('maps a port through a gateway and releases it', () async {
      final gw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <List<int>>[];
      gw.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = gw.receive();
        if (d == null) return;
        seen.add(d.data);
        final reply = d.data[1] == 0
            ? (ByteData(12)
              ..setUint8(1, 128)
              ..setUint32(4, 1)
              ..setUint8(8, 49)
              ..setUint8(9, 36)
              ..setUint8(10, 10)
              ..setUint8(11, 1))
            : (ByteData(16)
              ..setUint8(1, 130)
              ..setUint16(8, ByteData.sublistView(d.data).getUint16(4))
              ..setUint16(10, 40001)
              ..setUint32(12, 3600));
        gw.send(reply.buffer.asUint8List(), d.address, d.port);
      });
      final m = await NatPmpClient('127.0.0.1', port: gw.port).map(5555);
      expect(m, isNotNull);
      expect(m!.endpoint.encode(), '49.36.10.1:40001');
      await m.release();
      expect(ByteData.sublistView(Uint8List.fromList(seen.last)).getUint32(8), 0, reason: 'lifetime 0 = delete');
      gw.close();
    });

    test('a router behind carrier-grade NAT is not used', () async {
      final gw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      gw.listen((e) {
        final d = gw.receive();
        if (d == null) return;
        final r = ByteData(12)
          ..setUint8(1, 128)
          ..setUint8(8, 100)
          ..setUint8(9, 72)
          ..setUint8(10, 1)
          ..setUint8(11, 1);
        gw.send(r.buffer.asUint8List(), d.address, d.port);
      });
      expect(await NatPmpClient('127.0.0.1', port: gw.port).map(5555), isNull);
      gw.close();
    });

    test('no gateway answer times out quickly', () async {
      final gw = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sw = Stopwatch()..start();
      expect(await NatPmpClient('127.0.0.1', port: gw.port).map(5555), isNull);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      gw.close();
    });
  });

  group('UPnP IGD', () {
    test('parses SSDP replies and device descriptions', () {
      final loc = UpnpClient.parseSsdpLocation(
          'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nLocation: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n');
      expect(loc.toString(), 'http://192.168.1.1:5000/rootDesc.xml');
      final c = UpnpClient.fromDescription(Uri.parse('http://192.168.1.1:5000/rootDesc.xml'), _desc('/ctl/IPConn'));
      expect(c!.controlUrl.toString(), 'http://192.168.1.1:5000/ctl/IPConn');
      expect(c.serviceType, 'urn:schemas-upnp-org:service:WANIPConnection:1');
    });

    test('maps through a router and deletes the mapping on release', () async {
      final actions = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        final action = (req.headers.value('SOAPAction') ?? '').split('#').last.replaceAll('"', '');
        actions.add(action.isEmpty ? req.uri.path : action);
        req.response.headers.contentType = ContentType('text', 'xml');
        if (req.method == 'GET') {
          req.response.write(_desc('/ctl/IPConn'));
        } else if (action == 'GetExternalIPAddress') {
          req.response.write('<s:Envelope><s:Body><u:GetExternalIPAddressResponse>'
              '<NewExternalIPAddress>49.36.10.1</NewExternalIPAddress>'
              '</u:GetExternalIPAddressResponse></s:Body></s:Envelope>');
        } else if (action == 'AddPortMapping' && body.contains('<NewLeaseDuration>3600<')) {
          // Router that only supports permanent leases (error 725).
          req.response.statusCode = 500;
          req.response.write('<s:Fault><errorCode>725</errorCode></s:Fault>');
        } else {
          req.response.write('<s:Envelope><s:Body/></s:Envelope>');
        }
        await req.response.close();
      });
      final client = await UpnpClient.fromLocation(Uri.parse('http://127.0.0.1:${server.port}/rootDesc.xml'));
      final m = await client!.map(5555, '192.168.1.20');
      expect(m!.endpoint.encode(), '49.36.10.1:5555');
      expect(m.method, 'UPnP');
      await m.release();
      expect(actions, ['/rootDesc.xml', 'GetExternalIPAddress', 'AddPortMapping', 'AddPortMapping', 'DeletePortMapping']);
      await server.close(force: true);
    });
  });
}

String _desc(String control) => '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><device><deviceList><device><deviceList><device>
<serviceList><service>
<serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
<controlURL>$control</controlURL>
</service></serviceList></device></deviceList></device></deviceList></device></root>''';
