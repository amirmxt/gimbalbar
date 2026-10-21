// GimbalBar 1.2: read-only UVC discovery for DJI Osmo Pocket 3.
// Never sends SET_CUR, USB reset, interface claim, or configuration changes.
// Standalone tool: does not alter GimbalBar.app or its existing PTZ driver.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { DJI_VENDOR = 0x2ca3, POCKET3_PRODUCT = 0x0023 };
enum { USB_DESC_INTERFACE = 0x04, USB_DESC_CS_INTERFACE = 0x24 };
enum { UVC_CLASS = 0x0e, UVC_VIDEO_CONTROL = 0x01 };
enum { VC_INPUT_TERMINAL = 0x02, VC_PROCESSING_UNIT = 0x05 };
enum { GET_CUR = 0x81, GET_MIN = 0x82, GET_MAX = 0x83, GET_INFO = 0x86 };

typedef struct {
    const char *name;
    uint8_t selector;
    uint8_t advertisedBit;
    uint8_t valueSize;
} Probe;

static const Probe cameraProbes[] = {
    { "Auto exposure (AE)", 0x02,  1, 1 },
    { "Exposure time",        0x04,  3, 4 },
    { "Manual focus",               0x06,  5, 2 },
    { "Auto focus",           0x08, 17, 1 },
    { "Absolute zoom",             0x0b,  9, 2 },
    { "Absolute pan/tilt",         0x0d, 11, 8 }
};

static const Probe processingProbes[] = {
    { "Brightness",                    0x02,  0, 2 },
    { "Contrast",                 0x03,  1, 2 },
    { "Gain",                     0x04,  9, 2 },
    { "Saturation",                 0x07,  3, 2 },
    { "Sharpness",                   0x08,  4, 2 },
    { "White balance temperature",     0x0a,  6, 2 },
    { "Auto white balance",         0x0b, 12, 1 },
    { "Backlight compensation",  0x01,  8, 2 }
};

static IOUSBDeviceInterface **open_pocket3(void) {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (!match) return NULL;
    int vendor = DJI_VENDOR, product = POCKET3_PRODUCT;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &product);
    if (!v || !p) {
        if (v) CFRelease(v);
        if (p) CFRelease(p);
        CFRelease(match);
        return NULL;
    }
    CFDictionarySetValue(match, CFSTR("idVendor"), v);
    CFDictionarySetValue(match, CFSTR("idProduct"), p);
    CFRelease(v);
    CFRelease(p);

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    // The matching service call consumes 'match'.
    if (!service) return NULL;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score
    );
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plugin) return NULL;

    IOUSBDeviceInterface **device = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device
    );
    IODestroyPlugInInterface(plugin);
    return hr == S_OK ? device : NULL;
}

static bool is_advertised(const uint8_t *bitmap, size_t n, unsigned bit) {
    return bit / 8 < n && (bitmap[bit / 8] & (uint8_t)(1u << (bit % 8))) != 0;
}

static IOReturn read_uvc(IOUSBDeviceInterface **device, uint8_t iface,
                         uint8_t entity, uint8_t selector, uint8_t command,
                         void *data, uint16_t length) {
    // Hard restriction: the tool only issues four read requests.
    if (command != GET_INFO && command != GET_CUR &&
        command != GET_MIN && command != GET_MAX) return kIOReturnUnsupported;
    IOUSBDevRequest request = {
        .bmRequestType = 0xa1,  // class/interface/device-to-host (read only)
        .bRequest = command,
        .wValue = (UInt16)selector << 8,
        .wIndex = ((UInt16)entity << 8) | iface,
        .wLength = length,
        .pData = data
    };
    return (*device)->DeviceRequest(device, &request);
}

static void print_value(const char *label, const uint8_t *bytes, size_t length) {
    printf("      %s: 0x", label);
    // Values remain raw little-endian bytes: no unverified units/scale.
    for (size_t i = 0; i < length; ++i) printf("%02x", bytes[i]);
    printf("\n");
}

static void probe_controls(IOUSBDeviceInterface **device, uint8_t iface,
                           uint8_t entity, const uint8_t *bitmap, size_t size,
                           const Probe *items, size_t count, bool values) {
    for (size_t i = 0; i < count; ++i) {
        const Probe *p = &items[i];
        if (!is_advertised(bitmap, size, p->advertisedBit)) {
            printf("  %-28s : not advertised\n", p->name);
            continue;
        }

        uint8_t info = 0;
        IOReturn err = read_uvc(device, iface, entity, p->selector,
                                GET_INFO, &info, 1);
        if (err != kIOReturnSuccess) {
            printf("  %-28s : advertised; GET_INFO failed (0x%08x)\n",
                   p->name, (unsigned)err);
            continue;
        }
        printf("  %-28s : advertised; GET=%s; SET=%s\n",
               p->name, (info & 0x01) ? "yes" : "no",
               (info & 0x02) ? "yes" : "no");

        if (!values || !(info & 0x01)) continue;

        const struct { uint8_t command; const char *label; } reads[] = {
            { GET_CUR, "current" }, { GET_MIN, "minimum" }, { GET_MAX, "maximum" }
        };
        for (size_t j = 0; j < sizeof(reads) / sizeof(reads[0]); ++j) {
            uint8_t buffer[8] = {0};
            err = read_uvc(device, iface, entity, p->selector,
                           reads[j].command, buffer, p->valueSize);
            if (err == kIOReturnSuccess) {
                print_value(reads[j].label, buffer, p->valueSize);
            } else {
                printf("      %s: unavailable (0x%08x)\n",
                       reads[j].label, (unsigned)err);
            }
        }
    }
}

static unsigned inspect_configuration(IOUSBDeviceInterface **device,
                                      uint8_t configurationIndex, bool values) {
    IOUSBConfigurationDescriptorPtr config = NULL;
    IOReturn err = (*device)->GetConfigurationDescriptorPtr(
        device, configurationIndex, &config
    );
    if (err != kIOReturnSuccess || !config) {
        printf("Configuration %u: descriptor unavailable (0x%08x)\n",
               configurationIndex, (unsigned)err);
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)config;
    const size_t total = (size_t)bytes[2] | ((size_t)bytes[3] << 8);
    if (total < 9 || total > 65535) {
        printf("Invalid configuration descriptor\n");
        return 0;
    }

    printf("Configuration %u: %zu descriptor bytes\n",
           configurationIndex, total);
    bool videoControlInterface = false;
    uint8_t interfaceID = 0;
    unsigned entities = 0;

    for (size_t offset = 0; offset + 2 <= total;) {
        const uint8_t *descriptor = bytes + offset;
        const size_t length = descriptor[0];
        if (length < 2 || length > total - offset) {
            printf("Truncated/invalid descriptor at %zu; stopping\n", offset);
            break;
        }
        const uint8_t type = descriptor[1];

        if (type == USB_DESC_INTERFACE && length >= 9) {
            videoControlInterface = descriptor[5] == UVC_CLASS &&
                                    descriptor[6] == UVC_VIDEO_CONTROL;
            interfaceID = descriptor[2];
        } else if (videoControlInterface && type == USB_DESC_CS_INTERFACE &&
                   length >= 4) {
            const uint8_t subtype = descriptor[2];
            if (subtype == VC_INPUT_TERMINAL && length >= 15) {
                const uint16_t terminalType = (uint16_t)descriptor[4] |
                                              ((uint16_t)descriptor[5] << 8);
                if (terminalType == 0x0201) {
                    const uint8_t size = descriptor[14];
                    if ((size_t)15 + size <= length) {
                        ++entities;
                        printf("\nCamera Terminal: id=%u, interface=%u, bitmap=",
                               descriptor[3], interfaceID);
                        for (size_t i = 0; i < size; ++i)
                            printf("%02x", descriptor[15 + i]);
                        printf("\n");
                        probe_controls(device, interfaceID, descriptor[3],
                                       descriptor + 15, size,
                                       cameraProbes, sizeof(cameraProbes)/sizeof(cameraProbes[0]),
                                       values);
                    }
                }
            } else if (subtype == VC_PROCESSING_UNIT && length >= 8) {
                const uint8_t size = descriptor[7];
                if ((size_t)8 + size <= length) {
                    ++entities;
                    printf("\nProcessing Unit: id=%u, interface=%u, bitmap=",
                           descriptor[3], interfaceID);
                    for (size_t i = 0; i < size; ++i)
                        printf("%02x", descriptor[8 + i]);
                    printf("\n");
                    probe_controls(device, interfaceID, descriptor[3],
                                   descriptor + 8, size,
                                   processingProbes, sizeof(processingProbes)/sizeof(processingProbes[0]),
                                   values);
                }
            }
        }
        offset += length;
    }
    return entities;
}

int main(int argc, char **argv) {
    bool values = false;
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--values") != 0)) {
        fprintf(stderr, "Usage: uvc_diag [--values]\n");
        return 2;
    }
    if (argc == 2) values = true;

    printf("GimbalBar 1.2 — USB UVC diagnostics (READ ONLY)\n");
    printf("DJI Osmo Pocket 3 VID=0x%04x PID=0x%04x\n", DJI_VENDOR, POCKET3_PRODUCT);
    printf("Mode: descriptors + GET_INFO%s. No SET command will be sent.\n\n",
           values ? " + GET_CUR/GET_MIN/GET_MAX" : "");

    IOUSBDeviceInterface **device = open_pocket3();
    if (!device) {
        fprintf(stderr, "Pocket 3 not found. Connect via USB-C and select Webcam mode.\n");
        return 1;
    }

    uint8_t configurationCount = 0;
    IOReturn err = (*device)->GetNumberOfConfigurations(device, &configurationCount);
    if (err != kIOReturnSuccess) {
        fprintf(stderr, "Failed to query configurations: 0x%08x\n", (unsigned)err);
        (*device)->Release(device);
        return 1;
    }
    printf("USB configurations: %u\n", configurationCount);
    unsigned discovered = 0;
    for (uint8_t i = 0; i < configurationCount; ++i)
        discovered += inspect_configuration(device, i, values);

    (*device)->Release(device);
    if (discovered == 0) {
        fprintf(stderr,
                "\nNo UVC terminal found. This does not prove lack of controls;\n"
                "check Webcam mode, descriptors and system permissions.\n");
        return 3;
    }
    printf("\nUVC entities found: %u\n", discovered);
    printf("Note: advertised controls do not guarantee practical macOS access.\n");
    return 0;
}
