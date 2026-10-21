# GimbalBar: build and hardware verification

This fork is under active development. The original project's MIT license and upstream history are preserved.

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select -p`)
- DJI Osmo Pocket 3 connected by USB-C with **Webcam** mode selected
- macOS camera permission for GimbalBar

## Build and run the development branch

```bash
cd ~/Projects/gimbalbar
git fetch origin
git switch --track origin/feat/usb-preview-reliability
./build.sh
open ./GimbalBar.app
```

If that branch already exists locally, use `git switch feat/usb-preview-reliability` followed by `git pull --ff-only`.

Build locally; do not run GitHub Actions merely to validate this iteration. The build script replaces `build/` and `GimbalBar.app/` **inside the repository**, but does not install anything into `/Applications`.

## Swift 6.4 / Command Line Tools troubleshooting

If the compiler reports `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`, the issue can arise from the Command Line Tools compiler lacking the `SwiftUIMacros` plugin. The source uses `@StoredState` (an alias for the `SwiftUI.State` property wrapper) instead of direct `@State` to avoid the macro dependency.

To inspect your environment:

```bash
xcode-select -p
xcrun --find swiftc
swiftc --version
```

After fetching this branch, run `./build.sh` again. A successful build ends with `Built .../GimbalBar.app`. Only run `open ./GimbalBar.app` after that message. Do not interpret the creation of an incomplete `.app` directory as a successful compilation.

Reference: https://github.com/drumih/turbo-fieldfare/issues/185 and https://github.com/drumih/turbo-fieldfare/pull/186

## Manual smoke tests

1. **Without camera:** Open GimbalBar. The menu panel should report "Not connected" / "Pocket 3 not found". Buttons must not queue physical movements.
2. **Attach the camera:** Plug in the Pocket 3 and select Webcam mode. Confirm the connection indicator, preview, and reported pan/tilt position update.
3. **Movement:** With the camera on a stable surface and the gimbal unobstructed, select a 5° step and move once in each direction. Confirm the actual movement. Test center once.
4. **High-frequency control:** Drag the movement pad briefly. Confirm commands do not accumulate or keep moving after the drag ends.
5. **Hot unplug/replug with panel open:** Remove USB, verify preview/status update, reconnect in Webcam mode, and verify the preview and pan/tilt return *without restarting the app*.
6. **Hot unplug/replug with panel closed:** Repeat with the popover closed and reopen it after reconnection.
7. **Stress test:** Repeat reconnection three times; verify no duplicated preview sessions, frozen UI, or stale camera input.
8. **Global shortcuts:** Test Control-Option + arrows and Control-Option-C from another app; document any conflicting system shortcuts.
9. **Camera authorization:** Revoke permission in System Settings and relaunch; verify a visible explanatory status.

## Expected limitations

- This is a source-only development change; **no Mac build or physical Pocket 3 test has been run by the GitHub connector**.
- Disconnect/reconnect depends on macOS delivering AVCaptureDevice connection notifications.
- One probe of pan/tilt limits is attempted per detected USB connection; fallback values remain when the camera cannot report limits.
- Software must not be assumed to prevent collisions or protect gimbal motors.

## Release gate

Do not merge to `main` or replace a working installation until compilation and the smoke tests pass. Record the macOS version, Swift compiler version (`swiftc --version`), camera firmware version, failures, and relevant console output in the PR.
