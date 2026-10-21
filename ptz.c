#include "ptz.h"
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#define VID 0x2ca3          // DJI
#define PID 0x0023          // Osmo Pocket 3
#define CT_PANTILT_ABS 0x0D // UVC camera terminal control selector
#define CT_ZOOM_ABS 0x0B // Standard UVC Camera Terminal zoom
#define WINDEX ((1 << 8) | 0) // camera terminal id 1, VideoControl interface 0

#define GET_CUR 0x81
#define GET_MIN 0x82
#define GET_MAX 0x83
#define SET_CUR 0x01

// Opens the device for one request; cheap enough at UI rates and survives replugging.
static IOUSBDeviceInterface **open_device(void) {
  CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
  int vid = VID, pid = PID;
  CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
  CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
  CFDictionarySetValue(match, CFSTR("idVendor"), v);
  CFDictionarySetValue(match, CFSTR("idProduct"), p);
  CFRelease(v);
  CFRelease(p);

  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
  if (!svc) return NULL;

  IOCFPlugInInterface **plug = NULL;
  SInt32 score;
  kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                       kIOCFPlugInInterfaceID, &plug, &score);
  IOObjectRelease(svc);
  if (kr || !plug) return NULL;

  IOUSBDeviceInterface **dev = NULL;
  (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
  IODestroyPlugInInterface(plug);
  return dev;
}

static int request(UInt8 type, UInt8 req, int32_t v[2]) {
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  IOUSBDevRequest r = {
    .bmRequestType = type, .bRequest = req,
    .wValue = CT_PANTILT_ABS << 8, .wIndex = WINDEX,
    .wLength = 8, .pData = v,
  };
  IOReturn kr = (*dev)->DeviceRequest(dev, &r);
  (*dev)->Release(dev);
  return kr ? -2 : 0;
}

static int get_pair(UInt8 req, double *pan, double *tilt) {
  int32_t v[2] = {0};
  int rc = request(0xA1, req, v);
  if (rc) return rc;
  *pan = v[0] / 3600.0; // UVC units are arc-seconds
  *tilt = v[1] / 3600.0;
  return 0;
}

int ptz_get(double *pan, double *tilt) {
  return get_pair(GET_CUR, pan, tilt);
}

int ptz_set(double pan, double tilt) {
  int32_t v[2] = { (int32_t)(pan * 3600), (int32_t)(tilt * 3600) };
  return request(0x21, SET_CUR, v);
}

int ptz_range(ptz_range_t *out) {
  int rc = get_pair(GET_MIN, &out->panMin, &out->tiltMin);
  return rc ? rc : get_pair(GET_MAX, &out->panMax, &out->tiltMax);
}

// Zoom uses an unsigned 16-bit little-endian value per the UVC specification.
// Its actual bounds are read from the connected camera (not guessed).
static int zoom_request(UInt8 type, UInt8 cmd, uint8_t bytes[2]) {
  IOUSBDeviceInterface **dev = open_device();
  if (!dev) return -1;
  IOUSBDevRequest r = {
    .bmRequestType = type, .bRequest = cmd,
    .wValue = CT_ZOOM_ABS << 8, .wIndex = WINDEX,
    .wLength = 2, .pData = bytes,
  };
  IOReturn kr = (*dev)->DeviceRequest(dev, &r);
  (*dev)->Release(dev);
  return kr == kIOReturnSuccess ? 0 : -2;
}

static int zoom_read(UInt8 cmd, int *value) {
  if (!value) return -3;
  uint8_t bytes[2] = {0, 0};
  int rc = zoom_request(0xA1, cmd, bytes);
  if (rc) return rc;
  *value = (int)bytes[0] | ((int)bytes[1] << 8);
  return 0;
}

int ptz_zoom_get(int *zoom) {
  return zoom_read(GET_CUR, zoom);
}

int ptz_zoom_range(int *minimum, int *maximum) {
  if (!minimum || !maximum) return -3;
  int rc = zoom_read(GET_MIN, minimum);
  if (rc) return rc;
  rc = zoom_read(GET_MAX, maximum);
  if (rc) return rc;
  // Refuse corrupt or unexpected bounds, never issue unbounded zoom requests.
  return (*minimum >= 1 && *maximum <= 1000 && *minimum < *maximum) ? 0 : -3;
}

int ptz_zoom_set(int zoom) {
  int minimum = 0, maximum = 0;
  int rc = ptz_zoom_range(&minimum, &maximum);
  if (rc) return rc;
  if (zoom < minimum || zoom > maximum) return -3;
  uint8_t bytes[2] = {
    (uint8_t)(zoom & 0xff), (uint8_t)((zoom >> 8) & 0xff)
  };
  return zoom_request(0x21, SET_CUR, bytes);
}

int ptz_zoom_set_checked(int zoom, int minimum, int maximum) {
  // This experimental driver accepts only the verified Pocket 3 zoom scale.
  // The caller has queried GET_MIN / GET_MAX after connecting.
  if (minimum < 100 || maximum > 400 || minimum >= maximum ||
      zoom < minimum || zoom > maximum) return -3;
  uint8_t bytes[2] = {
    (uint8_t)(zoom & 0xff), (uint8_t)((zoom >> 8) & 0xff)
  };
  return zoom_request(0x21, SET_CUR, bytes);
}
