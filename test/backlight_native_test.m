#define BEACON_BACKLIGHT_TEST
#import "../native/backlight.m"
#include <assert.h>

@interface FakeBrightness : NSObject <BeaconBrightness>
@property(nonatomic) float level;
@property(nonatomic) BOOL automatic;
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL failDimming;
@end
@implementation FakeBrightness
- (NSArray *)copyKeyboardBacklightIDs { return @[@1]; }
- (BOOL)isKeyboardBuiltIn:(unsigned long long)key { (void)key; return YES; }
- (float)brightnessForKeyboard:(unsigned long long)key { (void)key; return self.level; }
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)key { (void)key; return self.automatic; }
- (BOOL)isIdleDimmingSuspendedOnKeyboard:(unsigned long long)key { (void)key; return self.suspended; }
- (BOOL)enableAutoBrightness:(BOOL)value forKeyboard:(unsigned long long)key { (void)key; self.automatic = value; return YES; }
- (BOOL)suspendIdleDimming:(BOOL)value forKeyboard:(unsigned long long)key {
    (void)key; self.suspended = value;
    if (self.failDimming) { self.failDimming = NO; return NO; }
    return YES;
}
- (BOOL)setBrightness:(float)value fadeSpeed:(int)speed commit:(BOOL)commit forKeyboard:(unsigned long long)key {
    (void)key; assert(speed == 0); assert(!commit); self.level = value; return YES;
}
@end

int main(void) {
    @autoreleasepool {
        FakeBrightness *client = [FakeBrightness new];
        BeaconBacklight *light = [BeaconBacklight new]; light.client = client; light.keyboard = 1;
        // The first phase may be dark. Snapshot before either phase, and restore
        // both sensor/dimming settings, including non-default starting values.
        for (int automatic=0; automatic<2; automatic++) {
            for (int suspended=0; suspended<2; suspended++) {
                client.level = 0.23f; client.automatic = automatic; client.suspended = suspended;
                assert([light write:NO]); assert(client.level == 0); assert(!client.automatic); assert(client.suspended);
                assert([light write:YES]); assert(fabsf(client.level - 0.35f) < 0.001f);
                assert([light restore]); assert(fabsf(client.level - 0.23f) < 0.001f);
                assert(client.automatic == automatic); assert(client.suspended == suspended);
            }
        }
        client.level = 0.8f; client.automatic = YES; client.suspended = NO;
        assert([light write:YES]); assert(client.level == 0.8f); assert([light restore]);
        // Failed takeover must still undo the setting that already succeeded.
        client.failDimming = YES;
        assert(![light write:YES]); assert([light restore]);
        assert(client.automatic); assert(!client.suspended); assert(client.level == 0.8f);
        client.level = NAN;
        assert(![light write:YES]); assert(!light.active); assert(client.automatic);
        puts("Native backlight snapshot/restore tests passed (fake backend, no hardware writes).");
    }
    return 0;
}
