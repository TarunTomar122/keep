# XIAO board recovery — 2026-08-22

## What went wrong

The bare XIAO was repeatedly rebooting immediately after boot with:

```text
Guru Meditation Error: Core 1 panic'ed (Double exception)
```

It never reached the normal Wi-Fi, camera, or application status messages.

## Why it failed

The board was still running a camera/media application image while the camera
module had been removed. That image was not a valid test for the bare board
and crashed during startup. A reset only restarted the same crashing image.

Soldering could still cause trouble later if there is a bridge or power issue,
but the board itself was not shown to be dead: USB, the ESP32-S3, flash, and
PSRAM all responded normally in bootloader mode.

## How it was fixed

1. Entered the ESP32-S3 bootloader with the reset/boot-button sequence.
2. Confirmed ESP32-S3 revision 0.2, 8 MB flash, and 8 MB PSRAM.
3. Read and saved the complete 8 MB flash backup locally at
   `/tmp/keep-xiao-flash-backup-20260822.bin`. It is intentionally not in the
   repository because the dump may contain saved Wi-Fi credentials.
4. Flashed `firmware/hello_xiao/hello_xiao.ino`, including boot metadata, and
   verified the application bytes against flash.
5. Confirmed stable serial output once per second and a blinking onboard LED.

## What to expect now

The board is healthy as a bare XIAO and is currently running the minimal
heartbeat probe. Camera, Wi-Fi, and capture routes are intentionally absent
until the camera module is reattached.

When the camera is reattached, inspect solder joints and power first, then
restore `firmware/media_stream/media_stream.ino`. If the double exception
returns, test once with the camera disconnected and inspect the camera rail or
recent solder work before changing the app firmware again.
