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

1. Confirmed the board was visible at `/dev/cu.usbmodem1101` with
   `arduino-cli board list`.
2. Tried the normal upload first. It failed with `No serial data received`
   because the crashing application was not entering the bootloader.
3. Entered the ESP32-S3 bootloader by double-pressing `RST`, then holding
   `BOOT`, tapping `RST`, and releasing `BOOT`.
4. Confirmed the chip and flash with:

   ```bash
   esptool --before no-reset --after no-reset \
     --port /dev/cu.usbmodem1101 chip-id
   esptool --before no-reset --after no-reset \
     --port /dev/cu.usbmodem1101 flash-id
   ```

   This reported ESP32-S3 revision 0.2, 8 MB flash, and 8 MB PSRAM.
5. Read and saved the complete 8 MB flash backup locally with:

   ```bash
   esptool --before no-reset --after no-reset \
     --port /dev/cu.usbmodem1101 read-flash 0 0x800000 \
     /tmp/keep-xiao-flash-backup-20260822.bin
   ```

   It is intentionally not in the repository because the dump may contain
   saved Wi-Fi credentials.
6. Flashed the minimal recovery sketch with:

   ```bash
   arduino-cli compile --upload \
     --port /dev/cu.usbmodem1101 \
     --fqbn esp32:esp32:XIAO_ESP32S3 \
     firmware/hello_xiao
   ```

   This was a targeted reflash of the bootloader metadata and application;
   no full-chip erase was needed.
7. Verified the application bytes with `esptool verify-flash`; the digest
   matched. The sketch then printed `clippy: heartbeat ... ms` once per
   second and blinked the onboard LED.

The recovery was repeated later with the same `hello_xiao` command. Arduino
CLI verified the unchanged bootloader and partition data, rewrote the
application image, and `esptool verify-flash` again reported a matching
digest.

The exact recovery image is:

```text
firmware/hello_xiao/hello_xiao.ino
```

## What to expect now

The board is healthy as a bare XIAO and is currently running the minimal
heartbeat probe. Camera, Wi-Fi, and capture routes are intentionally absent
until the camera module is reattached.

When the camera is reattached, inspect solder joints and power first, then
restore `firmware/media_stream/media_stream.ino`. If the double exception
returns, test once with the camera disconnected and inspect the camera rail or
recent solder work before changing the app firmware again.
