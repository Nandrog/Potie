import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP client for the Arrows Bar API that still works on networks whose DNS
/// can't find the server's address (some Wi-Fi networks block or fail to
/// resolve `onrender.com`).
///
/// It connects normally first. If the address can't be looked up, it asks a
/// public DNS service over HTTPS - reached by its fixed IP address, so no DNS is
/// needed - and then connects straight to the server's IP. The TLS handshake
/// still checks the certificate against the real host name, so this is exactly
/// as secure as a normal connection.
http.Client createApiClient() {
  if (kIsWeb) return http.Client(); // browsers do their own DNS
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  client.connectionFactory = (uri, proxyHost, proxyPort) => _connect(uri);
  return IOClient(client);
}

/// Server addresses found through DNS-over-HTTPS, kept for this run of the app.
final Map<String, List<String>> _resolved = {};

Future<ConnectionTask<Socket>> _connect(Uri uri) async {
  final secure = uri.scheme == 'https';
  final port = uri.hasPort ? uri.port : (secure ? 443 : 80);

  // The factory must return the finished connection: Dart does not add TLS to
  // sockets it gets from a custom factory, so do the handshake here.
  Future<Socket> open(Object target) async {
    final raw = await Socket.connect(target, port,
        timeout: const Duration(seconds: 15));
    return secure ? SecureSocket.secure(raw, host: uri.host) : raw;
  }

  Future<Socket> connect() async {
    try {
      return await open(uri.host);
    } on SocketException {
      if (InternetAddress.tryParse(uri.host) != null) rethrow; // already an IP
      final ips = _resolved[uri.host] ?? await resolveViaDoh(uri.host);
      Object? last;
      for (final ip in ips) {
        try {
          final s = await open(InternetAddress(ip));
          _resolved[uri.host] = ips;
          return s;
        } on SocketException catch (e) {
          last = e;
        }
      }
      throw last ?? SocketException('Failed host lookup: ${uri.host}');
    }
  }

  return ConnectionTask.fromSocket(connect(), () {});
}

/// Looks up IPv4 addresses with Cloudflare, then Google, over HTTPS (by IP).
@visibleForTesting
Future<List<String>> resolveViaDoh(String host) async {
  final services = [
    Uri.https('1.1.1.1', '/dns-query', {'name': host, 'type': 'A'}),
    Uri.https('8.8.8.8', '/resolve', {'name': host, 'type': 'A'}),
  ];
  for (final url in services) {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await c.getUrl(url).timeout(const Duration(seconds: 8));
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      final answers = (jsonDecode(body) as Map)['Answer'] as List? ?? const [];
      final ips = [
        for (final a in answers)
          if ((a as Map)['type'] == 1) a['data'] as String
      ];
      if (ips.isNotEmpty) return ips;
    } catch (_) {
      // try the next service
    } finally {
      c.close(force: true);
    }
  }
  return const [];
}
