# 🛡️ Shakti SOS | Offline SOS Bridge

### Women's Safety

Shakti SOS is a Flutter-based emergency communication application designed to help women seek assistance during unsafe situations. It combines cloud synchronization, SMS, and Bluetooth Mesh to help transmit emergency alerts even when internet connectivity is unavailable.

## 🚨 Key Features

- **SOS Alerts:** Quickly send emergency alerts when feeling unsafe.
- **Cloud Sync:** Synchronize alerts through Supabase when internet is available.
- **SMS Fallback:** Send alerts through cellular networks when supported.
- **Bluetooth Mesh:** Relay emergency messages between nearby devices without requiring internet or a SIM on every device.
- **Multi-Hop Relay:** Forward SOS messages through participating devices.
- **Gateway Sync:** Forward offline alerts to Supabase through an internet-connected device.
- **Alert Queueing:** Store pending alerts until a communication path becomes available.
- **Duplicate Suppression:** Prevent repeated processing of the same message.

## 📡 Three Communication Methods

### 1. ☁️ Cloud Synchronization
- Requires an internet connection.
- Sends emergency alerts to Supabase.
- Enables synchronization with the configured emergency dashboard.

### 2. 📩 SMS Fallback
- Requires cellular coverage and a working SIM.
- Sends emergency messages through the mobile network.
- Useful when mobile data or Wi-Fi is unavailable but SMS service works.

### 3. 🔵 Bluetooth Mesh
- Requires Bluetooth and compatible nearby devices running the relay functionality.
- Relays SOS messages between participating devices without requiring internet on every device.
- Can forward messages toward an internet-connected gateway, which can synchronize them with Supabase.

## 🔗 Bluetooth Mesh Architecture

```text
👩 User Triggers SOS
         |
         v
📱 Relay Node A
         |
         v
📱 Relay Node B
         |
         v
🌐 Connected Gateway
         |
         v
☁️ Supabase / Emergency Dashboard
```

## 🛠️ Tech Stack

- **Frontend:** Flutter, Dart
- **Backend:** Supabase Realtime
- **Offline Communication:** Bluetooth Mesh
- **SMS:** Android SMS APIs
- **Platform:** Android

## 📱 How to Build and Get the APK

### Method 1: Android Studio

1. Open the project in Android Studio with Flutter support.
2. Open the terminal and run:

   ```bash
   flutter pub get
   flutter build apk --release
   ```

3. Find the APK at:

   `build/app/outputs/flutter-apk/app-release.apk`

### Method 2: Visual Studio Code

1. Open the project folder in VS Code.
2. Open the integrated terminal.
3. Run:

   ```bash
   flutter pub get
   flutter build apk --release
   ```

4. Find the generated APK in:

   `build/app/outputs/flutter-apk/app-release.apk`

### Method 3: GitHub Actions

1. Push the project to your GitHub repository.
2. Open the repository and select **Actions**.
3. Select the configured APK build workflow.
4. Click **Run workflow** if manual execution is enabled, or trigger it through a configured push event.
5. Wait for the workflow to complete successfully.
6. Open the completed workflow run and download the APK from **Artifacts**.

## 🔐 Permissions

Depending on the implemented features, the application may require:

- **Bluetooth / Nearby Devices:** Offline peer discovery and communication.
- **SMS:** Sending or receiving emergency messages.
- **Location:** Sharing emergency coordinates when enabled.
- **Camera:** Emergency media capture, if implemented.

## 🌍 Our Goal

To improve women's access to emergency assistance through resilient communication, offline message relaying, and privacy-conscious safety features.

**Safety shouldn't stop when the network does.** 🚨
