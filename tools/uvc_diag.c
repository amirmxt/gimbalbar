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
    { "Exposicao automatica (AE)", 0x02,  1, 1 },
    { "Tempo de exposicao",        0x04,  3, 4 },
    { "Foco manual",               0x06,  5, 2 },
    { "Foco automatico",           0x08, 17, 1 },
    { "Zoom absoluto",             0x0b,  9, 2 },
    { "Pan/Tilt absoluto",         0x0d, 11, 8 }
};

static const Probe processingProbes[] = {
    { "Brilho",                    0x02,  0, 2 },
    { "Contraste",                 0x03,  1, 2 },
    { "Ganho",                     0x04,  9, 2 },
    { "Saturacao",                 0x07,  3, 2 },
    { "Nitidez",                   0x08,  4, 2 },
    { "Temperatura de branco",     0x0a,  6, 2 },
    { "Branco automatico",         0x0b, 12, 1 },
    { "Compensacao de contraluz",  0x01,  8, 2 }
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
            printf("  %-28s : nao anunciado\n", p->name);
            continue;
        }

        uint8_t info = 0;
        IOReturn err = read_uvc(device, iface, entity, p->selector,
                                GET_INFO, &info, 1);
        if (err != kIOReturnSuccess) {
            printf("  %-28s : anunciado; GET_INFO falhou (0x%08x)\n",
                   p->name, (unsigned)err);
            continue;
        }
        printf("  %-28s : anunciado; GET=%s; SET=%s\n",
               p->name, (info & 0x01) ? "sim" : "nao",
               (info & 0x02) ? "sim" : "nao");

        if (!values || !(info & 0x01)) continue;

        const struct { uint8_t command; const char *label; } reads[] = {
            { GET_CUR, "atual" }, { GET_MIN, "minimo" }, { GET_MAX, "maximo" }
        };
        for (size_t j = 0; j < sizeof(reads) / sizeof(reads[0]); ++j) {
            uint8_t buffer[8] = {0};
            err = read_uvc(device, iface, entity, p->selector,
                           reads[j].command, buffer, p->valueSize);
            if (err == kIOReturnSuccess) {
                print_value(reads[j].label, buffer, p->valueSize);
            } else {
                printf("      %s: indisponivel (0x%08x)\n",
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
        printf("Configuracao %u: descritor indisponivel (0x%08x)\n",
               configurationIndex, (unsigned)err);
        return 0;
    }
    const uint8_t *bytes = (const uint8_t *)config;
    const size_t total = (size_t)bytes[2] | ((size_t)bytes[3] << 8);
    if (total < 9 || total > 65535) {
        printf("Descritor de configuracao invalido\n");
        return 0;
    }

    printf("Configuracao %u: %zu bytes de descritores\n",
           configurationIndex, total);
    bool videoControlInterface = false;
    uint8_t interfaceID = 0;
    unsigned entities = 0;

    for (size_t offset = 0; offset + 2 <= total;) {
        const uint8_t *descriptor = bytes + offset;
        const size_t length = descriptor[0];
        if (length < 2 || length > total - offset) {
            printf("Descritor truncado/invalido em %zu; interrompendo\n", offset);
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
        fprintf(stderr, "Uso: uvc_diag [--values]\n");
        return 2;
    }
    if (argc == 2) values = true;

    printf("GimbalBar 1.2 — diagnostico USB UVC (SOMENTE LEITURA)\n");
    printf("DJI Osmo Pocket 3 VID=0x%04x PID=0x%04x\n", DJI_VENDOR, POCKET3_PRODUCT);
    printf("Modo: descritores + GET_INFO%s. Nenhum comando SET sera enviado.\n\n",
           values ? " + GET_CUR/GET_MIN/GET_MAX" : "");

    IOUSBDeviceInterface **device = open_pocket3();
    if (!device) {
        fprintf(stderr, "Pocket 3 nao localizada. Conecte por USB-C e selecione Webcam.\n");
        return 1;
    }

    uint8_t configurationCount = 0;
    IOReturn err = (*device)->GetNumberOfConfigurations(device, &configurationCount);
    if (err != kIOReturnSuccess) {
        fprintf(stderr, "Falha ao consultar configuracoes: 0x%08x\n", (unsigned)err);
        (*device)->Release(device);
        return 1;
    }
    printf("Configuracoes USB: %u\n", configurationCount);
    unsigned discovered = 0;
    for (uint8_t i = 0; i < configurationCount; ++i)
        discovered += inspect_configuration(device, i, values);

    (*device)->Release(device);
    if (discovered == 0) {
        fprintf(stderr,
                "\nNenhum terminal UVC identificado. Nao significa ausencia de recursos;\n"
                "verifique modo Webcam, descritores e permissoes do sistema.\n");
        return 3;
    }
    printf("\nEntidades UVC identificadas: %u\n", discovered);
    printf("Lembrete: controles anunciados nao garantem acesso pratico no macOS.\n");
    return 0;
}
