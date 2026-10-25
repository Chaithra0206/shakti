import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:postgres/postgres.dart';
import '../config/secrets.dart';

// The actual connection string is securely loaded from lib/config/secrets.dart
// which is ignored by Git, ensuring your credentials are NEVER pushed to GitHub.

class NeonDbService {
  NeonDbService._internal();
  static final NeonDbService instance = NeonDbService._internal();

  Connection? _connection;
  bool _isConnecting = false;

  /// Check if the user has replaced the default placeholder string
  bool get isConfigured =>
      neonConnectionString.isNotEmpty &&
      !neonConnectionString.contains("PASTE_YOUR_NEON_CONNECTION_STRING_HERE") &&
      neonConnectionString.startsWith("postgres");

  /// Parse the connection string into an Endpoint
  Endpoint? _parseConnectionString(String connStr) {
    try {
      final uri = Uri.parse(connStr);
      String username = '';
      String? password;

      if (uri.userInfo.isNotEmpty) {
        final userParts = uri.userInfo.split(':');
        username = Uri.decodeComponent(userParts[0]);
        if (userParts.length > 1) {
          password = Uri.decodeComponent(userParts.sublist(1).join(':'));
        }
      }

      final dbName = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : 'neondb';
      final port = uri.port > 0 ? uri.port : 5432;

      return Endpoint(
        host: uri.host,
        port: port,
        database: dbName,
        username: username.isNotEmpty ? username : null,
        password: password,
      );
    } catch (e) {
      debugPrint("❌ Error parsing Neon DB connection string: $e");
      return null;
    }
  }

  /// Get or create an active connection to Neon PostgreSQL
  Future<Connection?> getConnection() async {
    if (!isConfigured) {
      debugPrint("⚠️ Neon DB connection string is not configured yet.");
      return null;
    }

    if (_connection != null && _connection!.isOpen) {
      return _connection;
    }

    if (_isConnecting) {
      // Wait for in-flight connection
      int waitMs = 0;
      while (_isConnecting && waitMs < 5000) {
        await Future.delayed(const Duration(milliseconds: 200));
        waitMs += 200;
      }
      if (_connection != null && _connection!.isOpen) return _connection;
    }

    _isConnecting = true;
    try {
      final endpoint = _parseConnectionString(neonConnectionString);
      if (endpoint == null) {
        _isConnecting = false;
        return null;
      }

      debugPrint("🔌 Connecting to Neon DB at ${endpoint.host}...");
      _connection = await Connection.open(
        endpoint,
        settings: const ConnectionSettings(
          sslMode: SslMode.require,
          connectTimeout: Duration(seconds: 15),
          queryTimeout: Duration(seconds: 15),
        ),
      );

      debugPrint("✅ Connected to Neon PostgreSQL successfully!");
      await _ensureTableExists(_connection!);
      _isConnecting = false;
      return _connection;
    } catch (e) {
      _isConnecting = false;
      debugPrint("❌ Neon DB connection error: $e");
      return null;
    }
  }

  /// Automatically create the emergency_wal_logs table if it doesn't exist
  Future<void> _ensureTableExists(Connection conn) async {
    try {
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS emergency_wal_logs (
          hlc_timestamp TEXT PRIMARY KEY,
          sender TEXT,
          payload TEXT,
          status TEXT,
          victim_location TEXT,
          created_at TIMESTAMPTZ DEFAULT NOW()
        );
      ''');
    } catch (e) {
      debugPrint("Notice ensuring table exists: $e");
    }
  }

  /// Upsert a single emergency record into Neon DB
  Future<bool> upsertRecord({
    required String hlc,
    required String sender,
    required String payload,
    required String status,
    String? victimLocation,
  }) async {
    try {
      final conn = await getConnection();
      if (conn == null) return false;

      await conn.execute(
        Sql.named('''
          INSERT INTO emergency_wal_logs (hlc_timestamp, sender, payload, status, victim_location)
          VALUES (@hlc, @sender, @payload, @status, @victimLocation)
          ON CONFLICT (hlc_timestamp) 
          DO UPDATE SET 
            payload = EXCLUDED.payload,
            status = EXCLUDED.status,
            victim_location = COALESCE(EXCLUDED.victim_location, emergency_wal_logs.victim_location);
        '''),
        parameters: {
          'hlc': hlc,
          'sender': sender,
          'payload': payload,
          'status': status,
          'victimLocation': victimLocation,
        },
      );
      return true;
    } catch (e) {
      debugPrint("❌ Error upserting record to Neon DB: $e");
      return false;
    }
  }

  /// Close the connection cleanly if needed
  Future<void> close() async {
    try {
      if (_connection != null && _connection!.isOpen) {
        await _connection!.close();
        _connection = null;
      }
    } catch (_) {}
  }
}
