import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'nats_service.dart';

/// Domain-level trading functions (trades, adjustments, etc.)
class TradeService {
  TradeService._();
  static final TradeService instance = TradeService._();

  /// Sends a NEW_TRADE message as JSON on:
  ///   Trades.<InstrumentToken>.<UserIdToken>
  ///
  /// - [instrument]: human-readable instrument (as chosen in UI)
  /// - [isLong]: true = BUY, false = SELL
  /// - [quantity]: positive integer
  /// - [priceType]: 'MKT' or 'LIMIT'
  /// - [price]: required if priceType == 'LIMIT'
  /// - [stopLoss] / [takeProfit]: optional
  /// - [userId]: comes from Firestore field `uid`
  Future<void> sendNewTrade({
    required String instrument,
    required bool isLong,
    required int quantity,
    required String priceType,
    double? price,
    double? stopLoss,
    double? takeProfit,
    required String userId,
  }) async {
    if (!NatsService.instance.connected.value) {
      throw StateError('Not connected to NATS');
    }

    final subject = _buildTradeSubject(instrument, userId);
    final side = isLong ? 'BUY' : 'SELL';
    final now = DateTime.now().toUtc();

    final payload = <String, dynamic>{
      'userId': userId,
      'instrument': instrument,
      'side': side,
      'quantity': quantity,
      'priceType': priceType, // MKT / LIMIT
      if (price != null) 'price': price,
      if (stopLoss != null) 'stopLoss': stopLoss,
      if (takeProfit != null) 'takeProfit': takeProfit,
      'timestamp': now.toIso8601String(),
    };

    if (kDebugMode) {
      print(
        '[TradeService] publish NEW_TRADE to $subject: '
        '${jsonEncode(payload)}',
      );
    }

    NatsService.instance.publishJson(subject, payload);
  }

  /// Builds subject: Trades.<InstrumentToken>.<UserIdToken>
  String _buildTradeSubject(String instrument, String userId) {
    final instToken = _sanitizeToken(instrument);
    final userToken = _sanitizeToken(userId);
    return 'Trades.$instToken.$userToken';
  }

  /// Convert arbitrary text into NATS-safe token:
  /// - uppercase
  /// - spaces -> '_'
  /// - everything except [A-Z0-9_.-] -> '_'
  String _sanitizeToken(String value) {
    final trimmed = value.trim().toUpperCase();
    if (trimmed.isEmpty) return 'UNKNOWN';
    final noSpaces = trimmed.replaceAll(RegExp(r'\s+'), '_');
    return noSpaces.replaceAll(RegExp(r'[^A-Z0-9_.-]'), '_');
  }
}
