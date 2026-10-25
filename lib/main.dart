import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:another_telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:sqflite/sqflite.dart';
import 'services/bluetooth_mesh_service.dart';
import 'services/neon_db_service.dart';

// SUPABASE CONFIGURATION
const String supabaseUrl = "https://cpqowlqxmruszognbzbn.supabase.co";
const String supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNwcW93bHF4bXJ1c3pvZ25iemJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ5OTAzMDEsImV4cCI6MjEwMDU2NjMwMX0.oqpZg0hbdfoL3pWxtspSEnT8wqK6uJra4Hub1qO-H3E";

String normalizePhoneSender(String input) {
  final trimmed = input.trim();
  if (trimmed.startsWith("NODE_") || trimmed == "ALL_NEARBY" || trimmed == "MESH_BROADCAST" || trimmed == "NEARBY_PEER") {
    return trimmed;
  }
  String digitsOnly = trimmed.replaceAll(RegExp(r'\D'), '');
  if (digitsOnly.length > 10) {
    return digitsOnly.substring(digitsOnly.length - 10);
  }
  return digitsOnly.isEmpty ? trimmed : digitsOnly;
}

final StreamController<void> _walUpdateStream = StreamController<void>.broadcast();

bool isEmergencyProtocolMessage(String body) {
  final clean = body.trim();
  return clean.startsWith("SOS|") ||
      clean.startsWith("ALT|") ||
      clean.startsWith("ACCEPT|") ||
      clean.startsWith("RESCUED|") ||
      clean.startsWith("MEDIA|") ||
      clean.startsWith("MEDIA_PENDING|") ||
      clean.startsWith("TXT|");
}

// -----------------------------------------------------------------------------
// PURE DART FILE-BASED PERSISTENT WAL STORE & CONFIG STORE
// -----------------------------------------------------------------------------
class LocalWalStore {
  static Future<File> _getWalFile() async {
    Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = Directory('/data/user/0/com.example.offline_bridge/app_flutter');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
    return File('${dir.path}/emergency_wal.json');
  }

  static Future<File> _getConfigFile() async {
    Directory dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/app_config.json');
  }

  static Future<void> saveQuickSosNumber(String number) async {
    try {
      final file = await _getConfigFile();
      await file.writeAsString(jsonEncode({'quick_sos_number': number}));
    } catch (e) {
      debugPrint("Config save error: $e");
    }
  }

  static Future<String> getQuickSosNumber() async {
    try {
      final file = await _getConfigFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        return data['quick_sos_number'] ?? '';
      }
    } catch (e) {
      debugPrint("Config read error: $e");
    }
    return '';
  }

  static Future<void> insertRecord({
    required String hlc,
    required String sender,
    required String payload,
    required bool isMe,
    String? localMediaPath,
  }) async {
    try {
      final file = await _getWalFile();

      if (await file.exists()) {
        final lines = await file.readAsLines();
        for (var line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final existing = jsonDecode(line.trim());
            if (!payload.startsWith("ALT|")) {
              if (existing['hlc'] == hlc || (existing['payload'] == payload && existing['sender'] == sender)) {
                return;
              }
            }
          } catch (_) {}
        }
      }

      final recordMap = {
        'hlc': hlc,
        'sender': sender,
        'payload': payload,
        'is_me': isMe ? 1 : 0,
        'status': 'PENDING',
        'local_media_path': localMediaPath ?? '',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      final line = jsonEncode(recordMap) + '\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      _walUpdateStream.add(null);
    } catch (e) {
      debugPrint("❌ WAL WRITE ERROR: $e");
    }
  }

  static Future<List<Map<String, dynamic>>> readAllRecords() async {
    try {
      final file = await _getWalFile();
      if (!await file.exists()) return [];

      final lines = await file.readAsLines();
      List<Map<String, dynamic>> records = [];

      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final parsed = jsonDecode(line.trim());
          if (parsed is Map<String, dynamic>) {
            records.add(parsed);
          }
        } catch (_) {}
      }
      return records;
    } catch (e) {
      return [];
    }
  }

  static Future<int> syncPendingToSupabase(Telephony telephony) async {
    try {
      final file = await _getWalFile();
      if (!await file.exists()) return 0;

      final records = await readAllRecords();
      if (records.isEmpty) return 0;

      int syncedCount = 0;
      bool hasChanges = false;
      final supabase = Supabase.instance.client;

      for (var record in records) {
        if (record['status'] == 'PENDING') {
          try {
            String payloadStr = record['payload'].toString();
            String localPath = record['local_media_path']?.toString() ?? '';

            if (payloadStr.startsWith("MEDIA_PENDING|") && localPath.isNotEmpty) {
              final mediaFile = File(localPath);
              if (await mediaFile.exists()) {
                final bytes = await mediaFile.readAsBytes();
                final fileExt = localPath.split('.').last;
                final fileName = "${DateTime.now().millisecondsSinceEpoch}.$fileExt";
                final filePath = "emergency_uploads/$fileName";

                await supabase.storage.from('emergency-media').uploadBinary(filePath, bytes);
                final String publicUrl = supabase.storage.from('emergency-media').getPublicUrl(filePath);

                final parts = payloadStr.split('|');
                String sessionId = parts.length > 1 ? parts[1] : "S_SYNC";
                payloadStr = "MEDIA|$sessionId|$publicUrl";
                record['payload'] = payloadStr;
              }
            }

            String currentStatus = "SOS";
            if (payloadStr.startsWith("ACCEPT|")) currentStatus = "ACCEPTED";
            if (payloadStr.startsWith("RESCUED|")) currentStatus = "RESCUED";
            if (payloadStr.startsWith("MEDIA|")) currentStatus = "MEDIA";
            if (payloadStr.startsWith("TXT|")) currentStatus = "CHAT";

            final parts = payloadStr.split('|');
            String victimLoc = (parts.length >= 4 && (parts[0] == 'SOS' || parts[0] == 'ALT')) ? "${parts[2]}, ${parts[3]}" : "";

            // 1. Sync to Supabase
            try {
              await supabase.from('emergency_wal_logs').upsert({
                'hlc_timestamp': record['hlc'].toString(),
                'sender': record['sender'].toString(),
                'payload': payloadStr,
                'status': currentStatus,
                'victim_location': victimLoc.isNotEmpty ? victimLoc : null,
              }, onConflict: 'hlc_timestamp');
            } catch (supaErr) {
              debugPrint("Supabase sync notice: $supaErr");
            }

            // 2. Sync to Neon DB (if connection string is set)
            if (NeonDbService.instance.isConfigured) {
              await NeonDbService.instance.upsertRecord(
                hlc: record['hlc'].toString(),
                sender: record['sender'].toString(),
                payload: payloadStr,
                status: currentStatus,
                victimLocation: victimLoc.isNotEmpty ? victimLoc : null,
              );
            }

            record['status'] = 'SYNCED';
            syncedCount++;
            hasChanges = true;
          } catch (e) {
            debugPrint("Sync row exception: $e");
          }
        }
      }

      if (hasChanges) {
        final buffer = StringBuffer();
        for (var rec in records) {
          buffer.writeln(jsonEncode(rec));
        }
        await file.writeAsString(buffer.toString(), flush: true);
        _walUpdateStream.add(null);
      }

      return syncedCount;
    } catch (e) {
      debugPrint("Sync execution error: $e");
      return 0;
    }
  }

  static Future<void> clearAll() async {
    try {
      final file = await _getWalFile();
      if (await file.exists()) {
        await file.delete();
      }
      _walUpdateStream.add(null);
    } catch (e) {
      debugPrint("Error clearing WAL file: $e");
    }
  }
}

// TOP-LEVEL BACKGROUND SMS HANDLER
@pragma('vm:entry-point')
void backgroundSmsHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();

  final body = message.body ?? "";
  final sender = message.address ?? "Unknown";

  if (body.isEmpty || !isEmergencyProtocolMessage(body)) return;

  String cleanSender = normalizePhoneSender(sender);

  final now = DateTime.now().millisecondsSinceEpoch;
  final hlc = "$now:0:BG_NODE";
  await LocalWalStore.insertRecord(
    hlc: hlc,
    sender: cleanSender,
    payload: body,
    isMe: false,
  );

  if (body.startsWith("SOS|")) {
    try {
      FlutterRingtonePlayer().playAlarm(looping: true, asAlarm: true);
    } catch (e) {
      debugPrint("Background Siren Error: $e");
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseAnonKey,
    );
  } catch (e) {
    debugPrint("Supabase init notice: $e");
  }

  runApp(const OfflineBridgeApp());
}

// -----------------------------------------------------------------------------
// HYBRID LOGICAL CLOCK (HLC)
// -----------------------------------------------------------------------------
class Hlc implements Comparable<Hlc> {
  final int physicalTime;
  final int logicalCounter;
  final String nodeId;

  Hlc({
    required this.physicalTime,
    required this.logicalCounter,
    required this.nodeId,
  });

  factory Hlc.now(String nodeId, {Hlc? lastSeen}) {
    int now = DateTime.now().millisecondsSinceEpoch;
    if (lastSeen == null) {
      return Hlc(physicalTime: now, logicalCounter: 0, nodeId: nodeId);
    }
    int maxPhysical = max(now, lastSeen.physicalTime);
    int nextCounter = (maxPhysical == lastSeen.physicalTime) ? lastSeen.logicalCounter + 1 : 0;
    return Hlc(physicalTime: maxPhysical, logicalCounter: nextCounter, nodeId: nodeId);
  }

  String pack() => "$physicalTime:$logicalCounter:$nodeId";

  @override
  int compareTo(Hlc other) {
    if (physicalTime != other.physicalTime) return physicalTime.compareTo(other.physicalTime);
    if (logicalCounter != other.logicalCounter) return logicalCounter.compareTo(other.logicalCounter);
    return nodeId.compareTo(other.nodeId);
  }
}

// -----------------------------------------------------------------------------
// MAIN FLUTTER APPLICATION
// -----------------------------------------------------------------------------
class OfflineBridgeApp extends StatelessWidget {
  const OfflineBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OffGrid SOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const MethodChannel _emergencyChannel = MethodChannel('com.example.offline_bridge/emergency_actions');
  final Telephony telephony = Telephony.instance;
  final List<ParsedPacket> _packets = [];
  final Set<String> _acceptedSessionIds = {};
  bool _permissionGranted = false;
  bool _isAlarmPlaying = false;
  bool _sirenManuallyMuted = false;
  bool _showHistoryArchive = false;
  Hlc? _latestHlc;

  double? _currentDeviceLat;
  double? _currentDeviceLng;
  Position? _lastBroadcastPosition;
  String _presetQuickNumber = "";

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<void>? _walSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _realtimeSupabaseSubscription;
  Timer? _periodicFileWatcher;
  Timer? _autoSyncTimer;

  bool _isOnline = false;
  bool _isHighPrecisionGpsActive = false;
  bool _isLocationServiceEnabled = true;

  @override
  void initState() {
    super.initState();
    _initEmergencyActionChannel();
    BluetoothMeshService.instance.init(
      onMessageReceived: (sender, payload) {
        _handleIncomingMessage(sender, payload, isSentByMe: false);
      },
      onStatusChanged: () {
        if (mounted) setState(() {});
      },
    );
    _requestPermissions();
    _loadWalFromStorage();
    _loadPresetQuickNumber();
    _initConnectivityListener();
    _initRealtimeListeners();
    _initNativeEmergencyActions();

    _autoSyncTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_isOnline) {
        _triggerCloudSync();
      }
    });
  }

  @override
  void dispose() {
    BluetoothMeshService.instance.stopMesh();
    _positionSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _walSubscription?.cancel();
    _realtimeSupabaseSubscription?.cancel();
    _periodicFileWatcher?.cancel();
    _autoSyncTimer?.cancel();
    super.dispose();
  }

  void _loadPresetQuickNumber() async {
    String num = await LocalWalStore.getQuickSosNumber();
    if (mounted) setState(() => _presetQuickNumber = num);
  }

  void _initNativeEmergencyActions() {
    _emergencyChannel.setMethodCallHandler((call) async {
      if (call.method == "onEmergencyTrigger") {
        final action = call.arguments as String?;
        if (action != null) {
          _handleEmergencyAction(action);
        }
      }
    });

    // Auto-mount lockscreen emergency widget and handle cold-start intent triggers
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _emergencyChannel.invokeMethod('showLockscreenNotification');
      } catch (e) {
        debugPrint("Error auto-activating lock screen SOS widget: $e");
      }
      try {
        final String? initialAction = await _emergencyChannel.invokeMethod<String>('getInitialAction');
        if (initialAction != null && initialAction.isNotEmpty) {
          _handleEmergencyAction(initialAction);
        }
      } catch (e) {
        debugPrint("Error checking initial emergency action: $e");
      }
    });
  }

  Future<void> _handleEmergencyAction(String action) async {
    debugPrint("🚨 Received Native Emergency Action: $action");
    if (action == 'sos') {
      if (_presetQuickNumber.isEmpty) {
        _presetQuickNumber = await LocalWalStore.getQuickSosNumber();
      }
      _dispatchQuickSosPayload();
    } else if (action == 'siren') {
      if (_isAlarmPlaying) {
        _stopSiren();
      } else {
        _startSiren();
      }
    }
  }

  Future<void> _pinSosWidget() async {
    try {
      final bool? success = await _emergencyChannel.invokeMethod<bool>('pinSosWidget');
      if (mounted) {
        if (success == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.green,
              content: Text("📌 SOS Widget pinning requested! Check your home screen to place it."),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.orange,
              content: Text("ℹ️ Automatic pinning not supported. You can add the 'SHAKTI SOS' widget manually from your home screen widget menu."),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Widget pinning error: $e")),
        );
      }
    }
  }

  void _initRealtimeListeners() {
    _walSubscription = _walUpdateStream.stream.listen((_) {
      _loadWalFromStorage();
    });

    _periodicFileWatcher = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadWalFromStorage();
    });

    try {
      final supabase = Supabase.instance.client;
      _realtimeSupabaseSubscription = supabase
          .from('emergency_wal_logs')
          .stream(primaryKey: ['hlc_timestamp'])
          .listen((data) async {
        for (var row in data) {
          String sender = row['sender'] ?? '';
          String payload = row['payload'] ?? '';
          String hlc = row['hlc_timestamp'] ?? '';

          if (payload.isNotEmpty && isEmergencyProtocolMessage(payload)) {
            bool exists = _packets.any((p) => p.rawBody == payload && normalizePhoneSender(p.sender) == normalizePhoneSender(sender));
            if (!exists) {
              await LocalWalStore.insertRecord(
                hlc: hlc,
                sender: sender,
                payload: payload,
                isMe: false,
              );
            }
          }
        }
      });
    } catch (e) {
      debugPrint("Realtime subscription notice: $e");
    }
  }

  void _initConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) async {
      bool hasNet = results.any((r) => r != ConnectivityResult.none);
      if (mounted) setState(() => _isOnline = hasNet);

      if (hasNet) {
        _triggerCloudSync();
      }
    });
  }

  Future<void> _triggerCloudSync() async {
    int synced = await LocalWalStore.syncPendingToSupabase(telephony);
    await _loadWalFromStorage();
    if (synced > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("☁️ Auto-Synced $synced record(s) & media to Supabase over 2G/LTE!")),
      );
    }
  }

  Future<Position?> _getFreshCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        await Geolocator.openLocationSettings();
        return null;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }

      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 7),
      );

      if (mounted) {
        setState(() {
          _currentDeviceLat = pos.latitude;
          _currentDeviceLng = pos.longitude;
        });
      }
      return pos;
    } catch (e) {
      return await Geolocator.getLastKnownPosition();
    }
  }

  Future<void> _loadWalFromStorage() async {
    try {
      final entries = await LocalWalStore.readAllRecords();
      if (!mounted) return;

      List<ParsedPacket> loadedPackets = [];

      for (var entry in entries) {
        String sender = entry['sender'] ?? "Unknown";
        String payload = entry['payload'] ?? "";
        bool isMe = (entry['is_me'] ?? 0) == 1;

        if (isEmergencyProtocolMessage(payload)) {
          loadedPackets.insert(0, ParsedPacket.fromString(
            sender: sender,
            rawBody: payload,
            isSentByMe: isMe,
            localMediaPath: entry['local_media_path'] ?? '',
          ));
        }
      }

      setState(() {
        _packets.clear();
        _packets.addAll(loadedPackets);
      });

      _checkActiveAlarms();
    } catch (e) {
      debugPrint("Error loading WAL entries: $e");
    }
  }

  void _checkActiveAlarms() {
    if (_sirenManuallyMuted) {
      if (_isAlarmPlaying) {
        _stopSiren();
      }
      return;
    }

    Map<String, List<ParsedPacket>> sessions = _groupPacketsBySession();
    bool hasPendingUnacceptedSos = false;

    for (var entry in sessions.entries) {
      String sId = entry.key;
      var sessionPackets = entry.value;
      bool isRescued = sessionPackets.any((p) => p.type == 'RESCUED');
      bool isAccepted = sessionPackets.any((p) => p.type == 'ACCEPT') || _acceptedSessionIds.contains(sId);
      bool isIncomingSOS = sessionPackets.any((p) => !p.isSentByMe && p.type == 'SOS');

      if (isIncomingSOS && !isAccepted && !isRescued) {
        hasPendingUnacceptedSos = true;
        break;
      }
    }

    if (!hasPendingUnacceptedSos && _isAlarmPlaying) {
      _stopSiren();
    } else if (hasPendingUnacceptedSos && !_isAlarmPlaying) {
      _startSiren();
    }
  }

  Future<void> _requestPermissions() async {
    bool locEnabled = await Geolocator.isLocationServiceEnabled();
    if (mounted) setState(() => _isLocationServiceEnabled = locEnabled);

    Map<Permission, PermissionStatus> statuses = await [
      Permission.sms,
      Permission.phone,
      Permission.location,
      Permission.camera,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
      Permission.notification,
    ].request();

    if (statuses[Permission.sms]?.isGranted == true) {
      setState(() => _permissionGranted = true);
      _initSmsListener();
      _startGpsStream(isHighPrecision: true);
      _getFreshCurrentLocation();
    }

    try {
      await _emergencyChannel.invokeMethod('showLockscreenNotification');
    } catch (_) {}

    // Auto-start decentralized Bluetooth Mesh (works offline without SIM or cellular)
    await BluetoothMeshService.instance.startMesh();
    if (mounted) setState(() {});
  }

  /// Multi-channel emergency broadcaster:
  /// 1. Broadcasts to nearby Bluetooth Mesh peers (100% offline fallback)
  /// 2. Dispatches cellular SMS if cellular signal & recipient number are available
  /// 3. Ingests into local WAL for local display and automated Supabase cloud sync
  Future<void> _broadcastEmergencyMessage({
    required String recipientPhone,
    required String payload,
    String? localMediaPath,
  }) async {
    // 1. Bluetooth Mesh Broadcast (Zero-internet, zero-SIM fallback)
    await BluetoothMeshService.instance.broadcastPacket(
      payload: payload,
      senderPhone: recipientPhone,
    );

    // 2. Cellular SMS Transmission (if recipient is set)
    if (recipientPhone.isNotEmpty && recipientPhone != "0000000000") {
      try {
        await telephony.sendSms(to: recipientPhone, message: payload);
      } catch (e) {
        debugPrint("Cellular SMS dispatch failed or no SIM network: $e");
      }
    }

    // 3. Local WAL Store & UI State update
    _handleIncomingMessage(
      recipientPhone.isNotEmpty ? recipientPhone : "MESH_BROADCAST",
      payload,
      isSentByMe: true,
      localMediaPath: localMediaPath,
    );
  }

  void _showMeshInfoDialog() {
    final bt = BluetoothMeshService.instance;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bluetooth_audio, color: Colors.cyanAccent),
            SizedBox(width: 8),
            Expanded(
              child: Text("Bluetooth Mesh Status", style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.cyan.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.cyan.shade800),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.hub, color: Colors.cyanAccent, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Node ID: ${bt.localNodeId}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 2),
                          Text(
                            "Status: ${bt.status == MeshStatus.active ? '🟢 ACTIVE & DISCOVERABLE' : bt.status.name.toUpperCase()}",
                            style: TextStyle(
                              fontSize: 11,
                              color: bt.status == MeshStatus.active ? Colors.greenAccent : Colors.orangeAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text("Mesh Relay Performance:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              _buildMeshMetricRow("Peers in Direct Range:", "${bt.connectedEndpoints.length}"),
              _buildMeshMetricRow("Packets Broadcasted:", "${bt.stats.packetsSent}"),
              _buildMeshMetricRow("Packets Ingested:", "${bt.stats.packetsReceived}"),
              _buildMeshMetricRow("Multi-Hop Relays Executed:", "${bt.stats.packetsRelayed}"),
              const SizedBox(height: 12),
              const Text("Connected Nodes:", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              if (bt.connectedEndpoints.isEmpty)
                const Text("Searching for nearby mesh rescue nodes... (Auto-connect enabled)", style: TextStyle(fontSize: 11, color: Colors.grey))
              else
                ...bt.connectedNodeNames.map((n) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Row(
                        children: [
                          const Icon(Icons.circle, size: 8, color: Colors.greenAccent),
                          const SizedBox(width: 6),
                          Text(n, style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    )),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  "💡 Bluetooth Mesh operates 100% offline without cellular or internet. Packets automatically hop across multiple devices to reach distant responders.",
                  style: TextStyle(fontSize: 10, color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await bt.stopMesh();
              await bt.startMesh();
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text("Restart Mesh", style: TextStyle(color: Colors.cyanAccent)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  Widget _buildMeshMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
        ],
      ),
    );
  }

  void _startGpsStream({required bool isHighPrecision}) async {
    if (_isHighPrecisionGpsActive == isHighPrecision && _positionSubscription != null) return;

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    await _positionSubscription?.cancel();
    _isHighPrecisionGpsActive = isHighPrecision;

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: isHighPrecision ? LocationAccuracy.bestForNavigation : LocationAccuracy.medium,
        distanceFilter: 10,
      ),
    ).listen((Position pos) {
      if (mounted) {
        setState(() {
          _currentDeviceLat = pos.latitude;
          _currentDeviceLng = pos.longitude;
        });

        _checkAndBroadcastMovement(pos);
      }
    });
  }

  void _checkAndBroadcastMovement(Position newPos) {
    if (_packets.isEmpty) return;

    Map<String, List<ParsedPacket>> activeSessions = _groupPacketsBySession();
    for (var entry in activeSessions.entries) {
      List<ParsedPacket> thread = entry.value;
      bool isRescued = thread.any((p) => p.type == 'RESCUED');
      if (isRescued) continue;

      ParsedPacket sosPacket = thread.lastWhere(
            (p) => p.type == 'SOS' || p.type == 'ALT',
        orElse: () => thread.last,
      );

      String sessionId = sosPacket.sessionId;
      String partnerPhone = "";

      if (sosPacket.isSentByMe) {
        ParsedPacket? acceptPkt = thread.firstWhere(
              (p) => p.type == 'ACCEPT',
          orElse: () => ParsedPacket(sender: '', rawBody: '', time: '', type: '', sessionId: '', lat: '', long: '', message: '', localMediaPath: '', isStructured: false, isSentByMe: false),
        );
        partnerPhone = normalizePhoneSender(acceptPkt.sender);
      } else {
        partnerPhone = normalizePhoneSender(sosPacket.sender);
      }

      if (partnerPhone.isEmpty) continue;

      if (_lastBroadcastPosition != null) {
        double movedMeters = Geolocator.distanceBetween(
          _lastBroadcastPosition!.latitude,
          _lastBroadcastPosition!.longitude,
          newPos.latitude,
          newPos.longitude,
        );

        if (movedMeters >= 10.0) {
          _lastBroadcastPosition = newPos;
          String altPayload = "ALT|$sessionId|${newPos.latitude.toStringAsFixed(6)}|${newPos.longitude.toStringAsFixed(6)}|Live Movement Update (10m+ moved)";
          _broadcastEmergencyMessage(recipientPhone: partnerPhone, payload: altPayload);
        }
      } else {
        _lastBroadcastPosition = newPos;
      }
    }
  }

  void _initSmsListener() {
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        _handleIncomingMessage(
          message.address ?? "Unknown Responder",
          message.body ?? "",
          isSentByMe: false,
        );
      },
      onBackgroundMessage: backgroundSmsHandler,
      listenInBackground: true,
    );
  }

  Future<void> _handleIncomingMessage(String sender, String body, {required bool isSentByMe, String? localMediaPath}) async {
    if (body.isEmpty || !isEmergencyProtocolMessage(body)) return;

    String cleanSender = normalizePhoneSender(sender);

    try {
      _latestHlc = Hlc.now("DEVICE_NODE_1", lastSeen: _latestHlc);
      await LocalWalStore.insertRecord(
        hlc: _latestHlc!.pack(),
        sender: cleanSender,
        payload: body,
        isMe: isSentByMe,
        localMediaPath: localMediaPath,
      );
    } catch (e) {
      debugPrint("WAL Insert error: $e");
    }

    await _loadWalFromStorage();

    final parsed = ParsedPacket.fromString(
      sender: cleanSender,
      rawBody: body,
      isSentByMe: isSentByMe,
      localMediaPath: localMediaPath ?? '',
    );

    if (_isOnline) {
      unawaited(LocalWalStore.syncPendingToSupabase(telephony));
    }

    if (!isSentByMe && parsed.type == "SOS") {
      _sirenManuallyMuted = false;
      _checkActiveAlarms();
    } else if (parsed.type == "RESCUED" || parsed.type == "ACCEPT") {
      _checkActiveAlarms();
      if (mounted && parsed.type == "RESCUED") {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("🎉 VICTIM RESCUED! Incident moved to History.")),
        );
      } else if (mounted && !isSentByMe && parsed.type == "ACCEPT") {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("🚨 Rescue Dispatched by ${parsed.message}!")),
        );
      }
    }
  }

  void _startSiren() {
    _sirenManuallyMuted = false;
    setState(() => _isAlarmPlaying = true);
    FlutterRingtonePlayer().playAlarm(looping: true, asAlarm: true);
  }

  void _stopSiren() async {
    _sirenManuallyMuted = true;
    try {
      await FlutterRingtonePlayer().stop();
    } catch (e) {
      debugPrint("Error stopping siren: $e");
    }
    if (mounted) {
      setState(() => _isAlarmPlaying = false);
    }
  }

  void _showSetQuickNumberDialog() {
    final textController = TextEditingController(text: _presetQuickNumber);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.bolt, color: Colors.redAccent),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "Preset Quick SOS Number",
                style: TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Enter default mobile number for instant 1-tap SOS broadcast:", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: "Emergency Phone Number",
                prefixIcon: Icon(Icons.phone),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                _pinSosWidget();
              },
              icon: const Icon(Icons.widgets, size: 16, color: Colors.cyanAccent),
              label: const Text("Pin SOS Widget to Home Screen", style: TextStyle(fontSize: 12, color: Colors.cyanAccent)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900, foregroundColor: Colors.white),
            onPressed: () async {
              String num = textController.text.trim();
              if (num.isNotEmpty) {
                await LocalWalStore.saveQuickSosNumber(num);
                setState(() => _presetQuickNumber = num);
                if (ctx.mounted) Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("⚡ Quick SOS Contact Saved: $num")),
                );
              }
            },
            child: const Text("Save Number"),
          ),
        ],
      ),
    );
  }

  Future<void> _pinLockscreenSosWidget() async {
    try {
      final bool? success = await _emergencyChannel.invokeMethod<bool>('pinSosWidget');
      if (mounted) {
        if (success == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("✅ SOS Widget pin requested! Confirm on your screen."),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("ℹ️ Lock screen widget is already active automatically! You can also add home screen widget via launcher menu."),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Widget pin notice: $e")),
        );
      }
    }
  }

  Future<void> _refreshLockscreenNotification() async {
    try {
      await _emergencyChannel.invokeMethod('showLockscreenNotification');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🔔 Lock Screen SOS Widget active & updated!"),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      debugPrint("Error refreshing lockscreen notification: $e");
    }
  }

  void _showLockScreenWidgetDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.screen_lock_portrait, color: Colors.redAccent, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                "Lock Screen SOS & Widgets",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield, color: Colors.redAccent, size: 22),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Trigger emergency alerts & siren directly from your lock screen without unlocking your phone!",
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text("HOW TO ACCESS SOS ON LOCK SCREEN:", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
              const SizedBox(height: 10),

              // Feature 1: Lock Screen / Home AppWidget
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.widgets, color: Colors.orangeAccent, size: 20),
                        SizedBox(width: 8),
                        Text("1. Lock & Home Screen Widget", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Place the 1-Tap SOS + Siren widget on your home or supported lock screen (Keyguard / Samsung OneUI / Glanceable Hub).",
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.add_to_home_screen, size: 18),
                        label: const Text("Pin SOS Widget to Screen", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _pinLockscreenSosWidget();
                        },
                      ),
                    ),
                  ],
                ),
              ),

              // Feature 2: Persistent Lock Screen Notification
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.notifications_active, color: Colors.redAccent, size: 20),
                        SizedBox(width: 8),
                        Text("2. Persistent Lock Screen Notification", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      "Always available on your lock screen notification shade with direct [🚨 SEND SOS] and [🔊 SIREN] action buttons. Launches over lock screen.",
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text("Activate / Refresh Notification", style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _refreshLockscreenNotification();
                        },
                      ),
                    ),
                  ],
                ),
              ),

              // Feature 3: Quick Settings Tile
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.swipe_down_rounded, color: Colors.cyanAccent, size: 20),
                        SizedBox(width: 8),
                        Text("3. Quick Settings Pull-Down Tile", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13)),
                      ],
                    ),
                    SizedBox(height: 6),
                    Text(
                      "Swipe down from top on lock screen -> tap edit pencil/tiles -> add '🚨 Quick SOS' tile to trigger alerts anytime.",
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),

              // Contact configuration info
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      "Target Contact: ${_presetQuickNumber.isEmpty ? 'None (Mesh Broadcast Only)' : _presetQuickNumber}",
                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showSetQuickNumberDialog();
                    },
                    child: const Text("Edit Contact", style: TextStyle(fontSize: 12, color: Colors.cyanAccent)),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close", style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  void _triggerQuickSosBubbleTap() {
    if (_presetQuickNumber.isEmpty) {
      _showSetQuickNumberDialog();
      return;
    }

    int secondsRemaining = 3;
    Timer? countdownTimer;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) async {
              if (secondsRemaining > 1) {
                setModalState(() {
                  secondsRemaining--;
                });
              } else {
                timer.cancel();
                Navigator.pop(ctx);
                _dispatchQuickSosPayload();
              }
            });

            return AlertDialog(
              backgroundColor: Colors.red.shade900,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Colors.redAccent, width: 2),
              ),
              title: const Column(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 48, color: Colors.redAccent),
                  SizedBox(height: 8),
                  Text("BROADCASTING QUICK SOS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Sending emergency payload to $_presetQuickNumber in:",
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.redAccent.withValues(alpha: 0.5), blurRadius: 15, spreadRadius: 5)
                      ],
                    ),
                    child: Center(
                      child: Text(
                        "$secondsRemaining",
                        style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text("Tap X to cancel broadcast", style: TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                ],
              ),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                IconButton(
                  iconSize: 32,
                  icon: const Icon(Icons.cancel, color: Colors.white),
                  onPressed: () {
                    countdownTimer?.cancel();
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("❌ Quick SOS Canceled!")),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _dispatchQuickSosPayload() async {
    Position? livePos = await _getFreshCurrentLocation();
    String latStr = livePos != null ? livePos.latitude.toStringAsFixed(6) : (_currentDeviceLat?.toStringAsFixed(6) ?? "0.0");
    String longStr = livePos != null ? livePos.longitude.toStringAsFixed(6) : (_currentDeviceLng?.toStringAsFixed(6) ?? "0.0");

    String newSessionId = "S${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}";
    final payload = "SOS|$newSessionId|$latStr|$longStr|TARGET:CUSTOM | QUICK ONE-TAP CRITICAL EMERGENCY ALERT";

    await _broadcastEmergencyMessage(recipientPhone: _presetQuickNumber, payload: payload);

    if (mounted) {
      final targetDesc = _presetQuickNumber.isNotEmpty ? _presetQuickNumber : "ALL Nearby Mesh Peers";
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("⚡ QUICK SOS BROADCASTED (Mesh & SMS Fallback Active) to $targetDesc ($latStr, $longStr)")),
      );
    }
  }

  Future<void> _captureAndQueueMedia(String recipientPhone, String sessionId, ImageSource source, bool isVideo) async {
    final ImagePicker picker = ImagePicker();
    XFile? file;

    if (isVideo) {
      file = await picker.pickVideo(source: source);
    } else {
      file = await picker.pickImage(source: source, imageQuality: 70);
    }

    if (file == null) return;

    String localFilePath = file.path;
    String pendingPayload = "MEDIA_PENDING|$sessionId|$localFilePath";

    await LocalWalStore.insertRecord(
      hlc: Hlc.now("DEVICE_NODE_1", lastSeen: _latestHlc).pack(),
      sender: recipientPhone,
      payload: pendingPayload,
      isMe: true,
      localMediaPath: localFilePath,
    );

    if (_isOnline) {
      try {
        final bytes = await file.readAsBytes();
        final fileExt = file.path.split('.').last;
        final fileName = "${DateTime.now().millisecondsSinceEpoch}.$fileExt";
        final filePath = "emergency_uploads/$fileName";

        final supabase = Supabase.instance.client;
        await supabase.storage.from('emergency-media').uploadBinary(filePath, bytes);
        final String publicUrl = supabase.storage.from('emergency-media').getPublicUrl(filePath);

        String mediaPayload = "MEDIA|$sessionId|$publicUrl";
        await _broadcastEmergencyMessage(recipientPhone: recipientPhone, payload: mediaPayload, localMediaPath: localFilePath);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("📷 Media uploaded & broadcasted via SMS + Mesh!")),
          );
        }
        return;
      } catch (e) {
        debugPrint("Online upload fallback to offline queue: $e");
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("💾 Media saved in WAL! Will auto-upload to database when internet connects.")),
      );
    }
  }

  void _openInAppMap(String sessionId, String partnerPhone, String label, bool isSelfSent) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MapScreen(
          sessionId: sessionId,
          partnerPhone: partnerPhone,
          label: label,
          isSelfSent: isSelfSent,
        ),
      ),
    );
  }

  Future<void> _launchExternalGoogleMaps(String lat, String lng) async {
    final Uri googleMapsUri = Uri.parse("geo:$lat,$lng?q=$lat,$lng(Emergency+Location)");
    final Uri webMapsUri = Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lng");

    if (await canLaunchUrl(googleMapsUri)) {
      await launchUrl(googleMapsUri);
    } else if (await canLaunchUrl(webMapsUri)) {
      await launchUrl(webMapsUri, mode: LaunchMode.externalApplication);
    }
  }

  void _acceptEmergencyMission(String senderPhone, String sessionId) async {
    if (_acceptedSessionIds.contains(sessionId)) return;
    _acceptedSessionIds.add(sessionId);

    _stopSiren();

    String myLat = _currentDeviceLat?.toStringAsFixed(6) ?? "0.0";
    String myLng = _currentDeviceLng?.toStringAsFixed(6) ?? "0.0";
    String acceptPayload = "ACCEPT|$sessionId|$myLat|$myLng|Rescue Ambulance Dispatched";

    // Immediately record ACCEPT packet locally so WAL & UI are updated instantly on first click
    await _handleIncomingMessage(
      senderPhone.isNotEmpty ? senderPhone : "MESH_BROADCAST",
      acceptPayload,
      isSentByMe: true,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Mission Accepted! Dispatched via Mesh & SMS.")),
      );
    }

    // Try fetching fresh GPS coordinates in the background (short timeout)
    try {
      Position? pos = await _getFreshCurrentLocation().timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      if (pos != null) {
        myLat = pos.latitude.toStringAsFixed(6);
        myLng = pos.longitude.toStringAsFixed(6);
        acceptPayload = "ACCEPT|$sessionId|$myLat|$myLng|Rescue Ambulance Dispatched";
      }
    } catch (_) {}

    // Broadcast across Bluetooth Mesh & Cellular SMS
    await BluetoothMeshService.instance.broadcastPacket(
      payload: acceptPayload,
      senderPhone: senderPhone,
    );

    if (senderPhone.isNotEmpty && senderPhone != "0000000000") {
      try {
        await telephony.sendSms(to: senderPhone, message: acceptPayload);
      } catch (e) {
        debugPrint("Cellular SMS dispatch failed or no SIM network: $e");
      }
    }
  }

  void _markAsRescued(String senderPhone, String sessionId) async {
    _stopSiren();

    String rescuePayload = "RESCUED|$sessionId|0.0|0.0|Victim Has Been Successfully Rescued";

    await _broadcastEmergencyMessage(recipientPhone: senderPhone, payload: rescuePayload);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("🎉 VICTIM MARKED AS RESCUED! Incident moved to History.")),
      );
    }
  }

  void _showLocalWalDebugDialog() async {
    final entries = await LocalWalStore.readAllRecords();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Local WAL Store (${entries.length} records)"),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text("No entries in local WAL store yet."),
          )
              : ListView.builder(
            shrinkWrap: true,
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final item = entries[index];
              bool isSynced = item['status'] == 'SYNCED';
              return Card(
                color: isSynced ? Colors.green.shade900.withValues(alpha: 0.3) : Colors.orange.shade900.withValues(alpha: 0.3),
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  dense: true,
                  title: Text(
                    "${item['sender']} (${item['is_me'] == 1 ? 'Sent' : 'Received'}) • Status: ${item['status']}",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isSynced ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                  ),
                  subtitle: Text("Payload: ${item['payload']}"),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await LocalWalStore.clearAll();
              await _loadWalFromStorage();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text("Clear DB", style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  void _showSendPacketSheet() async {
    String selectedRecipientType = "MESH";
    final manualNumberController = TextEditingController();
    final latController = TextEditingController(text: "Fetching live GPS...");
    final longController = TextEditingController(text: "Fetching live GPS...");
    final medicalController = TextEditingController(text: "BLEEDING | BLOOD: O+");

    _getFreshCurrentLocation().then((livePos) {
      if (livePos != null) {
        latController.text = livePos.latitude.toStringAsFixed(6);
        longController.text = livePos.longitude.toStringAsFixed(6);
      }
    });

    final Map<String, String> presets = {
      "MESH": "ALL_NEARBY",
      "HOSPITAL": "108",
      "POLICE": "100",
      "FIRE": "101",
      "OTHER": "",
    };

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Broadcast SOS Emergency Alert",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.redAccent),
                      ),
                      IconButton(
                        icon: const Icon(Icons.my_location, color: Colors.greenAccent),
                        onPressed: () async {
                          Position? fresh = await _getFreshCurrentLocation();
                          if (fresh != null) {
                            setModalState(() {
                              latController.text = fresh.latitude.toStringAsFixed(6);
                              longController.text = fresh.longitude.toStringAsFixed(6);
                            });
                          }
                        },
                      )
                    ],
                  ),
                  const SizedBox(height: 12),

                  const Text("Select Emergency Target:", style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 2,
                    childAspectRatio: 2.8,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _buildPresetTile("Nearby Mesh (No SIM)", Icons.bluetooth_audio, "MESH", selectedRecipientType, (val) {
                        setModalState(() => selectedRecipientType = val);
                      }),
                      _buildPresetTile("Hospital (108)", Icons.local_hospital, "HOSPITAL", selectedRecipientType, (val) {
                        setModalState(() => selectedRecipientType = val);
                      }),
                      _buildPresetTile("Police (100)", Icons.local_police, "POLICE", selectedRecipientType, (val) {
                        setModalState(() => selectedRecipientType = val);
                      }),
                      _buildPresetTile("Custom Number", Icons.phone, "OTHER", selectedRecipientType, (val) {
                        setModalState(() => selectedRecipientType = val);
                      }),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (selectedRecipientType == "MESH")
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: Colors.cyan.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.cyan.shade700),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.wifi_tethering, color: Colors.cyanAccent, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "📡 No phone number needed! This broadcasts directly over Bluetooth radio waves to all nearby rescue phones.",
                              style: TextStyle(fontSize: 11, color: Colors.cyanAccent),
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (selectedRecipientType == "OTHER")
                    TextField(
                      controller: manualNumberController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: "Phone Number (Optional - leave empty for Mesh-only)",
                        prefixIcon: Icon(Icons.phone),
                        border: OutlineInputBorder(),
                      ),
                    ),

                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: latController,
                          decoration: const InputDecoration(labelText: "Live Lat (GPS)", border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: longController,
                          decoration: const InputDecoration(labelText: "Live Long (GPS)", border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: medicalController,
                    decoration: const InputDecoration(
                      labelText: "Medical Info & Alert Details",
                      prefixIcon: Icon(Icons.medical_information),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        String recipient = selectedRecipientType == "OTHER"
                            ? manualNumberController.text.trim()
                            : (presets[selectedRecipientType] ?? "ALL_NEARBY");

                        if (recipient.isEmpty) {
                          recipient = "ALL_NEARBY";
                        }

                        if (latController.text.contains("Fetching") || double.tryParse(latController.text) == null) {
                          Position? fresh = await _getFreshCurrentLocation();
                          if (fresh != null) {
                            latController.text = fresh.latitude.toStringAsFixed(6);
                            longController.text = fresh.longitude.toStringAsFixed(6);
                          }
                        }

                        String newSessionId = "S${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}";
                        final payload = "SOS|$newSessionId|${latController.text}|${longController.text}|TARGET:$selectedRecipientType | ${medicalController.text.trim().toUpperCase()}";

                        await _broadcastEmergencyMessage(recipientPhone: recipient, payload: payload);

                        if (ctx.mounted) Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(recipient == "ALL_NEARBY"
                              ? "⚡ Emergency SOS Broadcasted to ALL Nearby Bluetooth Rescuers!"
                              : "Emergency SOS Broadcasted (Mesh & SMS) to $recipient: ${latController.text}, ${longController.text}")),
                        );
                      },
                      icon: const Icon(Icons.warning),
                      label: const Text("BROADCAST SOS EMERGENCY"),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPresetTile(String title, IconData icon, String key, String selectedKey, Function(String) onSelect) {
    bool isSelected = key == selectedKey;
    return InkWell(
      onTap: () => onSelect(key),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.deepOrange.withValues(alpha: 0.25) : Colors.white10,
          border: Border.all(color: isSelected ? Colors.deepOrange : Colors.grey.shade700),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: isSelected ? Colors.deepOrange : Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? Colors.white : Colors.grey.shade300,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, List<ParsedPacket>> _groupPacketsBySession() {
    Map<String, List<ParsedPacket>> sessionGroups = {};

    for (var packet in _packets) {
      String key = packet.sessionId.isNotEmpty
          ? packet.sessionId
          : normalizePhoneSender(packet.sender);

      sessionGroups.putIfAbsent(key, () => []).add(packet);
    }
    return sessionGroups;
  }

  @override
  Widget build(BuildContext context) {
    bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom != 0;

    Map<String, List<ParsedPacket>> allSessions = _groupPacketsBySession();

    Map<String, List<ParsedPacket>> activeSessions = {};
    Map<String, List<ParsedPacket>> historySessions = {};

    allSessions.forEach((key, packets) {
      bool isRescued = packets.any((p) => p.type == 'RESCUED');
      if (isRescued) {
        historySessions[key] = packets;
      } else {
        activeSessions[key] = packets;
      }
    });

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('OffGrid SOS'),
        actions: [
          IconButton(
            tooltip: "Lock Screen & Widgets",
            icon: const Icon(Icons.screen_lock_portrait, color: Colors.amberAccent),
            onPressed: _showLockScreenWidgetDialog,
          ),
          IconButton(
            tooltip: "Inspect WAL Store",
            icon: const Icon(Icons.bug_report, color: Colors.orangeAccent),
            onPressed: _showLocalWalDebugDialog,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: Icon(
                _permissionGranted ? Icons.cell_tower : Icons.signal_cellular_off,
                color: _permissionGranted ? Colors.greenAccent : Colors.redAccent,
                size: 18,
              ),
              label: Text(_permissionGranted ? 'Active' : 'No Access'),
            ),
          )
        ],
      ),

      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: isKeyboardOpen
          ? null
          : Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: _triggerQuickSosBubbleTap,
              onLongPress: _showSetQuickNumberDialog,
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.red.shade700, Colors.red.shade900],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.redAccent, width: 2),
                  boxShadow: [
                    BoxShadow(color: Colors.redAccent.withValues(alpha: 0.5), blurRadius: 12, spreadRadius: 3)
                  ],
                ),
                child: const Center(
                  child: Icon(Icons.bolt, color: Colors.white, size: 32),
                ),
              ),
            ),

            FloatingActionButton.extended(
              onPressed: _showSendPacketSheet,
              backgroundColor: Colors.redAccent,
              icon: const Icon(Icons.warning, color: Colors.white),
              label: const Text("Send SOS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),

      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Direct Lock Screen Emergency SOS Widget Indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.screen_lock_portrait, size: 16, color: Colors.redAccent),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "🔒 Lock Screen SOS Widget: Directly Active on Your Lock Screen",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _showLockScreenWidgetDialog,
                    child: const Text("Info", style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                  ),
                ],
              ),
            ),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: _isOnline ? Colors.green.withValues(alpha: 0.15) : Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _isOnline ? Colors.green.shade700 : Colors.orange.shade700),
              ),
              child: Row(
                children: [
                  Icon(_isOnline ? Icons.cloud_done : Icons.cloud_off, size: 16, color: _isOnline ? Colors.greenAccent : Colors.orangeAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isOnline
                          ? "Supabase Live • Realtime Engine Active (2G/LTE)"
                          : "Offline Mode • Saved Locally in File Store",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _isOnline ? Colors.greenAccent : Colors.orangeAccent),
                    ),
                  ),
                  if (_isOnline)
                    TextButton(
                      onPressed: _triggerCloudSync,
                      child: const Text("Sync Now", style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
                    )
                ],
              ),
            ),

            if (!_isLocationServiceEnabled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade700),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_off, size: 16, color: Colors.amberAccent),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "GPS/Location is OFF! Turn ON Location in device settings so Bluetooth Mesh can discover peers.",
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await Geolocator.openLocationSettings();
                        bool enabled = await Geolocator.isLocationServiceEnabled();
                        if (mounted) setState(() => _isLocationServiceEnabled = enabled);
                      },
                      child: const Text("Turn ON", style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
                    ),
                  ],
                ),
              ),

            // BLUETOOTH MESH STATUS BANNER (OFFLINE P2P FALLBACK)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: BluetoothMeshService.instance.status == MeshStatus.active
                    ? Colors.cyan.withValues(alpha: 0.15)
                    : Colors.blueGrey.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: BluetoothMeshService.instance.status == MeshStatus.active
                      ? Colors.cyan.shade700
                      : Colors.blueGrey.shade700,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    BluetoothMeshService.instance.hasPeers
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_searching,
                    size: 16,
                    color: BluetoothMeshService.instance.hasPeers ? Colors.cyanAccent : Colors.cyan.shade200,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      BluetoothMeshService.instance.hasPeers
                          ? "BT Mesh Active • ${BluetoothMeshService.instance.connectedEndpoints.length} Peer(s) Connected • Auto-Relay Fallback Ready"
                          : (BluetoothMeshService.instance.status == MeshStatus.active
                              ? "BT Mesh Active (${BluetoothMeshService.instance.localNodeId}) • Searching for Nearby Rescuers..."
                              : "BT Mesh • Offline P2P Fallback Engine"),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: BluetoothMeshService.instance.hasPeers ? Colors.cyanAccent : Colors.grey.shade300,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await BluetoothMeshService.instance.restartMesh();
                      if (mounted) setState(() {});
                    },
                    child: const Text("Re-scan", style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
                  ),
                  TextButton(
                    onPressed: _showMeshInfoDialog,
                    child: const Text("Info", style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
                  ),
                ],
              ),
            ),

            if (_isAlarmPlaying)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active, color: Colors.white, size: 24),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "EMERGENCY SIREN RINGING",
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      ),
                      onPressed: _stopSiren,
                      child: const Text("Mute"),
                    )
                  ],
                ),
              ),

            const SizedBox(height: 8),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 80),
                children: [
                  if (activeSessions.isEmpty && historySessions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: Text("No emergency requests yet.", style: TextStyle(color: Colors.grey))),
                    ),

                  if (activeSessions.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text("Active Emergency Missions", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.redAccent)),
                    ),
                    ...activeSessions.entries.map((entry) {
                      List<ParsedPacket> thread = entry.value;

                      ParsedPacket sosPacket = thread.lastWhere(
                            (p) => p.type == "SOS" || p.type == "ALT",
                        orElse: () => thread.last,
                      );

                      bool isSelfSentSOS = sosPacket.isSentByMe;
                      String currentSessionId = sosPacket.sessionId;

                      String partnerPhone = "";
                      if (isSelfSentSOS) {
                        ParsedPacket? acceptPkt = thread.firstWhere(
                              (p) => p.type == "ACCEPT",
                          orElse: () => ParsedPacket(sender: '', rawBody: '', time: '', type: '', sessionId: '', lat: '', long: '', message: '', localMediaPath: '', isStructured: false, isSentByMe: false),
                        );
                        partnerPhone = normalizePhoneSender(acceptPkt.sender);
                      } else {
                        partnerPhone = normalizePhoneSender(sosPacket.sender);
                      }

                      ParsedPacket locationPacket = thread.lastWhere(
                            (p) => (p.type == "SOS" || p.type == "ALT") && p.hasCoordinates && (p.isSentByMe == isSelfSentSOS),
                        orElse: () => thread.firstWhere(
                              (p) => (p.type == "SOS" || p.type == "ALT") && p.hasCoordinates,
                          orElse: () => thread.first,
                        ),
                      );

                      ParsedPacket? acceptPacket = thread.lastWhere(
                            (p) => (p.type == "ACCEPT" || p.type == "ALT") && p.hasCoordinates && (p.isSentByMe != isSelfSentSOS),
                        orElse: () => thread.firstWhere(
                              (p) => p.type == "ACCEPT" && p.hasCoordinates,
                          orElse: () => thread.first,
                        ),
                      );

                      bool hasAcceptance = thread.any((p) => p.type == "ACCEPT") || _acceptedSessionIds.contains(currentSessionId);

                      double distance = 0.0;
                      if (isSelfSentSOS && acceptPacket != null && acceptPacket.hasCoordinates) {
                        distance = locationPacket.getDistanceTo(acceptPacket.parsedLat, acceptPacket.parsedLng);
                      } else {
                        distance = locationPacket.getDistanceTo(_currentDeviceLat, _currentDeviceLng);
                      }
                      int estMins = (distance * 2.5).round();

                      return ThreadedHospitalCard(
                        senderPhone: partnerPhone.isNotEmpty ? partnerPhone : normalizePhoneSender(sosPacket.sender),
                        sessionId: currentSessionId,
                        packets: thread,
                        locationPacket: locationPacket,
                        acceptPacket: hasAcceptance ? acceptPacket : null,
                        hasAcceptance: hasAcceptance,
                        isRescued: false,
                        isSelfSent: isSelfSentSOS,
                        distance: distance,
                        estMins: estMins,
                        currentLat: _currentDeviceLat,
                        currentLng: _currentDeviceLng,
                        onAccept: () => _acceptEmergencyMission(normalizePhoneSender(sosPacket.sender), currentSessionId),
                        onRescued: () => _markAsRescued(normalizePhoneSender(sosPacket.sender), currentSessionId),
                        onOpenInAppMap: (sessionId, pPhone, lbl) => _openInAppMap(sessionId, pPhone, lbl, isSelfSentSOS),
                        onOpenExternalMap: (lat, lng) => _launchExternalGoogleMaps(lat, lng),
                        onSendMessage: (msgText) {
                          String targetPhone = partnerPhone.isNotEmpty ? partnerPhone : normalizePhoneSender(sosPacket.sender);
                          String replyPayload = currentSessionId.isNotEmpty ? "TXT|$currentSessionId|$msgText" : msgText;
                          _broadcastEmergencyMessage(recipientPhone: targetPhone, payload: replyPayload);
                        },
                        onCaptureMedia: (source, isVideo) {
                          String targetPhone = partnerPhone.isNotEmpty ? partnerPhone : normalizePhoneSender(sosPacket.sender);
                          _captureAndQueueMedia(targetPhone, currentSessionId, source, isVideo);
                        },
                      );
                    }).toList(),
                  ],

                  if (historySessions.isNotEmpty) ...[
                    const Divider(height: 32),
                    InkWell(
                      onTap: () => setState(() => _showHistoryArchive = !_showHistoryArchive),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Rescued Incident History (${historySessions.length})",
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                            ),
                            Icon(_showHistoryArchive ? Icons.expand_less : Icons.expand_more, color: Colors.tealAccent),
                          ],
                        ),
                      ),
                    ),
                    if (_showHistoryArchive)
                      ...historySessions.entries.map((entry) {
                        List<ParsedPacket> thread = entry.value;

                        ParsedPacket locationPacket = thread.lastWhere(
                              (p) => (p.type == "SOS" || p.type == "ALT") && p.hasCoordinates,
                          orElse: () => thread.firstWhere(
                                (p) => p.hasCoordinates,
                            orElse: () => thread.first,
                          ),
                        );

                        ParsedPacket sosPacket = thread.lastWhere(
                              (p) => p.type == "SOS" || p.type == "ALT",
                          orElse: () => thread.last,
                        );
                        bool isSelfSentSOS = sosPacket.isSentByMe;
                        String senderPhone = normalizePhoneSender(sosPacket.sender);
                        String currentSessionId = sosPacket.sessionId;

                        double distance = locationPacket.getDistanceTo(_currentDeviceLat, _currentDeviceLng);

                        return ThreadedHospitalCard(
                          senderPhone: senderPhone,
                          sessionId: currentSessionId,
                          packets: thread,
                          locationPacket: locationPacket,
                          acceptPacket: null,
                          hasAcceptance: true,
                          isRescued: true,
                          isSelfSent: isSelfSentSOS,
                          distance: distance,
                          estMins: 0,
                          currentLat: _currentDeviceLat,
                          currentLng: _currentDeviceLng,
                          onAccept: () {},
                          onRescued: () {},
                          onOpenInAppMap: (sessionId, partnerPhone, lbl) => _openInAppMap(sessionId, partnerPhone, lbl, isSelfSentSOS),
                          onOpenExternalMap: (lat, lng) => _launchExternalGoogleMaps(lat, lng),
                          onSendMessage: (msgText) {},
                          onCaptureMedia: (source, isVideo) => _captureAndQueueMedia(senderPhone, currentSessionId, source, isVideo),
                        );
                      }).toList(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Thread Card Widget
class ThreadedHospitalCard extends StatefulWidget {
  final String senderPhone;
  final String sessionId;
  final List<ParsedPacket> packets;
  final ParsedPacket locationPacket;
  final ParsedPacket? acceptPacket;
  final bool hasAcceptance;
  final bool isRescued;
  final bool isSelfSent;
  final double distance;
  final int estMins;
  final double? currentLat;
  final double? currentLng;
  final VoidCallback onAccept;
  final VoidCallback onRescued;
  final Function(String, String, String) onOpenInAppMap;
  final Function(String, String) onOpenExternalMap;
  final Function(String) onSendMessage;
  final Function(ImageSource, bool) onCaptureMedia;

  const ThreadedHospitalCard({
    super.key,
    required this.senderPhone,
    required this.sessionId,
    required this.packets,
    required this.locationPacket,
    this.acceptPacket,
    required this.hasAcceptance,
    required this.isRescued,
    required this.isSelfSent,
    required this.distance,
    required this.estMins,
    required this.currentLat,
    required this.currentLng,
    required this.onAccept,
    required this.onRescued,
    required this.onOpenInAppMap,
    required this.onOpenExternalMap,
    required this.onSendMessage,
    required this.onCaptureMedia,
  });

  @override
  State<ThreadedHospitalCard> createState() => _ThreadedHospitalCardState();
}

class _ThreadedHospitalCardState extends State<ThreadedHospitalCard> {
  bool _isExpanded = true;
  final TextEditingController _inlineInputController = TextEditingController();

  String _getBadgeTitle() {
    if (widget.isRescued) {
      return "VICTIM RESCUED ✓";
    }
    if (widget.isSelfSent) {
      return widget.hasAcceptance ? "RESCUER DISPATCHED!" : "SOS SENT • WAITING";
    }
    return widget.hasAcceptance ? "RESCUE DISPATCHED" : "INCOMING EMERGENCY";
  }

  Color _getBadgeColor() {
    if (widget.isRescued) {
      return Colors.teal;
    }
    return widget.hasAcceptance ? Colors.green : Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: widget.isRescued
          ? Colors.teal.shade900.withValues(alpha: 0.25)
          : (widget.hasAcceptance
          ? Colors.green.shade900.withValues(alpha: 0.3)
          : Colors.red.shade900.withValues(alpha: 0.2)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Chip(
                  label: Text(
                    _getBadgeTitle(),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white),
                  ),
                  backgroundColor: _getBadgeColor(),
                ),
                Text("Contact: ${widget.senderPhone}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),

            if (widget.locationPacket.hasCoordinates) ...[
              Text(
                "Victim Location: ${widget.locationPacket.lat}, ${widget.locationPacket.long}",
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                widget.isRescued
                    ? "Status: Resolved & Archived"
                    : "Distance: ${widget.distance.toStringAsFixed(2)} km  •  ETA: ${widget.estMins} mins",
                style: TextStyle(color: widget.isRescued ? Colors.tealAccent : Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 10),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => widget.onOpenInAppMap(
                        widget.sessionId,
                        widget.senderPhone,
                        widget.locationPacket.message,
                      ),
                      icon: const Icon(Icons.map, size: 16),
                      label: const Text("Offline Map", style: TextStyle(fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => widget.onOpenExternalMap(
                        widget.locationPacket.lat,
                        widget.locationPacket.long,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text("Google App", style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ],

            if (!widget.isSelfSent && !widget.hasAcceptance && !widget.isRescued) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  onPressed: widget.onAccept,
                  icon: const Icon(Icons.check_circle, size: 16),
                  label: const Text("I'LL GO (ACCEPT MISSION)"),
                ),
              ),
            ],

            if (!widget.isSelfSent && widget.hasAcceptance && !widget.isRescued) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
                  onPressed: widget.onRescued,
                  icon: const Icon(Icons.verified, size: 16),
                  label: const Text("MARK AS RESCUED (COMPLETE)"),
                ),
              ),
            ],

            const Divider(height: 20),

            InkWell(
              onTap: () => setState(() => _isExpanded = !_isExpanded),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Chat & Attachments (${widget.packets.length})",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.orangeAccent),
                  ),
                  Icon(_isExpanded ? Icons.expand_less : Icons.expand_more, color: Colors.orangeAccent),
                ],
              ),
            ),

            if (_isExpanded) ...[
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 250),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  reverse: true,
                  itemCount: widget.packets.length,
                  itemBuilder: (ctx, idx) {
                    final msg = widget.packets[idx];
                    bool isMedia = msg.type == "MEDIA" || msg.type == "MEDIA_PENDING";

                    return Align(
                      alignment: msg.isSentByMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: msg.isSentByMe ? Colors.deepOrange.shade800 : Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: isMedia
                            ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  msg.type == "MEDIA_PENDING" ? Icons.cloud_upload : Icons.image,
                                  size: 14,
                                  color: msg.type == "MEDIA_PENDING" ? Colors.orangeAccent : Colors.greenAccent,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  msg.type == "MEDIA_PENDING" ? "Queued in WAL (Offline)" : "Media Attachment:",
                                  style: TextStyle(fontSize: 10, color: msg.type == "MEDIA_PENDING" ? Colors.orangeAccent : Colors.greenAccent),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: msg.localMediaPath.isNotEmpty && File(msg.localMediaPath).existsSync()
                                  ? Image.file(File(msg.localMediaPath), height: 140, width: 200, fit: BoxFit.cover)
                                  : Image.network(
                                msg.message,
                                height: 140,
                                width: 200,
                                fit: BoxFit.cover,
                                errorBuilder: (c, e, s) => const Text("🎥 [Media Link - Tap to Open]"),
                              ),
                            ),
                            Text(msg.time, style: const TextStyle(fontSize: 9, color: Colors.white54)),
                          ],
                        )
                            : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(msg.message, style: const TextStyle(fontSize: 13, color: Colors.white)),
                            const SizedBox(height: 2),
                            Text(msg.time, style: const TextStyle(fontSize: 9, color: Colors.white54)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),

              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.camera_alt, color: Colors.orangeAccent),
                      onPressed: () => widget.onCaptureMedia(ImageSource.camera, false),
                    ),
                    IconButton(
                      icon: const Icon(Icons.photo_library, color: Colors.orangeAccent),
                      onPressed: () => widget.onCaptureMedia(ImageSource.gallery, false),
                    ),
                    IconButton(
                      icon: const Icon(Icons.videocam, color: Colors.orangeAccent),
                      onPressed: () => widget.onCaptureMedia(ImageSource.camera, true),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _inlineInputController,
                        decoration: const InputDecoration(
                          hintText: "Send reply...",
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send, color: Colors.deepOrange),
                      onPressed: () {
                        final text = _inlineInputController.text.trim();
                        if (text.isNotEmpty) {
                          widget.onSendMessage(text);
                          _inlineInputController.clear();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 100% OFFLINE-FIRST MBTILES MAP SCREEN (MOVING VICTIM & RESCUER POINTERS)
// -----------------------------------------------------------------------------
class MapScreen extends StatefulWidget {
  final String sessionId;
  final String partnerPhone;
  final String label;
  final bool isSelfSent;

  const MapScreen({
    super.key,
    required this.sessionId,
    required this.partnerPhone,
    required this.label,
    required this.isSelfSent,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MbTilesTileProvider? _offlineTileProvider;
  bool _isOfflineMapLoaded = false;
  final MapController _mapController = MapController();

  StreamSubscription<Position>? _liveMapGpsStream;
  StreamSubscription<void>? _mapWalSubscription;
  Timer? _liveSyncTimer;

  LatLng? _myLivePos;
  LatLng? _remoteVictimPos;
  LatLng? _remoteRescuerPos;
  Position? _lastMapBroadcastPos;
  bool _hasCameraLocked = false;

  @override
  void initState() {
    super.initState();
    _initOfflineMbTilesMap();
    _startLiveSensorTracking();
    _loadLatestSessionLocations();

    _mapWalSubscription = _walUpdateStream.stream.listen((_) {
      _loadLatestSessionLocations();
    });

    _liveSyncTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _loadLatestSessionLocations();
    });
  }

  Future<void> _initOfflineMbTilesMap() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      String filePath = '${dir.path}/karnataka.mbtiles';

      if (await File(filePath).exists()) {
        final tileProvider = MbTilesTileProvider.fromPath(path: filePath);

        if (mounted) {
          setState(() {
            _offlineTileProvider = tileProvider;
            _isOfflineMapLoaded = true;
          });
        }
      } else {
        debugPrint("⚠️ Offline .mbtiles file not found at $filePath. Using Tactical Grid Fallback.");
      }
    } catch (e) {
      debugPrint("Error loading offline MBTiles: $e");
    }
  }

  @override
  void dispose() {
    _liveMapGpsStream?.cancel();
    _mapWalSubscription?.cancel();
    _liveSyncTimer?.cancel();
    _offlineTileProvider?.dispose();
    super.dispose();
  }

  void _loadLatestSessionLocations() async {
    final entries = await LocalWalStore.readAllRecords();
    if (!mounted) return;

    List<ParsedPacket> allPackets = [];
    for (var entry in entries) {
      String payload = entry['payload'] ?? '';
      String sender = entry['sender'] ?? '';
      bool isMe = (entry['is_me'] ?? 0) == 1;

      if (isEmergencyProtocolMessage(payload)) {
        ParsedPacket p = ParsedPacket.fromString(sender: sender, rawBody: payload, isSentByMe: isMe);
        allPackets.add(p);
      }
    }

    ParsedPacket? victimPkt;
    ParsedPacket? rescuerPkt;

    if (widget.isSelfSent) {
      rescuerPkt = allPackets.lastWhere(
            (p) => (p.type == 'ACCEPT' || p.type == 'ALT' || p.type == 'SOS') && p.hasCoordinates && !p.isSentByMe,
        orElse: () => ParsedPacket(sender: '', rawBody: '', time: '', type: '', sessionId: '', lat: '', long: '', message: '', localMediaPath: '', isStructured: false, isSentByMe: false),
      );
    } else {
      victimPkt = allPackets.lastWhere(
            (p) => (p.type == 'SOS' || p.type == 'ALT') && p.hasCoordinates && !p.isSentByMe,
        orElse: () => ParsedPacket(sender: '', rawBody: '', time: '', type: '', sessionId: '', lat: '', long: '', message: '', localMediaPath: '', isStructured: false, isSentByMe: false),
      );
    }

    if (mounted) {
      setState(() {
        if (victimPkt != null && victimPkt.hasCoordinates) {
          _remoteVictimPos = LatLng(victimPkt.parsedLat, victimPkt.parsedLng);
        }
        if (rescuerPkt != null && rescuerPkt.hasCoordinates) {
          _remoteRescuerPos = LatLng(rescuerPkt.parsedLat, rescuerPkt.parsedLng);
        }
      });

      _autoCenterCameraOnce();
    }
  }

  void _startLiveSensorTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    _liveMapGpsStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 10,
      ),
    ).listen((Position pos) {
      if (mounted) {
        setState(() {
          _myLivePos = LatLng(pos.latitude, pos.longitude);
        });

        _broadcastMapMovementOverSms(pos);
        _autoCenterCameraOnce();
      }
    });
  }

  void _broadcastMapMovementOverSms(Position currentPos) {
    if (widget.partnerPhone.isEmpty) return;

    if (_lastMapBroadcastPos != null) {
      double movedMeters = Geolocator.distanceBetween(
        _lastMapBroadcastPos!.latitude,
        _lastMapBroadcastPos!.longitude,
        currentPos.latitude,
        currentPos.longitude,
      );

      if (movedMeters >= 10.0) {
        _lastMapBroadcastPos = currentPos;
        String altPayload = "ALT|${widget.sessionId}|${currentPos.latitude.toStringAsFixed(6)}|${currentPos.longitude.toStringAsFixed(6)}|Live Movement Update (10m+ moved)";
        Telephony.instance.sendSms(to: widget.partnerPhone, message: altPayload);
        LocalWalStore.insertRecord(
          hlc: "${DateTime.now().millisecondsSinceEpoch}:0:MAP_NODE",
          sender: widget.partnerPhone,
          payload: altPayload,
          isMe: true,
        );
      }
    } else {
      _lastMapBroadcastPos = currentPos;
    }
  }

  void _autoCenterCameraOnce() {
    if (_hasCameraLocked) return;

    LatLng target = _myLivePos ?? _remoteVictimPos ?? _remoteRescuerPos ?? const LatLng(0, 0);
    if (target.latitude != 0.0) {
      _hasCameraLocked = true;
      _mapController.move(target, 15.0);
    }
  }

  void _fitBothMarkersOnMap(LatLng p1, LatLng p2) {
    double minLat = min(p1.latitude, p2.latitude);
    double maxLat = max(p1.latitude, p2.latitude);
    double minLng = min(p1.longitude, p2.longitude);
    double maxLng = max(p1.longitude, p2.longitude);

    LatLngBounds bounds = LatLngBounds(
      LatLng(minLat - 0.0005, minLng - 0.0005),
      LatLng(maxLat + 0.0005, maxLng + 0.0005),
    );

    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Marker> mapMarkers = [];

    // 1. VICTIM LIVE MOVING POINTER
    LatLng victimPos = widget.isSelfSent
        ? (_myLivePos ?? _remoteVictimPos ?? const LatLng(0, 0))
        : (_remoteVictimPos ?? const LatLng(0, 0));

    if (victimPos.latitude != 0.0) {
      mapMarkers.add(
        Marker(
          point: victimPos,
          width: 120,
          height: 70,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.red.shade900, borderRadius: BorderRadius.circular(6)),
                child: const Text("🚨 VICTIM", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
              const Icon(Icons.location_on, color: Colors.redAccent, size: 40),
            ],
          ),
        ),
      );
    }

    // 2. RESCUER LIVE MOVING POINTER
    LatLng rescuerPos = !widget.isSelfSent
        ? (_myLivePos ?? _remoteRescuerPos ?? const LatLng(0, 0))
        : (_remoteRescuerPos ?? const LatLng(0, 0));

    if (rescuerPos.latitude != 0.0) {
      mapMarkers.add(
        Marker(
          point: rescuerPos,
          width: 120,
          height: 70,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.green.shade900, borderRadius: BorderRadius.circular(6)),
                child: const Text("🚑 RESCUER", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
              const Icon(Icons.location_on, color: Colors.greenAccent, size: 40),
            ],
          ),
        ),
      );
    }

    LatLng fallbackTarget = victimPos.latitude != 0.0
        ? victimPos
        : (_myLivePos ?? const LatLng(12.9716, 77.5946));

    return Scaffold(
      appBar: AppBar(
        title: const Text("Live Moving Map & Radar"),
        actions: [
          IconButton(
            tooltip: "Fit Both Units On Map",
            icon: const Icon(Icons.zoom_out_map, color: Colors.tealAccent),
            onPressed: () {
              if (victimPos.latitude != 0.0 && rescuerPos.latitude != 0.0) {
                _fitBothMarkersOnMap(victimPos, rescuerPos);
              } else if (_myLivePos != null) {
                _mapController.move(_myLivePos!, 15.0);
              }
            },
          )
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            color: Colors.black87,
            child: Text(
              _isOfflineMapLoaded
                  ? "✓ Offline MBTiles Map Active (0% Internet) • Live 10m Tracking"
                  : "⚠️ Tactical Grid Mode • Live 10m Tracking Active",
              style: TextStyle(
                fontSize: 11,
                color: _isOfflineMapLoaded ? Colors.greenAccent : Colors.orangeAccent,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  color: const Color(0xFF1E2229),
                  child: CustomPaint(
                    painter: TacticalGridPainter(),
                    child: Container(),
                  ),
                ),
                if (_isOfflineMapLoaded && _offlineTileProvider != null)
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: fallbackTarget,
                      initialZoom: 14.0,
                    ),
                    children: [
                      TileLayer(
                        tileProvider: _offlineTileProvider!,
                      ),
                      MarkerLayer(markers: mapMarkers),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TacticalGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    const double step = 40.0;
    for (double i = 0; i < size.width; i += step) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double i = 0; i < size.height; i += step) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }

    final centerPaint = Paint()
      ..color = Colors.tealAccent.withValues(alpha: 0.2)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), centerPaint);
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), centerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ParsedPacket {
  final String sender;
  final String rawBody;
  final String time;
  final String type;
  final String sessionId;
  final String lat;
  final String long;
  final String message;
  final String localMediaPath;
  final bool isStructured;
  final bool isSentByMe;

  ParsedPacket({
    required this.sender,
    required this.rawBody,
    required this.time,
    required this.type,
    required this.sessionId,
    required this.lat,
    required this.long,
    required this.message,
    required this.localMediaPath,
    required this.isStructured,
    required this.isSentByMe,
  });

  factory ParsedPacket.fromString({
    required String sender,
    required String rawBody,
    bool isSentByMe = false,
    String localMediaPath = '',
  }) {
    final now = DateTime.now().toString().substring(11, 19);
    final parts = rawBody.split('|');

    if (parts.length >= 5) {
      return ParsedPacket(
        sender: sender,
        rawBody: rawBody,
        time: now,
        type: parts[0],
        sessionId: parts[1],
        lat: parts[2],
        long: parts[3],
        message: parts.sublist(4).join('|'),
        localMediaPath: localMediaPath,
        isStructured: true,
        isSentByMe: isSentByMe,
      );
    } else if (parts.length == 3 && (parts[0] == "MEDIA" || parts[0] == "MEDIA_PENDING")) {
      return ParsedPacket(
        sender: sender,
        rawBody: rawBody,
        time: now,
        type: parts[0],
        sessionId: parts[1],
        lat: "",
        long: "",
        message: parts[2],
        localMediaPath: localMediaPath,
        isStructured: true,
        isSentByMe: isSentByMe,
      );
    } else if (parts.length >= 3 && parts[0] == "TXT") {
      return ParsedPacket(
        sender: sender,
        rawBody: rawBody,
        time: now,
        type: "TXT",
        sessionId: parts[1],
        lat: "",
        long: "",
        message: parts.sublist(2).join('|'),
        localMediaPath: localMediaPath,
        isStructured: true,
        isSentByMe: isSentByMe,
      );
    }

    return ParsedPacket(
      sender: sender,
      rawBody: rawBody,
      time: now,
      type: "TXT",
      sessionId: "",
      lat: "",
      long: "",
      message: rawBody,
      localMediaPath: localMediaPath,
      isStructured: false,
      isSentByMe: isSentByMe,
    );
  }

  bool get hasCoordinates => lat.isNotEmpty && long.isNotEmpty && double.tryParse(lat) != null && double.tryParse(long) != null;
  double get parsedLat => double.parse(lat);
  double get parsedLng => double.parse(long);

  double getDistanceTo(double? deviceLat, double? deviceLng) {
    if (!hasCoordinates || deviceLat == null || deviceLng == null) return 0.0;

    var p = 0.017453292519943295;
    var c = cos;
    var a = 0.5 - c((parsedLat - deviceLat) * p) / 2 +
        c(deviceLat * p) * c(parsedLat * p) * (1 - c((parsedLng - deviceLng) * p)) / 2;
    return 12742 * asin(sqrt(a));
  }
}
