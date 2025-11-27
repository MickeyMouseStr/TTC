import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dart_nats/dart_nats.dart' as dart_nats;

/// Minimal NATS service using `dart_nats`.
///
/// Public API:
/// - connectForCurrentUser({required String url, String? connectionName})
/// - connect({required String url, Map<String, dynamic>? credentials, List<String>? topics, String? connectionName})
/// - disconnect()
/// - publishJson(String subject, Map<String, dynamic> json)
class NatsService {
  NatsService._privateConstructor();
  static final NatsService instance = NatsService._privateConstructor();

  dart_nats.Client? _client;
  final Map<String, dart_nats.Subscription> _subs = {};
  final ValueNotifier<bool> connected = ValueNotifier(false);
  String? lastError;
  StreamSubscription<dart_nats.Status>? _statusSub;

  /// Connect using the current Firebase user; looks up the `users` collection by email
  /// and expects the doc to include:
  ///   - `natsCredential` (either raw .creds string, or a map with creds/jwt/seed/token/user/pass)
  ///   - `subscriptions` (List<String> of subjects)
  Future<void> connectForCurrentUser({
    required String url,
    String? connectionName,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('No logged-in user');

    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('email', isEqualTo: user.email)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) {
      throw Exception('No Firestore user doc for ${user.email}');
    }

    final data = snap.docs.first.data();

    final cred = data['natsCredential'];
    final subs = <String>[];
    if (data['subscriptions'] is Iterable) {
      subs.addAll(List<String>.from(data['subscriptions']));
    } else if (data['subscriptions'] is String &&
        (data['subscriptions'] as String).trim().isNotEmpty) {
      // also accept a single string
      subs.add((data['subscriptions'] as String).trim());
    }

    // Normalise credential shape:
    // - if it's the raw .creds string (like you pasted), wrap in {'creds': ...}
    // - if it's already a map, clone it
    Map<String, dynamic>? credsMap;
    if (cred is String && cred.trim().isNotEmpty) {
      credsMap = {'creds': cred};
    } else if (cred is Map<String, dynamic>) {
      credsMap = Map<String, dynamic>.from(cred);
    }

    if (kDebugMode) {
      print('[NATS] Firestore user: ${user.email}');
      print('[NATS] natsCredential runtimeType: ${cred.runtimeType}');
      print('[NATS] subscriptions: $subs');
    }

    await connect(
      url: url,
      credentials: credsMap,
      topics: subs,
      connectionName: connectionName ?? user.email,
    );
  }

  /// Connect to NATS (NGS) and subscribe to optional topics.
  ///
  /// For NGS, `credentials` should contain either:
  ///   - {'creds': '<full .creds file text>'}
  ///   - or {'jwt': '...', 'seed': '...'}
  ///   - or token / username+password for non-NGS setups.
  Future<void> connect({
    required String url,
    Map<String, dynamic>? credentials,
    List<String>? topics,
    String? connectionName,
    bool tlsOnly = false,
    dart_nats.Client? clientOverride,
  }) async {
    if (_client != null) {
      if (kDebugMode) {
        print(
          '[NATS] connect() called but client already exists, '
          'status: ${_client!.status}',
        );
      }
      return; // already connected/connecting
    }

    final client = clientOverride ?? dart_nats.Client();
    _client = client;

    // Keep ValueNotifier in sync with the real client status.
    _statusSub?.cancel();
    _statusSub = client.statusStream.listen((status) {
      if (kDebugMode) print('[NATS] status changed: $status');
      connected.value = status == dart_nats.Status.connected;
    });

    try {
      dart_nats.ConnectOption? opt;

      if (credentials != null) {
        if (credentials.containsKey('creds')) {
          // Full .creds file content (like the big string you pasted).
          final parsed = _parseNatsCreds(
            credentials['creds']?.toString() ?? '',
          );
          if (parsed != null) {
            final jwt = parsed['jwt'];
            final seed = parsed['seed'];
            if (seed != null && seed.isNotEmpty) {
              client.seed = seed;
            }
            opt = dart_nats.ConnectOption(
              jwt: jwt,
              name: connectionName,
              verbose: true,
            );
          } else {
            if (kDebugMode) {
              print(
                '[NATS] _parseNatsCreds() returned null — cannot extract jwt/seed',
              );
            }
          }
        } else if (credentials.containsKey('jwt') &&
            credentials.containsKey('seed')) {
          // Direct jwt + seed shape
          final jwt = credentials['jwt']?.toString();
          final seed = credentials['seed']?.toString();
          if (seed != null && seed.isNotEmpty) {
            client.seed = seed;
          }
          opt = dart_nats.ConnectOption(
            jwt: jwt,
            name: connectionName,
            verbose: true,
          );
        } else if (credentials.containsKey('token')) {
          opt = dart_nats.ConnectOption(
            authToken: credentials['token'],
            name: connectionName,
            verbose: true,
          );
        } else if (credentials.containsKey('username') &&
            credentials.containsKey('password')) {
          opt = dart_nats.ConnectOption(
            user: credentials['username'],
            pass: credentials['password'],
            name: connectionName,
            verbose: true,
          );
        }
      }

      final parsedUrl = Uri.parse(url);
      if (kDebugMode) {
        print('[NATS] connecting to: $parsedUrl');
        print(
          '[NATS] connectOption: '
          'jwt=${opt?.jwt != null}, '
          'token=${opt?.authToken != null}, '
          'user=${opt?.user}',
        );
      }

      await client.connect(parsedUrl, connectOption: opt);
      if (kDebugMode) {
        print('[NATS] connected, client.status: ${client.status}');
      }

      // Subscribe to topics, if any.
      if (topics != null && topics.isNotEmpty) {
        for (final t in topics) {
          final sub = client.sub(t);
          sub.stream.listen((msg) {
            if (kDebugMode) print('[NATS][$t] ${msg.string}');
          });
          _subs[t] = sub;
          if (kDebugMode) print('[NATS] subscribed to $t');
        }
      }

      lastError = null;
      // `connected` ValueNotifier is updated by statusStream listener.
    } catch (e, st) {
      lastError = e.toString();
      if (kDebugMode) {
        print('[NATS] connect error: $e');
        print(st);
      }
      connected.value = false;
      await _statusSub?.cancel();
      _statusSub = null;
      _client = null;
      rethrow;
    }
  }

  /// Disconnect and cleanup
  Future<void> disconnect() async {
    if (_client == null) return;
    try {
      for (final s in _subs.values) {
        try {
          _client!.unSub(s);
        } catch (_) {}
      }
      _subs.clear();
      await _client!.close();
    } catch (_) {
      // ignore
    }
    _client = null;
    await _statusSub?.cancel();
    _statusSub = null;
    connected.value = false;
  }

  /// Publish JSON on a given subject using the current NATS connection.
  ///
  /// Throws [StateError] if no client is connected.
  void publishJson(String subject, Map<String, dynamic> json) {
    final client = _client;
    if (client == null) {
      throw StateError('NATS client is not connected');
    }

    final jsonString = jsonEncode(json);
    final bytes = Uint8List.fromList(utf8.encode(jsonString));

    if (kDebugMode) {
      print('[NATS] publish $subject: $jsonString');
    }

    client.pub(subject, bytes);
  }

  /// Robust .creds parser: extract JWT and seed from an NGS creds string.
  Map<String, String>? _parseNatsCreds(String credsText) {
    if (credsText.trim().isEmpty) return null;

    final jwtRe = RegExp(
      r'-+\s*BEGIN\s+NATS\s+USER\s+JWT\s*-+\s*([\s\S]*?)\s*-+\s*END\s+NATS\s+USER\s+JWT\s*-+',
      multiLine: true,
    );
    final seedRe = RegExp(
      r'-+\s*BEGIN\s+USER\s+NKEY\s+SEED\s*-+\s*([\s\S]*?)\s*-+\s*END\s+USER\s+NKEY\s+SEED\s*-+',
      multiLine: true,
    );

    final jm = jwtRe.firstMatch(credsText);
    final sm = seedRe.firstMatch(credsText);

    if (jm == null || sm == null) {
      if (kDebugMode) {
        print(
          '[NATS] _parseNatsCreds: could not find JWT and/or seed in creds text',
        );
      }
      return null;
    }

    final rawJwt = jm.group(1) ?? '';
    final rawSeed = sm.group(1) ?? '';

    final jwt = rawJwt.replaceAll(RegExp(r'\s+'), '').trim();
    final seed = rawSeed.replaceAll(RegExp(r'\s+'), '').trim();

    if (jwt.isEmpty || seed.isEmpty) {
      if (kDebugMode) {
        print('[NATS] _parseNatsCreds: extracted empty jwt or seed');
      }
      return null;
    }

    return {'jwt': jwt, 'seed': seed};
  }
}
