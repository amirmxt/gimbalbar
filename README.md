# GimbalBar

macOS menu bar app that controls the DJI Osmo Pocket 3 gimbal while it's connected as a USB webcam, with a live preview.

## How it works

The Pocket 3 exposes the standard UVC **Pan/Tilt Absolute** control (camera terminal 1, VideoControl interface 0, selector `0x0D`). `ptz.c` sends `GET_CUR`/`GET_MIN`/`GET_MAX`/`SET_CUR` requests to it through IOKit. libusb can't do this on macOS because the system UVC driver owns the interface.

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

- Drag pad, arrow buttons, 5°/15°/30° step
- ⌃⌥ + arrows to move and ⌃⌥C to recenter, from any app
- Set as Center saves the current position; Invert Pan swaps left and right

## Disclaimer

Not affiliated with or endorsed by DJI. Tested only on the Osmo Pocket 3.

Use at your own risk. This is a hobby project provided as is, with no warranty of any kind. It sends USB control commands that move the gimbal's motors. The author is not responsible or liable for any damage to your camera, gimbal, computer or data, voided warranties, injury, or any other loss that results from using, building or modifying this software. See the [LICENSE](LICENSE) for the full terms.

## License

MIT
