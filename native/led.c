/* Adapted from CapsPulse (MIT), Copyright (c) 2026 ssk090.
 * See THIRD_PARTY_NOTICES.md. This program writes LED output only. */
#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDLib.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

static volatile sig_atomic_t running = 1;
static void stop_running(int number) { (void)number; running = 0; }
static bool logical_caps(void) {
    return (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & kCGEventFlagMaskAlphaShift) != 0;
}
static bool write_led(IOHIDDeviceRef device, IOHIDElementRef element, bool on) {
    IOHIDValueRef value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, on);
    if (!value) return false;
    IOReturn result = IOHIDDeviceSetValue(device, element, value);
    CFRelease(value);
    if (result != kIOReturnSuccess) fprintf(stderr, "LED write failed: 0x%x\n", result);
    return result == kIOReturnSuccess;
}
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "serve"))) {
        fprintf(stderr, "Usage: beacon-led inspect|serve (stdin: 1=on, 0=off, r=restore, q=quit)\n");
        return 64;
    }
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) return 1;
    const void *keys[] = {CFSTR(kIOHIDProductKey), CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey)};
    int page = kHIDPage_GenericDesktop;
    int usage = kHIDUsage_GD_Keyboard;
    CFNumberRef page_value = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usage_value = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *values[] = {CFSTR("Apple Internal Keyboard / Trackpad"), page_value, usage_value};
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching); CFRelease(page_value); CFRelease(usage_value);
    IOHIDDeviceRef target = NULL;
    IOHIDElementRef output = NULL;
    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices) {
        CFIndex count = CFSetGetCount(devices);
        const void **list = calloc((size_t)count, sizeof(*list));
        if (list) {
            CFSetGetValues(devices, list);
            for (CFIndex i = 0; i < count && !output; i++) {
                IOHIDDeviceRef device = (IOHIDDeviceRef)list[i];
                CFTypeRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
                if (!product || CFGetTypeID(product) != CFStringGetTypeID() ||
                    CFStringCompare(product, CFSTR("Apple Internal Keyboard / Trackpad"), 0) != kCFCompareEqualTo) continue;
                CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
                if (!elements) continue;
                for (CFIndex j = 0; j < CFArrayGetCount(elements); j++) {
                    IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, j);
                    if (IOHIDElementGetUsagePage(el) == kHIDPage_LEDs && IOHIDElementGetUsage(el) == kHIDUsage_LED_CapsLock && IOHIDElementGetType(el) == kIOHIDElementTypeOutput) {
                        target = (IOHIDDeviceRef)CFRetain(device);
                        output = (IOHIDElementRef)CFRetain(el); break;
                    }
                }
                CFRelease(elements);
            }
            free(list);
        }
        CFRelease(devices);
    }
    int result = 0;
    if (!output) { fprintf(stderr, "No accessible built-in Caps Lock LED. Karabiner or Input Monitoring may restrict access.\n"); result = 1; }
    else if (!strcmp(argv[1], "inspect")) {
        printf("{\"keyboard\":\"Apple Internal Keyboard / Trackpad\",\"led_output\":true,\"logical_caps_lock\":%s}\n", logical_caps() ? "true" : "false");
    } else {
        IOReturn opened = IOHIDDeviceOpen(target, kIOHIDOptionsTypeNone);
        if (opened != kIOReturnSuccess) {
            fprintf(stderr, "Cannot open keyboard LED output: 0x%x (%s). No key mapping or modifier state changed.\n", opened, mach_error_string(opened));
            CFRelease(output); CFRelease(target); CFRelease(manager);
            return 1;
        }
        signal(SIGINT, stop_running); signal(SIGTERM, stop_running); signal(SIGHUP, stop_running);
        puts("ready"); fflush(stdout);
        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN | POLLHUP};
        while (running) {
            int ready = poll(&input, 1, 250);
            if (ready < 0) { if (errno == EINTR) continue; result = 1; break; }
            if (!ready) continue;
            char command;
            if (read(STDIN_FILENO, &command, 1) != 1 || command == 'q') break;
            if (command == '\n') continue;
            if (command != '0' && command != '1' && command != 'r') { result = 64; break; }
            bool before = logical_caps();
            if (!write_led(target, output, command == 'r' ? before : command == '1')) { result = 2; break; }
            if (logical_caps() != before) { fprintf(stderr, "Logical Caps Lock changed during LED write; stopping.\n"); result = 3; break; }
            puts("ok"); fflush(stdout);
        }
        if (!write_led(target, output, logical_caps())) result = 2;
        IOHIDDeviceClose(target, kIOHIDOptionsTypeNone);
    }
    if (output) CFRelease(output);
    if (target) CFRelease(target);
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone); CFRelease(manager);
    return result;
}
