#import "UhfBle.h"

// Nordic UART Service UUIDs
#define kServiceUUID    @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define kWriteUUID      @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define kNotifyUUID     @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// Event names
#define EVENT_SCAN_BLE          @"ScanBLEListener"
#define EVENT_READ_RFID         @"ReadRFIDListener"
#define EVENT_CONNECTION_STATUS @"ConnectionStatusListener"

// A5 5A command bytes (Chainway official protocol)
// Frame format: A5 5A [LEN_H][LEN_L][CMD][data...][XOR_CRC][0D][0A]
// LEN = total frame size = 8 + data.length
// XOR_CRC = XOR of bytes[2..LEN-4] (i.e. LEN_H ^ LEN_L ^ CMD ^ data...)
#define CMD_START_INVENTORY  0x82   // payload: [count_H=00][count_L=00] (infinite)
#define CMD_STOP_INVENTORY   0x8C   // no payload
#define CMD_GET_LAB_MESSAGE  0xE0   // no payload — device returns buffered tags
#define CMD_READ_TAG         0x84
#define CMD_WRITE_TAG        0x86
#define CMD_LOCK_TAG         0x88
#define CMD_KILL_TAG         0x8A
#define CMD_SET_POWER        0x10
#define CMD_SET_REGION       0x2C   // payload: [save=0x01][region_byte]
                                    // region: 0x01=China1 0x02=China2 0x04=EU
                                    //         0x08=FCC/US 0x16=Korea 0x32=Japan

// Response cmd bytes
#define RESP_INVENTORY_BATCH 0xE1   // batch tag data in response to CMD_GET_LAB_MESSAGE
#define RESP_READ_TAG        0x85
#define RESP_WRITE_TAG       0x87
#define RESP_LOCK_TAG        0x89
#define RESP_KILL_TAG        0x8B
#define RESP_SET_POWER       0x11
#define RESP_SET_REGION      0x2D

// Inventory stall watchdog.
// We poll the reader every 50ms (GET_LAB_MESSAGE) and it always replies, so
// complete inbound silence means the reader/link has wedged — the classic
// "scanning stopped, only a reconnect fixes it". Re-arm a few times, then
// escalate to a full reconnect-and-resume.
#define kStallReArmInterval 2.5   // seconds of device silence before re-arming
#define kStallMaxReArms     4     // re-arms before escalating to a reconnect

typedef NS_ENUM(NSInteger, PendingOperation) {
    OperationNone = 0,
    OperationRead,
    OperationWrite,
    OperationErase,
    OperationLock,
    OperationKill,
    OperationSingleInventory,
    OperationSetPower,
    OperationSetFrequency,
};

@interface UhfBle ()

@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong) CBPeripheral *connectedPeripheral;
@property (nonatomic, strong) CBCharacteristic *writeCharacteristic;
@property (nonatomic, strong) NSMutableArray<CBPeripheral *> *discoveredPeripherals;
@property (nonatomic, strong) NSMutableArray<NSString *> *discoveredAddresses;
@property (nonatomic, strong) NSMutableArray<NSString *> *tagBuffer;
@property (nonatomic, strong) NSMutableData *receiveBuffer;

@property (nonatomic, assign) BOOL isInventorying;
@property (nonatomic, assign) BOOL hasListeners;
@property (nonatomic, assign) BOOL pendingScan;
@property (nonatomic, copy)   NSString *filterEpc;

// Stall watchdog state
@property (nonatomic, assign) NSTimeInterval lastRxTimestamp;            // time of last inbound data
@property (nonatomic, assign) NSInteger      stallReArmCount;            // consecutive re-arms
@property (nonatomic, assign) BOOL           resumeInventoryAfterReconnect;

// 50 ms poll timer — fires CMD_GET_LAB_MESSAGE while inventorying
@property (nonatomic, strong) NSTimer *pollTimer;

// L2CAP CoC (iOS 11+, faster than GATT NUS when device supports it)
@property (nonatomic, strong) id        l2capChannel;       // CBL2CAPChannel*
@property (nonatomic, strong) NSMutableData *l2capRxBuffer;
@property (nonatomic, assign) BOOL      usingL2CAP;
@property (nonatomic, assign) uint16_t  l2capPSM;

// Pending promise callbacks
@property (nonatomic, copy) RCTPromiseResolveBlock pendingResolve;
@property (nonatomic, copy) RCTPromiseRejectBlock  pendingReject;
@property (nonatomic, assign) PendingOperation pendingOp;

// Connect promise (delayed resolve)
@property (nonatomic, copy) RCTPromiseResolveBlock connectResolve;
@property (nonatomic, copy) RCTPromiseRejectBlock  connectReject;

@end

@implementation UhfBle

RCT_EXPORT_MODULE()

// ─── Lifecycle ────────────────────────────────────────────────────────────────

- (instancetype)init {
    self = [super init];
    if (self) {
        _discoveredPeripherals = [NSMutableArray array];
        _discoveredAddresses   = [NSMutableArray array];
        _tagBuffer             = [NSMutableArray array];
        _receiveBuffer         = [NSMutableData data];
        _isInventorying        = NO;
        _hasListeners          = NO;
        _pendingScan           = NO;
        _pendingOp             = OperationNone;
        dispatch_queue_t queue = dispatch_queue_create("com.uhfble.ble", DISPATCH_QUEUE_SERIAL);
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:queue];
    }
    return self;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[EVENT_SCAN_BLE, EVENT_READ_RFID, EVENT_CONNECTION_STATUS];
}

- (void)startObserving { self.hasListeners = YES; }
- (void)stopObserving  { self.hasListeners = NO;  }

+ (BOOL)requiresMainQueueSetup { return NO; }

// ─── BLE Scan ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(scanBLE) {
    NSLog(@"[UhfBle] scanBLE called, state=%ld hasListeners=%d", (long)self.centralManager.state, self.hasListeners);
    [self.discoveredPeripherals removeAllObjects];
    [self.discoveredAddresses removeAllObjects];
    if (self.centralManager.state == CBManagerStatePoweredOn) {
        [self.centralManager scanForPeripheralsWithServices:nil options:nil];
        NSLog(@"[UhfBle] Scan started");
    } else {
        self.pendingScan = YES;
        NSLog(@"[UhfBle] BT not ready, queued scan");
    }
}

RCT_EXPORT_METHOD(stopScanBLE) {
    [self.centralManager stopScan];
}

// ─── Connect ─────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(connectAddress:(NSString *)address
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    self.connectResolve = resolve;
    self.connectReject  = reject;

    CBPeripheral *target = nil;
    for (CBPeripheral *p in self.discoveredPeripherals) {
        if ([p.identifier.UUIDString isEqualToString:address] ||
            [p.name isEqualToString:address]) {
            target = p;
            break;
        }
    }

    if (target) {
        [self.centralManager stopScan];
        [self.centralManager connectPeripheral:target options:nil];
    } else {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:address];
        if (uuid) {
            NSArray *known = [self.centralManager retrievePeripheralsWithIdentifiers:@[uuid]];
            if (known.count > 0) {
                [self.centralManager connectPeripheral:known[0] options:nil];
                return;
            }
        }
        reject(@"NOT_FOUND", @"Device not found. Run scanBLE first.", nil);
        self.connectResolve = nil;
        self.connectReject  = nil;
    }
}

RCT_EXPORT_METHOD(disconnect) {
    if (self.connectedPeripheral) {
        [self.centralManager cancelPeripheralConnection:self.connectedPeripheral];
    }
}

RCT_EXPORT_METHOD(getConnectionStatus:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (self.connectedPeripheral &&
        self.connectedPeripheral.state == CBPeripheralStateConnected) {
        resolve(@"connected");
    } else if (self.connectedPeripheral &&
               self.connectedPeripheral.state == CBPeripheralStateConnecting) {
        resolve(@"connecting");
    } else {
        resolve(@"disconnected");
    }
}

// ─── Inventory ───────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(startInventory) {
    if (self.isInventorying) return;
    self.filterEpc = nil;
    [self.tagBuffer removeAllObjects];
    self.isInventorying = YES;
    [self resetStallWatchdog];
    [self sendCommand:[self buildStartInventoryCommand]];
    [self startPollTimer];
}

RCT_EXPORT_METHOD(startInventoryWithFilter:(NSString *)epc) {
    if (self.isInventorying) return;
    self.filterEpc = epc;
    [self.tagBuffer removeAllObjects];
    self.isInventorying = YES;
    [self resetStallWatchdog];
    [self sendCommand:[self buildStartInventoryCommand]];
    [self startPollTimer];
}

RCT_EXPORT_METHOD(stopInventory) {
    self.isInventorying = NO;
    self.filterEpc = nil;
    [self stopPollTimer];
    [self sendCommand:[self buildStopInventoryCommand]];
}

RCT_EXPORT_METHOD(inventorySingleTag:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationSingleInventory resolve:resolve reject:reject];
    self.isInventorying = YES;
    [self sendCommand:[self buildStartInventoryCommand]];
    [self startPollTimer];
}

RCT_EXPORT_METHOD(clearData:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    [self.tagBuffer removeAllObjects];
    resolve(@YES);
}

// ─── Read Tag ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(readTag:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationRead resolve:resolve reject:reject];

    int bank = [params[@"bank"] intValue];
    int ptr  = [params[@"ptr"]  intValue];
    int len  = [params[@"len"]  intValue];
    NSString *pwd = params[@"password"] ?: @"00000000";

    NSData *cmd = [self buildReadCommand:bank ptr:ptr len:len password:pwd];
    [self sendCommand:cmd];
}

// ─── Write Tag ───────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(writeTag:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationWrite resolve:resolve reject:reject];

    int bank      = [params[@"bank"] intValue];
    int ptr       = [params[@"ptr"]  intValue];
    int len       = [params[@"len"]  intValue];
    NSString *data = params[@"data"]     ?: @"";
    NSString *pwd  = params[@"password"] ?: @"00000000";

    NSData *cmd = [self buildWriteCommand:bank ptr:ptr len:len password:pwd data:data];
    [self sendCommand:cmd];
}

// ─── Lock Tag ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(lockTag:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationLock resolve:resolve reject:reject];

    NSString *pwd      = params[@"password"] ?: @"00000000";
    NSString *lockCode = params[@"lockCode"] ?: @"000000";

    NSData *cmd = [self buildLockCommand:pwd lockCode:lockCode];
    [self sendCommand:cmd];
}

// ─── Kill Tag ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(killTag:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationKill resolve:resolve reject:reject];

    NSString *pwd = params[@"password"] ?: @"00000000";

    NSData *cmd = [self buildKillCommand:pwd];
    [self sendCommand:cmd];
}

// ─── Settings ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(setPower:(int)power
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationSetPower resolve:resolve reject:reject];
    [self sendCommand:[self buildSetPowerCommand:power]];
}

// ─── Erase Tag ────────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(eraseTag:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationErase resolve:resolve reject:reject];

    int bank      = [params[@"bank"] intValue];
    int ptr       = [params[@"ptr"]  intValue];
    int len       = [params[@"len"]  intValue];
    NSString *pwd = params[@"password"] ?: @"00000000";

    // Erase = write zeros (len words = len*4 hex chars of zeros)
    NSMutableString *zeros = [NSMutableString string];
    for (int i = 0; i < len * 4; i++) [zeros appendString:@"0"];

    NSData *cmd = [self buildWriteCommand:bank ptr:ptr len:len password:pwd data:zeros];
    [self sendCommand:cmd];
}

// ─── Set Frequency ────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(setFrequency:(int)mode
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationSetFrequency resolve:resolve reject:reject];
    [self sendCommand:[self buildSetFrequencyCommand:mode]];
}

// ─── Poll timer ──────────────────────────────────────────────────────────────

- (void)startPollTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Invalidate inline — do NOT call stopPollTimer here, which would
        // dispatch another async block that would kill the timer we're about to create.
        [self.pollTimer invalidate];
        self.pollTimer = nil;
        // Schedule on NSRunLoopCommonModes (not the default mode that
        // +scheduledTimerWithTimeInterval: uses). A default-mode timer is PAUSED
        // whenever the main run loop enters UITrackingRunLoopMode — i.e. while the
        // user scrolls/touches the UI. That stops the 50ms drain of the reader's
        // tag buffer and makes inventory appear to "randomly stop". Common modes
        // keeps it firing during tracking.
        NSTimer *t = [NSTimer timerWithTimeInterval:0.05
                                             target:self
                                           selector:@selector(pollTagData)
                                           userInfo:nil
                                            repeats:YES];
        self.pollTimer = t;
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    });
}

- (void)stopPollTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pollTimer invalidate];
        self.pollTimer = nil;
    });
}

- (void)pollTagData {
    // Called on main thread by NSTimer
    if (!self.isInventorying) {
        // Directly invalidate — we ARE on main thread already
        [self.pollTimer invalidate];
        self.pollTimer = nil;
        return;
    }

    // ── Stall watchdog ─────────────────────────────────────────────────────────
    // The reader replies to every GET_LAB_MESSAGE poll, so sustained inbound
    // silence means it has wedged. Re-arm a few times; if it stays silent,
    // reconnect and resume. Skipped for single-tag mode, which legitimately
    // waits (possibly long) for the first tag to enter the field.
    if (self.pendingOp != OperationSingleInventory) {
        NSTimeInterval silent = [NSDate timeIntervalSinceReferenceDate] - self.lastRxTimestamp;
        if (silent > kStallReArmInterval) {
            self.stallReArmCount++;
            if (self.stallReArmCount > kStallMaxReArms) {
                NSLog(@"[UhfBle] WATCHDOG: reader silent %.1fs after %ld re-arms — forcing reconnect",
                      silent, (long)self.stallReArmCount);
                [self forceReconnectAndResume];
                return;
            }
            NSLog(@"[UhfBle] WATCHDOG: reader silent %.1fs — re-arming inventory (#%ld)",
                  silent, (long)self.stallReArmCount);
            [self sendCommand:[self buildStopInventoryCommand]];
            [self sendCommand:[self buildStartInventoryCommand]];
            // Give it a fresh window before counting silence again.
            self.lastRxTimestamp = [NSDate timeIntervalSinceReferenceDate];
            return;
        }
    }

    // Flow control: don't pile up write-without-response packets when the BLE
    // TX queue is congested — that backlog itself wedges the command channel.
    // Skip this tick; the next one (50ms later) retries once the link drains.
    if (@available(iOS 11.0, *)) {
        if (!self.usingL2CAP && self.connectedPeripheral &&
            !self.connectedPeripheral.canSendWriteWithoutResponse) {
            return;
        }
    }
    [self sendCommand:[self buildGetLabMessageCommand]];
}

- (void)resetStallWatchdog {
    self.lastRxTimestamp = [NSDate timeIntervalSinceReferenceDate];
    self.stallReArmCount = 0;
}

// Cancel the current connection and immediately reconnect to the same
// peripheral, resuming inventory once services are rediscovered. This mirrors
// the manual reconnect that currently "fixes" a wedged reader.
- (void)forceReconnectAndResume {
    CBPeripheral *p = self.connectedPeripheral;
    [self stopPollTimer];
    self.isInventorying  = NO;   // didDisconnect will also clear; resume flag re-starts it
    self.stallReArmCount = 0;
    if (!p) return;
    self.resumeInventoryAfterReconnect = YES;
    NSLog(@"[UhfBle] WATCHDOG: cancelling + reconnecting %@", p.identifier.UUIDString);
    [self.centralManager cancelPeripheralConnection:p];
    [self.centralManager connectPeripheral:p options:nil];
}

// ─── CBCentralManagerDelegate ────────────────────────────────────────────────

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSLog(@"[UhfBle] centralManagerDidUpdateState: %ld", (long)central.state);
    if (central.state == CBManagerStatePoweredOn && self.pendingScan) {
        self.pendingScan = NO;
        [self.centralManager scanForPeripheralsWithServices:nil options:nil];
        NSLog(@"[UhfBle] Started pending scan");
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *uuidStr = peripheral.identifier.UUIDString;
    if ([self.discoveredAddresses containsObject:uuidStr]) return;

    [self.discoveredAddresses addObject:uuidStr];
    [self.discoveredPeripherals addObject:peripheral];

    NSString *name = peripheral.name
        ?: advertisementData[CBAdvertisementDataLocalNameKey]
        ?: @"Unknown";

    NSLog(@"[UhfBle] Discovered: %@ (%@)", name, uuidStr);

    [self sendEventWithName:EVENT_SCAN_BLE body:@{
        @"name_device":    name,
        @"address_device": uuidStr,
        @"rssi":           RSSI.stringValue,
    }];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    self.connectedPeripheral = peripheral;
    peripheral.delegate = self;
    // Discover all services — lets us find L2CAP PSM characteristic if device supports it
    [peripheral discoverServices:nil];

    [self sendEventWithName:EVENT_CONNECTION_STATUS body:@{
        @"status": @"connected",
        @"device": peripheral.name ?: @"",
    }];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    if (self.connectReject) {
        self.connectReject(@"CONNECT_FAIL", error.localizedDescription ?: @"Connection failed", error);
        self.connectResolve = nil;
        self.connectReject  = nil;
    }
    [self sendEventWithName:EVENT_CONNECTION_STATUS body:@{ @"status": @"disconnected" }];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    [self stopPollTimer];
    self.isInventorying = NO;

    if (@available(iOS 11.0, *)) {
        if (self.l2capChannel) {
            CBL2CAPChannel *ch = (CBL2CAPChannel *)self.l2capChannel;
            [ch.inputStream close];
            [ch.outputStream close];
        }
    }
    self.l2capChannel        = nil;
    self.usingL2CAP          = NO;
    self.connectedPeripheral = nil;
    self.writeCharacteristic = nil;
    [self sendEventWithName:EVENT_CONNECTION_STATUS body:@{ @"status": @"disconnected" }];
}

// ─── CBPeripheralDelegate ────────────────────────────────────────────────────

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverServices:(NSError *)error {
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kWriteUUID]]) {
            if (c.properties & CBCharacteristicPropertyWriteWithoutResponse) {
                self.writeCharacteristic = c;
            }
        }
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kNotifyUUID]]) {
            [peripheral setNotifyValue:YES forCharacteristic:c];
        }
        if (@available(iOS 11.0, *)) {
            if ([c.UUID.UUIDString.uppercaseString isEqualToString:
                     [CBUUIDL2CAPPSMCharacteristicString uppercaseString]]) {
                NSLog(@"[UhfBle] Found L2CAP PSM characteristic — reading");
                [peripheral readValueForCharacteristic:c];
            }
        }
    }
    if (self.writeCharacteristic && self.connectResolve) {
        NSString *name = peripheral.name ?: peripheral.identifier.UUIDString;
        self.connectResolve(name);
        self.connectResolve = nil;
        self.connectReject  = nil;
    }

    // Watchdog-driven reconnect: services are back, resume inventory where we
    // left off (tagBuffer is preserved so dedup survives the blip).
    if (self.writeCharacteristic && self.resumeInventoryAfterReconnect) {
        self.resumeInventoryAfterReconnect = NO;
        NSLog(@"[UhfBle] WATCHDOG: reconnected — resuming inventory");
        self.isInventorying = YES;
        [self resetStallWatchdog];
        [self sendCommand:[self buildStartInventoryCommand]];
        [self startPollTimer];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error || !characteristic.value) return;

    if (@available(iOS 11.0, *)) {
        if ([characteristic.UUID.UUIDString.uppercaseString isEqualToString:
                 [CBUUIDL2CAPPSMCharacteristicString uppercaseString]]) {
            if (characteristic.value.length >= 2) {
                uint16_t psm = 0;
                [characteristic.value getBytes:&psm length:sizeof(psm)];
                psm = CFSwapInt16LittleToHost(psm);
                self.l2capPSM = psm;
                NSLog(@"[UhfBle] L2CAP PSM = %u — opening channel", psm);
                [peripheral openL2CAPChannel:psm];
            }
            return;
        }
    }

    // NUS notify data — only process via GATT path if not on L2CAP
    if (!self.usingL2CAP) {
        [self processReceivedData:characteristic.value];
    }
}

// ─── CBPeripheralDelegate — L2CAP ────────────────────────────────────────────

- (void)peripheral:(CBPeripheral *)peripheral
didOpenL2CAPChannel:(id)channel
              error:(NSError *)error API_AVAILABLE(ios(11.0)) {
    if (error || !channel) {
        NSLog(@"[UhfBle] L2CAP open failed (%@) — staying on GATT", error.localizedDescription);
        return;
    }
    CBL2CAPChannel *ch = (CBL2CAPChannel *)channel;
    self.l2capChannel   = ch;
    self.usingL2CAP     = YES;
    self.l2capRxBuffer  = [NSMutableData data];

    ch.inputStream.delegate = self;
    [ch.inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [ch.inputStream open];
    [ch.outputStream open];
    NSLog(@"[UhfBle] L2CAP channel open, PSM=%u — all I/O now via L2CAP", ch.PSM);
}

// ─── NSStreamDelegate ────────────────────────────────────────────────────────

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    if (@available(iOS 11.0, *)) {
        switch (eventCode) {
            case NSStreamEventHasBytesAvailable: {
                uint8_t buf[512];
                NSInteger n = [(NSInputStream *)aStream read:buf maxLength:sizeof(buf)];
                if (n > 0) {
                    [self processReceivedData:[NSData dataWithBytes:buf length:n]];
                }
                break;
            }
            case NSStreamEventEndEncountered:
            case NSStreamEventErrorOccurred: {
                NSLog(@"[UhfBle] L2CAP stream ended/error — falling back to GATT");
                self.usingL2CAP  = NO;
                self.l2capChannel = nil;
                break;
            }
            default:
                break;
        }
    }
}

// ─── Command builders ────────────────────────────────────────────────────────
//
// A5 5A frame format:
//   A5 5A [LEN_H][LEN_L][CMD][data...][XOR_CRC][0D][0A]
//
// LEN     = 8 + data.length  (total frame size)
// XOR_CRC = XOR(LEN_H, LEN_L, CMD, data[0], data[1], ...)

- (NSData *)buildA55AFrame:(uint8_t)cmd data:(NSData *)data {
    NSUInteger dataLen = data ? data.length : 0;
    uint16_t totalLen  = (uint16_t)(8 + dataLen);
    uint8_t lenH = (totalLen >> 8) & 0xFF;
    uint8_t lenL = totalLen & 0xFF;

    // XOR checksum over bytes[2..LEN-4]: LEN_H, LEN_L, CMD, data bytes
    uint8_t xorCrc = lenH ^ lenL ^ cmd;
    if (data) {
        const uint8_t *db = data.bytes;
        for (NSUInteger i = 0; i < dataLen; i++) xorCrc ^= db[i];
    }

    NSMutableData *frame = [NSMutableData dataWithCapacity:totalLen];
    uint8_t header[2] = { 0xA5, 0x5A };
    [frame appendBytes:header length:2];
    [frame appendBytes:&lenH length:1];
    [frame appendBytes:&lenL length:1];
    [frame appendBytes:&cmd  length:1];
    if (data) [frame appendData:data];
    [frame appendBytes:&xorCrc length:1];
    uint8_t tail[2] = { 0x0D, 0x0A };
    [frame appendBytes:tail length:2];
    return frame;
}

- (NSData *)buildStartInventoryCommand {
    // cmd=0x82, payload=[00 00] (count=0 means infinite)
    uint8_t payload[2] = { 0x00, 0x00 };
    return [self buildA55AFrame:CMD_START_INVENTORY
                           data:[NSData dataWithBytes:payload length:2]];
}

- (NSData *)buildStopInventoryCommand {
    return [self buildA55AFrame:CMD_STOP_INVENTORY data:nil];
}

- (NSData *)buildGetLabMessageCommand {
    return [self buildA55AFrame:CMD_GET_LAB_MESSAGE data:nil];
}

- (NSData *)buildReadCommand:(int)bank ptr:(int)ptr len:(int)len password:(NSString *)pwd {
    // data = [pwd:4][MMB=0][MSA_H=0][MSA_L=0][MDL_H=0][MDL_L=0][MB][SA_H][SA_L][DL_H][DL_L]
    NSMutableData *payload = [NSMutableData dataWithCapacity:14];
    [payload appendData:[self hexStringToData:pwd]];   // 4 bytes password
    uint8_t zeros5[5] = { 0, 0, 0, 0, 0 };            // MMB + MSA(2) + MDL(2) — no mask filter
    [payload appendBytes:zeros5 length:5];
    uint8_t  mb   = bank & 0xFF;
    uint8_t  saH  = (ptr >> 8) & 0xFF;
    uint8_t  saL  = ptr & 0xFF;
    uint8_t  dlH  = (len >> 8) & 0xFF;
    uint8_t  dlL  = len & 0xFF;
    uint8_t  addr[5] = { mb, saH, saL, dlH, dlL };
    [payload appendBytes:addr length:5];
    return [self buildA55AFrame:CMD_READ_TAG data:payload];
}

- (NSData *)buildWriteCommand:(int)bank ptr:(int)ptr len:(int)len password:(NSString *)pwd data:(NSString *)data {
    NSMutableData *payload = [NSMutableData data];
    [payload appendData:[self hexStringToData:pwd]];   // 4 bytes password
    uint8_t zeros5[5] = { 0, 0, 0, 0, 0 };
    [payload appendBytes:zeros5 length:5];
    uint8_t mb   = bank & 0xFF;
    uint8_t saH  = (ptr >> 8) & 0xFF;
    uint8_t saL  = ptr & 0xFF;
    uint8_t dlH  = (len >> 8) & 0xFF;
    uint8_t dlL  = len & 0xFF;
    uint8_t addr[5] = { mb, saH, saL, dlH, dlL };
    [payload appendBytes:addr length:5];
    [payload appendData:[self hexStringToData:data]];  // write data
    return [self buildA55AFrame:CMD_WRITE_TAG data:payload];
}

- (NSData *)buildLockCommand:(NSString *)pwd lockCode:(NSString *)lockCode {
    // data = [pwd:4][MMB=0][MSA_H=0][MSA_L=0][MDL_H=0][MDL_L=0][lockData:3]
    NSMutableData *payload = [NSMutableData data];
    [payload appendData:[self hexStringToData:pwd]];   // 4 bytes password
    uint8_t zeros5[5] = { 0, 0, 0, 0, 0 };
    [payload appendBytes:zeros5 length:5];
    [payload appendData:[self hexStringToData:lockCode]]; // 3 bytes lock code
    return [self buildA55AFrame:CMD_LOCK_TAG data:payload];
}

- (NSData *)buildKillCommand:(NSString *)pwd {
    // data = [killPwd:4][MMB=0][MSA_H=0][MSA_L=0][MDL_H=0][MDL_L=0]
    NSMutableData *payload = [NSMutableData data];
    [payload appendData:[self hexStringToData:pwd]];   // 4 bytes kill password
    uint8_t zeros5[5] = { 0, 0, 0, 0, 0 };
    [payload appendBytes:zeros5 length:5];
    return [self buildA55AFrame:CMD_KILL_TAG data:payload];
}

- (NSData *)buildSetPowerCommand:(int)power {
    // data = [0x02][antenna=0x00][readPower*100 BE:2][writePower*100 BE:2]
    NSMutableData *payload = [NSMutableData dataWithCapacity:6];
    uint16_t powerRaw = (uint16_t)(power * 100);
    uint8_t  powerH   = (powerRaw >> 8) & 0xFF;
    uint8_t  powerL   = powerRaw & 0xFF;
    uint8_t  bytes[6] = { 0x02, 0x00, powerH, powerL, powerH, powerL };
    [payload appendBytes:bytes length:6];
    return [self buildA55AFrame:CMD_SET_POWER data:payload];
}

- (NSData *)buildSetFrequencyCommand:(int)mode {
    // data = [save=0x01][region_byte]
    // mode/region: 0x01=China1 0x02=China2 0x04=EU 0x08=FCC/US 0x16=Korea 0x32=Japan
    uint8_t bytes[2] = { 0x01, (uint8_t)(mode & 0xFF) };
    return [self buildA55AFrame:CMD_SET_REGION
                           data:[NSData dataWithBytes:bytes length:2]];
}

// ─── Response parser ─────────────────────────────────────────────────────────
//
// Device frame format: A5 5A [LEN_H][LEN_L][CMD][data...][XOR_CRC][0D][0A]
// Parse using LENGTH field — no need to search for terminator

- (void)processReceivedData:(NSData *)incoming {
    // Any inbound traffic proves the link + reader are alive — feed the watchdog.
    self.lastRxTimestamp = [NSDate timeIntervalSinceReferenceDate];
    self.stallReArmCount = 0;
    [self.receiveBuffer appendData:incoming];

    while (self.receiveBuffer.length >= 8) { // minimum valid frame size
        const uint8_t *bytes = self.receiveBuffer.bytes;

        // Sync to A5 5A preamble
        if (bytes[0] != 0xA5) {
            NSUInteger skip = 1;
            while (skip < self.receiveBuffer.length && bytes[skip] != 0xA5) skip++;
            [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, skip) withBytes:NULL length:0];
            continue;
        }
        if (bytes[1] != 0x5A) {
            [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, 1) withBytes:NULL length:0];
            continue;
        }

        // Need LEN field
        if (self.receiveBuffer.length < 4) break;

        uint16_t totalLen = ((uint16_t)bytes[2] << 8) | bytes[3];
        if (totalLen < 8) {
            // Invalid frame length — skip this A5 and retry
            [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
            continue;
        }

        // Wait until we have the complete frame
        if (self.receiveBuffer.length < totalLen) break;

        uint8_t   cmd     = bytes[4];
        NSUInteger dataLen = totalLen - 8; // exclude A5 5A LEN_H LEN_L CMD XOR 0D 0A
        NSData    *payload = (dataLen > 0)
            ? [self.receiveBuffer subdataWithRange:NSMakeRange(5, dataLen)]
            : [NSData data];

        [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, totalLen) withBytes:NULL length:0];

        [self processCmd:cmd payload:payload];
    }
}

- (void)processCmd:(uint8_t)cmd payload:(NSData *)payload {
    NSLog(@"[UhfBle] cmd=0x%02X payloadLen=%lu", cmd, (unsigned long)payload.length);

    switch (cmd) {
        case RESP_INVENTORY_BATCH:
            if (self.isInventorying) {
                [self parseInventoryBatch:payload];
            }
            break;

        case RESP_READ_TAG: {
            if (self.pendingOp != OperationRead) break;
            const uint8_t *b = payload.bytes;
            // payload[0] = status, payload[1..] = data words
            if (payload.length >= 1 && b[0] == 0x00 && payload.length > 1) {
                NSData *readData = [payload subdataWithRange:NSMakeRange(1, payload.length - 1)];
                NSString *hex = [self dataToHexString:readData];
                if (self.pendingResolve) self.pendingResolve(hex);
            } else {
                if (self.pendingReject) self.pendingReject(@"READ_FAIL", @"Read tag failed", nil);
            }
            [self clearPending];
            break;
        }

        case RESP_WRITE_TAG:    // also handles erase (which is a write of zeros)
        case RESP_LOCK_TAG:
        case RESP_KILL_TAG:
        case RESP_SET_POWER:
        case RESP_SET_REGION: {
            if (self.pendingOp == OperationNone) break;
            const uint8_t *b = payload.bytes;
            BOOL ok = (payload.length >= 1 && b[0] == 0x00);
            if (ok && self.pendingResolve) self.pendingResolve(@YES);
            else if (!ok && self.pendingReject) self.pendingReject(@"OP_FAIL", @"Operation failed", nil);
            [self clearPending];
            break;
        }

        default:
            // ACK frames (e.g. 0x83 for start, 0x8D for stop) — ignored
            break;
    }
}

// ─── Inventory batch parser ───────────────────────────────────────────────────
//
// cmd=0xE1 payload: [idx_H][idx_L][count][len1][tag1_data...][len2][tag2_data...]...
// tag_data = [PC:2][EPC:N][RSSI:2]
//   epcByteCount = (PC[0] >> 3) * 2
//   rssi_dBm     = -(65535 - uint16(rssiBytes)) / 10.0

- (void)parseInventoryBatch:(NSData *)payload {
    if (payload.length < 3) return;
    const uint8_t *bytes = payload.bytes;
    NSUInteger count  = bytes[2]; // number of tags in this batch
    NSUInteger offset = 3;

    for (NSUInteger i = 0; i < count; i++) {
        if (offset >= payload.length) break;
        NSUInteger tagLen = bytes[offset++];
        if (offset + tagLen > payload.length) break;

        // tag_data = [PC:2][EPC:N][RSSI:2]
        if (tagLen < 4) { offset += tagLen; continue; } // need PC(2) + at least RSSI(2)

        uint8_t    pc0          = bytes[offset];
        NSUInteger epcByteCount = ((pc0 >> 3) & 0x1F) * 2;

        if (2 + epcByteCount + 2 > tagLen) { offset += tagLen; continue; } // sanity

        NSData   *epcData = [payload subdataWithRange:NSMakeRange(offset + 2, epcByteCount)];
        NSString *epc     = [[self dataToHexString:epcData] uppercaseString];

        uint16_t rssiRaw = ((uint16_t)bytes[offset + tagLen - 2] << 8)
                         |  (uint16_t)bytes[offset + tagLen - 1];
        double   rssiDbm = -(65535.0 - rssiRaw) / 10.0;
        NSString *rssiStr = [NSString stringWithFormat:@"%.1f", rssiDbm];

        offset += tagLen;

        if (epc.length == 0) continue;

        NSLog(@"[UhfBle] tag EPC=%@ RSSI=%@", epc, rssiStr);

        if (self.pendingOp == OperationSingleInventory) {
            self.isInventorying = NO;
            [self stopPollTimer];
            [self sendCommand:[self buildStopInventoryCommand]];
            if (self.pendingResolve) self.pendingResolve(@{ @"rfid_tag": epc, @"rssi": rssiStr });
            [self clearPending];
            return;
        }

        if (self.filterEpc && self.filterEpc.length > 0 &&
            ![self.filterEpc.uppercaseString isEqualToString:epc]) continue;
        if ([self.tagBuffer containsObject:epc]) continue;

        [self.tagBuffer addObject:epc];
        [self sendEventWithName:EVENT_READ_RFID body:@{ @"rfid_tag": epc, @"rssi": rssiStr }];
    }
}

// ─── BLE write helper ────────────────────────────────────────────────────────

- (void)sendCommand:(NSData *)data {
    if (!self.connectedPeripheral) {
        NSLog(@"[UhfBle] sendCommand: not connected");
        return;
    }
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02X ", bytes[i]];
    NSLog(@"[UhfBle] sendCommand (%@): %@", self.usingL2CAP ? @"L2CAP" : @"GATT", hex);

    // ── L2CAP path ────────────────────────────────────────────────────────────
    if (@available(iOS 11.0, *)) {
        if (self.usingL2CAP && self.l2capChannel) {
            CBL2CAPChannel *ch = (CBL2CAPChannel *)self.l2capChannel;
            NSOutputStream *out = ch.outputStream;
            NSUInteger offset = 0;
            while (offset < data.length) {
                if (!out.hasSpaceAvailable) {
                    usleep(1000);
                    continue;
                }
                NSInteger written = [out write:(bytes + offset) maxLength:(data.length - offset)];
                if (written <= 0) break;
                offset += written;
            }
            return;
        }
    }

    // ── GATT NUS path (fallback) ──────────────────────────────────────────────
    if (!self.writeCharacteristic) {
        NSLog(@"[UhfBle] sendCommand: no write characteristic");
        return;
    }
    NSUInteger maxLen = [self.connectedPeripheral
                            maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSUInteger chunkLen = MIN(maxLen, data.length - offset);
        NSData *chunk = [data subdataWithRange:NSMakeRange(offset, chunkLen)];
        [self.connectedPeripheral writeValue:chunk
                           forCharacteristic:self.writeCharacteristic
                                        type:CBCharacteristicWriteWithoutResponse];
        if (data.length > maxLen) usleep(1000 * 30);
        offset += chunkLen;
    }
}

// ─── Utilities ───────────────────────────────────────────────────────────────

- (NSData *)hexStringToData:(NSString *)hex {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int byte;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
        uint8_t b = byte & 0xFF;
        [data appendBytes:&b length:1];
    }
    return data;
}

- (NSString *)dataToHexString:(NSData *)data {
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return hex;
}

- (BOOL)assertConnected:(RCTPromiseRejectBlock)reject {
    if (!self.connectedPeripheral ||
        self.connectedPeripheral.state != CBPeripheralStateConnected) {
        reject(@"NOT_CONNECTED", @"No device connected", nil);
        return NO;
    }
    return YES;
}

- (void)setPendingOp:(PendingOperation)op
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject {
    self.pendingOp      = op;
    self.pendingResolve = resolve;
    self.pendingReject  = reject;
}

- (void)clearPending {
    self.pendingOp      = OperationNone;
    self.pendingResolve = nil;
    self.pendingReject  = nil;
}

@end
