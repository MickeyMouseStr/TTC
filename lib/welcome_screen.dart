import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'services/nats_service.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final user = FirebaseAuth.instance.currentUser;

  final _searchController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');
  final _priceController = TextEditingController();
  final _stopLossController = TextEditingController();
  final _takeProfitController = TextEditingController();

  final _oaTakeProfitController = TextEditingController();
  final _oaStopLossController = TextEditingController();

  bool _isLong = true;
  // NATS connection indicator
  final ValueNotifier<bool> _natsConnected = ValueNotifier(false);
  Map<String, dynamic>? _natsCredential;
  List<String> _natsSubscriptions = [];

  void _setMkt() {
    setState(() {
      _priceController.text = 'MKT';
    });
  }

  Future<void> _manualNatsConnect() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    try {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: u.email)
          .limit(1)
          .get();
      if (query.docs.isEmpty) return;
      final data = query.docs.first.data();
      final dynamic cred = data['natsCredential'];
      final subs = <String>[];
      if (data['subscriptions'] is Iterable) {
        subs.addAll(List<String>.from(data['subscriptions']));
      }

      await NatsService.instance.connect(
        url: 'tls://connect.ngs.global:4222',
        credentials: cred is Map<String, dynamic> ? cred : null,
        topics: subs,
      );
      if (kDebugMode) print('[NATS] manual connect success');
      setState(() {});
    } catch (e) {
      if (kDebugMode) print('[NATS] manual connect failed: $e');
      setState(() {});
    }
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

  @override
  void initState() {
    super.initState();
    NatsService.instance.connected.addListener(_onNatsConnectedChanged);
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
      if (query.docs.isEmpty) return;
      final data = query.docs.first.data();
      final dynamic cred = data['natsCredential'];
      final subs = <String>[];
      if (data['subscriptions'] is Iterable) {
        subs.addAll(List<String>.from(data['subscriptions']));
      }

      // store for debug
      _natsCredential = cred is Map<String, dynamic> ? Map.from(cred) : null;
      _natsSubscriptions = subs;
      setState(() {});

      // connect and subscribe
      await NatsService.instance.connect(
        url: 'tls://connect.ngs.global:4222',
        credentials: cred is Map<String, dynamic> ? cred : null,
        topics: subs,
      );
    } catch (e) {
      if (kDebugMode) print('setupNatsForUser error: $e');
    }
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
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const SizedBox(width: 8),
                ],
              ),
              // Removed Positioned indicator from individual block; main indicator is in build (bottom-right for entire screen)
            ],
          ),
          if ((kDebugMode) &&
              (_natsCredential != null || _natsSubscriptions.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_natsCredential != null)
                    Text(
                      'NATS Creds: ${_natsCredential!['user'] ?? _natsCredential!['token'] ?? 'creds'}',
                    ),
                  Text('Subscriptions: ${_natsSubscriptions.join(', ')}'),
                  if (NatsService.instance.lastError != null)
                    Text(
                      'NATS lastError: ${NatsService.instance.lastError!}',
                      style: const TextStyle(color: Colors.red),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          // Buttons and inputs
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ToggleButtons(
                isSelected: [_isLong, !_isLong],
                onPressed: (index) {
                  setState(() => _isLong = index == 0);
                },
                children: const [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('Long'),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text('Short'),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _quantityController,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  keyboardType: TextInputType.number,
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
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
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
                width: 110,
                child: TextField(
                  controller: _stopLossController,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Stop-Loss',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _takeProfitController,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Take Profit',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  // TODO: implement trade execution
                },
                child: const Text('Go'),
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
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Take Profit',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: () {}, child: const Text('Go')),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: TextField(
              controller: _oaStopLossController,
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Stop-Loss',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: () {}, child: const Text('Go')),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    // Cleanup controllers and nats
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
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'Profile', child: Text('Profile')),
                const PopupMenuItem(value: 'Settings', child: Text('Settings')),
                const PopupMenuItem(value: 'Logout', child: Text('Logout')),
              ],
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8.0),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey[300],
                ),
                child: Center(
                  child: Text(
                    (user?.email ?? 'U').substring(0, 1).toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Re-connect NATS (debug)',
            onPressed: _manualNatsConnect,
            icon: const Icon(Icons.wifi),
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
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      _buildOrderAdjustment(context),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
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
