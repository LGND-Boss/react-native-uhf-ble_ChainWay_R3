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
  StatusBar,
  ActivityIndicator,
  Platform,
} from 'react-native';
import {
  scanBLE,
  stopScanBLE,
  connectAddress,
  disconnect,
  getConnectionStatus,
  startInventory,
  startInventoryWithFilter,
  stopInventory,
  clearData,
  readTag,
  writeTag,
  lockTag,
  killTag,
  setPower,
  getPower,
  UhfBleEmitter,
  SCAN_BLE_EVENT,
  READ_RFID_EVENT,
  CONNECTION_STATUS_EVENT,
  type BLEDevice,
  type RFIDTag,
} from 'react-native-uhf-ble';

// ─── Theme ────────────────────────────────────────────────────────────────────

const C = {
  primary:   '#1a73e8',
  success:   '#1e8c45',
  warning:   '#e37400',
  danger:    '#d93025',
  purple:    '#7b2d9e',
  bg:        '#f1f3f4',
  card:      '#ffffff',
  border:    '#dadce0',
  text:      '#202124',
  subtext:   '#5f6368',
};

type Tab = 'scan' | 'inventory' | 'readwrite' | 'operations';

// ─── App ──────────────────────────────────────────────────────────────────────

export default function App() {
  const [tab, setTab]               = useState<Tab>('scan');
  const [connStatus, setConnStatus] = useState<'disconnected' | 'connecting' | 'connected'>('disconnected');
  const [connDevice, setConnDevice] = useState('');
  const [bleDevices, setBleDevices] = useState<BLEDevice[]>([]);
  const [isScanning, setIsScanning] = useState(false);
  const [rfidTags, setRfidTags]     = useState<RFIDTag[]>([]);
  const [isInventorying, setInventory] = useState(false);
  const pendingTags = useRef<RFIDTag[]>([]);
  const flushTimer  = useRef<ReturnType<typeof setTimeout> | null>(null);

  // R/W
  const [rwBank, setRwBank] = useState('1');
  const [rwPtr,  setRwPtr]  = useState('2');
  const [rwLen,  setRwLen]  = useState('6');
  const [rwPwd,  setRwPwd]  = useState('00000000');
  const [rwData, setRwData] = useState('');
  const [rwBusy, setRwBusy] = useState(false);

  // Operations
  const [opPwd,       setOpPwd]      = useState('00000000');
  const [lockCode,    setLockCode]   = useState('000000');
  const [power,       setPowerVal]   = useState('20');
  const [devicePower, setDevicePower] = useState<number | null>(null);
  const [opBusy,      setOpBusy]     = useState(false);

  // EPC filter
  const [filterEpc, setFilterEpc] = useState('');

  useEffect(() => {
    const s1 = UhfBleEmitter.addListener(SCAN_BLE_EVENT, (d: BLEDevice) => {
      setBleDevices(prev =>
        prev.find(x => x.address_device === d.address_device)
          ? prev
          : [...prev, d].sort((a, b) => parseInt(b.rssi) - parseInt(a.rssi))
      );
    });
    const s2 = UhfBleEmitter.addListener(READ_RFID_EVENT, (tag: RFIDTag) => {
      pendingTags.current.push(tag);
      if (!flushTimer.current) {
        flushTimer.current = setTimeout(() => {
          flushTimer.current = null;
          const batch = pendingTags.current.splice(0);
          if (!batch.length) return;
          setRfidTags(prev => {
            const fresh = batch.filter(t => !prev.find(p => p.rfid_tag === t.rfid_tag));
            return fresh.length ? [...prev, ...fresh] : prev;
          });
        }, 0);
      }
    });
    const s3 = UhfBleEmitter.addListener(CONNECTION_STATUS_EVENT, (e: any) => {
      setConnStatus(e.status);
      if (e.device) setConnDevice(e.device);
      else if (e.status === 'disconnected') { setConnDevice(''); setInventory(false); }
    });
    return () => { s1.remove(); s2.remove(); s3.remove(); };
  }, []);

  const handleConnect = useCallback(async (addr: string) => {
    try {
      stopScanBLE();
      setIsScanning(false);
      setConnStatus('connecting');
      const name = await connectAddress(addr);
      setConnDevice(name);
    } catch (e: any) {
      setConnStatus('disconnected');
      Alert.alert('Connect Failed', e.message);
    }
  }, []);

  const handleScan = () => {
    setBleDevices([]);
    setIsScanning(true);
    scanBLE();
  };
  const handleStopScan = () => {
    setIsScanning(false);
    stopScanBLE();
  };

  const handleStartInventory = () => {
    setRfidTags([]);
    pendingTags.current = [];
    if (flushTimer.current) { clearTimeout(flushTimer.current); flushTimer.current = null; }
    setInventory(true);
    filterEpc ? startInventoryWithFilter(filterEpc) : startInventory();
  };
  const handleStopInventory = () => {
    setInventory(false);
    stopInventory();
  };
  const handleClearTags = async () => {
    await clearData();
    setRfidTags([]);
  };

  const handleRead = useCallback(async () => {
    setRwBusy(true);
    try {
      const data = await readTag({
        bank: parseInt(rwBank), ptr: parseInt(rwPtr),
        len: parseInt(rwLen), password: rwPwd,
      });
      setRwData(data);
      Alert.alert('Read OK', data);
    } catch (e: any) {
      Alert.alert('Read Failed', e.message);
    } finally { setRwBusy(false); }
  }, [rwBank, rwPtr, rwLen, rwPwd]);

  const handleWrite = useCallback(async () => {
    if (!rwData.trim()) { Alert.alert('Error', 'Enter hex data to write'); return; }
    setRwBusy(true);
    try {
      await writeTag({
        bank: parseInt(rwBank), ptr: parseInt(rwPtr),
        len: parseInt(rwLen), data: rwData, password: rwPwd,
      });
      Alert.alert('Write OK', 'Tag written successfully.');
    } catch (e: any) {
      Alert.alert('Write Failed', e.message);
    } finally { setRwBusy(false); }
  }, [rwBank, rwPtr, rwLen, rwData, rwPwd]);

  const handleLock = useCallback(async () => {
    setOpBusy(true);
    try {
      await lockTag({ password: opPwd, lockCode });
      Alert.alert('Lock OK', 'Tag locked successfully.');
    } catch (e: any) {
      Alert.alert('Lock Failed', e.message);
    } finally { setOpBusy(false); }
  }, [opPwd, lockCode]);

  const handleKill = useCallback(async () => {
    Alert.alert('Kill Tag', 'This permanently disables the tag. Continue?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Kill', style: 'destructive', onPress: async () => {
        setOpBusy(true);
        try {
          await killTag({ password: opPwd });
          Alert.alert('Kill OK', 'Tag has been permanently disabled.');
        } catch (e: any) {
          Alert.alert('Kill Failed', e.message);
        } finally { setOpBusy(false); }
      }},
    ]);
  }, [opPwd]);

  const handleSetPower = async () => {
    setOpBusy(true);
    try {
      await setPower(parseInt(power));
      Alert.alert('Power Set', `Output power set to ${power} dBm.`);
    } catch (e: any) {
      Alert.alert('Error', e.message);
    } finally { setOpBusy(false); }
  };

  const handleGetPower = async () => {
    setOpBusy(true);
    try {
      const p = await getPower();
      setDevicePower(p);
    } catch (e: any) {
      Alert.alert('Error', e.message);
    } finally { setOpBusy(false); }
  };

  const statusColor = connStatus === 'connected' ? C.success
    : connStatus === 'connecting' ? C.warning : C.danger;

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar backgroundColor={statusColor} barStyle="light-content" />

      {/* ── Header ── */}
      <View style={[styles.header, { backgroundColor: statusColor }]}>
        <View>
          <Text style={styles.headerTitle}>UHF BLE Reader</Text>
          <View style={styles.statusRow}>
            <View style={[styles.dot, { backgroundColor: connStatus === 'connected' ? '#a8e6bf' : '#fff' }]} />
            <Text style={styles.headerSub}>
              {connStatus === 'connected'
                ? connDevice || 'Connected'
                : connStatus === 'connecting'
                ? 'Connecting\u2026'
                : 'Not connected'}
            </Text>
          </View>
        </View>
        {connStatus === 'connected' && (
          <TouchableOpacity style={styles.disconnectBtn} onPress={disconnect}>
            <Text style={styles.disconnectTxt}>Disconnect</Text>
          </TouchableOpacity>
        )}
        {connStatus === 'connecting' && (
          <ActivityIndicator color="#fff" style={{ marginRight: 4 }} />
        )}
      </View>

      {/* ── Tab bar ── */}
      <View style={styles.tabBar}>
        {(['scan', 'inventory', 'readwrite', 'operations'] as Tab[]).map(t => (
          <TouchableOpacity key={t} style={[styles.tab, tab === t && styles.tabActive]}
            onPress={() => setTab(t)}>
            <Text style={[styles.tabLabel, tab === t && { color: C.primary, fontWeight: '700' }]}>
              {t === 'readwrite' ? 'R/W' : t[0].toUpperCase() + t.slice(1)}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      {/* ── SCAN ── */}
      {tab === 'scan' && (
        <View style={styles.panel}>
          <View style={styles.actionRow}>
            {!isScanning
              ? <PrimaryBtn title="Scan BLE" color={C.primary} onPress={handleScan} />
              : <PrimaryBtn title="Stop Scan" color={C.subtext} onPress={handleStopScan} />
            }
            {isScanning && <ActivityIndicator color={C.primary} style={{ marginLeft: 12 }} />}
          </View>
          <SectionHeader
            title={`Devices found: ${bleDevices.length}`}
            hint="Tap a device to connect"
          />
          <FlatList
            data={bleDevices}
            keyExtractor={i => i.address_device}
            contentContainerStyle={{ paddingBottom: 16 }}
            ListEmptyComponent={
              <EmptyState
                message={isScanning ? 'Scanning for devices\u2026' : 'Tap "Scan BLE" to discover devices.'}
              />
            }
            renderItem={({ item }) => (
              <TouchableOpacity
                style={[styles.card, connStatus === 'connected' && connDevice === item.name_device && styles.cardActive]}
                onPress={() => handleConnect(item.address_device)}
                activeOpacity={0.7}
              >
                <View style={styles.cardRow}>
                  <View style={styles.cardIcon}>
                    <Text style={styles.cardIconTxt}>BT</Text>
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.cardTitle}>{item.name_device || 'Unknown Device'}</Text>
                    <Text style={styles.cardSub} numberOfLines={1}>{item.address_device}</Text>
                  </View>
                  <View style={[styles.rssiBadge, { backgroundColor: rssiColor(item.rssi) }]}>
                    <Text style={styles.rssiBadgeTxt}>{item.rssi} dBm</Text>
                  </View>
                </View>
              </TouchableOpacity>
            )}
          />
        </View>
      )}

      {/* ── INVENTORY ── */}
      {tab === 'inventory' && (
        <View style={styles.panel}>
          <TextInput
            style={styles.input}
            placeholder="Filter by EPC (optional)"
            placeholderTextColor={C.subtext}
            value={filterEpc}
            onChangeText={setFilterEpc}
            autoCapitalize="characters"
            autoCorrect={false}
          />
          <View style={styles.actionRow}>
            {!isInventorying
              ? <PrimaryBtn title="Start Inventory" color={C.success} onPress={handleStartInventory} />
              : <PrimaryBtn title="Stop" color={C.danger} onPress={handleStopInventory} />
            }
            <OutlineBtn title="Clear" onPress={handleClearTags} />
            {isInventorying && <ActivityIndicator color={C.success} style={{ marginLeft: 8 }} />}
          </View>
          <SectionHeader
            title={`Tags: ${rfidTags.length}`}
            hint="Each EPC counted once per session"
          />
          <FlatList
            data={rfidTags}
            keyExtractor={(_, i) => String(i)}
            contentContainerStyle={{ paddingBottom: 16 }}
            ListEmptyComponent={
              <EmptyState
                message={isInventorying ? 'Scanning for tags\u2026' : 'Press "Start Inventory" to read tags.'}
              />
            }
            renderItem={({ item, index }) => (
              <View style={styles.card}>
                <View style={styles.cardRow}>
                  <View style={[styles.cardIndex, { backgroundColor: C.primary }]}>
                    <Text style={styles.cardIndexTxt}>{index + 1}</Text>
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={styles.cardTitle}>{item.rfid_tag}</Text>
                    {item.rssi ? (
                      <Text style={styles.cardSub}>RSSI {item.rssi} dBm</Text>
                    ) : null}
                  </View>
                </View>
              </View>
            )}
          />
        </View>
      )}

      {/* ── READ / WRITE ── */}
      {tab === 'readwrite' && (
        <ScrollView style={styles.panel} keyboardShouldPersistTaps="handled">
          <FieldLabel>Memory Bank</FieldLabel>
          <View style={styles.chipRow}>
            {([['RSVD', '0'], ['EPC', '1'], ['TID', '2'], ['USER', '3']] as const).map(([l, v]) => (
              <TouchableOpacity key={v} style={[styles.chip, rwBank === v && styles.chipActive]}
                onPress={() => setRwBank(v)}>
                <Text style={[styles.chipTxt, rwBank === v && styles.chipTxtActive]}>{l}</Text>
              </TouchableOpacity>
            ))}
          </View>
          <InputField label="Address (word ptr)" value={rwPtr} onChange={setRwPtr} numeric />
          <InputField label="Length (words)" value={rwLen} onChange={setRwLen} numeric />
          <InputField label="Access Password (hex)" value={rwPwd} onChange={setRwPwd} mono />
          <InputField label="Data (hex)" value={rwData} onChange={setRwData} mono
            hint="Leave empty to read; fill to write" />
          <View style={styles.actionRow}>
            <PrimaryBtn title={rwBusy ? '\u2026' : 'Read Tag'} color={C.primary}
              onPress={handleRead} disabled={rwBusy} />
            <PrimaryBtn title={rwBusy ? '\u2026' : 'Write Tag'} color={C.warning}
              onPress={handleWrite} disabled={rwBusy || !rwData.trim()} />
          </View>
        </ScrollView>
      )}

      {/* ── OPERATIONS ── */}
      {tab === 'operations' && (
        <ScrollView style={styles.panel} keyboardShouldPersistTaps="handled">
          <InputField label="Access / Kill Password (hex)" value={opPwd} onChange={setOpPwd} mono />
          <InputField label="Lock Code (3 bytes hex)" value={lockCode} onChange={setLockCode} mono
            hint="Encodes per-bank lock bits. 000000 = no change." />
          <View style={styles.actionRow}>
            <PrimaryBtn title={opBusy ? '\u2026' : 'Lock Tag'} color={C.purple}
              onPress={handleLock} disabled={opBusy} />
            <PrimaryBtn title={opBusy ? '\u2026' : 'Kill Tag'} color={C.danger}
              onPress={handleKill} disabled={opBusy} />
          </View>

          <Divider />

          <InputField label="RF Power (dBm, 5\u201330)" value={power} onChange={setPowerVal} numeric />
          <View style={styles.actionRow}>
            <PrimaryBtn title={opBusy ? '\u2026' : `Set Power (${power} dBm)`} color={C.success}
              onPress={handleSetPower} disabled={opBusy} />
            <OutlineBtn title="Read from Device" onPress={handleGetPower} />
          </View>
          {devicePower !== null && (
            <View style={styles.powerReadout}>
              <Text style={styles.powerReadoutLabel}>Current device power</Text>
              <Text style={styles.powerReadoutValue}>{devicePower} dBm</Text>
            </View>
          )}

          <View style={styles.warningBox}>
            <Text style={styles.warningTitle}>Kill is irreversible</Text>
            <Text style={styles.warningBody}>
              Killing a tag permanently disables it. Ensure you have the correct kill password
              before proceeding.
            </Text>
          </View>
        </ScrollView>
      )}
    </SafeAreaView>
  );
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function rssiColor(rssi: string): string {
  const v = parseInt(rssi);
  if (v >= -60) return '#1e8c45';
  if (v >= -75) return '#e37400';
  return '#d93025';
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function PrimaryBtn({ title, color, onPress, disabled }: {
  title: string; color: string; onPress: () => void; disabled?: boolean;
}) {
  return (
    <TouchableOpacity
      style={[styles.btn, { backgroundColor: disabled ? '#b0b0b0' : color }]}
      onPress={onPress}
      disabled={disabled}
      activeOpacity={0.8}
    >
      <Text style={styles.btnTxt}>{title}</Text>
    </TouchableOpacity>
  );
}

function OutlineBtn({ title, onPress }: { title: string; onPress: () => void }) {
  return (
    <TouchableOpacity style={styles.outlineBtn} onPress={onPress} activeOpacity={0.7}>
      <Text style={styles.outlineBtnTxt}>{title}</Text>
    </TouchableOpacity>
  );
}

function SectionHeader({ title, hint }: { title: string; hint?: string }) {
  return (
    <View style={styles.sectionHeader}>
      <Text style={styles.sectionTitle}>{title}</Text>
      {hint ? <Text style={styles.sectionHint}>{hint}</Text> : null}
    </View>
  );
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return <Text style={styles.fieldLabel}>{children}</Text>;
}

function InputField({ label, value, onChange, numeric, mono, hint }: {
  label: string; value: string; onChange: (v: string) => void;
  numeric?: boolean; mono?: boolean; hint?: string;
}) {
  return (
    <View style={{ marginBottom: 14 }}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput
        style={[styles.textInput, mono && styles.inputMono]}
        value={value}
        onChangeText={onChange}
        keyboardType={numeric ? 'numeric' : 'default'}
        autoCapitalize="characters"
        autoCorrect={false}
        placeholderTextColor={C.subtext}
      />
      {hint ? <Text style={styles.inputHint}>{hint}</Text> : null}
    </View>
  );
}

function EmptyState({ message }: { message: string }) {
  return (
    <View style={styles.emptyState}>
      <Text style={styles.emptyStateTxt}>{message}</Text>
    </View>
  );
}

function Divider() {
  return <View style={styles.divider} />;
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  root:             { flex: 1, backgroundColor: C.bg },

  // Header
  header:           { flexDirection: 'row', justifyContent: 'space-between',
                      alignItems: 'center', paddingHorizontal: 16, paddingVertical: 12 },
  headerTitle:      { color: '#fff', fontWeight: '700', fontSize: 16, letterSpacing: 0.3 },
  statusRow:        { flexDirection: 'row', alignItems: 'center', marginTop: 2 },
  dot:              { width: 7, height: 7, borderRadius: 4, marginRight: 5 },
  headerSub:        { color: 'rgba(255,255,255,0.88)', fontSize: 12 },
  disconnectBtn:    { paddingHorizontal: 12, paddingVertical: 6,
                      borderRadius: 6, borderWidth: 1, borderColor: 'rgba(255,255,255,0.6)' },
  disconnectTxt:    { color: '#fff', fontSize: 12, fontWeight: '600' },

  // Tab bar
  tabBar:           { flexDirection: 'row', backgroundColor: C.card,
                      borderBottomWidth: 1, borderColor: C.border },
  tab:              { flex: 1, alignItems: 'center', paddingVertical: 11 },
  tabActive:        { borderBottomWidth: 2, borderBottomColor: C.primary },
  tabLabel:         { fontSize: 12, color: C.subtext },

  // Panel
  panel:            { flex: 1, padding: 12 },
  actionRow:        { flexDirection: 'row', alignItems: 'center', flexWrap: 'wrap',
                      marginBottom: 12, gap: 8 },

  // Buttons
  btn:              { paddingHorizontal: 18, paddingVertical: 10, borderRadius: 8 },
  btnTxt:           { color: '#fff', fontWeight: '700', fontSize: 13 },
  outlineBtn:       { paddingHorizontal: 14, paddingVertical: 9, borderRadius: 8,
                      borderWidth: 1.5, borderColor: C.border, backgroundColor: C.card },
  outlineBtnTxt:    { color: C.text, fontWeight: '600', fontSize: 13 },

  // Section header
  sectionHeader:    { flexDirection: 'row', alignItems: 'baseline',
                      justifyContent: 'space-between', marginBottom: 8 },
  sectionTitle:     { fontSize: 13, fontWeight: '700', color: C.text },
  sectionHint:      { fontSize: 11, color: C.subtext },

  // Cards
  card:             { backgroundColor: C.card, borderRadius: 10, padding: 12,
                      marginBottom: 8, borderWidth: 1, borderColor: C.border, elevation: 2 },
  cardActive:       { borderColor: C.primary, borderWidth: 1.5 },
  cardRow:          { flexDirection: 'row', alignItems: 'center', gap: 10 },
  cardIcon:         { width: 38, height: 38, borderRadius: 10, backgroundColor: C.primary + '18',
                      alignItems: 'center', justifyContent: 'center' },
  cardIconTxt:      { fontSize: 11, fontWeight: '800', color: C.primary },
  cardIndex:        { width: 28, height: 28, borderRadius: 8,
                      alignItems: 'center', justifyContent: 'center' },
  cardIndexTxt:     { fontSize: 12, fontWeight: '700', color: '#fff' },
  cardTitle:        { fontSize: 14, fontWeight: '600', color: C.text },
  cardSub:          { fontSize: 11, color: C.subtext, marginTop: 2 },

  // RSSI badge
  rssiBadge:        { paddingHorizontal: 7, paddingVertical: 3, borderRadius: 6 },
  rssiBadgeTxt:     { fontSize: 11, fontWeight: '700', color: '#fff' },

  // Fields / inputs
  fieldLabel:       { fontSize: 12, fontWeight: '600', color: C.subtext, marginBottom: 5 },
  textInput:        { borderWidth: 1.5, borderColor: C.border, borderRadius: 8,
                      paddingHorizontal: 12, paddingVertical: 9,
                      backgroundColor: C.card, fontSize: 13, color: C.text },
  inputMono:        { fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
  inputHint:        { fontSize: 11, color: C.subtext, marginTop: 4, marginLeft: 2 },

  // Chip row (memory bank selector)
  chipRow:          { flexDirection: 'row', marginBottom: 14, gap: 8 },
  chip:             { paddingHorizontal: 14, paddingVertical: 7, borderRadius: 20,
                      borderWidth: 1.5, borderColor: C.border, backgroundColor: C.card },
  chipActive:       { backgroundColor: C.primary, borderColor: C.primary },
  chipTxt:          { fontSize: 12, fontWeight: '600', color: C.subtext },
  chipTxtActive:    { color: '#fff' },

  // Misc
  divider:          { height: 1, backgroundColor: C.border, marginVertical: 18 },
  emptyState:       { alignItems: 'center', paddingVertical: 48 },
  emptyStateTxt:    { fontSize: 13, color: C.subtext, textAlign: 'center', lineHeight: 20 },
  warningBox:       { backgroundColor: '#fce8e6', borderRadius: 10, padding: 14, marginTop: 20,
                      borderLeftWidth: 3, borderLeftColor: C.danger },
  warningTitle:     { fontSize: 13, fontWeight: '700', color: C.danger, marginBottom: 4 },
  warningBody:      { fontSize: 12, color: '#5f2120', lineHeight: 18 },
  powerReadout:     { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                      backgroundColor: '#1e8c4512', borderRadius: 8, padding: 12,
                      borderWidth: 1, borderColor: '#1e8c4540', marginTop: 4 },
  powerReadoutLabel: { fontSize: 12, color: C.success, fontWeight: '600' },
  powerReadoutValue: { fontSize: 20, fontWeight: '800', color: C.success },
});
