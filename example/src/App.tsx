import React, { useEffect, useState, useCallback } from 'react';
import {
  SafeAreaView,
  View,
  Text,
  TouchableOpacity,
  FlatList,
  TextInput,
  StyleSheet,
  Alert,
  ScrollView,
} from 'react-native';
import {
  scanBLE,
  stopScanBLE,
  connectAddress,
  disconnect,
  startInventory,
  startInventoryWithFilter,
  stopInventory,
  clearData,
  readTag,
  writeTag,
  lockTag,
  killTag,
  setPower,
  UhfBleEmitter,
  SCAN_BLE_EVENT,
  READ_RFID_EVENT,
  CONNECTION_STATUS_EVENT,
  type BLEDevice,
  type RFIDTag,
} from 'react-native-uhf-ble';

type Tab = 'scan' | 'inventory' | 'readwrite' | 'operations';

export default function App() {
  const [tab, setTab] = useState<Tab>('scan');
  const [connectionStatus, setConnectionStatus] = useState('disconnected');
  const [connectedDevice, setConnectedDevice] = useState('');
  const [bleDevices, setBleDevices] = useState<BLEDevice[]>([]);
  const [rfidTags, setRfidTags] = useState<RFIDTag[]>([]);

  // ReadWrite state
  const [rwBank, setRwBank] = useState('1');
  const [rwPtr, setRwPtr] = useState('2');
  const [rwLen, setRwLen] = useState('6');
  const [rwPwd, setRwPwd] = useState('00000000');
  const [rwData, setRwData] = useState('');

  // Operations state
  const [opPwd, setOpPwd] = useState('00000000');
  const [lockCode, setLockCode] = useState('000000');
  const [powerValue, setPowerValue] = useState('20');

  // Filter for inventory
  const [filterEpc, setFilterEpc] = useState('');

  useEffect(() => {
    const scanSub = UhfBleEmitter.addListener(SCAN_BLE_EVENT, (device: BLEDevice) => {
      setBleDevices(prev => {
        if (prev.find(d => d.address_device === device.address_device)) return prev;
        return [...prev, device].sort((a, b) => parseInt(b.rssi) - parseInt(a.rssi));
      });
    });
    const rfidSub = UhfBleEmitter.addListener(READ_RFID_EVENT, (tag: RFIDTag) => {
      setRfidTags(prev => {
        if (prev.find(t => t.rfid_tag === tag.rfid_tag)) return prev;
        return [...prev, tag];
      });
    });
    const connSub = UhfBleEmitter.addListener(CONNECTION_STATUS_EVENT, (e: any) => {
      setConnectionStatus(e.status);
      if (e.device) setConnectedDevice(e.device);
      else if (e.status === 'disconnected') setConnectedDevice('');
    });
    return () => {
      scanSub.remove();
      rfidSub.remove();
      connSub.remove();
    };
  }, []);

  const handleConnect = useCallback(async (address: string) => {
    try {
      stopScanBLE();
      setConnectionStatus('connecting');
      const result = await connectAddress(address);
      setConnectedDevice(result);
    } catch (e: any) {
      Alert.alert('Connect Error', e.message);
    }
  }, []);

  const handleRead = useCallback(async () => {
    try {
      const data = await readTag({
        bank: parseInt(rwBank),
        ptr: parseInt(rwPtr),
        len: parseInt(rwLen),
        password: rwPwd,
      });
      setRwData(data);
      Alert.alert('Read Success', data);
    } catch (e: any) {
      Alert.alert('Read Failed', e.message);
    }
  }, [rwBank, rwPtr, rwLen, rwPwd]);

  const handleWrite = useCallback(async () => {
    if (!rwData) { Alert.alert('Error', 'Enter data to write'); return; }
    try {
      await writeTag({
        bank: parseInt(rwBank),
        ptr: parseInt(rwPtr),
        len: parseInt(rwLen),
        data: rwData,
        password: rwPwd,
      });
      Alert.alert('Write Success');
    } catch (e: any) {
      Alert.alert('Write Failed', e.message);
    }
  }, [rwBank, rwPtr, rwLen, rwData, rwPwd]);

  const handleLock = useCallback(async () => {
    try {
      await lockTag({ password: opPwd, lockCode });
      Alert.alert('Lock Success');
    } catch (e: any) {
      Alert.alert('Lock Failed', e.message);
    }
  }, [opPwd, lockCode]);

  const handleKill = useCallback(async () => {
    Alert.alert('Kill Tag', 'This permanently disables the tag. Continue?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Kill', style: 'destructive', onPress: async () => {
          try {
            await killTag({ password: opPwd });
            Alert.alert('Kill Success');
          } catch (e: any) {
            Alert.alert('Kill Failed', e.message);
          }
        }
      }
    ]);
  }, [opPwd]);

  const handleSetPower = useCallback(async () => {
    try {
      await setPower(parseInt(powerValue));
      Alert.alert('Power Set', `Power set to ${powerValue} dBm`);
    } catch (e: any) {
      Alert.alert('Set Power Failed', e.message);
    }
  }, [powerValue]);

  const statusColor = connectionStatus === 'connected' ? '#27ae60'
    : connectionStatus === 'connecting' ? '#f39c12' : '#e74c3c';

  return (
    <SafeAreaView style={styles.container}>
      {/* Status bar */}
      <View style={[styles.statusBar, { backgroundColor: statusColor }]}>
        <Text style={styles.statusText}>
          {connectionStatus.toUpperCase()}
          {connectedDevice ? ` — ${connectedDevice}` : ''}
        </Text>
        {connectionStatus === 'connected' && (
          <TouchableOpacity onPress={disconnect}>
            <Text style={styles.disconnectBtn}>Disconnect</Text>
          </TouchableOpacity>
        )}
      </View>

      {/* Tabs */}
      <View style={styles.tabs}>
        {(['scan', 'inventory', 'readwrite', 'operations'] as Tab[]).map(t => (
          <TouchableOpacity key={t} style={[styles.tab, tab === t && styles.tabActive]} onPress={() => setTab(t)}>
            <Text style={[styles.tabText, tab === t && styles.tabTextActive]}>
              {t === 'readwrite' ? 'R/W' : t.charAt(0).toUpperCase() + t.slice(1)}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* ── SCAN TAB ── */}
      {tab === 'scan' && (
        <View style={styles.panel}>
          <View style={styles.row}>
            <Btn title="Scan BLE" color="#2980b9" onPress={() => { setBleDevices([]); scanBLE(); }} />
            <Btn title="Stop Scan" color="#7f8c8d" onPress={stopScanBLE} />
          </View>
          <Text style={styles.sectionLabel}>Devices ({bleDevices.length})</Text>
          <FlatList
            data={bleDevices}
            keyExtractor={item => item.address_device}
            renderItem={({ item }) => (
              <TouchableOpacity style={styles.listItem} onPress={() => handleConnect(item.address_device)}>
                <Text style={styles.listItemTitle}>{item.name_device || 'Unknown'}</Text>
                <Text style={styles.listItemSub}>{item.address_device}  RSSI: {item.rssi}</Text>
              </TouchableOpacity>
            )}
          />
        </View>
      )}

      {/* ── INVENTORY TAB ── */}
      {tab === 'inventory' && (
        <View style={styles.panel}>
          <TextInput
            style={styles.input}
            placeholder="Filter by EPC (optional)"
            value={filterEpc}
            onChangeText={setFilterEpc}
          />
          <View style={styles.row}>
            <Btn title="Start" color="#27ae60"
              onPress={() => filterEpc ? startInventoryWithFilter(filterEpc) : startInventory()} />
            <Btn title="Stop" color="#e74c3c" onPress={stopInventory} />
            <Btn title="Clear" color="#7f8c8d"
              onPress={() => clearData().then(() => setRfidTags([]))} />
          </View>
          <Text style={styles.sectionLabel}>Tags ({rfidTags.length})</Text>
          <FlatList
            data={rfidTags}
            keyExtractor={(item, i) => `${item.rfid_tag}-${i}`}
            renderItem={({ item, index }) => (
              <View style={styles.listItem}>
                <Text style={styles.listItemTitle}>{index + 1}. {item.rfid_tag}</Text>
                {item.rssi ? <Text style={styles.listItemSub}>RSSI: {item.rssi}</Text> : null}
              </View>
            )}
          />
        </View>
      )}

      {/* ── READ/WRITE TAB ── */}
      {tab === 'readwrite' && (
        <ScrollView style={styles.panel}>
          <Text style={styles.sectionLabel}>Memory Bank</Text>
          <View style={styles.row}>
            {[['RESERVED', '0'], ['EPC', '1'], ['TID', '2'], ['USER', '3']].map(([label, val]) => (
              <TouchableOpacity key={val} style={[styles.chip, rwBank === val && styles.chipActive]}
                onPress={() => setRwBank(val)}>
                <Text style={[styles.chipText, rwBank === val && styles.chipTextActive]}>{label}</Text>
              </TouchableOpacity>
            ))}
          </View>
          <Field label="Address (ptr)" value={rwPtr} onChangeText={setRwPtr} keyboardType="numeric" />
          <Field label="Length (words)" value={rwLen} onChangeText={setRwLen} keyboardType="numeric" />
          <Field label="Access Password" value={rwPwd} onChangeText={setRwPwd} />
          <Field label="Data (hex)" value={rwData} onChangeText={setRwData} />
          <View style={styles.row}>
            <Btn title="Read" color="#2980b9" onPress={handleRead} />
            <Btn title="Write" color="#e67e22" onPress={handleWrite} />
          </View>
        </ScrollView>
      )}

      {/* ── OPERATIONS TAB ── */}
      {tab === 'operations' && (
        <ScrollView style={styles.panel}>
          <Field label="Access / Kill Password" value={opPwd} onChangeText={setOpPwd} />
          <Field label="Lock Code (hex, 3 bytes)" value={lockCode} onChangeText={setLockCode} />
          <View style={styles.row}>
            <Btn title="Lock Tag" color="#8e44ad" onPress={handleLock} />
            <Btn title="Kill Tag" color="#c0392b" onPress={handleKill} />
          </View>
          <View style={styles.divider} />
          <Field label="Power (dBm, 5–30)" value={powerValue} onChangeText={setPowerValue} keyboardType="numeric" />
          <Btn title="Set Power" color="#16a085" onPress={handleSetPower} />
        </ScrollView>
      )}
    </SafeAreaView>
  );
}

function Btn({ title, color, onPress }: { title: string; color: string; onPress: () => void }) {
  return (
    <TouchableOpacity style={[styles.btn, { backgroundColor: color }]} onPress={onPress}>
      <Text style={styles.btnText}>{title}</Text>
    </TouchableOpacity>
  );
}

function Field({ label, value, onChangeText, keyboardType }: any) {
  return (
    <View style={styles.fieldWrap}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput style={styles.input} value={value} onChangeText={onChangeText}
        keyboardType={keyboardType || 'default'} autoCapitalize="characters" />
    </View>
  );
}

const styles = StyleSheet.create({
  container:      { flex: 1, backgroundColor: '#f0f2f5' },
  statusBar:      { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', padding: 10 },
  statusText:     { color: '#fff', fontWeight: '700', fontSize: 13 },
  disconnectBtn:  { color: '#fff', fontSize: 12, textDecorationLine: 'underline' },
  tabs:           { flexDirection: 'row', backgroundColor: '#fff', borderBottomWidth: 1, borderColor: '#ddd' },
  tab:            { flex: 1, alignItems: 'center', paddingVertical: 10 },
  tabActive:      { borderBottomWidth: 2, borderBottomColor: '#2980b9' },
  tabText:        { fontSize: 12, color: '#7f8c8d' },
  tabTextActive:  { color: '#2980b9', fontWeight: '700' },
  panel:          { flex: 1, padding: 12 },
  row:            { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 10 },
  btn:            { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 6, marginRight: 6, marginBottom: 6 },
  btnText:        { color: '#fff', fontWeight: '600', fontSize: 13 },
  sectionLabel:   { fontSize: 13, fontWeight: '600', color: '#555', marginVertical: 8 },
  listItem:       { backgroundColor: '#fff', padding: 12, borderRadius: 8, marginBottom: 6, elevation: 1 },
  listItemTitle:  { fontSize: 14, fontWeight: '600', color: '#2c3e50' },
  listItemSub:    { fontSize: 12, color: '#7f8c8d', marginTop: 2 },
  input:          { borderWidth: 1, borderColor: '#ccc', borderRadius: 6, padding: 8, backgroundColor: '#fff', fontSize: 13 },
  fieldWrap:      { marginBottom: 10 },
  fieldLabel:     { fontSize: 12, color: '#555', marginBottom: 4 },
  chip:           { paddingHorizontal: 10, paddingVertical: 6, borderRadius: 14, borderWidth: 1, borderColor: '#ccc', backgroundColor: '#fff' },
  chipActive:     { backgroundColor: '#2980b9', borderColor: '#2980b9' },
  chipText:       { fontSize: 12, color: '#555' },
  chipTextActive: { color: '#fff', fontWeight: '600' },
  divider:        { height: 1, backgroundColor: '#ddd', marginVertical: 14 },
});
