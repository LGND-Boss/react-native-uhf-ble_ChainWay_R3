package com.uhfble;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.module.annotations.ReactModule;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.rscja.deviceapi.RFIDWithUHFBLE;
import com.rscja.deviceapi.entity.UHFTAGInfo;
import com.rscja.deviceapi.interfaces.ConnectionStatus;
import com.rscja.deviceapi.interfaces.ConnectionStatusCallback;
import com.rscja.deviceapi.interfaces.KeyEventCallback;
import com.rscja.deviceapi.interfaces.ScanBTCallback;

import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@ReactModule(name = UhfBleModule.NAME)
public class UhfBleModule extends ReactContextBaseJavaModule {

    public static final String NAME = "UhfBle";
    private static final String TAG = "UhfBleModule";

    private static final String EVENT_SCAN_BLE          = "ScanBLEListener";
    private static final String EVENT_READ_RFID         = "ReadRFIDListener";
    private static final String EVENT_CONNECTION_STATUS = "ConnectionStatusListener";

    private static final int PERMISSION_REQUEST_CODE = 100;

    private static ReactApplicationContext reactContext;
    private final RFIDWithUHFBLE uhf = RFIDWithUHFBLE.getInstance();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    private volatile boolean isScanning  = false;
    private volatile boolean isDestroyed = false;
    private volatile String  filterEpc   = null;
    private String connectedDevice = "";

    // Thread-safe sets for deduplication
    // Each unique EPC is counted and emitted EXACTLY once per session
    private final Set<String> seenEpcs      = Collections.synchronizedSet(new HashSet<>());
    private final Set<String> seenAddresses = Collections.synchronizedSet(new HashSet<>());

    public UhfBleModule(ReactApplicationContext context) {
        super(context);
        reactContext = context;
        uhf.init(context);

        uhf.setKeyEventCallback(new KeyEventCallback() {
            @Override
            public void onKeyDown(int keycode) {
                if (isDestroyed || uhf.getConnectStatus() != ConnectionStatus.CONNECTED) return;
                if (keycode == 3) {
                    startInventory();
                } else if (keycode == 1) {
                    if (isScanning) stopInventory();
                    else startInventory();
                }
            }
            @Override
            public void onKeyUp(int keycode) {
                if (keycode == 4) stopInventory();
            }
        });

        uhf.setConnectionStatusCallback(new ConnectionStatusCallback<Object>() {
            @Override
            public void getStatus(ConnectionStatus status, Object device) {
                WritableMap payload = Arguments.createMap();
                if (status == ConnectionStatus.CONNECTED && device instanceof BluetoothDevice) {
                    BluetoothDevice btDevice = (BluetoothDevice) device;
                    connectedDevice = btDevice.getName() + "(" + btDevice.getAddress() + ")";
                    payload.putString("status", "connected");
                    payload.putString("device", connectedDevice);
                } else if (status == ConnectionStatus.DISCONNECTED) {
                    connectedDevice = "";
                    payload.putString("status", "disconnected");
                } else {
                    payload.putString("status", "connecting");
                }
                sendEvent(reactContext, EVENT_CONNECTION_STATUS, payload);
            }
        });
    }

    @Override
    @NonNull
    public String getName() { return NAME; }

    private void sendEvent(ReactContext context, String eventName, @Nullable WritableMap params) {
        context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
               .emit(eventName, params);
    }

    // ─── Permission helpers (Android 12+ aware) ──────────────────────────────

    private boolean hasPermission(String permission) {
        return ActivityCompat.checkSelfPermission(reactContext, permission)
               == PackageManager.PERMISSION_GRANTED;
    }

    private boolean checkBlePermissions() {
        if (getCurrentActivity() == null) return false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+ needs BLUETOOTH_SCAN + BLUETOOTH_CONNECT
            boolean hasScan    = hasPermission(Manifest.permission.BLUETOOTH_SCAN);
            boolean hasConnect = hasPermission(Manifest.permission.BLUETOOTH_CONNECT);
            if (!hasScan || !hasConnect) {
                ActivityCompat.requestPermissions(getCurrentActivity(),
                    new String[]{
                        Manifest.permission.BLUETOOTH_SCAN,
                        Manifest.permission.BLUETOOTH_CONNECT
                    }, PERMISSION_REQUEST_CODE);
                return false;
            }
        } else {
            // Android < 12 needs ACCESS_FINE_LOCATION for BLE scan
            if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) {
                ActivityCompat.requestPermissions(getCurrentActivity(),
                    new String[]{ Manifest.permission.ACCESS_FINE_LOCATION },
                    PERMISSION_REQUEST_CODE);
                return false;
            }
        }
        return true;
    }

    // ─── BLE device scan ─────────────────────────────────────────────────────

    @ReactMethod
    public void scanBLE() {
        if (!checkBlePermissions()) return;
        seenAddresses.clear();
        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            Log.w(TAG, "Bluetooth not available or not enabled");
            return;
        }
        uhf.startScanBTDevices(new ScanBTCallback() {
            @Override
            public void getDevices(BluetoothDevice device, int rssi, byte[] scanRecord) {
                if (device == null) return;
                String addr = device.getAddress();
                // Only emit each device address once per scan session
                if (!seenAddresses.add(addr)) return;
                WritableMap payload = Arguments.createMap();
                payload.putString("name_device",    device.getName() != null ? device.getName() : "");
                payload.putString("address_device", addr);
                payload.putString("rssi",           String.valueOf(rssi));
                sendEvent(reactContext, EVENT_SCAN_BLE, payload);
            }
        });
    }

    @ReactMethod
    public void stopScanBLE() {
        uhf.stopScanBTDevices();
    }

    @ReactMethod
    public void connectAddress(String address, Promise promise) {
        uhf.connect(address);
        new Handler(Looper.getMainLooper()).postDelayed(() ->
            promise.resolve(connectedDevice.isEmpty() ? address : connectedDevice), 3000);
    }

    @ReactMethod
    public void disconnect() {
        uhf.disconnect();
    }

    @ReactMethod
    public void getConnectionStatus(Promise promise) {
        ConnectionStatus s = uhf.getConnectStatus();
        if (s == ConnectionStatus.CONNECTED)    promise.resolve("connected");
        else if (s == ConnectionStatus.DISCONNECTED) promise.resolve("disconnected");
        else promise.resolve("connecting");
    }

    // ─── RFID Inventory ──────────────────────────────────────────────────────

    @ReactMethod
    public void startInventory() {
        if (isScanning) return;
        filterEpc   = null;
        isScanning  = true;
        executor.execute(new InventoryRunnable());
    }

    @ReactMethod
    public void startInventoryWithFilter(String epc) {
        if (isScanning) return;
        filterEpc  = epc;
        isScanning = true;
        executor.execute(new InventoryRunnable());
    }

    @ReactMethod
    public void stopInventory() {
        isScanning = false;
    }

    @ReactMethod
    public void clearData(Promise promise) {
        try {
            seenEpcs.clear();
            promise.resolve(true);
        } catch (Exception e) {
            promise.reject("CLEAR_ERROR", e.getMessage());
        }
    }

    private class InventoryRunnable implements Runnable {
        @Override
        public void run() {
            if (!uhf.startInventoryTag()) {
                isScanning = false;
                return;
            }
            while (isScanning) {
                java.util.List<UHFTAGInfo> list = uhf.readTagFromBufferList();
                if (list == null || list.isEmpty()) {
                    SystemClock.sleep(10);
                    continue;
                }
                for (UHFTAGInfo info : list) {
                    if (info == null || info.getEPC() == null) continue;
                    String epc = info.getEPC().trim();
                    if (epc.isEmpty()) continue;

                    // Filter by specific EPC if set
                    if (filterEpc != null && !filterEpc.isEmpty() && !filterEpc.equals(epc)) continue;

                    // UNIQUE COUNT: each EPC emitted exactly once per session
                    // seenEpcs.add() returns false if already present — skip if so
                    if (!seenEpcs.add(epc)) continue;

                    WritableMap payload = Arguments.createMap();
                    payload.putString("rfid_tag", epc);
                    payload.putString("rssi",     info.getRssi() != null ? info.getRssi() : "");
                    sendEvent(reactContext, EVENT_READ_RFID, payload);
                }
            }
            uhf.stopInventory();
        }
    }

    // ─── Tag Read / Write ────────────────────────────────────────────────────

    @ReactMethod
    public void readTag(ReadableMap params, Promise promise) {
        executor.execute(() -> {
            try {
                int    bank = params.getInt("bank");
                int    ptr  = params.getInt("ptr");
                int    len  = params.getInt("len");
                String pwd  = safePassword(params.hasKey("password") ? params.getString("password") : null);
                String data;
                if (params.hasKey("filter") && params.getMap("filter") != null) {
                    ReadableMap f = params.getMap("filter");
                    data = uhf.readData(pwd, f.getInt("bank"), f.getInt("ptr"), f.getInt("len"),
                                        f.getString("data"), bank, ptr, len);
                } else {
                    data = uhf.readData(pwd, bank, ptr, len);
                }
                if (data != null && !data.isEmpty()) promise.resolve(data);
                else promise.reject("READ_FAIL", "Read returned no data");
            } catch (Exception e) { promise.reject("READ_ERROR", e.getMessage()); }
        });
    }

    @ReactMethod
    public void writeTag(ReadableMap params, Promise promise) {
        executor.execute(() -> {
            try {
                int    bank = params.getInt("bank");
                int    ptr  = params.getInt("ptr");
                int    len  = params.getInt("len");
                String data = params.getString("data");
                String pwd  = safePassword(params.hasKey("password") ? params.getString("password") : null);
                boolean result;
                if (params.hasKey("filter") && params.getMap("filter") != null) {
                    ReadableMap f = params.getMap("filter");
                    result = uhf.writeData(pwd, f.getInt("bank"), f.getInt("ptr"), f.getInt("len"),
                                           f.getString("data"), bank, ptr, len, data);
                } else {
                    result = uhf.writeData(pwd, bank, ptr, len, data);
                }
                if (result) promise.resolve(true);
                else promise.reject("WRITE_FAIL", "Write operation failed");
            } catch (Exception e) { promise.reject("WRITE_ERROR", e.getMessage()); }
        });
    }

    // ─── Tag Operations ──────────────────────────────────────────────────────

    @ReactMethod
    public void lockTag(ReadableMap params, Promise promise) {
        executor.execute(() -> {
            try {
                String pwd      = safePassword(params.getString("password"));
                String lockCode = params.getString("lockCode");
                boolean result;
                if (params.hasKey("filter") && params.getMap("filter") != null) {
                    ReadableMap f = params.getMap("filter");
                    result = uhf.lockData(pwd, f.getInt("bank"), f.getInt("ptr"),
                                          f.getInt("len"), f.getString("data"), lockCode);
                } else {
                    result = uhf.lockData(pwd, lockCode);
                }
                if (result) promise.resolve(true);
                else promise.reject("LOCK_FAIL", "Lock operation failed");
            } catch (Exception e) { promise.reject("LOCK_ERROR", e.getMessage()); }
        });
    }

    @ReactMethod
    public void killTag(ReadableMap params, Promise promise) {
        executor.execute(() -> {
            try {
                String pwd = safePassword(params.getString("password"));
                boolean result;
                if (params.hasKey("filter") && params.getMap("filter") != null) {
                    ReadableMap f = params.getMap("filter");
                    result = uhf.killData(pwd, f.getInt("bank"), f.getInt("ptr"),
                                          f.getInt("len"), f.getString("data"));
                } else {
                    result = uhf.killData(pwd);
                }
                if (result) promise.resolve(true);
                else promise.reject("KILL_FAIL", "Kill operation failed");
            } catch (Exception e) { promise.reject("KILL_ERROR", e.getMessage()); }
        });
    }

    @ReactMethod
    public void eraseTag(ReadableMap params, Promise promise) {
        executor.execute(() -> {
            try {
                int    bank = params.getInt("bank");
                int    ptr  = params.getInt("ptr");
                int    len  = params.getInt("len");
                String pwd  = safePassword(params.hasKey("password") ? params.getString("password") : null);
                StringBuilder zeros = new StringBuilder();
                for (int i = 0; i < len * 4; i++) zeros.append("0");
                boolean result;
                if (params.hasKey("filter") && params.getMap("filter") != null) {
                    ReadableMap f = params.getMap("filter");
                    result = uhf.writeData(pwd, f.getInt("bank"), f.getInt("ptr"), f.getInt("len"),
                                           f.getString("data"), bank, ptr, len, zeros.toString());
                } else {
                    result = uhf.writeData(pwd, bank, ptr, len, zeros.toString());
                }
                if (result) promise.resolve(true);
                else promise.reject("ERASE_FAIL", "Erase operation failed");
            } catch (Exception e) { promise.reject("ERASE_ERROR", e.getMessage()); }
        });
    }

    // ─── Settings ────────────────────────────────────────────────────────────

    @ReactMethod
    public void setPower(int power, Promise promise) {
        executor.execute(() -> {
            try { promise.resolve(uhf.setPower(power)); }
            catch (Exception e) { promise.reject("POWER_ERROR", e.getMessage()); }
        });
    }

    @ReactMethod
    public void getPower(Promise promise) {
        executor.execute(() -> {
            try { promise.resolve(uhf.getPower()); }
            catch (Exception e) { promise.reject("GET_POWER_FAIL", e.getMessage()); }
        });
    }

    @ReactMethod
    public void setFrequency(int mode, Promise promise) {
        executor.execute(() -> {
            try { promise.resolve(uhf.setFrequencyMode(mode)); }
            catch (Exception e) { promise.reject("FREQ_ERROR", e.getMessage()); }
        });
    }

    // ─── Lifecycle ───────────────────────────────────────────────────────────

    @Override
    public void onCatalystInstanceDestroy() {
        super.onCatalystInstanceDestroy();
        isDestroyed = true;
        isScanning  = false;
        uhf.disconnect();
        seenEpcs.clear();
        seenAddresses.clear();
        executor.shutdownNow();
    }

    @ReactMethod public void addListener(String eventName) {}
    @ReactMethod public void removeListeners(Integer count) {}

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private String safePassword(@Nullable String pwd) {
        return (pwd == null || pwd.isEmpty()) ? "00000000" : pwd;
    }
}
