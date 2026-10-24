#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(
    CFAllocatorRef allocator, uint32_t type, CFDictionaryRef attributes);

static volatile sig_atomic_t running = 1;
static void stop_running(int number) { (void)number; running = 0; }
static bool logical_caps(void) {
    return (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & kCGEventFlagMaskAlphaShift) != 0;
}
static bool truthy(CFTypeRef value) {
    if (!value) return false;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue(value);
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        return CFNumberGetValue(value, kCFNumberIntType, &number) && number != 0;
    }
    return false;
}
static bool service_is_builtin(IOHIDServiceClientRef service) {
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, CFSTR("Built-In"));
    bool result = truthy(value);
    if (value) CFRelease(value);
    return result;
}
static bool override_led(IOHIDEventSystemClientRef client, CFStringRef mode) {
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return false;
    bool found = false;
    bool accepted = false;
    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        if (!IOHIDServiceClientConformsTo(service, kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard) ||
            !service_is_builtin(service)) continue;
        found = true;
        accepted |= IOHIDServiceClientSetProperty(service, CFSTR("HIDCapsLockLED"), mode);
    }
    CFRelease(services);
    return found && accepted;
}
static IOHIDEventSystemClientRef create_override_client(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 2, NULL);
    if (!client || !override_led(client, CFSTR("Auto"))) {
        if (client) CFRelease(client);
        return NULL;
    }
    return client;
}
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "inspect") && strcmp(argv[1], "serve"))) {
        fprintf(stderr, "Usage: beacon-led inspect|serve (stdin: 1=on, 0=off, r=restore, q=quit)\n");
        return 64;
    }
    IOHIDEventSystemClientRef override = create_override_client();
    if (!override) {
        fprintf(stderr, "Built-in Caps Lock LED ownership is unavailable. No key state or mapping was changed.\n");
        return 1;
    }
    int result = 0;
    if (!strcmp(argv[1], "inspect")) {
        printf("{\"keyboard\":\"Apple Internal Keyboard / Trackpad\",\"led_output\":true,\"ownership\":\"system_override\",\"logical_caps_lock\":%s}\n",
            logical_caps() ? "true" : "false");
    } else {
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
            bool written = override_led(override, command == 'r' ? CFSTR("Auto") : command == '1' ? CFSTR("On") : CFSTR("Off"));
            if (!written) { result = 2; break; }
            if (logical_caps() != before) { fprintf(stderr, "Logical Caps Lock changed during LED write; stopping.\n"); result = 3; break; }
            puts("ok"); fflush(stdout);
        }
        if (!override_led(override, CFSTR("Auto"))) result = 2;
    }
    CFRelease(override);
    return result;
}
