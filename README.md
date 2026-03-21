# react-native-uhf-ble

React Native library for UHF RFID readers connected via Bluetooth Low Energy (BLE).

Supports Android (API 21+) and iOS (CoreBluetooth). Wraps the rscja UHF BLE SDK on Android and Nordic UART Service (NUS) on iOS.

---

## Features

- Scan for BLE UHF RFID readers
- Connect / disconnect
- RFID tag inventory (continuous, with unique EPC deduplication)
- Filter inventory by EPC
- Read / write tag memory banks (RESERVED, EPC, TID, USER)
- Lock, kill, and erase tags
- Set / get reader RF power
- Set frequency region
- Single-tag read (one-shot inventory)
- Full TypeScript types

---

## Installation

```sh
npm install react-native-uhf-ble
```

### Android

1. Copy `DeviceAPI_ver20251103_release.aar` into `android/app/libs/`
2. In `android/app/build.gradle` add:
   ```groovy
   dependencies {
       implementation fileTree(dir: 'libs', include: ['*.aar', '*.jar'])
   }
   ```
3. Add BLE permissions to `AndroidManifest.xml`:
   ```xml
   <!-- Android < 12 -->
   <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
   <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />

   <!-- Android 12+ -->
   <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
   <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
   ```
4. Register the package in `MainApplication.kt`:
   ```kotlin
   import com.uhfble.UhfBlePackage

   override fun getPackages(): List<ReactPackage> =
       PackageList(this).packages.apply {
           add(UhfBlePackage())
       }
   ```

### iOS

See [`ios-setup/INSTRUCTIONS.txt`](ios-setup/INSTRUCTIONS.txt) for full Mac/Xcode setup.

Add Bluetooth permissions to `Info.plist`:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to connect to the UHF RFID reader</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app uses Bluetooth to connect to the UHF RFID reader</string>
```

---

## Quick Start

```tsx
import {
  scanBLE,
  stopScanBLE,
  connectAddress,
  startInventory,
  stopInventory,
  clearData,
  UhfBleEmitter,
  SCAN_BLE_EVENT,
  READ_RFID_EVENT,
  CONNECTION_STATUS_EVENT,
} from 'react-native-uhf-ble';

// Listen for BLE devices
const sub = UhfBleEmitter.addListener(SCAN_BLE_EVENT, (device) => {
  console.log(device.name_device, device.address_device, device.rssi);
});

// Scan
scanBLE();

// Connect
await connectAddress('AA:BB:CC:DD:EE:FF');

// Start inventory
UhfBleEmitter.addListener(READ_RFID_EVENT, (tag) => {
  console.log(tag.rfid_tag, tag.rssi);
});
startInventory();

// Stop & clear
stopInventory();
await clearData();

// Cleanup
sub.remove();
```

---

## API Reference

### BLE Management

#### `scanBLE(): void`
Start scanning for nearby BLE UHF readers. Results are emitted as `SCAN_BLE_EVENT` events.

#### `stopScanBLE(): void`
Stop the BLE scan.

#### `connectAddress(address: string): Promise<string>`
Connect to a device by MAC address. Resolves with a device identifier string on success.

| Parameter | Type | Description |
|-----------|------|-------------|
| address | string | MAC address e.g. `"AA:BB:CC:DD:EE:FF"` |

#### `disconnect(): void`
Disconnect from the currently connected device.

#### `getConnectionStatus(): Promise<string>`
Returns `'connected'`, `'disconnected'`, or `'connecting'`.

---

### RFID Inventory

#### `startInventory(): void`
Begin continuous RFID tag scanning. Each unique EPC is emitted **exactly once** per session via `READ_RFID_EVENT`.

#### `startInventoryWithFilter(epc: string): void`
Same as `startInventory()` but only emits tags whose EPC matches the given string. Useful for locating a specific tag.

#### `stopInventory(): void`
Stop the inventory loop.

#### `inventorySingleTag(): Promise<{ rfid_tag: string; rssi: string }>`
Read the first tag in range and return immediately without starting a continuous session.

```ts
const tag = await inventorySingleTag();
console.log(tag.rfid_tag, tag.rssi);
```

#### `clearData(): Promise<boolean>`
Reset the internal seen-tag list so the next inventory starts fresh.

---

### Tag Read / Write

#### `readTag(params: ReadParams): Promise<string>`
Read data from a tag memory bank. Returns a hex string.

```ts
interface ReadParams {
  bank: number;      // 0=RESERVED, 1=EPC, 2=TID, 3=USER
  ptr: number;       // word address to start reading from
  len: number;       // number of words to read
  password?: string; // 8-char hex access password (default: "00000000")
  filter?: FilterParams;
}
```

**Example:**
```ts
const data = await readTag({ bank: 1, ptr: 2, len: 6 });
// returns e.g. "E2001234567890ABCDEF1234"
```

#### `writeTag(params: WriteParams): Promise<boolean>`
Write hex data to a tag memory bank.

```ts
interface WriteParams {
  bank: number;
  ptr: number;
  len: number;
  data: string;      // hex string to write
  password?: string;
  filter?: FilterParams;
}
```

**Example:**
```ts
await writeTag({ bank: 1, ptr: 2, len: 6, data: 'E2001234567890ABCDEF1234' });
```

---

### Tag Operations

#### `lockTag(params: LockParams): Promise<boolean>`
Lock a tag memory bank.

```ts
interface LockParams {
  password: string;  // 8-char hex kill/access password
  lockCode: string;  // 6-char hex LD field (3 bytes)
  filter?: FilterParams;
}
```

**Lock code reference:**

| Value | Effect |
|-------|--------|
| `000000` | No change |
| `AAAAAA` | Lock all banks |
| `080000` | Lock EPC bank |
| `020000` | Lock TID bank |
| `008000` | Lock USER bank |

#### `killTag(params: KillParams): Promise<boolean>`
Permanently disable a tag. The tag's kill password must be non-zero.

```ts
interface KillParams {
  password: string; // 8-char hex kill password programmed on tag
  filter?: FilterParams;
}
```

> WARNING: This is irreversible. The tag cannot be used again after a successful kill.

#### `eraseTag(params: EraseParams): Promise<boolean>`
Zero out a region of a tag memory bank.

```ts
interface EraseParams {
  bank: number;
  ptr: number;
  len: number;
  password?: string;
  filter?: FilterParams;
}
```

---

### Device Settings

#### `setPower(power: number): Promise<boolean>`
Set the RF transmit power in dBm. Typical range: **5–30**.

```ts
await setPower(26); // 26 dBm
```

#### `getPower(): Promise<number>`
Read the current RF transmit power from the device. Returns the power level in dBm.

```ts
const power = await getPower();
console.log(power); // e.g. 26
```

#### `setFrequency(mode: number): Promise<boolean>`
Set the frequency region. `0x08` = FCC (US/Canada). Other values are device-specific.

---

### Filter Params

Used in read/write/lock/kill/erase to target a specific tag by matching a portion of its memory.

```ts
interface FilterParams {
  bank: number; // memory bank to match against
  ptr: number;  // bit offset to start matching
  len: number;  // number of bits to match
  data: string; // hex string to match
}
```

**Example — read only a tag matching a known EPC:**
```ts
await readTag({
  bank: 1, ptr: 2, len: 6,
  filter: { bank: 1, ptr: 32, len: 48, data: 'AABBCCDDEEFF' }
});
```

---

### Events

| Constant | Event name | Payload |
|----------|-----------|---------|
| `SCAN_BLE_EVENT` | `'ScanBLEListener'` | `BLEDevice` |
| `READ_RFID_EVENT` | `'ReadRFIDListener'` | `RFIDTag` |
| `CONNECTION_STATUS_EVENT` | `'ConnectionStatusListener'` | `ConnectionStatus` |

```ts
interface BLEDevice {
  name_device: string;
  address_device: string;
  rssi: string;
}

interface RFIDTag {
  rfid_tag: string;
  rssi: string;
}

interface ConnectionStatus {
  status: 'connected' | 'disconnected' | 'connecting';
  device?: string;
}
```

---

### Memory Bank Reference

| Value | Bank |
|-------|------|
| `0` | RESERVED (kill + access passwords) |
| `1` | EPC |
| `2` | TID |
| `3` | USER |

---

## BLE UUIDs (Nordic UART Service)

| Role | UUID |
|------|------|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| Write (TX) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| Notify (RX) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

---

## Android Compatibility

| Android version | API level | Notes |
|----------------|-----------|-------|
| 5.0 – 11 | 21 – 30 | Uses `ACCESS_FINE_LOCATION` for BLE scan |
| 12+ | 31+ | Uses `BLUETOOTH_SCAN` + `BLUETOOTH_CONNECT` |
| 14 (tested) | 34 | Fully supported |

---

## License

MIT
