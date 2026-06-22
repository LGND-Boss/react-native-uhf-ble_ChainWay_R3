/**
 * UHF BLE App
 * Works on both Android and iOS.
 * Native module (UhfBle) handles BLE + RFID communication.
 */
import React, { useEffect, useState, useCallback, useRef } from 'react';
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
  NativeModules,
  NativeEventEmitter,
  Platform,
} from 'react-native';

const UhfBleNative = NativeModules.UhfBle;
const emitter = new NativeEventEmitter(UhfBleNative);

const SCAN_BLE_EVENT          = 'ScanBLEListener';
const READ_RFID_EVENT         = 'ReadRFIDListener';
const CONNECTION_STATUS_EVENT = 'ConnectionStatusListener';

type Tab = 'scan' | 'inventory' | 'readwrite' | 'operations';

export default function App() {
  const [tab, setTab]                       = useState<Tab>('scan');
  const [connectionStatus, setStatus]       = useState('disconnected');
  const [connectedDevice, setDevice]        = useState('');
  const [bleDevices, setBleDevices]         = useState<any[]>([]);
  const [rfidTags, setRfidTags]             = useState<any[]>([]);
  // Coalesce tag events into one state update per tick (batched flush) and dedup
  // EPCs via a Set (O(1)). The old per-tag setState + prev.find scan re-rendered
  // and rescanned the whole list for every tag — O(n²) and janky past a few hundred.
  const pendingTags = useRef<any[]>([]);
  const flushTimer  = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seenTags    = useRef<Set<string>>(new Set());

  // Read/Write
  const [rwBank, setRwBank]   = useState('1');
  const [rwPtr, setRwPtr]     = useState('2');
  const [rwLen, setRwLen]     = useState('6');
  const [rwPwd, setRwPwd]     = useState('00000000');
  const [rwData, setRwData]   = useState('');

  // Operations
  const [opPwd, setOpPwd]         = useState('00000000');
  const [lockCode, setLockCode]   = useState('000000');
  const [powerVal, setPowerVal]   = useState('20');
  const [filterEpc, setFilterEpc] = useState('');

  useEffect(() => {
    const s1 = emitter.addListener(SCAN_BLE_EVENT, (d: any) => {
      setBleDevices(prev => {
        if (prev.find(x => x.address_device === d.address_device)) return prev;
        return [...prev, d].sort((a, b) => parseInt(b.rssi) - parseInt(a.rssi));
      });
    });
    const s2 = emitter.addListener(READ_RFID_EVENT, (tag: any) => {
      // Buffer tags and flush once per tick — one re-render per batch, not per tag.
      pendingTags.current.push(tag);
      if (!flushTimer.current) {
        flushTimer.current = setTimeout(() => {
          flushTimer.current = null;
          const batch = pendingTags.current.splice(0);
          if (!batch.length) return;
          const fresh: any[] = [];
          for (const t of batch) {
            if (!seenTags.current.has(t.rfid_tag)) {
              seenTags.current.add(t.rfid_tag);
              fresh.push(t);
            }
          }
          if (!fresh.length) return;
          setRfidTags(prev => [...prev, ...fresh]);
        }, 0);
      }
    });
    const s3 = emitter.addListener(CONNECTION_STATUS_EVENT, (e: any) => {
      setStatus(e.status);
      if (e.device) setDevice(e.device);
      else if (e.status === 'disconnected') setDevice('');
    });
    return () => { s1.remove(); s2.remove(); s3.remove(); };
  }, []);

  const handleConnect = useCallback(async (addr: string) => {
    try {
      UhfBleNative.stopScanBLE();
      setStatus('connecting');
      const result = await UhfBleNative.connectAddress(addr);
      setDevice(result);
    } catch (e: any) { Alert.alert('Connect Error', e.message); }
  }, []);

  const handleRead = useCallback(async () => {
    try {
      const data = await UhfBleNative.readTag({
        bank: parseInt(rwBank), ptr: parseInt(rwPtr),
        len: parseInt(rwLen), password: rwPwd,
      });
      setRwData(data);
      Alert.alert('Read OK', data);
    } catch (e: any) { Alert.alert('Read Failed', e.message); }
  }, [rwBank, rwPtr, rwLen, rwPwd]);

  const handleWrite = useCallback(async () => {
    if (!rwData) { Alert.alert('Error', 'Enter hex data to write'); return; }
    try {
      await UhfBleNative.writeTag({
        bank: parseInt(rwBank), ptr: parseInt(rwPtr),
        len: parseInt(rwLen), data: rwData, password: rwPwd,
      });
      Alert.alert('Write OK');
    } catch (e: any) { Alert.alert('Write Failed', e.message); }
  }, [rwBank, rwPtr, rwLen, rwData, rwPwd]);

  const handleLock = useCallback(async () => {
    try {
      await UhfBleNative.lockTag({ password: opPwd, lockCode });
      Alert.alert('Lock OK');
    } catch (e: any) { Alert.alert('Lock Failed', e.message); }
  }, [opPwd, lockCode]);

  const handleKill = useCallback(async () => {
    Alert.alert('Kill Tag', 'This permanently disables the tag. Continue?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Kill', style: 'destructive', onPress: async () => {
        try {
          await UhfBleNative.killTag({ password: opPwd });
          Alert.alert('Kill OK');
        } catch (e: any) { Alert.alert('Kill Failed', e.message); }
      }},
    ]);
  }, [opPwd]);

  const statusColor = connectionStatus === 'connected' ? '#27ae60'
    : connectionStatus === 'connecting' ? '#f39c12' : '#e74c3c';

  return (
    <SafeAreaView style={styles.root}>
      {/* Connection banner */}
      <View style={[styles.banner, { backgroundColor: statusColor }]}>
        <Text style={styles.bannerText}>
          {connectionStatus.toUpperCase()}{connectedDevice ? ` — ${connectedDevice}` : ''}
        </Text>
        {connectionStatus === 'connected' && (
          <TouchableOpacity onPress={() => UhfBleNative.disconnect()}>
            <Text style={styles.disconnectText}>Disconnect</Text>
          </TouchableOpacity>
        )}
      </View>

      {/* Tab bar */}
      <View style={styles.tabBar}>
        {(['scan', 'inventory', 'readwrite', 'operations'] as Tab[]).map(t => (
          <TouchableOpacity key={t} style={[styles.tab, tab === t && styles.tabActive]}
            onPress={() => setTab(t)}>
            <Text style={[styles.tabLabel, tab === t && styles.tabLabelActive]}>
              {t === 'readwrite' ? 'R/W' : t[0].toUpperCase() + t.slice(1)}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* ── SCAN ── */}
      {tab === 'scan' && (
        <View style={styles.panel}>
          <Row>
            <Btn color="#2980b9" title="Scan BLE"
              onPress={() => { setBleDevices([]); UhfBleNative.scanBLE(); }} />
            <Btn color="#7f8c8d" title="Stop"
              onPress={() => UhfBleNative.stopScanBLE()} />
          </Row>
          <Label>Devices ({bleDevices.length}) — tap to connect</Label>
          <FlatList data={bleDevices} keyExtractor={i => i.address_device}
            renderItem={({ item }) => (
              <TouchableOpacity style={styles.card} onPress={() => handleConnect(item.address_device)}>
                <Text style={styles.cardTitle}>{item.name_device || 'Unknown'}</Text>
                <Text style={styles.cardSub}>{item.address_device} · RSSI {item.rssi}</Text>
              </TouchableOpacity>
            )} />
        </View>
      )}

      {/* ── INVENTORY ── */}
      {tab === 'inventory' && (
        <View style={styles.panel}>
          <TextInput style={styles.input} placeholder="Filter by EPC (optional)"
            value={filterEpc} onChangeText={setFilterEpc} autoCapitalize="characters" />
          <Row>
            <Btn color="#27ae60" title="Start"
              onPress={() => {
                setRfidTags([]);
                pendingTags.current = [];
                seenTags.current.clear();
                filterEpc
                  ? UhfBleNative.startInventoryWithFilter(filterEpc)
                  : UhfBleNative.startInventory();
              }} />
            <Btn color="#e74c3c" title="Stop"  onPress={() => UhfBleNative.stopInventory()} />
            <Btn color="#7f8c8d" title="Clear"
              onPress={() => UhfBleNative.clearData().then(() => {
                setRfidTags([]);
                pendingTags.current = [];
                seenTags.current.clear();
              })} />
          </Row>
          <Label>Tags read: {rfidTags.length} (each EPC counted once)</Label>
          <FlatList data={rfidTags} keyExtractor={(_, i) => String(i)}
            renderItem={({ item, index }) => (
              <View style={styles.card}>
                <Text style={styles.cardTitle}>#{index + 1}  {item.rfid_tag}</Text>
                {item.rssi ? <Text style={styles.cardSub}>RSSI {item.rssi}</Text> : null}
              </View>
            )} />
        </View>
      )}

      {/* ── READ / WRITE ── */}
      {tab === 'readwrite' && (
        <ScrollView style={styles.panel}>
          <Label>Memory Bank</Label>
          <View style={styles.chipRow}>
            {[['RESERVED','0'],['EPC','1'],['TID','2'],['USER','3']].map(([l, v]) => (
              <TouchableOpacity key={v} style={[styles.chip, rwBank === v && styles.chipOn]}
                onPress={() => setRwBank(v)}>
                <Text style={[styles.chipTxt, rwBank === v && styles.chipTxtOn]}>{l}</Text>
              </TouchableOpacity>
            ))}
          </View>
          <Field label="Address (ptr)" value={rwPtr} onChange={setRwPtr} numeric />
          <Field label="Length (words)" value={rwLen} onChange={setRwLen} numeric />
          <Field label="Access Password" value={rwPwd} onChange={setRwPwd} />
          <Field label="Data (hex)" value={rwData} onChange={setRwData} />
          <Row>
            <Btn color="#2980b9" title="Read Tag"  onPress={handleRead} />
            <Btn color="#e67e22" title="Write Tag" onPress={handleWrite} />
          </Row>
        </ScrollView>
      )}

      {/* ── OPERATIONS ── */}
      {tab === 'operations' && (
        <ScrollView style={styles.panel}>
          <Field label="Access / Kill Password" value={opPwd} onChange={setOpPwd} />
          <Field label="Lock Code (3 bytes hex)" value={lockCode} onChange={setLockCode} />
          <Row>
            <Btn color="#8e44ad" title="Lock Tag" onPress={handleLock} />
            <Btn color="#c0392b" title="Kill Tag" onPress={handleKill} />
          </Row>
          <View style={styles.divider} />
          <Field label="Power (dBm, 5–30)" value={powerVal} onChange={setPowerVal} numeric />
          <Btn color="#16a085" title="Set Power"
            onPress={async () => {
              try {
                await UhfBleNative.setPower(parseInt(powerVal));
                Alert.alert('Power set to ' + powerVal + ' dBm');
              } catch (e: any) { Alert.alert('Error', e.message); }
            }} />
        </ScrollView>
      )}
    </SafeAreaView>
  );
}

function Btn({ title, color, onPress }: any) {
  return (
    <TouchableOpacity style={[styles.btn, { backgroundColor: color }]} onPress={onPress}>
      <Text style={styles.btnTxt}>{title}</Text>
    </TouchableOpacity>
  );
}
function Row({ children }: any) {
  return <View style={styles.row}>{children}</View>;
}
function Label({ children }: any) {
  return <Text style={styles.label}>{children}</Text>;
}
function Field({ label, value, onChange, numeric }: any) {
  return (
    <View style={{ marginBottom: 10 }}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput style={styles.input} value={value} onChangeText={onChange}
        keyboardType={numeric ? 'numeric' : 'default'} autoCapitalize="characters" />
    </View>
  );
}

const styles = StyleSheet.create({
  root:          { flex: 1, backgroundColor: '#f0f2f5' },
  banner:        { flexDirection: 'row', justifyContent: 'space-between',
                   alignItems: 'center', padding: 10 },
  bannerText:    { color: '#fff', fontWeight: '700', fontSize: 13 },
  disconnectText:{ color: '#fff', fontSize: 12, textDecorationLine: 'underline' },
  tabBar:        { flexDirection: 'row', backgroundColor: '#fff',
                   borderBottomWidth: 1, borderColor: '#ddd' },
  tab:           { flex: 1, alignItems: 'center', paddingVertical: 10 },
  tabActive:     { borderBottomWidth: 2, borderBottomColor: '#2980b9' },
  tabLabel:      { fontSize: 12, color: '#7f8c8d' },
  tabLabelActive:{ color: '#2980b9', fontWeight: '700' },
  panel:         { flex: 1, padding: 12 },
  row:           { flexDirection: 'row', flexWrap: 'wrap', marginBottom: 10 },
  btn:           { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 6,
                   marginRight: 8, marginBottom: 6 },
  btnTxt:        { color: '#fff', fontWeight: '600', fontSize: 13 },
  label:         { fontSize: 13, fontWeight: '600', color: '#555', marginVertical: 8 },
  fieldLabel:    { fontSize: 12, color: '#555', marginBottom: 4 },
  card:          { backgroundColor: '#fff', padding: 12, borderRadius: 8,
                   marginBottom: 6, elevation: 1, shadowColor: '#000',
                   shadowOpacity: 0.06, shadowRadius: 4, shadowOffset: { width:0, height:2 } },
  cardTitle:     { fontSize: 14, fontWeight: '600', color: '#2c3e50' },
  cardSub:       { fontSize: 12, color: '#7f8c8d', marginTop: 2 },
  input:         { borderWidth: 1, borderColor: '#ccc', borderRadius: 6,
                   padding: 8, backgroundColor: '#fff', fontSize: 13 },
  chipRow:       { flexDirection: 'row', marginBottom: 10 },
  chip:          { paddingHorizontal: 10, paddingVertical: 6, borderRadius: 14,
                   borderWidth: 1, borderColor: '#ccc', backgroundColor: '#fff',
                   marginRight: 6 },
  chipOn:        { backgroundColor: '#2980b9', borderColor: '#2980b9' },
  chipTxt:       { fontSize: 12, color: '#555' },
  chipTxtOn:     { color: '#fff', fontWeight: '600' },
  divider:       { height: 1, backgroundColor: '#ddd', marginVertical: 14 },
});
