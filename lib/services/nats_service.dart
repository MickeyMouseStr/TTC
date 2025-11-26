import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:nats_client/natslite/nats.dart' as nats;
import 'package:nats_client/nats/credauth.dart' as cred_auth;

class NatsService {
  NatsService._privateConstructor();
  static final NatsService instance = NatsService._privateConstructor();

  nats.Nats? _client;
  final Map<String, dynamic> _subs = {};
  final ValueNotifier<bool> connected = ValueNotifier(false);
  String? lastError;

  Future<void> connect({
    required String url,
    Map<String, dynamic>? credentials,
    List<String>? topics,
  }) async {
    if (_client != null) return;
    try {
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

  void _subscribe(String topic) {
    if (_client == null) return;
    if (_subs.containsKey(topic)) return;

    final sub = _client!.subscribe(topic, (res) {
      if (kDebugMode) {
        try {
          final decoded = res.decode;
          print('[NATS][$topic] $decoded');
        } catch (_) {
          print('[NATS][$topic] received bytes: ${res.data}');
        }
      }
    });
    _subs[topic] = sub;
  }

  Future<void> disconnect() async {
    if (_client == null) return;
    for (final sub in _subs.values) {
      sub.unsubscribe();
    }
    _subs.clear();
    _client!.close();
    _client = null;
    connected.value = false;
  }
}
