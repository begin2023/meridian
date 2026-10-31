#ifndef DISPLAY_PRIVATE_H
#define DISPLAY_PRIVATE_H

#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>

// Declarations for private display APIs used by DisplayLab. Symbols are
// provided by the system frameworks (CoreGraphics.tbd, IOKit.tbd,
// CoreDisplay.tbd); nothing here has a local implementation. Availability is
// probed at runtime before use so missing symbols degrade gracefully.

// MARK: - IOAVService (IOKit, Apple Silicon AV service: DDC/CI + EDID)

typedef struct IOAVService *IOAVServiceRef;

extern IOAVServiceRef __nullable IOAVServiceCreate(CFAllocatorRef __nullable allocator);

extern IOAVServiceRef __nullable IOAVServiceCreateWithService(CFAllocatorRef __nullable allocator,
                                                              io_service_t service);

extern IOAVServiceRef __nullable IOAVServiceCreateWithLocation(CFAllocatorRef __nullable allocator,
                                                               CFStringRef __nullable location);

extern CFDataRef __nullable IOAVServiceCopyEDID(IOAVServiceRef service);

// Read `outputBufferSize` bytes from the I2C device at `chipAddress`,
// starting at register `offset`.
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void *outputBuffer,
                                   uint32_t outputBufferSize);

// Write `inputBufferSize` bytes to the I2C device at `chipAddress`,
// using `dataAddress` as the register/protocol address.
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

extern IOReturn IOAVServiceSetVirtualEDIDMode(IOAVServiceRef service, int mode);

// MARK: - CoreDisplay

// Returns a dictionary containing kCGDisplayUUID, kIODisplayLocation,
// kCGDisplayVendorNumber, kCGDisplayProductNumber and more. Caller releases.
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

// MARK: - CGS display modes (exported by CoreGraphics)

// Reverse-engineered mode description layout (length 0xD4). `density` is the
// backing scale factor: 2.0 marks a HiDPI mode. `refreshRate` is an integer
// frequency in Hz.
typedef struct CGSDisplayModeDescription {
    uint32_t mode;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t reserved[42];
    uint16_t reserved16;
    uint16_t refreshRate;
    uint32_t reserved2[4];
    float density;
} CGSDisplayModeDescription;

extern CGError CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int *nModes);

extern CGError CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display,
                                                    int index,
                                                    CGSDisplayModeDescription *description,
                                                    int length);

extern CGError CGSGetCurrentDisplayMode(CGDirectDisplayID display, int *modeNumber);

extern CGError CGSConfigureDisplayMode(CGDisplayConfigRef config,
                                       CGDirectDisplayID display,
                                       int modeNumber);

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          int enabled);

// MARK: - CGVirtualDisplay (ObjC classes exported by CoreGraphics)

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;
@property (readonly) NSUInteger width;
@property (readonly) NSUInteger height;
@property (readonly) CGFloat refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (dispatch_queue_t)dispatchQueue;
@property (copy) NSString *name;
@property NSUInteger maxPixelsWide;
@property NSUInteger maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property UInt32 serialNum;
@property UInt32 productID;
@property UInt32 vendorID;
@property UInt32 serialNumber;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (copy) NSArray<CGVirtualDisplayMode *> *modes;
@property NSUInteger hiDPI;
@property NSUInteger rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
@property (readonly) CGDirectDisplayID displayID;
@property (readonly) NSArray<CGVirtualDisplayMode *> *modes;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property NSUInteger hiDPI;
@end

#endif /* DISPLAY_PRIVATE_H */
