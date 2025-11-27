# Trading Desktop App (Flutter + NATS + Firebase)

This project is a Flutter **desktop** trading prototype that connects to a NATS backend (Synadia/NGS), using per-user credentials stored in Firebase Firestore. It provides a simple trade ticket UI that publishes structured JSON messages to NATS subjects.

---

## What’s implemented so far

### 1. Authentication & user bootstrap

- Uses **Firebase Auth** to identify the currently signed-in user.
- On the `WelcomeScreen`:
  - Looks up the user in Firestore from the `users` collection by `email`.
  - Reads and stores:
    - `uid` (used as the user id token in trade subjects).
    - `natsCredential` (either a full `.creds` string or a structured map).
    - `subscriptions` (list of NATS subjects to subscribe to on connect).
  - Displays basic debug info:
    - Which NATS credentials are in use (user/token/creds).
    - The list of active subscriptions.
    - Any last NATS error.

---

### 2. NATS integration (Synadia / NGS)

All NATS interaction is encapsulated in `services/nats_service.dart`.

**Key capabilities:**

- **Per-user connection** via `connectForCurrentUser`:
  - Expects Firestore to hold either:
    - A raw `.creds` file in `natsCredential`, **or**
    - A map with `jwt`/`seed` or `token` or `username`/`password`.
  - Uses `tls://connect.ngs.global:4222` (TLS) for Synadia NGS.
  - Automatically subscribes to all subjects from Firestore `subscriptions`.

- **Credential handling**:
  - Robust `.creds` parser extracts:
    - `JWT` from `-----BEGIN NATS USER JWT----- ... -----END NATS USER JWT-----`.
    - `NKEY seed` from `-----BEGIN USER NKEY SEED----- ... -----END USER NKEY SEED-----`.
  - Supports:
    - JWT + NKEY seed (NGS-style).
    - Token-based auth.
    - Username/password auth.

- **Connection state & lifecycle**:
  - Wraps a `dart_nats.Client`.
  - Keeps a `ValueNotifier<bool> connected` in sync with the client’s `statusStream`.
  - Tracks `lastError` for display in the UI.
  - Clean `disconnect()`:
    - Unsubscribes from all tracked subscriptions.
    - Closes the NATS client and cancels the status listener.

- **Publishing helper**:
  - `publishJson(String subject, Map<String, dynamic> json)`:
    - Serializes to JSON.
    - Sends as bytes via `client.pub(...)`.
    - Logs the payload in debug mode.

---

### 3. Trade domain logic

All “domain-level” trading behavior currently lives in `services/trade_service.dart`.

#### NEW_TRADE command

- Public API:  
  ```dart
  Future<void> sendNewTrade({
    required String instrument,
    required bool isLong,
    required int quantity,
    required String priceType, // "MKT" or "LIMIT"
    double? price,
    double? stopLoss,
    double? takeProfit,
    required String userId,
  })
