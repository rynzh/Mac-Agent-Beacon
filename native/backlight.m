// Optional CoreBrightness adapter. No keyboard events or modifier mappings.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

@protocol BeaconBrightness
- (NSArray *)copyKeyboardBacklightIDs;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)keyboard;
- (float)brightnessForKeyboard:(unsigned long long)keyboard;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)keyboard;
- (BOOL)isIdleDimmingSuspendedOnKeyboard:(unsigned long long)keyboard;
- (BOOL)enableAutoBrightness:(BOOL)enabled forKeyboard:(unsigned long long)keyboard;
- (BOOL)suspendIdleDimming:(BOOL)suspended forKeyboard:(unsigned long long)keyboard;
- (BOOL)setBrightness:(float)brightness fadeSpeed:(int)speed commit:(BOOL)commit forKeyboard:(unsigned long long)keyboard;
@end

@interface BeaconBacklight : NSObject
@property(nonatomic, strong) id<BeaconBrightness> client;
@property(nonatomic) unsigned long long keyboard;
@property(nonatomic) float brightness;
@property(nonatomic) BOOL automatic;
@property(nonatomic) BOOL suspended;
@property(nonatomic) BOOL active;
- (BOOL)write:(BOOL)on;
- (BOOL)restore;
@end

@implementation BeaconBacklight
- (BOOL)write:(BOOL)on {
    if (!self.active) {
        self.brightness = [self.client brightnessForKeyboard:self.keyboard];
        if (!isfinite(self.brightness) || self.brightness < 0 || self.brightness > 1) return NO;
        self.automatic = [self.client isAutoBrightnessEnabledForKeyboard:self.keyboard];
        self.suspended = [self.client isIdleDimmingSuspendedOnKeyboard:self.keyboard];
        // Mark before changing either setting so partial failures also restore.
        self.active = YES;
        if (![self.client enableAutoBrightness:NO forKeyboard:self.keyboard] ||
            ![self.client suspendIdleDimming:YES forKeyboard:self.keyboard]) return NO;
    }
    // A dark keyboard still needs a visible alert; avoid forcing full brightness.
    float level = on ? fmaxf(self.brightness, 0.35f) : 0;
    return [self.client setBrightness:level fadeSpeed:0 commit:NO forKeyboard:self.keyboard];
}
- (BOOL)restore {
    if (!self.active) return YES;
    BOOL level = [self.client setBrightness:self.brightness fadeSpeed:0 commit:NO forKeyboard:self.keyboard];
    BOOL dimming = [self.client suspendIdleDimming:self.suspended forKeyboard:self.keyboard];
    BOOL sensor = [self.client enableAutoBrightness:self.automatic forKeyboard:self.keyboard];
    BOOL restored = level && dimming && sensor;
    if (restored) self.active = NO;
    return restored;
}
@end

#ifndef BEACON_BACKLIGHT_TEST
static volatile sig_atomic_t running = 1;
static void stop_running(int number) { (void)number; running = 0; }
static double monotonic_time(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static id<BeaconBrightness> brightness_client(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)) return nil;
    Class cls = NSClassFromString(@"KeyboardBrightnessClient");
    id client = [[cls alloc] init];
    // A private API may disappear on a future OS. Fail only this optional output.
    NSArray *selectors = @[@"copyKeyboardBacklightIDs", @"isKeyboardBuiltIn:", @"brightnessForKeyboard:",
        @"isAutoBrightnessEnabledForKeyboard:", @"isIdleDimmingSuspendedOnKeyboard:",
        @"enableAutoBrightness:forKeyboard:", @"suspendIdleDimming:forKeyboard:",
        @"setBrightness:fadeSpeed:commit:forKeyboard:"];
    for (NSString *name in selectors) if (![client respondsToSelector:NSSelectorFromString(name)]) return nil;
    return client;
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "serve"))) {
        fprintf(stderr, "Usage: beacon-backlight inspect|serve (stdin: 1=on, 0=off, r=restore, q=quit)\n");
        return 64;
    }
    @autoreleasepool {
        BeaconBacklight *light = [BeaconBacklight new];
        int result = 0;
        @try {
            light.client = brightness_client();
            if (!light.client) @throw [NSException exceptionWithName:@"Unavailable" reason:@"CoreBrightness keyboard API unavailable" userInfo:nil];
            NSArray *ids = [light.client copyKeyboardBacklightIDs];
            BOOL found = NO;
            if ([ids isKindOfClass:[NSArray class]]) {
                for (id key in ids) {
                    if ([key isKindOfClass:[NSNumber class]] && [light.client isKeyboardBuiltIn:[key unsignedLongLongValue]]) {
                        light.keyboard = [key unsignedLongLongValue]; found = YES; break;
                    }
                }
            }
            if (!found) @throw [NSException exceptionWithName:@"Unavailable" reason:@"No built-in keyboard backlight" userInfo:nil];
            if (!strcmp(argv[1], "inspect")) {
                NSDictionary *state = @{@"available": @YES, @"brightness": @([light.client brightnessForKeyboard:light.keyboard]),
                    @"auto_brightness": @([light.client isAutoBrightnessEnabledForKeyboard:light.keyboard]),
                    @"idle_dimming_suspended": @([light.client isIdleDimmingSuspendedOnKeyboard:light.keyboard])};
                NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
                if (!json) return 1;
                fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
            } else {
                signal(SIGINT, stop_running); signal(SIGTERM, stop_running); signal(SIGHUP, stop_running);
                signal(SIGPIPE, SIG_IGN);
                puts("ready"); fflush(stdout);
                double last = monotonic_time();
                struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP};
                while (running) {
                    int ready = poll(&input, 1, 100);
                    if (ready < 0) { if (errno == EINTR) continue; result = 1; break; }
                    // Restore if the parent freezes or stops sending the blinking phase.
                    if (!ready) {
                        if (light.active && monotonic_time() - last > 2 && ![light restore]) { result = 1; break; }
                        continue;
                    }
                    char command;
                    if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
                    if (command == '\n') continue;
                    if (command != '0' && command != '1' && command != 'r') { result = 64; break; }
                    last = monotonic_time();
                    BOOL ok = command == 'r' ? [light restore] : [light write:command == '1'];
                    if (!ok) { fprintf(stderr, "Keyboard backlight write failed\n"); result = 1; break; }
                    if (puts("ok") == EOF || fflush(stdout) == EOF) { result = 1; break; }
                }
            }
        } @catch (NSException *exception) {
            fprintf(stderr, "Keyboard backlight unavailable: %s\n", exception.reason.UTF8String);
            result = 1;
        } @finally {
            @try {
                if (![light restore]) { fprintf(stderr, "Could not restore keyboard backlight settings\n"); result = 1; }
            } @catch (NSException *exception) {
                (void)exception; fprintf(stderr, "Keyboard backlight restoration failed\n"); result = 1;
            }
        }
        return result;
    }
}
#endif
