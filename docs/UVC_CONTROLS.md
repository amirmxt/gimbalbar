# Pocket 3 UVC camera controls

## Observed hardware

On October 21, 2026, a DJI Osmo Pocket 3 was connected to an Apple Silicon Mac via USB-C in **Webcam** mode. The read-only scanner (`zsh ./diagnose.sh --values`) identified:

| UVC entity | Interface / ID | Descriptor | Result |
|---|---|---|---|
| Camera Terminal | VideoControl 0 / 1 | `bmControls=00 2A 00` | Absolute zoom and absolute pan/tilt advertised with GET and SET support |
| Processing Unit | VideoControl 0 / 2 | `bmControls=00 00` | No standard processing controls advertised |

### Zoom Absolute — CT selector `0x0B`

| Request | Raw little-endian bytes | Value | Meaning |
|---|---|---:|---|
| `GET_CUR` | `64 00` | 100 | 1× |
| `GET_MIN` | `64 00` | 100 | 1× |
| `GET_MAX` | `90 01` | 400 | 4× |

The camera reports `GET_INFO` read/write support and responds to actual `SET_CUR` zoom requests (tested visually from the Mac in Webcam mode). The scale used for the UI is integer hundredths: 100 = 1×, 400 = 4×.

Standard exposure, focus, white balance, and other Processing Unit controls **were not advertised** on this unit. This does not prove they are unavailable through the camera screen or proprietary DJI protocols.

## Implementation

`ptz.c` uses IOKit to issue USB class/interface requests because the system camera driver owns the UVC interface. The zoom selector is `0x0B`, terminal `1`, interface `0`; it carries a two-byte little-endian unsigned value.

The app queries actual zoom bounds after connecting and rejects values outside the observed safe range. The zoom UI coalesces requests to avoid a backlog of USB writes and keeps the requested slider position separate from the latest camera `GET_CUR` readback. Pan/tilt uses a shared serial queue, and camera reconnection reprobes the supported range.

**Do not assume an immediate `GET_CUR` response proves the visual zoom transition has finished.** The USB control may be acknowledged before the image processing catches up.

## Read-only scanner

```bash
zsh ./diagnose.sh
zsh ./diagnose.sh --values
```

The tool parses UVC terminal/unit descriptors and advertized bitmaps and makes class-specific `GET_INFO`, optionally `GET_CUR`, `GET_MIN`, and `GET_MAX` requests. It never sends `SET_CUR`, resets the USB device, or installs an application.

The source file is `tools/uvc_diag.c`. Its purpose is to verify other device/firmware revisions before enabling additional camera controls, rather than speculate about unsupported zoom/focus/exposure values.

## Safety and limitations

- Only tested with DJI Osmo Pocket 3 in Webcam mode on an Apple Silicon Mac.
- Changing native zoom affects the camera image provided to other apps.
- The source-only diagnostic needs local macOS compilation; no GitHub Actions are required.
- The motor safety disclaimer in the root [README](../README.md) still applies.
