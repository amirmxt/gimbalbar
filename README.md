# GimbalBar

macOS menu bar app that controls the DJI Osmo Pocket 3 gimbal while it's connected as a USB webcam, with a live preview.

## How it works

The Pocket 3 exposes the standard UVC **Pan/Tilt Absolute** control (camera terminal 1, VideoControl interface 0, selector `0x0D`), as well as **Zoom Absolute** (selector `0x0B`) on the tested firmware. `ptz.c` sends `GET_CUR`/`GET_MIN`/`GET_MAX`/`SET_CUR` requests through IOKit. libusb can't do this on macOS because the system UVC driver owns the interface.

Ranges the camera reports: pan -35° to 215°, tilt -90° to 90°, in 1° steps.

Bluetooth (DJI's DUML protocol) was tested first. Pairing and telemetry work, but the Pocket 3 ignores every gimbal command over Bluetooth.

## Install

Download `GimbalBar.zip` from [Releases](../../releases), unzip, and move `GimbalBar.app` to `/Applications`. The app isn't notarized, so macOS will block it the first time. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/GimbalBar.app
```

Apple Silicon, macOS 14 or later. Plug the Pocket 3 in over USB-C and pick webcam mode on the camera.

## Build from source

```bash
./build.sh
cp -R GimbalBar.app /Applications/
```

Needs the Xcode command line tools.

## Controls

- Live camera preview, drag pad, arrow buttons, selectable 5°/15°/30° movement steps
- Center position and invert-pan settings
- Three persistent camera positions (P1–P3), with stepped software transitions; a new manual movement cancels the remaining transition
- Native camera zoom (tested 1×–4×): interactive slider, camera readback, and 1× reset. USB updates are coalesced during dragging; this is **not** a crop of the Mac preview
- Global shortcuts with enable/disable and selectable modifier profiles (Control–Option, Command–Option, or Control–Shift). Modifiers + arrows move, + C centers, and + 1/2/3 recalls saved positions
- A compact two-column menu panel without scrolling

The graduated motion controls **do not directly configure the gimbal motor speed**; they send a series of small absolute-position commands. Canceling a transition does not cancel a USB command already accepted by the camera.

## UVC capabilities and diagnostics

The tested Pocket 3 advertises zoom absolute values 100–400, corresponding to 1×–4×. The camera's UVC descriptors did **not** advertise exposure, focus, or white balance controls; these may still be adjustable on the camera itself but are not exposed here.

To inspect UVC capabilities on another unit or firmware revision, connect the camera in Webcam mode and run:

```bash
zsh ./diagnose.sh
zsh ./diagnose.sh --values
```

This standalone diagnostic reads USB descriptors and UVC capability/value requests only. It does not send any `SET_CUR` requests. See [UVC controls](docs/UVC_CONTROLS.md) and [hardware tests](docs/TESTING.md).

## Disclaimer

Not affiliated with or endorsed by DJI. Tested only on the Osmo Pocket 3.

Use at your own risk. This is a hobby project provided as is, with no warranty of any kind. It sends USB control commands that move the gimbal's motors. The author is not responsible or liable for any damage to your camera, gimbal, computer or data, voided warranties, injury, or any other loss that results from using, building or modifying this software. See the [LICENSE](LICENSE) for the full terms.

## License

MIT
