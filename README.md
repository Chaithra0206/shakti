# 🛡️ Shakti SOS | Offline SOS Bridge

### Women's Safety

Shakti SOS is a Flutter-based emergency communication application designed to help women seek assistance during unsafe situations. It combines cloud synchronization, SMS, and **Bluetooth Mesh communication** to relay SOS alerts, including when internet connectivity is unavailable.

## 🚨 Key Features

- **SOS Alerts:** Quickly send emergency alerts when feeling unsafe.
- **Cloud Sync:** Synchronize alerts through Supabase when internet is available.
- **SMS Fallback:** Transmit alerts through cellular networks when supported.
- **Bluetooth Mesh:** Enable offline communication between nearby devices without requiring internet access.
- **Multi-Hop Relay:** Forward SOS messages across multiple participating devices.
- **Automatic Gateway Sync:** Forward relayed alerts to Supabase through a device with internet access.
- **Alert Queueing:** Store pending alerts until a communication path becomes available.
- **Duplicate Suppression:** Prevent repeated processing of the same emergency message.

## 📡 Bluetooth Mesh Architecture

```text
👩 User Triggers SOS
         |
         v
📱 Nearby Relay Node A
         |
         v
📱 Relay Node B
         |
         v
📱 Rescue Gateway Node
         |
         v
☁️ Supabase / Emergency Dashboard
```

SOS alerts can travel across participating devices through multi-hop relaying, allowing messages to reach a connected gateway beyond the sender's direct range.

## 🛠️ Tech Stack

- **Frontend:** Flutter, Dart
- **Backend:** Supabase Realtime
- **Offline Network:** Bluetooth Mesh
- **Communication Fallback:** SMS
- **Platform:** Android

## 📱 Build APK

```bash
flutter pub get
flutter build apk --release
```

APK location:

`build/app/outputs/flutter-apk/app-release.apk`

## 🌍 Our Goal

To improve women's access to emergency assistance through resilient SOS communication, offline message relaying, and privacy-conscious safety features.

**Safety shouldn't stop when the network does.** 🚨
