import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nats_client/natslite/nats.dart' as nats;
import 'package:nats_client/nats/credauth.dart' as cred_auth;
import 'package:nats_client/nats/sign.dart' as nats_sign;

class NatsService {
  NatsService._privateConstructor();
  static final NatsService instance = NatsService._privateConstructor();

  nats.Nats? _client;
  SecureSocket? _tlsSocket;
  final Map<String, dynamic> _subs = {};
  final ValueNotifier<bool> connected = ValueNotifier(false);
  String? lastError;

  Future<void> connect({
    required String url,
    Map<String, dynamic>? credentials,
    List<String>? topics,
    bool tlsOnly = true,
  }) async {
    if (_client != null || _tlsSocket != null) return;
    try {
      // If the URL scheme indicates a TLS native (non-WebSocket) NATS endpoint,
      // connect using raw TCP/TLS via SecureSocket. We check for schemes like 'tls' or 'nats'.
      try {
        final parsed = Uri.parse(url);
        if (parsed.scheme == 'tls' ||
            parsed.scheme == 'nats' ||
            parsed.scheme == 'ssl' ||
            parsed.scheme == 'tcps' ||
            parsed.scheme == 'nats+tls') {
          // Use native TLS connect
          await _connectTls(
            parsed.host,
            parsed.hasPort ? parsed.port : 4222,
            credentials,
            topics,
          );
          return;
        }
      } catch (_) {
        // ignore parsing errors and proceed with WebSocket fallback
      }
      // If TLS only, do not attempt WebSocket fallbacks.
      if (tlsOnly) {
        // If scheme present and not a tls/nats style, attempt to parse host and still try TLS
        try {
          final parsed = Uri.parse(url);
          await _connectTls(
            parsed.host,
            parsed.hasPort ? parsed.port : 4222,
            credentials,
            topics,
          );
          return;
        } catch (_) {
          // fall through to throwing later
        }
      }

      // Build candidate WebSocket URLs for connecting.
      final List<String> candidates = [];
      try {
        final parsed = Uri.parse(url);
        String host = parsed.host;
        int port = parsed.hasPort
            ? parsed.port
            : (parsed.scheme == 'wss' || parsed.scheme == 'wss' ? 443 : 4222);
        // If user supplied a ws/wss URL, use it as-is
        if (parsed.scheme == 'ws' || parsed.scheme == 'wss') {
          candidates.add(url);
        }
        // If user supplied tls/nats, try websocket equivalents (wss)
        if (parsed.scheme == 'tls' ||
            parsed.scheme == 'ssl' ||
            parsed.scheme == 'nats') {
          candidates.add('wss://$host:$port');
          // Common websocket port fallback
          if (port != 443) candidates.add('wss://$host:443');
        }
        // If the string is a host:port (no scheme) or other, try it raw as wss first
        if (parsed.scheme.isEmpty) {
          candidates.add('wss://$url');
          candidates.add('wss://$host:443');
        }
      } catch (_) {
        // Fallback to using the raw url as wss
        candidates.add(url.replaceFirst('tls://', 'wss://'));
      }
      // Try each candidate until one succeeds
      Exception? lastException;
      for (final candidate in candidates) {
        final opts = <String, dynamic>{'servers': candidate};
        dynamic authenticator;
        if (credentials != null) {
          if (credentials.containsKey('token')) {
            opts['token'] = credentials['token'];
          } else if (credentials.containsKey('username') &&
              credentials.containsKey('password')) {
            opts['user'] = credentials['username'];
            opts['pass'] = credentials['password'];
          } else if (credentials.containsKey('creds')) {
            // creds file/string, use creds authenticator
            authenticator = cred_auth.CredsAuthenticator(credentials['creds']);
          }
        }
        try {
          _client = await nats.Nats.connect(
            opts: opts,
            authenticator: authenticator,
          );
          lastError = null;
          break;
        } catch (e) {
          lastException = e as Exception? ?? Exception(e.toString());
          if (kDebugMode) {
            print('[NATS] connect attempt to $candidate failed: $e');
          }
        }
      }
      if (_client == null) {
        throw lastException ?? Exception('Unable to connect to NATS');
      }
      // set connected true (already done by ws client later)
      connected.value = true;
      lastError = null;

      if (topics != null && topics.isNotEmpty) {
        for (final t in topics) {
          _subscribe(t);
        }
      }
    } catch (e) {
      connected.value = false;
      lastError = e.toString();
      if (kDebugMode) {
        print('[NATS] connect error: $e');
      }
      rethrow;
    }
  }

  Future<void> _connectTls(
    String host,
    int port,
    Map<String, dynamic>? credentials,
    List<String>? topics,
  ) async {
    if (_tlsSocket != null) return;
    try {
      if (kDebugMode) {
        print('[NATS][TLS] Attempting native TLS connect to $host:$port');
      }
      final socket = await SecureSocket.connect(
        host,
        port,
        onBadCertificate: (cert) => true,
      );
      _tlsSocket = socket;
      // Read initial INFO from server (first line)
      final completer = Completer<String>();
      final subBuff = StringBuffer();
      void onData(dynamic data) {
        final s = String.fromCharCodes(data);
        if (kDebugMode) print('[NATS][TLS] recv chunk: $s');
        subBuff.write(s);
        final full = subBuff.toString();
        if (full.contains('\r\n')) {
          final idx = full.indexOf('\r\n');
          final first = full.substring(0, idx);
          completer.complete(first);
        }
      }

      socket.listen(
        onData,
        onDone: () {
          if (kDebugMode) print('[NATS][TLS] socket closed');
          connected.value = false;
        },
        onError: (e) {
          if (kDebugMode) print('[NATS][TLS] socket error: $e');
          connected.value = false;
        },
      );

      // Wait for INFO
      final infoLine = await completer.future;
      if (kDebugMode) print('[NATS][TLS] INFO: $infoLine');
      Map<String, dynamic>? infoJson;
      try {
        final idx = infoLine.indexOf(' ');
        final jsonStr = idx >= 0 ? infoLine.substring(idx + 1) : infoLine;
        infoJson = json.decode(jsonStr) as Map<String, dynamic>?;
      } catch (_) {
        infoJson = null;
      }

      // Build CONNECT JSON
      final connectPayload = <String, dynamic>{
        'lang': 'dart',
        'version': '1.0',
        'verbose': false,
        'pedantic': false,
      };
      if (credentials != null) {
        if (credentials.containsKey('token')) {
          connectPayload['auth_token'] = credentials['token'];
        } else if (credentials.containsKey('username') &&
            credentials.containsKey('password')) {
          connectPayload['user'] = credentials['username'];
          connectPayload['pass'] = credentials['password'];
        } else if (credentials.containsKey('creds')) {
          // Attempt to parse .creds and perform JWT/NKEY auth flow
          final credsText = credentials['creds']?.toString() ?? '';
          final parsed = _parseNatsCreds(credsText);
          if (parsed != null) {
            final userJWT = parsed['jwt'] as String;
            final seed = parsed['seed'] as String;
            // If server sends nonce -> sign it
            String? nonce;
            if (infoJson != null && infoJson.containsKey('nonce')) {
              nonce = infoJson['nonce'] as String?;
            }
            if (nonce != null && nonce.isNotEmpty) {
              final sig = nats_sign.encodeSeed(seed, nonce);
              // encodeSeed returns { 'nkey':..., 'sig':... }
              final sigVal = sig['sig'] as String;
              connectPayload['jwt'] = userJWT;
              connectPayload['sig'] = sigVal;
            } else {
              // fallback: send JWT alone (some servers accept it)
              connectPayload['jwt'] = userJWT;
            }
          } else {
            if (kDebugMode) print('[NATS][TLS] creds parsing failed');
          }
        }
      }
      final jsonStr = json.encode(connectPayload);
      socket.write('CONNECT $jsonStr\r\n');
      // Subscribe to topics (if any)
      if (topics != null && topics.isNotEmpty) {
        var sid = 1;
        for (final t in topics) {
          socket.write('SUB $t $sid\r\n');
          _subs[t] = sid; // store subscription id for TCP path
          sid++;
        }
      }
      // send a PING to ensure handshake
      socket.write('PING\r\n');
      connected.value = true;
      lastError = null;
      if (kDebugMode) {
        print('[NATS][TLS] native TLS connection established');
      }
    } catch (e) {
      lastError = e.toString();
      connected.value = false;
      if (kDebugMode) print('[NATS][TLS] failed to connect: $e');
      rethrow;
    }
  }

  void _subscribe(String topic) {
    if (_subs.containsKey(topic)) return;
    if (_client != null) {
      final sub = _client!.subscribe(topic, (res) {
        if (kDebugMode) {
          try {
            final decoded = res.decode;
            {
              print('[NATS][$topic] $decoded');
            }
          } catch (_) {
            {
              print('[NATS][$topic] received bytes: ${res.data}');
            }
          }
        }
      });
      _subs[topic] = sub;
      return;
    }
    if (_tlsSocket != null) {
      // For TCP/TLS path, send SUB messages directly; assign a numeric sid
      var sid = 1;
      // find max existing sid
      for (final v in _subs.values) {
        if (v is int && v >= sid) sid = v + 1;
      }
      try {
        _tlsSocket!.write('SUB $topic $sid\r\n');
        _subs[topic] = sid;
        if (kDebugMode) print('[NATS][TLS] SUB $topic $sid');
      } catch (e) {
        if (kDebugMode) print('[NATS][TLS] SUB failed: $e');
      }
    }
  }

  Future<void> disconnect() async {
    if (_client != null) {
      for (final sub in _subs.values) {
        try {
          sub.unsubscribe();
        } catch (_) {}
      }
      _subs.clear();
      _client!.close();
      _client = null;
      connected.value = false;
      return;
    }
    if (_tlsSocket != null) {
      // Attempt to unsubscribe for TCP path
      try {
        for (final entry in _subs.entries) {
          final v = entry.value;
          if (v is int) {
            _tlsSocket!.write('UNSUB $v\r\n');
          }
        }
      } catch (_) {}
      _subs.clear();
      try {
        _tlsSocket!.destroy();
      } catch (_) {}
      _tlsSocket = null;
      connected.value = false;
      return;
    }
  }

  // Minimal .creds parser - extract user JWT and seed (NKEY) from a creds file text
  Map<String, String>? _parseNatsCreds(String credsText) {
    if (credsText.trim().isEmpty) return null;
    final jwtRe = RegExp(
      r'-----BEGIN\s+NATS\s+USER\s+JWT-----\s*([\w\-_.=\n\r]+)\s*-----END\s+NATS\s+USER\s+JWT-----',
      dotAll: true,
    );
    final seedRe = RegExp(
      r'-----BEGIN\s+USER\s+NKEY\s+SEED-----\s*([A-Z0-9]+)\s*-----END\s+USER\s+NKEY\s+SEED-----',
      dotAll: true,
    );
    String? jwt;
    String? seed;
    final jm = jwtRe.firstMatch(credsText);
    if (jm != null) {
      jwt = jm.group(1)!.replaceAll(RegExp(r'\s+'), '').trim();
    }
    final sm = seedRe.firstMatch(credsText);
    if (sm != null) {
      seed = sm.group(1)!.replaceAll(RegExp(r'\s+'), '').trim();
    }
    if (jwt == null || seed == null) return null;
    return {'jwt': jwt, 'seed': seed};
  }
}
