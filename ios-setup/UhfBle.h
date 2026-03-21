#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

@interface UhfBle : RCTEventEmitter <RCTBridgeModule, CBCentralManagerDelegate, CBPeripheralDelegate, NSStreamDelegate>

@end

NS_ASSUME_NONNULL_END
