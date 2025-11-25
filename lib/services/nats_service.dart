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

  Future<void> connect({
    required String url,
    Map<String, dynamic>? credentials,
    List<String>? topics,
  }) async {
    if (_client != null) return;
    try {
      final opts = <String, dynamic>{'servers': url, 'tls': true};
      dynamic authenticator;
      if (credentials != null && credentials is Map<String, dynamic>) {
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

      _client = await nats.Nats.connect(
        opts: opts,
        authenticator: authenticator,
      );
      connected.value = true;

      if (topics != null && topics.isNotEmpty) {
        for (final t in topics) {
          _subscribe(t);
        }
      }
    } catch (e) {
      connected.value = false;
      if (kDebugMode) print('[NATS] connect error: $e');
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
