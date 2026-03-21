#import "UhfBle.h"

// Nordic UART Service UUIDs (same as the iOS app)
#define kServiceUUID    @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define kWriteUUID      @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define kNotifyUUID     @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// Event names
#define EVENT_SCAN_BLE          @"ScanBLEListener"
#define EVENT_READ_RFID         @"ReadRFIDListener"
#define EVENT_CONNECTION_STATUS @"ConnectionStatusListener"

// Command bytes (rscja BLE protocol)
#define CMD_INVENTORY_START     0x27
#define CMD_INVENTORY_STOP      0x28
#define CMD_READ_TAG            0x39
#define CMD_WRITE_TAG           0x49
#define CMD_LOCK_TAG            0x82
#define CMD_KILL_TAG            0x65
#define CMD_SET_POWER           0xB6
#define CMD_SET_FREQ            0xAD

typedef NS_ENUM(NSInteger, PendingOperation) {
    OperationNone = 0,
    OperationRead,
    OperationWrite,
    OperationLock,
    OperationKill,
    OperationErase,
    OperationSetPower,
    OperationSetFrequency,
    OperationConnect,
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
@property (nonatomic, copy)   NSString *filterEpc;

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
    [self.discoveredPeripherals removeAllObjects];
    [self.discoveredAddresses removeAllObjects];
    if (self.centralManager.state == CBManagerStatePoweredOn) {
        [self.centralManager scanForPeripheralsWithServices:nil options:nil];
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
        // Try connecting by UUID directly
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
    self.isInventorying = YES;
    [self sendCommand:[self buildStartInventoryCommand]];
}

RCT_EXPORT_METHOD(startInventoryWithFilter:(NSString *)epc) {
    if (self.isInventorying) return;
    self.filterEpc = epc;
    self.isInventorying = YES;
    [self sendCommand:[self buildStartInventoryCommand]];
}

RCT_EXPORT_METHOD(stopInventory) {
    self.isInventorying = NO;
    self.filterEpc = nil;
    [self sendCommand:[self buildStopInventoryCommand]];
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

// ─── Erase Tag ───────────────────────────────────────────────────────────────

RCT_EXPORT_METHOD(eraseTag:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationErase resolve:resolve reject:reject];

    int bank   = [params[@"bank"] intValue];
    int ptr    = [params[@"ptr"]  intValue];
    int len    = [params[@"len"]  intValue];
    NSString *pwd = params[@"password"] ?: @"00000000";

    // Write zeros
    NSMutableString *zeros = [NSMutableString string];
    for (int i = 0; i < len * 4; i++) [zeros appendString:@"0"];

    NSData *cmd = [self buildWriteCommand:bank ptr:ptr len:len password:pwd data:zeros];
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

RCT_EXPORT_METHOD(setFrequency:(int)mode
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    if (![self assertConnected:reject]) return;
    [self setPendingOp:OperationSetFrequency resolve:resolve reject:reject];
    [self sendCommand:[self buildSetFrequencyCommand:mode]];
}

// Required stubs for RN event emitter
RCT_EXPORT_METHOD(addListener:(NSString *)eventName) {}
RCT_EXPORT_METHOD(removeListeners:(int)count) {}

// ─── CBCentralManagerDelegate ────────────────────────────────────────────────

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    // Bluetooth state changed — no action needed here
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (!peripheral.name || peripheral.name.length == 0) return;
    NSString *uuidStr = peripheral.identifier.UUIDString;
    if ([self.discoveredAddresses containsObject:uuidStr]) return;

    [self.discoveredAddresses addObject:uuidStr];
    [self.discoveredPeripherals addObject:peripheral];

    if (self.hasListeners) {
        [self sendEventWithName:EVENT_SCAN_BLE body:@{
            @"name_device":    peripheral.name ?: @"",
            @"address_device": uuidStr,
            @"rssi":           RSSI.stringValue,
        }];
    }
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral {
    self.connectedPeripheral = peripheral;
    peripheral.delegate = self;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:kServiceUUID]]];

    if (self.hasListeners) {
        [self sendEventWithName:EVENT_CONNECTION_STATUS body:@{
            @"status": @"connected",
            @"device": peripheral.name ?: @"",
        }];
    }
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    if (self.connectReject) {
        self.connectReject(@"CONNECT_FAIL", error.localizedDescription ?: @"Connection failed", error);
        self.connectResolve = nil;
        self.connectReject  = nil;
    }
    if (self.hasListeners) {
        [self sendEventWithName:EVENT_CONNECTION_STATUS body:@{ @"status": @"disconnected" }];
    }
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    self.connectedPeripheral   = nil;
    self.writeCharacteristic   = nil;
    self.isInventorying        = NO;
    if (self.hasListeners) {
        [self sendEventWithName:EVENT_CONNECTION_STATUS body:@{ @"status": @"disconnected" }];
    }
}

// ─── CBPeripheralDelegate ────────────────────────────────────────────────────

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverServices:(NSError *)error {
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:kServiceUUID]]) {
            [peripheral discoverCharacteristics:@[
                [CBUUID UUIDWithString:kWriteUUID],
                [CBUUID UUIDWithString:kNotifyUUID],
            ] forService:service];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kWriteUUID]]) {
            self.writeCharacteristic = c;
        }
        if ([c.UUID isEqual:[CBUUID UUIDWithString:kNotifyUUID]]) {
            [peripheral setNotifyValue:YES forCharacteristic:c];
        }
    }
    // Resolve connect promise once characteristics are ready
    if (self.writeCharacteristic && self.connectResolve) {
        NSString *name = peripheral.name ?: peripheral.identifier.UUIDString;
        self.connectResolve(name);
        self.connectResolve = nil;
        self.connectReject  = nil;
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error || !characteristic.value) return;
    [self processReceivedData:characteristic.value];
}

// ─── Command builders ────────────────────────────────────────────────────────

/// All commands follow the rscja BLE frame format:
/// BB <len_hi> <len_lo> <cmd> [data...] <checksum> 7E
///
/// Checksum = sum of all bytes between BB and checksum (exclusive), masked to 0xFF

- (NSData *)buildFrame:(uint8_t)cmd payload:(NSData *)payload {
    NSMutableData *frame = [NSMutableData data];
    uint8_t header = 0xBB;
    [frame appendBytes:&header length:1];
    uint16_t payloadLen = (uint16_t)(payload ? payload.length : 0);
    uint8_t lenHi = (payloadLen >> 8) & 0xFF;
    uint8_t lenLo = payloadLen & 0xFF;
    [frame appendBytes:&lenHi length:1];
    [frame appendBytes:&lenLo length:1];
    [frame appendBytes:&cmd   length:1];
    if (payload) [frame appendData:payload];

    // Checksum: sum of len_hi + len_lo + cmd + payload bytes
    uint8_t checksum = lenHi + lenLo + cmd;
    if (payload) {
        const uint8_t *bytes = payload.bytes;
        for (NSUInteger i = 0; i < payload.length; i++) checksum += bytes[i];
    }
    checksum &= 0xFF;
    [frame appendBytes:&checksum length:1];
    uint8_t tail = 0x7E;
    [frame appendBytes:&tail length:1];
    return frame;
}

- (NSData *)buildStartInventoryCommand {
    return [self buildFrame:CMD_INVENTORY_START payload:nil];
}

- (NSData *)buildStopInventoryCommand {
    return [self buildFrame:CMD_INVENTORY_STOP payload:nil];
}

- (NSData *)buildReadCommand:(int)bank ptr:(int)ptr len:(int)len password:(NSString *)pwd {
    NSMutableData *payload = [NSMutableData data];
    // password (4 bytes)
    NSData *pwdBytes = [self hexStringToData:pwd];
    [payload appendData:pwdBytes];
    // bank (1 byte), ptr (2 bytes), len (1 byte)
    uint8_t b = bank & 0xFF;
    uint16_t p = htons((uint16_t)ptr);
    uint8_t l = len & 0xFF;
    [payload appendBytes:&b length:1];
    [payload appendBytes:&p length:2];
    [payload appendBytes:&l length:1];
    return [self buildFrame:CMD_READ_TAG payload:payload];
}

- (NSData *)buildWriteCommand:(int)bank ptr:(int)ptr len:(int)len password:(NSString *)pwd data:(NSString *)data {
    NSMutableData *payload = [NSMutableData data];
    NSData *pwdBytes  = [self hexStringToData:pwd];
    NSData *dataBytes = [self hexStringToData:data];
    [payload appendData:pwdBytes];
    uint8_t b = bank & 0xFF;
    uint16_t p = htons((uint16_t)ptr);
    uint8_t l = len & 0xFF;
    [payload appendBytes:&b length:1];
    [payload appendBytes:&p length:2];
    [payload appendBytes:&l length:1];
    [payload appendData:dataBytes];
    return [self buildFrame:CMD_WRITE_TAG payload:payload];
}

- (NSData *)buildLockCommand:(NSString *)pwd lockCode:(NSString *)lockCode {
    NSMutableData *payload = [NSMutableData data];
    [payload appendData:[self hexStringToData:pwd]];
    [payload appendData:[self hexStringToData:lockCode]];
    return [self buildFrame:CMD_LOCK_TAG payload:payload];
}

- (NSData *)buildKillCommand:(NSString *)pwd {
    NSData *payload = [self hexStringToData:pwd];
    return [self buildFrame:CMD_KILL_TAG payload:payload];
}

- (NSData *)buildSetPowerCommand:(int)power {
    NSMutableData *payload = [NSMutableData data];
    // power as 2 bytes
    uint16_t p = htons((uint16_t)(power * 100));
    [payload appendBytes:&p length:2];
    return [self buildFrame:CMD_SET_POWER payload:payload];
}

- (NSData *)buildSetFrequencyCommand:(int)mode {
    NSMutableData *payload = [NSMutableData data];
    uint8_t m = mode & 0xFF;
    [payload appendBytes:&m length:1];
    return [self buildFrame:CMD_SET_FREQ payload:payload];
}

// ─── Response parser ─────────────────────────────────────────────────────────

- (void)processReceivedData:(NSData *)data {
    [self.receiveBuffer appendData:data];

    // Look for complete frames (0xBB ... 0x7E)
    while (self.receiveBuffer.length >= 5) {
        const uint8_t *bytes = self.receiveBuffer.bytes;
        if (bytes[0] != 0xBB) {
            // Discard until next 0xBB
            NSUInteger skip = 1;
            while (skip < self.receiveBuffer.length && bytes[skip] != 0xBB) skip++;
            [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, skip) withBytes:NULL length:0];
            continue;
        }
        if (self.receiveBuffer.length < 5) break;
        uint16_t payloadLen = (bytes[1] << 8) | bytes[2];
        NSUInteger frameLen = 4 + payloadLen + 1 + 1; // BB + len(2) + cmd + payload + checksum + 7E
        if (self.receiveBuffer.length < frameLen) break;
        if (bytes[frameLen - 1] != 0x7E) {
            [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, 1) withBytes:NULL length:0];
            continue;
        }
        uint8_t cmd    = bytes[3];
        NSData *payload = [self.receiveBuffer subdataWithRange:NSMakeRange(4, payloadLen)];
        [self.receiveBuffer replaceBytesInRange:NSMakeRange(0, frameLen) withBytes:NULL length:0];
        [self handleResponse:cmd payload:payload];
    }
}

- (void)handleResponse:(uint8_t)cmd payload:(NSData *)payload {
    const uint8_t *bytes = payload.bytes;
    BOOL success = (payload.length > 0 && bytes[0] == 0x00);

    switch (cmd) {
        case CMD_INVENTORY_START: {
            // Inventory data response: parse EPC from payload
            if (!self.isInventorying) break;
            if (payload.length < 4) break;
            // EPC starts at byte 2, length = payload[1] / 8 * 2 chars (in bytes)
            NSUInteger epcLen = bytes[1] / 8;
            if (payload.length < 2 + epcLen) break;
            NSData *epcData = [payload subdataWithRange:NSMakeRange(2, epcLen)];
            NSString *epc   = [self dataToHexString:epcData];
            if ([self.tagBuffer containsObject:epc]) break;
            if (self.filterEpc && self.filterEpc.length > 0 && ![self.filterEpc isEqualToString:epc]) break;
            [self.tagBuffer addObject:epc];
            if (self.hasListeners) {
                [self sendEventWithName:EVENT_READ_RFID body:@{
                    @"rfid_tag": epc,
                    @"rssi":     @"",
                }];
            }
            break;
        }
        case CMD_READ_TAG:
            if (self.pendingOp == OperationRead || self.pendingOp == OperationErase) {
                if (success && self.pendingResolve) {
                    // Data starts at byte 1
                    NSData *readData = [payload subdataWithRange:NSMakeRange(1, payload.length - 1)];
                    self.pendingResolve([self dataToHexString:readData]);
                } else if (self.pendingReject) {
                    self.pendingReject(@"READ_FAIL", @"Read tag failed", nil);
                }
                [self clearPending];
            }
            break;
        case CMD_WRITE_TAG:
            if (self.pendingOp == OperationWrite || self.pendingOp == OperationErase) {
                if (success && self.pendingResolve) self.pendingResolve(@YES);
                else if (self.pendingReject) self.pendingReject(@"WRITE_FAIL", @"Write tag failed", nil);
                [self clearPending];
            }
            break;
        case CMD_LOCK_TAG:
            if (self.pendingOp == OperationLock) {
                if (success && self.pendingResolve) self.pendingResolve(@YES);
                else if (self.pendingReject) self.pendingReject(@"LOCK_FAIL", @"Lock tag failed", nil);
                [self clearPending];
            }
            break;
        case CMD_KILL_TAG:
            if (self.pendingOp == OperationKill) {
                if (success && self.pendingResolve) self.pendingResolve(@YES);
                else if (self.pendingReject) self.pendingReject(@"KILL_FAIL", @"Kill tag failed", nil);
                [self clearPending];
            }
            break;
        case CMD_SET_POWER:
            if (self.pendingOp == OperationSetPower) {
                if (self.pendingResolve) self.pendingResolve(@(success));
                [self clearPending];
            }
            break;
        case CMD_SET_FREQ:
            if (self.pendingOp == OperationSetFrequency) {
                if (self.pendingResolve) self.pendingResolve(@(success));
                [self clearPending];
            }
            break;
        default:
            break;
    }
}

// ─── BLE write helper ────────────────────────────────────────────────────────

- (void)sendCommand:(NSData *)data {
    if (!self.connectedPeripheral || !self.writeCharacteristic) return;
    NSUInteger maxLen = 20; // BLE MTU typical max
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSUInteger chunkLen = MIN(maxLen, data.length - offset);
        NSData *chunk = [data subdataWithRange:NSMakeRange(offset, chunkLen)];
        [self.connectedPeripheral writeValue:chunk
                           forCharacteristic:self.writeCharacteristic
                                        type:CBCharacteristicWriteWithResponse];
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
