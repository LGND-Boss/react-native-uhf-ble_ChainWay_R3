import { NativeModules, NativeEventEmitter, Platform } from 'react-native';

const LINKING_ERROR =
  `react-native-uhf-ble is not linked. Make sure:\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n';

const UhfBleNative = NativeModules.UhfBle
  ? NativeModules.UhfBle
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

// ─── Event names ───────────────────────────────────────────────────────────────
export const SCAN_BLE_EVENT = 'ScanBLEListener';
export const READ_RFID_EVENT = 'ReadRFIDListener';
export const CONNECTION_STATUS_EVENT = 'ConnectionStatusListener';
export const DEBUG_EVENT = 'UhfDebugListener';

// ─── Types ─────────────────────────────────────────────────────────────────────
export interface BLEDevice {
  name_device: string;
  address_device: string;
  rssi: string;
}

export interface RFIDTag {
  rfid_tag: string;
  rssi: string;
}

export interface ConnectionStatus {
  status: 'connected' | 'disconnected' | 'connecting';
  device?: string;
}

export interface DebugEntry {
  ts: number;
  source: string;
  message: string;
}

/** bank: 0=RESERVED, 1=EPC, 2=TID, 3=USER */
export interface FilterParams {
  bank: number;
  ptr: number;
  len: number;
  data: string;
}

export interface ReadParams {
  bank: number;
  ptr: number;
  len: number;
  password?: string;
  filter?: FilterParams;
}

export interface WriteParams {
  bank: number;
  ptr: number;
  len: number;
  data: string;
  password?: string;
  filter?: FilterParams;
}

export interface LockParams {
  password: string;
  lockCode: string;
  filter?: FilterParams;
}

export interface KillParams {
  password: string;
  filter?: FilterParams;
}

export interface EraseParams {
  bank: number;
  ptr: number;
  len: number;
  password?: string;
  filter?: FilterParams;
}

// ─── Event emitter ─────────────────────────────────────────────────────────────
export const UhfBleEmitter = new NativeEventEmitter(UhfBleNative);

// ─── BLE device management ─────────────────────────────────────────────────────

/** Start scanning for BLE devices. Listen to SCAN_BLE_EVENT for results. */
export function scanBLE(): void {
  return UhfBleNative.scanBLE();
}

/** Stop scanning for BLE devices. */
export function stopScanBLE(): void {
  return UhfBleNative.stopScanBLE();
}

/**
 * Connect to a UHF reader by MAC address.
 * @returns device name + address string on success.
 */
export function connectAddress(address: string): Promise<string> {
  return UhfBleNative.connectAddress(address);
}

/** Disconnect from the connected device. */
export function disconnect(): void {
  return UhfBleNative.disconnect();
}

/** Returns current connection status string: 'connected' | 'disconnected' | 'connecting' */
export function getConnectionStatus(): Promise<string> {
  return UhfBleNative.getConnectionStatus();
}

// ─── RFID Inventory ────────────────────────────────────────────────────────────

/** Start continuous RFID tag inventory. Listen to READ_RFID_EVENT for tags. */
export function startInventory(): void {
  return UhfBleNative.startInventory();
}

/**
 * Start inventory and only emit tags matching the given EPC.
 * Useful for locating a specific tag.
 */
export function startInventoryWithFilter(epc: string): void {
  return UhfBleNative.startInventoryWithFilter(epc);
}

/** Stop RFID inventory. */
export function stopInventory(): void {
  return UhfBleNative.stopInventory();
}

/**
 * Start inventory, return the first tag found, then stop automatically.
 * iOS only — on Android use startInventory + onTagRead + stopInventory manually.
 */
export function inventorySingleTag(): Promise<{ rfid_tag: string; rssi: string }> {
  return UhfBleNative.inventorySingleTag();
}

/** Clear the internal tag list. */
export function clearData(): Promise<boolean> {
  return UhfBleNative.clearData();
}

// ─── Tag Read / Write ──────────────────────────────────────────────────────────

/**
 * Read data from a tag memory bank.
 * @returns hex string of data read, or rejects on failure.
 */
export function readTag(params: ReadParams): Promise<string> {
  return UhfBleNative.readTag(params);
}

/**
 * Write data to a tag memory bank.
 * @returns true on success, rejects on failure.
 */
export function writeTag(params: WriteParams): Promise<boolean> {
  return UhfBleNative.writeTag(params);
}

// ─── Tag Operations ────────────────────────────────────────────────────────────

/**
 * Lock a tag memory bank.
 * lockCode is a hex string representing the 3-byte LD field.
 */
export function lockTag(params: LockParams): Promise<boolean> {
  return UhfBleNative.lockTag(params);
}

/**
 * Kill (permanently disable) a tag.
 * password must be non-zero on the tag for this to succeed.
 */
export function killTag(params: KillParams): Promise<boolean> {
  return UhfBleNative.killTag(params);
}

/**
 * Erase (zero out) a tag memory bank region.
 */
export function eraseTag(params: EraseParams): Promise<boolean> {
  return UhfBleNative.eraseTag(params);
}

// ─── Device Settings ───────────────────────────────────────────────────────────

/**
 * Set the RF transmit power of the reader (dBm).
 * Typical range: 5–30.
 */
export function setPower(power: number): Promise<boolean> {
  return UhfBleNative.setPower(power);
}

/**
 * Read the current RF output power from the device.
 * @returns Current power in dBm as a number.
 */
export function getPower(): Promise<number> {
  return UhfBleNative.getPower();
}

/**
 * Set the frequency mode/region.
 * 0x08 = FCC (US), other values device-specific.
 */
export function setFrequency(mode: number): Promise<boolean> {
  return UhfBleNative.setFrequency(mode);
}

// ─── Debug ─────────────────────────────────────────────────────────────────────

/**
 * Enable/disable native debug events. When enabled, the native module emits a
 * DEBUG_EVENT for every significant state change (scan, connect, inventory
 * start/stop/retry, errors). Logcat lines are also written either way under
 * the tag `UhfBleModule` — visible via `adb logcat -s UhfBleModule`.
 */
export function setDebugMode(enabled: boolean): Promise<boolean> {
  return UhfBleNative.setDebugMode(enabled);
}

/**
 * Convenience: enables debug mode and pipes every debug entry to `console.log`
 * (or a custom sink). Returns a cleanup function that detaches the listener
 * and turns debug mode off.
 *
 * Example:
 * ```ts
 * useEffect(() => {
 *   const detach = attachDebugConsole();
 *   return detach;
 * }, []);
 * ```
 */
export function attachDebugConsole(
  sink: (entry: DebugEntry) => void = (e) =>
    // eslint-disable-next-line no-console
    console.log(
      `[UhfBle ${new Date(e.ts).toISOString().slice(11, 23)}] ${e.source} :: ${e.message}`
    )
): () => void {
  const sub = UhfBleEmitter.addListener(DEBUG_EVENT, sink);
  // Fire-and-forget; if the bridge isn't ready the promise will reject and
  // we don't want to crash the caller's setup code.
  UhfBleNative.setDebugMode(true)?.catch?.(() => {});
  return () => {
    sub.remove();
    UhfBleNative.setDebugMode(false)?.catch?.(() => {});
  };
}
