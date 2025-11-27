import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'services/nats_service.dart';
import 'services/trade_service.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final user = FirebaseAuth.instance.currentUser;

  // Trade setup controllers
  final _searchController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');
  final _priceController = TextEditingController();
  final _stopLossController = TextEditingController();
  final _takeProfitController = TextEditingController();

  // Order adjustment controllers
  final _oaTakeProfitController = TextEditingController();
  final _oaStopLossController = TextEditingController();

  bool _isLong = true;

  // NATS indicators & debug
  final ValueNotifier<bool> _natsConnected = ValueNotifier(false);
  Map<String, dynamic>? _natsCredential;
  List<String> _natsSubscriptions = [];
  String? _firestoreUid; // <--- Firestore field `uid`

  @override
  void initState() {
    super.initState();
    NatsService.instance.connected.addListener(_onNatsConnectedChanged);
    _onNatsConnectedChanged();
    _setupNatsForUser();
  }

  void _onNatsConnectedChanged() {
    _natsConnected.value = NatsService.instance.connected.value;
  }

  Future<void> _setupNatsForUser() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;

    try {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: u.email)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        final data = query.docs.first.data();
        final cred = data['natsCredential'];

        if (kDebugMode) {
          print('[NATS] Firestore fetched user: ${u.email}');
          print('[NATS] natsCredential runtimeType: ${cred.runtimeType}');
          print('[NATS] subs: ${data['subscriptions']}');
        }

        final rawSubs = data['subscriptions'];

        setState(() {
          _firestoreUid = data['uid']?.toString(); // <--- grab Firestore uid
          _natsCredential = cred is Map<String, dynamic>
              ? Map<String, dynamic>.from(cred)
              : null;
          if (rawSubs is Iterable) {
            _natsSubscriptions = List<String>.from(rawSubs);
          } else if (rawSubs is String && rawSubs.trim().isNotEmpty) {
            _natsSubscriptions = [rawSubs.trim()];
          } else {
            _natsSubscriptions = <String>[];
          }
        });
      }

      await NatsService.instance.connectForCurrentUser(
        url: 'tls://connect.ngs.global:4222',
        connectionName: u.email,
      );

      if (kDebugMode) print('[NATS] auto connect success');
      setState(() {});
    } catch (e, st) {
      if (kDebugMode) {
        print('[NATS] auto connect failed: $e');
        print(st);
      }
      setState(() {});
    }
  }

  Future<void> _reconnectNats() async {
    await NatsService.instance.disconnect();
    await _setupNatsForUser();
  }

  void _setLong() {
    setState(() => _isLong = true);
  }

  void _setShort() {
    setState(() => _isLong = false);
  }

  void _setMkt() {
    setState(() {
      _priceController.text = 'MKT';
    });
  }

  void _toggleProfileMenu(String choice) async {
    switch (choice) {
      case 'Profile':
        // TODO: show profile
        break;
      case 'Settings':
        // TODO: settings
        break;
      case 'Logout':
        final router = GoRouter.of(context);
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        router.go('/');
        break;
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _onGoPressed() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      _showSnack('No logged in user');
      return;
    }

    if (_firestoreUid == null || _firestoreUid!.isEmpty) {
      _showSnack('No Firestore uid found for user');
      return;
    }

    final instrument = _searchController.text.trim();
    if (instrument.isEmpty) {
      _showSnack('Please select an instrument');
      return;
    }

    final qtyText = _quantityController.text.trim();
    final qty = int.tryParse(qtyText);
    if (qty == null || qty <= 0) {
      _showSnack('Invalid quantity');
      return;
    }

    final priceText = _priceController.text.trim();
    String priceType;
    double? price;
    if (priceText.isEmpty || priceText.toUpperCase() == 'MKT') {
      priceType = 'MKT';
      price = null;
    } else {
      final parsed = double.tryParse(priceText.replaceAll(',', '.'));
      if (parsed == null || parsed <= 0) {
        _showSnack('Invalid price');
        return;
      }
      priceType = 'LIMIT';
      price = parsed;
    }

    double? sl;
    final slText = _stopLossController.text.trim();
    if (slText.isNotEmpty) {
      sl = double.tryParse(slText.replaceAll(',', '.'));
      if (sl == null) {
        _showSnack('Invalid stop loss');
        return;
      }
    }

    double? tp;
    final tpText = _takeProfitController.text.trim();
    if (tpText.isNotEmpty) {
      tp = double.tryParse(tpText.replaceAll(',', '.'));
      if (tp == null) {
        _showSnack('Invalid take profit');
        return;
      }
    }

    try {
      await TradeService.instance.sendNewTrade(
        instrument: instrument,
        isLong: _isLong,
        quantity: qty,
        priceType: priceType,
        price: price,
        stopLoss: sl,
        takeProfit: tp,
        userId: _firestoreUid!, // <--- Firestore uid used here
      );
      _showSnack('Trade sent');
    } catch (e) {
      _showSnack('Failed to send trade: $e');
    }
  }

  @override
  void dispose() {
    NatsService.instance.disconnect();
    NatsService.instance.connected.removeListener(_onNatsConnectedChanged);
    _natsConnected.dispose();
    _searchController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _stopLossController.dispose();
    _takeProfitController.dispose();
    _oaTakeProfitController.dispose();
    _oaStopLossController.dispose();
    super.dispose();
  }

  Widget _buildTradeSetup(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Search Field
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search instruments',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        filled: true,
                        fillColor: Colors.grey[100],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Paste from clipboard',
                    icon: const Icon(Icons.paste),
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        _searchController.text = data!.text!;
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Instrument row + direction
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Instrument',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[400]!),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.show_chart, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _searchController.text.isEmpty
                                      ? 'No instrument selected'
                                      : _searchController.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'Direction',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ToggleButtons(
                        isSelected: [_isLong, !_isLong],
                        onPressed: (index) {
                          if (index == 0) {
                            _setLong();
                          } else {
                            _setShort();
                          }
                        },
                        borderRadius: BorderRadius.circular(8),
                        children: const [
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12.0,
                              vertical: 6,
                            ),
                            child: Text('Long'),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12.0,
                              vertical: 6,
                            ),
                            child: Text('Short'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Quantity / Price / SL / TP
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _quantityController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: false,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _priceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Price',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(onPressed: _setMkt, child: const Text('MKT')),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _stopLossController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Stop Loss',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _takeProfitController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Take Profit',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _onGoPressed,
                    child: const Text('Go'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOrderAdjustment(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: TextField(
              controller: _oaTakeProfitController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Take Profit',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: TextField(
              controller: _oaStopLossController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Stop Loss',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              // TODO: implement order adjustment (can also go through TradeService)
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[200],
      appBar: AppBar(
        title: const Text('Trade Screen'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: PopupMenuButton<String>(
              onSelected: _toggleProfileMenu,
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'Profile', child: Text('Profile')),
                PopupMenuItem(value: 'Settings', child: Text('Settings')),
                PopupMenuItem(value: 'Logout', child: Text('Logout')),
              ],
              child: Row(
                children: [
                  Text(user?.email ?? 'User'),
                  const SizedBox(width: 8),
                  const Icon(Icons.account_circle),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Upper - Trade Setup
              Container(
                color: Colors.white,
                width: double.infinity,
                child: _buildTradeSetup(context),
              ),
              const Divider(height: 1),
              // Lower - Order Adjustment
              Expanded(
                child: Container(
                  color: Colors.grey[100],
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'Order Adjustment',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      _buildOrderAdjustment(context),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Top-right NATS debug controls
          Positioned(
            right: 8,
            top: 8,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Re-connect NATS (debug)',
                  onPressed: _reconnectNats,
                  icon: const Icon(Icons.wifi),
                ),
                IconButton(
                  tooltip: 'Disconnect NATS',
                  onPressed: () {
                    NatsService.instance.disconnect();
                  },
                  icon: const Icon(Icons.wifi_off),
                ),
              ],
            ),
          ),

          // Bottom-left NATS debug info
          Positioned(
            left: 8,
            bottom: 8,
            child: Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_natsCredential != null)
                      Text(
                        'NATS Creds: '
                        '${_natsCredential!['user'] ?? _natsCredential!['token'] ?? 'creds'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    Text(
                      'Subscriptions: ${_natsSubscriptions.join(', ')}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (NatsService.instance.lastError != null)
                      Text(
                        'NATS lastError: ${NatsService.instance.lastError!}',
                        style: const TextStyle(color: Colors.red),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom-right connection status lightbulb
          Positioned(
            right: 8,
            bottom: 8,
            child: ValueListenableBuilder<bool>(
              valueListenable: _natsConnected,
              builder: (context, connected, child) => Tooltip(
                message: connected ? 'Connected' : 'Disconnected',
                child: Icon(
                  Icons.lightbulb,
                  color: connected ? Colors.greenAccent : Colors.grey,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
