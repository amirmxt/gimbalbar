# GimbalBar — building and hardware testing

This is an optional local smoke-test checklist for the DJI Osmo Pocket 3 USB webcam. Development builds should be tested with the actual camera: the IOKit UVC interface cannot be fully validated on a CI runner.

## Requirements

- Apple Silicon Mac running macOS 14 or later
- Xcode Command Line Tools
- DJI Osmo Pocket 3 connected via USB-C in **Webcam** mode
- Camera access allowed in macOS System Settings

## Build a standalone test copy

```bash
./build.sh
open ./GimbalBar.app
```

The build script recreates `build/` and `GimbalBar.app/` **inside the repository**. It does not overwrite `/Applications/GimbalBar.app`. Close other running GimbalBar instances during testing to avoid conflicts with global hotkeys.

## Smoke tests

1. **No camera:** Panel reports a disconnected device. Camera controls should not send motor commands.
2. **Connect:** Plug in the Pocket 3 in Webcam mode. Confirm the connection indicator, live preview, and real pan/tilt values.
3. **Manual controls:** Try a small 5° movement with each arrow, drag the control pad, invert pan, and recenter.
4. **USB reconnection:** Disconnect/reconnect with the panel open, then closed. The preview and motor control should recover without relaunching.
5. **Saved positions:** Save P1/P2/P3; recall them one at a time. The transition should be made of small steps rather than one instantaneous far target. Confirm they persist after restarting the app.
6. **Interrupt movement:** Start recalling a saved position, then press Stop or move manually. No further software steps should queue. A command already received by the gimbal may still finish.
7. **Native zoom:** Confirm the camera-advertised range. Start from 1×, request approximately 1.2×, then 2×, then reset to 1×. Verify the actual image changes; the selected slider target and readback from the camera should converge after movement ends.
8. **Zoom while dragging:** Slowly drag 1×→2×. The UI should remain responsive. Intermediate requests should be coalesced, and pressing the 1× reset button should supersede the prior target.
9. **Global shortcuts:** Check Control–Option + arrows/C/1–3 from another app. Switch to Command–Option and Control–Shift, and verify that disabling shortcuts unregisters them. Some combinations may be reserved by macOS.
10. **Authorization:** Revoke camera permission and relaunch; confirm a useful error message.

Motor movements should be tested with the gimbal on a stable surface and unobstructed. Do not run tests unattended or during important recordings.

## Known constraints

- Zoom control is based on the standard Camera Terminal Zoom Absolute UVC selector `0x0B`, **not** on a crop inside the preview.
- A tested Pocket 3 reported `GET_MIN=100`, `GET_MAX=400`, corresponding to 1×–4×. The runtime probes its range and refuses unsupported values.
- The tested firmware did not advertise UVC exposure, focus, or white-balance controls.
- Interpolated pan/tilt is software stepping; UVC does not provide this code a motor-speed setting.
- A fast response from `SET_CUR` does not necessarily mean the lens/ISP has completed its digital zoom. The panel displays separately the requested target and camera-reported `GET_CUR`.
- Real-device testing of the contributor's fork was completed on October 21, 2026 with a Pocket 3 in Webcam mode, including restored preview after reconnection, presets, and responsive zoom. This PR has not run automated hardware tests.

## Swift toolchain warning

On one Apple Silicon Command Line Tools installation, direct `@State` usage required a SwiftUIMacros plugin unavailable to the compiler. The code therefore uses an alias to `SwiftUI.State` for the drag property. If the build fails, capture `swiftc --version`, `xcode-select -p`, and the complete diagnostics.

## Source and licensing

This checklist accompanies the [GimbalBar](https://github.com/amirmxt/gimbalbar) project. The original author's MIT license and attribution are retained.
