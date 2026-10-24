# Offline SOS Bridge 🚨

An emergency data transmission and disaster recovery bridge built with Flutter. It guarantees critical message delivery even when cellular networks fail and the internet is completely offline through a **3-tier hybrid fallback network**:

1. **Cloud Sync**: Supabase Realtime synchronization over 2G/LTE/Wi-Fi.
2. **Cellular SMS**: Low-overhead encoded protocol messages over carrier networks.
3. **Bluetooth Mesh (BLE/Wi-Fi P2P)**: **100% Offline Peer-to-Peer Mesh Relay** that works with **no internet and no SIM card**.

---

## 📡 Bluetooth Mesh Fallback Architecture

When disaster strikes (collapsed mobile towers, earthquakes, remote wilderness, or subway tunnels), traditional communication channels fail. The **Bluetooth Mesh Engine** provides an autonomous local communications network:

```
[Victim Device (No SIM/Net)] 
       │  (BLE Broadcast)
       ▼
[Nearby Node A (Relay Node)] 
       │  (Multi-Hop Relay, TTL=3)
       ▼
[Responder Node B (Relay Node)]
       │  (Multi-Hop Relay, TTL=2)
       ▼
[Rescue Gateway Node C (Has LTE/Internet)]
       │  (Automatic Gateway Bridge)
       ▼
[Supabase Cloud / Emergency Dispatch Center]
```

### Key Bluetooth Mesh Capabilities:
- **Zero Configuration**: Uses Google Nearby Connections `Strategy.P2P_CLUSTER`. Devices automatically advertise and discover nearby peers simultaneously.
- **Auto-Connect & Mesh Clustering**: Nearby rescue and victim nodes form an ad-hoc decentralized mesh network.
- **Multi-Hop Relay (Flooding with TTL)**: Packets carry a Time-to-Live (TTL=4) and hop counter. Intermediary nodes automatically forward packets to peers outside the sender's direct radio range.
- **Loop & Duplicate Suppression**: Packet IDs and Hybrid Logical Clocks (HLC) prevent redundant relays and infinite message loops.
- **Automatic Gateway Bridging**: If any peer in the mesh has internet access, it automatically syncs received offline mesh alerts up to the Supabase cloud dashboard.
- **Outbox Queueing**: If an emergency alert is triggered while no peers are in range, it is queued and instantly dispatched as soon as another node comes into proximity.
- **Live Mesh Monitor**: View connected peers, direct links, and packets sent/received/relayed from the in-app dashboard.

---

## 📱 How to Get the APK File

Because repositories only contain source code and exclude compiled binaries, the `.apk` file is generated through a build step. You have three easy ways to obtain the APK:

### Option 1: GitHub Actions (Recommended — Zero Local Setup)
We have configured a pre-built GitHub Actions workflow in `.github/workflows/build_apk.yml`:
1. Push this project to your GitHub repository:
   ```bash
   git init
   git add .
   git commit -m "feat: integrate Bluetooth Mesh offline fallback"
   git remote add origin https://github.com/<your-username>/<your-repo-name>.git
   git push -u origin main
   ```
2. On GitHub, navigate to the **Actions** tab.
3. Click on the **Build Android Release APK** workflow and click **Run workflow** (or let it run automatically on push).
4. Once completed (~2 minutes), click on the run summary and download the **`Offline-SOS-Bridge-Release-APK`** artifact.
5. Unzip the downloaded file and install `app-release.apk` directly on your Android phone!

---

### Option 2: Local Flutter Build (Terminal)
If you have Flutter and the Android SDK installed on your machine:

1. Clone or open the project folder in terminal:
   ```bash
   cd Offline_SOS_Bridge-main
   ```
2. Run the automated build script:
   ```bash
   ./build_apk.sh
   ```
   *Or execute the Flutter commands directly:*
   ```bash
   flutter pub get
   flutter build apk --release
   ```
3. Your installable release APK will be located at:
   ```
   build/app/outputs/flutter-apk/app-release.apk
   ```
   *(The app's release build is pre-configured to be signed automatically with debug release keys, so you do not need to configure any custom signing certificates).*

---

### Option 3: Android Studio
1. Open this project directory in **Android Studio** with the Flutter plugin enabled.
2. Allow Gradle and Flutter dependencies to sync (`flutter pub get`).
3. In the top menu, go to **Build** > **Flutter** > **Build APK**.
4. Once built, click the **locate** link in the event log to grab `app-release.apk`.

---

## 🔒 Permissions Configured

The app includes all required permissions in `android/app/src/main/AndroidManifest.xml`:
- **Bluetooth & Nearby Devices**: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `NEARBY_WIFI_DEVICES` (Offline peer discovery and mesh clustering).
- **SMS Operations**: `SEND_SMS`, `RECEIVE_SMS`, `READ_SMS` (Telephony bridge fallback).
- **Location Services**: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` (GPS coordinates for victim tracking).
- **Camera**: `CAMERA` (Emergency media capture).
