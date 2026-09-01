# Keep

Keep is a tiny long-distance photo device for couples.

The idea is simple: press a button on a small camera in one place, send the
photo through the phone, process it into a soft e-ink-friendly style, and show
it later on an e-ink display in another place.

```text
XIAO camera → phone app → server → recipient phone/XIAO → e-ink display
```

## Current status

Working now:

- Seeed XIAO ESP32S3 Sense camera capture.
- XIAO live camera stream over Wi-Fi.
- XIAO setup hotspot named `CLIPPY-XIAO`.
- Save Wi-Fi credentials to the board's flash storage.
- Station-mode reconnect after reboot.
- Board status, Wi-Fi reset, mDNS, and UDP discovery.
- Flutter companion app for Android.
- Paper/e-ink-inspired Home gallery and Settings screen.
- Local gallery persistence across app restarts.
- Original/Treated image detail view with centered header switch.
- Delete and back actions for gallery images.
- Phone-side image processing from real image bytes.
- Local image processing in a background Dart isolate.
- Runtime resizing, muted palette mapping, grain, edge accents, color
  quantization, and Floyd–Steinberg dithering.
- Server-driven gallery: the photo list, originals, and treated variants are
  fetched from the Keep server (`/photos` and `/photos/{id}/...`) and cached on
  the phone for offline viewing.
- Uploads send the original to the server, which generates the treated variant;
  the gallery and `/view` refresh automatically. Deleting a photo removes it from
  the server and every device.
- Syncing, uploading, and deleting show visible spinners and toast feedback.
- Tested on the Pixel 9 emulator and a real Pixel 6a.

The server, physical capture button, microSD queue, second board, and e-ink
display are still planned work.

## Product plan

### Phase 1 — capture and process locally

```text
XIAO or phone camera
        ↓
original image bytes
        ↓
phone-side treatment
        ↓
original + treated image saved locally
        ↓
gallery preview
```

The current processor is deterministic and model-free so the visual style can
be tuned quickly against the real e-ink panel. It is a first visual direction,
not the final AI illustration model.

### Phase 2 — phone sync

The phone will fetch pending photos from the XIAO, process them locally, and
upload the original and treated variants when the app is open. Retry and
background sync can be added after the basic flow is reliable.

### Phase 3 — server

The server will eventually provide:

- Private image storage.
- Original and treated image variants.
- Upload status and retry-safe records.
- Latest-image retrieval for the recipient device.
- Style selection and metadata.
- Authentication for the two-person couple space.

There is no Keep image server yet. The backend contract and storage choice are
the next backend task.

### Phase 4 — physical devices

- Add a physical capture button.
- Add microSD storage for offline photo queuing.
- Retry uploads when the phone becomes available.
- Add the second XIAO and e-ink display.
- Fetch the latest image and render it for the display's palette and
  resolution.
- Let the recipient choose a style later.

## Repository layout

```text
app/
  lib/main.dart                 Flutter app and device controls
  lib/image_processor.dart      On-device image treatment
  lib/mjpeg_stream.dart         Camera stream parsing
  lib/audio_stream.dart         Earlier audio transport prototype
  test/                         Focused Flutter tests
  assets/demo/                  Local source images
firmware/
  media_stream/                 Current Wi-Fi camera firmware
  wifi_camera/                  Earlier Wi-Fi camera prototype
  camera_feed/                  Earlier camera feed prototype
  sense_peripherals/            Sense board peripheral probe
  mic_probe/                    Microphone probe
  hello_xiao/                   First board bring-up sketch
```

## Flutter app

The app talks to a Keep server over HTTP. It ships with the production URL as a
default; the access token is compiled in at build time too:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release \
  --dart-define=KEEP_SERVER_URL=http://144.217.6.112:8400 \
  --dart-define=KEEP_SERVER_TOKEN=<your-bearer-token>
```

The URL and token can also be changed per-device in **Settings → Server**
(they are stored in secure storage).

Install on the Pixel 9 emulator:

```bash
flutter install -d emulator-5554
```

Install on a connected Android phone:

```bash
flutter devices
flutter install -d <device-id>
```

## Keep server

The server is a FastAPI app (`server/app.py`) served by `uvicorn` on port 8400
behind a systemd unit (`keep.service`). State lives in `data/`:

- `data/originals/`, `data/processed/`, `data/frames/`, `data/index.json`
- Token is read from `KEEP_TOKEN` in the service `.env` (default `dev-token`).

Routes (Bearer token required unless noted):

```text
POST   /upload              Auth. Upload original; server runs the e-ink treatment.
GET    /photos              Auth. List of moments (newest first).
GET    /photos/{id}         Auth. One moment record.
GET    /photos/{id}/original.jpg   Original bytes (public).
GET    /photos/{id}/processed.png  Treated bytes (public).
GET    /latest              Auth. Latest raw 120,000-byte e-paper frame
GET    /view                Latest processed image as a standalone page
                           (auto-refreshes every 10s).
DELETE /photos/{id}         Auth. Remove a moment and its files.
```

`/view` is the recipient's "latest photo" feed. It refreshes automatically as
photos are uploaded or deleted.

## XIAO firmware

The current sketch is:

```text
firmware/media_stream/media_stream.ino
```

The board currently exposes these HTTP routes:

```text
GET  /status
GET  /capture
POST /wifi/config
POST /wifi/reset
```

The live camera stream uses port `82`. The board starts its setup hotspot when
it has no saved Wi-Fi network, then switches to the saved network after
provisioning and reboot.

## Hardware assumptions

- Seeed XIAO ESP32S3 Sense with camera.
- Microphone support is deferred.
- MicroSD is planned but not currently installed.
- Battery reporting needs a voltage sensor or battery gauge.
- The board should not be treated as permanently connected to the laptop;
  phone and firmware testing use the USB connection one at a time.

## Scope note

This standalone repository contains the hardware project: firmware, the
Flutter companion app, local image processing, assets, and tests. The parent
Clippy repository has a separate conversation-memory backend; it is not the
Keep image server and is intentionally not duplicated here.

## Next useful milestone

Tune the on-device treatment using real photos until the result looks right on
the e-ink display. Then define the minimal upload API and build one complete
retry-safe path:

```text
capture → fetch → process → upload → retrieve → display
```
