import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';

/// Helper to detect emergency protocol strings
bool _isProtocolMessage(String body) {
  final clean = body.trim();
  return clean.startsWith("SOS|") ||
      clean.startsWith("ALT|") ||
      clean.startsWith("ACCEPT|") ||
      clean.startsWith("RESCUED|") ||
      clean.startsWith("MEDIA|") ||
      clean.startsWith("MEDIA_PENDING|") ||
      clean.startsWith("TXT|");
}

/// Representation of a message packaged for multi-hop mesh transport.
class MeshPacket {
  final String id;
  final String originNode;
  final String senderPhone;
  final String payload;
  final int ttl;
  final int hops;
  final int timestamp;

  MeshPacket({
    required this.id,
    required this.originNode,
    required this.senderPhone,
    required this.payload,
    this.ttl = 4,
    this.hops = 0,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'origin': originNode,
        'sender': senderPhone,
        'payload': payload,
        'ttl': ttl,
        'hops': hops,
        'ts': timestamp,
      };

  factory MeshPacket.fromJson(Map<String, dynamic> json) => MeshPacket(
        id: json['id'] as String? ?? 'pkt_${DateTime.now().millisecondsSinceEpoch}',
        originNode: json['origin'] as String? ?? 'UNKNOWN',
        senderPhone: json['sender'] as String? ?? '',
        payload: json['payload'] as String? ?? '',
        ttl: (json['ttl'] as num?)?.toInt() ?? 4,
        hops: (json['hops'] as num?)?.toInt() ?? 0,
        timestamp: (json['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      );

  MeshPacket copyWith({int? ttl, int? hops}) => MeshPacket(
        id: id,
        originNode: originNode,
        senderPhone: senderPhone,
        payload: payload,
        ttl: ttl ?? this.ttl,
        hops: hops ?? this.hops,
        timestamp: timestamp,
      );
}

/// Statistics for Bluetooth Mesh activity
class MeshStats {
  int packetsSent = 0;
  int packetsReceived = 0;
  int packetsRelayed = 0;
  int connectedNodesCount = 0;
}

enum MeshStatus { stopped, starting, active, error }

/// Singleton service managing decentralized Bluetooth/Wi-Fi Mesh networking.
/// Works 100% offline with zero internet and zero cellular reception.
/// Provides automatic peer-to-peer clustering and multi-hop packet relaying.
class BluetoothMeshService {
  BluetoothMeshService._internal();
  static final BluetoothMeshService instance = BluetoothMeshService._internal();

  final Nearby _nearby = Nearby();
  static const String _serviceId = "com.example.offline_bridge.mesh";
  final Strategy _strategy = Strategy.P2P_CLUSTER;

  String _localNodeId = "NODE_${Random().nextInt(9000) + 1000}";
  String get localNodeId => _localNodeId;

  MeshStatus _status = MeshStatus.stopped;
  MeshStatus get status => _status;

  final Set<String> _connectedEndpoints = {};
  final Map<String, String> _endpointNodeNames = {};
  final Set<String> _pendingConnectionEndpoints = {};
  final Map<String, Timer> _connectionTimeoutTimers = {};
  final Set<String> _processedPacketIds = {};
  final List<MeshPacket> _pendingOutbox = [];

  final MeshStats stats = MeshStats();

  Function(String sender, String payload)? _onMessageReceived;
  VoidCallback? _onStatusChanged;

  final StreamController<MeshStats> _statsController = StreamController<MeshStats>.broadcast();
  Stream<MeshStats> get statsStream => _statsController.stream;

  Set<String> get connectedEndpoints => Set.unmodifiable(_connectedEndpoints);
  List<String> get connectedNodeNames => _endpointNodeNames.values.toList();
  bool get hasPeers => _connectedEndpoints.isNotEmpty;

  /// Initialize the service with callbacks
  void init({
    required Function(String sender, String payload) onMessageReceived,
    VoidCallback? onStatusChanged,
    String? preferredNodeId,
  }) {
    _onMessageReceived = onMessageReceived;
    _onStatusChanged = onStatusChanged;
    if (preferredNodeId != null && preferredNodeId.isNotEmpty) {
      _localNodeId = preferredNodeId;
    }
  }

  /// Start Bluetooth Mesh discovery and advertising
  Future<bool> startMesh() async {
    if (!Platform.isAndroid) {
      debugPrint("📡 [BT-MESH] Non-Android platform: Running simulated mesh engine.");
      _status = MeshStatus.active;
      _notify();
      return true;
    }

    if (_status == MeshStatus.active || _status == MeshStatus.starting) {
      return true;
    }

    _status = MeshStatus.starting;
    _notify();

    try {
      // 1. Stop any dangling operations to guarantee clean radio state
      try {
        await _nearby.stopAdvertising();
        await _nearby.stopDiscovery();
      } catch (_) {}

      // 2. Start Advertising (Allows others to discover this node)
      bool advertisingOk = await _nearby.startAdvertising(
        _localNodeId,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: (endpointId, connectionInfo) {
          _handleConnectionInitiated(endpointId, connectionInfo);
        },
        onConnectionResult: (endpointId, status) {
          _handleConnectionResult(endpointId, status);
        },
        onDisconnected: (endpointId) {
          _handleDisconnected(endpointId);
        },
      );

      // 3. Start Discovery (Discovers other nearby nodes in the cluster)
      bool discoveryOk = await _nearby.startDiscovery(
        _localNodeId,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: (endpointId, endpointName, serviceId) {
          _handleEndpointFound(endpointId, endpointName);
        },
        onEndpointLost: (endpointId) {
          if (endpointId != null) {
            _handleEndpointLost(endpointId);
          }
        },
      );

      if (advertisingOk || discoveryOk) {
        _status = MeshStatus.active;
        debugPrint("📡 [BT-MESH] Mesh active as $_localNodeId (Adv: $advertisingOk, Disc: $discoveryOk)");
      } else {
        _status = MeshStatus.error;
        debugPrint("❌ [BT-MESH] Failed to start mesh advertising or discovery");
      }
    } catch (e) {
      debugPrint("❌ [BT-MESH] Error starting mesh: $e");
      _status = MeshStatus.error;
    }

    _notify();
    return _status == MeshStatus.active;
  }

  /// Restart Bluetooth Mesh services cleanly
  Future<void> restartMesh() async {
    debugPrint("🔄 [BT-MESH] Clean restart requested...");
    await stopMesh();
    await Future.delayed(const Duration(milliseconds: 600));
    await startMesh();
  }

  /// Stop Bluetooth Mesh services
  Future<void> stopMesh() async {
    for (var timer in _connectionTimeoutTimers.values) {
      timer.cancel();
    }
    _connectionTimeoutTimers.clear();
    _pendingConnectionEndpoints.clear();

    if (!Platform.isAndroid) {
      _status = MeshStatus.stopped;
      _connectedEndpoints.clear();
      _endpointNodeNames.clear();
      _notify();
      return;
    }

    try {
      await _nearby.stopAdvertising();
      await _nearby.stopDiscovery();
      await _nearby.stopAllEndpoints();
      _connectedEndpoints.clear();
      _endpointNodeNames.clear();
      _status = MeshStatus.stopped;
      stats.connectedNodesCount = 0;
      debugPrint("📡 [BT-MESH] Bluetooth Mesh stopped");
    } catch (e) {
      debugPrint("❌ [BT-MESH] Error stopping mesh: $e");
    }

    _notify();
  }

  /// Handles discovery of a nearby peer.
  /// Implements tie-breaking to avoid simultaneous connection collision (STATUS_ALREADY_CONNECTED_TO_ENDPOINT)
  void _handleEndpointFound(String endpointId, String endpointName) {
    debugPrint("📡 [BT-MESH] Discovered node: $endpointName ($endpointId)");

    if (_connectedEndpoints.contains(endpointId)) {
      debugPrint("📡 [BT-MESH] Already connected to $endpointName ($endpointId)");
      return;
    }

    if (_pendingConnectionEndpoints.contains(endpointId)) {
      debugPrint("📡 [BT-MESH] Connection already pending for $endpointName ($endpointId)");
      return;
    }

    // TIE-BREAKER:
    // When both devices discover each other simultaneously in P2P_CLUSTER, both calling
    // requestConnection results in handshake collision (error 8003).
    // Rule: The node with the lexicographically smaller nodeId initiates the request.
    // The node with the larger nodeId waits for the incoming connection.
    final bool shouldInitiate = _localNodeId.compareTo(endpointName) < 0;

    if (shouldInitiate) {
      debugPrint("📡 [BT-MESH] Initiating connection to $endpointName (Tie-breaker: $_localNodeId < $endpointName)");
      _initiateConnection(endpointId, endpointName);
    } else {
      debugPrint("📡 [BT-MESH] Waiting for incoming connection from $endpointName (Tie-breaker: $_localNodeId > $endpointName)");
      // Fallback timer: If peer has not initiated within 3.5 seconds, initiate anyway
      _connectionTimeoutTimers[endpointId]?.cancel();
      _connectionTimeoutTimers[endpointId] = Timer(const Duration(milliseconds: 3500), () {
        if (!_connectedEndpoints.contains(endpointId) && !_pendingConnectionEndpoints.contains(endpointId)) {
          debugPrint("📡 [BT-MESH] Fallback: Peer $endpointName did not initiate in 3.5s. Initiating now...");
          _initiateConnection(endpointId, endpointName);
        }
      });
    }
  }

  /// Sends a connection request to an endpoint with race-condition safeguards
  Future<void> _initiateConnection(String endpointId, String endpointName) async {
    if (_connectedEndpoints.contains(endpointId) || _pendingConnectionEndpoints.contains(endpointId)) {
      return;
    }

    _pendingConnectionEndpoints.add(endpointId);
    _endpointNodeNames[endpointId] = endpointName;

    try {
      debugPrint("📡 [BT-MESH] Calling requestConnection to $endpointName ($endpointId)...");
      await _nearby.requestConnection(
        _localNodeId,
        endpointId,
        onConnectionInitiated: (id, connectionInfo) {
          _handleConnectionInitiated(id, connectionInfo);
        },
        onConnectionResult: (id, status) {
          _handleConnectionResult(id, status);
        },
        onDisconnected: (id) {
          _handleDisconnected(id);
        },
      );
    } catch (e) {
      debugPrint("❌ [BT-MESH] Connection request error to $endpointName: $e");
      _pendingConnectionEndpoints.remove(endpointId);
    }
  }

  void _handleConnectionInitiated(String endpointId, ConnectionInfo connectionInfo) async {
    _connectionTimeoutTimers[endpointId]?.cancel();
    _connectionTimeoutTimers.remove(endpointId);
    _pendingConnectionEndpoints.add(endpointId);
    _endpointNodeNames[endpointId] = connectionInfo.endpointName;

    debugPrint("📡 [BT-MESH] Connection initiated with ${connectionInfo.endpointName} ($endpointId, incoming: ${connectionInfo.isIncomingConnection}). Auto-accepting...");

    try {
      await _nearby.acceptConnection(
        endpointId,
        onPayLoadRecieved: (id, payload) {
          _handleIncomingPayload(id, payload);
        },
        onPayloadTransferUpdate: (id, update) {
          // Progress for large transfers
        },
      );
    } catch (e) {
      debugPrint("❌ [BT-MESH] Error accepting connection from $endpointId: $e");
      _pendingConnectionEndpoints.remove(endpointId);
    }
  }

  void _handleConnectionResult(String endpointId, Status status) {
    _pendingConnectionEndpoints.remove(endpointId);
    _connectionTimeoutTimers[endpointId]?.cancel();
    _connectionTimeoutTimers.remove(endpointId);

    if (status == Status.CONNECTED) {
      _connectedEndpoints.add(endpointId);
      stats.connectedNodesCount = _connectedEndpoints.length;
      debugPrint("🟢 [BT-MESH] Connected to peer: ${_endpointNodeNames[endpointId] ?? endpointId} (Total: ${_connectedEndpoints.length})");
      _flushPendingOutbox();
    } else {
      _connectedEndpoints.remove(endpointId);
      _endpointNodeNames.remove(endpointId);
      stats.connectedNodesCount = _connectedEndpoints.length;
      debugPrint("🔴 [BT-MESH] Connection rejected/failed for $endpointId (Status: $status)");
    }
    _notify();
  }

  void _handleDisconnected(String endpointId) {
    _pendingConnectionEndpoints.remove(endpointId);
    _connectionTimeoutTimers[endpointId]?.cancel();
    _connectionTimeoutTimers.remove(endpointId);
    _connectedEndpoints.remove(endpointId);
    _endpointNodeNames.remove(endpointId);
    stats.connectedNodesCount = _connectedEndpoints.length;
    debugPrint("📡 [BT-MESH] Peer disconnected: $endpointId (Remaining: ${_connectedEndpoints.length})");
    _notify();
  }

  void _handleEndpointLost(String endpointId) {
    _connectionTimeoutTimers[endpointId]?.cancel();
    _connectionTimeoutTimers.remove(endpointId);
    _pendingConnectionEndpoints.remove(endpointId);
    debugPrint("📡 [BT-MESH] Lost nearby node endpoint: $endpointId");
  }

  /// Handles incoming byte packets over Bluetooth.
  /// Decodes both JSON MeshPacket envelopes and raw emergency protocol strings.
  void _handleIncomingPayload(String fromEndpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES || payload.bytes == null) {
      debugPrint("⚠️ [BT-MESH] Received non-byte payload or empty bytes");
      return;
    }

    try {
      final rawText = utf8.decode(payload.bytes!, allowMalformed: true).trim();
      if (rawText.isEmpty) return;

      debugPrint("📥 [BT-MESH] Incoming raw bytes decoded (${payload.bytes!.length}B): $rawText");

      MeshPacket? packet;
      try {
        final decoded = jsonDecode(rawText);
        if (decoded is Map<String, dynamic>) {
          packet = MeshPacket.fromJson(decoded);
        }
      } catch (_) {
        // Not a JSON object; handle as raw emergency protocol string below
      }

      if (packet != null) {
        // 1. Loop Suppression: Has this node already processed this message?
        if (_processedPacketIds.contains(packet.id)) {
          debugPrint("🔁 [BT-MESH] Suppressing duplicate packet: ${packet.id}");
          return;
        }
        _processedPacketIds.add(packet.id);
        stats.packetsReceived++;

        debugPrint("📥 [BT-MESH] Ingested MeshPacket [${packet.id}] from ${packet.originNode} (Sender: ${packet.senderPhone}, Hops: ${packet.hops}, TTL: ${packet.ttl})");

        // 2. Deliver to local application handler
        if (_onMessageReceived != null) {
          final senderId = packet.senderPhone.isNotEmpty ? packet.senderPhone : packet.originNode;
          _onMessageReceived!(senderId, packet.payload);
        }

        // 3. Multi-Hop Mesh Relay Flooding
        // If TTL > 1, decrement TTL, increment hop count, and relay to other connected peers
        if (packet.ttl > 1 && _connectedEndpoints.length > 1) {
          final relayPacket = packet.copyWith(
            ttl: packet.ttl - 1,
            hops: packet.hops + 1,
          );
          _relayPacketToOtherPeers(relayPacket, skipEndpointId: fromEndpointId);
        }
      } else if (_isProtocolMessage(rawText)) {
        // Direct raw protocol string (e.g. SOS|..., ACCEPT|..., ALT|...)
        final packetId = "raw_${rawText.hashCode}_${DateTime.now().millisecondsSinceEpoch}";
        if (_processedPacketIds.contains(packetId)) return;
        _processedPacketIds.add(packetId);
        stats.packetsReceived++;

        debugPrint("📥 [BT-MESH] Ingested raw emergency message from ${_endpointNodeNames[fromEndpointId] ?? fromEndpointId}: $rawText");

        if (_onMessageReceived != null) {
          final senderId = _endpointNodeNames[fromEndpointId] ?? "NEARBY_PEER";
          _onMessageReceived!(senderId, rawText);
        }
      } else {
        debugPrint("⚠️ [BT-MESH] Received unrecognized message format: $rawText");
      }
    } catch (e, stack) {
      debugPrint("❌ [BT-MESH] Error parsing incoming mesh payload: $e\n$stack");
    }

    _notify();
  }

  /// Relays packet to all connected peers except the one it was received from
  void _relayPacketToOtherPeers(MeshPacket packet, {required String skipEndpointId}) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toJson())));
    int count = 0;

    for (final endpoint in _connectedEndpoints) {
      if (endpoint != skipEndpointId) {
        try {
          await _nearby.sendBytesPayload(endpoint, bytes);
          count++;
        } catch (e) {
          debugPrint("❌ [BT-MESH] Failed to relay to $endpoint: $e");
        }
      }
    }

    if (count > 0) {
      stats.packetsRelayed += count;
      debugPrint("🔁 [BT-MESH] Relayed packet [${packet.id}] to $count peer(s) (Hop: ${packet.hops})");
      _notify();
    }
  }

  /// Broadcasts an emergency packet across the Bluetooth Mesh
  /// Returns true if broadcasted to at least one peer or queued for delivery
  Future<bool> broadcastPacket({
    required String payload,
    String senderPhone = '',
    int initialTtl = 4,
  }) async {
    final packet = MeshPacket(
      id: "pkt_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}",
      originNode: _localNodeId,
      senderPhone: senderPhone,
      payload: payload,
      ttl: initialTtl,
      hops: 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    _processedPacketIds.add(packet.id);

    if (!Platform.isAndroid) {
      debugPrint("📡 [BT-MESH SIMULATION] Broadcasted packet: ${packet.id}");
      stats.packetsSent++;
      _notify();
      return true;
    }

    if (_connectedEndpoints.isEmpty) {
      debugPrint("⚠️ [BT-MESH] No connected peers currently. Queued packet in outbox: ${packet.id}");
      _pendingOutbox.add(packet);
      // Auto-trigger discovery/advertising if stopped
      if (_status != MeshStatus.active) {
        startMesh();
      }
      return false;
    }

    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toJson())));
    int sentCount = 0;

    for (final endpoint in _connectedEndpoints) {
      try {
        await _nearby.sendBytesPayload(endpoint, bytes);
        sentCount++;
      } catch (e) {
        debugPrint("❌ [BT-MESH] Failed to send to $endpoint: $e");
      }
    }

    if (sentCount > 0) {
      stats.packetsSent += sentCount;
      debugPrint("🚀 [BT-MESH] Broadcasted packet [${packet.id}] to $sentCount connected peer(s)!");
      _notify();
      return true;
    } else {
      _pendingOutbox.add(packet);
      return false;
    }
  }

  void _flushPendingOutbox() async {
    if (_pendingOutbox.isEmpty || _connectedEndpoints.isEmpty) return;

    debugPrint("📤 [BT-MESH] Flushing ${_pendingOutbox.length} queued packets to newly connected peers...");
    final List<MeshPacket> toSend = List.from(_pendingOutbox);
    _pendingOutbox.clear();

    for (final packet in toSend) {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(packet.toJson())));
      for (final endpoint in _connectedEndpoints) {
        try {
          await _nearby.sendBytesPayload(endpoint, bytes);
          stats.packetsSent++;
        } catch (_) {}
      }
    }
    _notify();
  }

  void _notify() {
    _statsController.add(stats);
    if (_onStatusChanged != null) {
      _onStatusChanged!();
    }
  }

  void dispose() {
    _statsController.close();
    stopMesh();
  }
}
