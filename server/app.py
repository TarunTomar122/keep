from __future__ import annotations

import json
import os
import threading
import time
from typing import Optional
import uuid
from pathlib import Path

from fastapi import FastAPI, File, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, HTMLResponse

from pipeline import process_bytes

DATA_DIR = Path(os.environ.get("KEEP_DATA_DIR", str(Path(__file__).parent / "data")))
TOKEN = os.environ.get("KEEP_TOKEN", "dev-token")

ORIGINALS_DIR = DATA_DIR / "originals"
PROCESSED_DIR = DATA_DIR / "processed"
FRAMES_DIR = DATA_DIR / "frames"
DEMO_DIR = DATA_DIR / "demo"
INDEX_PATH = DATA_DIR / "index.json"

for directory in (ORIGINALS_DIR, PROCESSED_DIR, FRAMES_DIR, DEMO_DIR):
    directory.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="keep-server")
_lock = threading.Lock()


def _load_index() -> list[dict]:
    if not INDEX_PATH.exists():
        return []
    return json.loads(INDEX_PATH.read_text())


def _save_index(moments: list[dict]) -> None:
    INDEX_PATH.write_text(json.dumps(moments, indent=2))


def _require_token(authorization: str | None) -> None:
    if authorization != f"Bearer {TOKEN}":
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.post("/upload")
async def upload(
    photo: UploadFile = File(...),
    authorization: Optional[str] = Header(default=None),
) -> dict:
    _require_token(authorization)
    data = await photo.read()
    if not data:
        raise HTTPException(status_code=400, detail="Empty upload")

    moment_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    try:
        processed = process_bytes(data)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=f"Could not process image: {exc}")

    (ORIGINALS_DIR / f"{moment_id}.jpg").write_bytes(data)
    (PROCESSED_DIR / f"{moment_id}.png").write_bytes(processed.processed_png)
    (FRAMES_DIR / f"{moment_id}.bin").write_bytes(processed.frame)

    moment = {
        "id": moment_id,
        "created_at": time.time(),
        "width": processed.width,
        "height": processed.height,
        "original_url": f"/photos/{moment_id}/original.jpg",
        "processed_url": f"/photos/{moment_id}/processed.png",
    }
    with _lock:
        moments = _load_index()
        moments.append(moment)
        _save_index(moments)
    return moment


@app.get("/photos")
async def photos(authorization: Optional[str] = Header(default=None)) -> list[dict]:
    _require_token(authorization)
    return list(reversed(_load_index()))


@app.get("/photos/{moment_id}")
async def photo(moment_id: str, authorization: Optional[str] = Header(default=None)) -> dict:
    _require_token(authorization)
    for moment in _load_index():
        if moment["id"] == moment_id:
            return moment
    raise HTTPException(status_code=404, detail="Not found")


@app.delete("/photos/{moment_id}")
async def delete_photo(
    moment_id: str,
    authorization: Optional[str] = Header(default=None),
) -> dict:
    _require_token(authorization)
    moment_id = moment_id.replace(".jpg", "").replace(".png", "")
    with _lock:
        moments = _load_index()
        remaining = [moment for moment in moments if moment["id"] != moment_id]
        if len(remaining) == len(moments):
            raise HTTPException(status_code=404, detail="Not found")
        _save_index(remaining)
    for path in (
        ORIGINALS_DIR / f"{moment_id}.jpg",
        PROCESSED_DIR / f"{moment_id}.png",
        FRAMES_DIR / f"{moment_id}.bin",
    ):
        path.unlink(missing_ok=True)
    return {"deleted": moment_id}


@app.get("/photos/{moment_id}/original.jpg")
async def original(moment_id: str) -> FileResponse:
    path = ORIGINALS_DIR / f"{moment_id}.jpg"
    if not path.exists():
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(path, media_type="image/jpeg")


@app.get("/photos/{moment_id}/processed.png")
async def processed(moment_id: str) -> FileResponse:
    path = PROCESSED_DIR / f"{moment_id}.png"
    if not path.exists():
        raise HTTPException(status_code=404, detail="Not found")
    return FileResponse(path, media_type="image/png")


@app.get("/view")
async def view() -> HTMLResponse:
    moments = _load_index()
    if not moments:
        return HTMLResponse(
            "<!doctype html><html><body style='background:#1a1a1a;color:#eee;"
            "font-family:sans-serif;display:grid;place-items:center;height:100vh'>"
            "<p>No photos yet</p></body></html>"
        )
    newest = moments[-1]
    html = f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="10">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Keep · latest</title>
<style>
  body {{ margin: 0; min-height: 100vh; display: grid; place-items: center;
         background: #1a1a1a; font-family: -apple-system, sans-serif; }}
  main {{ text-align: center; }}
  img {{ max-width: min(92vw, 720px); border-radius: 12px;
        box-shadow: 0 8px 40px rgba(0,0,0,.6); image-rendering: pixelated; }}
  p {{ color: #8a8a8a; font-size: 13px; margin-top: 14px; }}
</style>
</head>
<body>
<main>
  <img src="{newest['processed_url']}?v={newest['id']}" alt="Latest moment">
  <p>{newest['id']}</p>
</main>
</body>
</html>"""
    return HTMLResponse(html)


@app.get("/latest")
async def latest(
    request: Request,
    authorization: Optional[str] = Header(default=None),
) -> Response:
    _require_token(authorization)
    moments = _load_index()
    if not moments:
        raise HTTPException(status_code=404, detail="No photos yet")
    newest = moments[-1]
    headers = {
        "X-Moment-Id": newest["id"],
        "ETag": f'"{newest["id"]}"',
        "Cache-Control": "no-cache",
    }
    if request.headers.get("if-none-match") == headers["ETag"]:
        return Response(status_code=304, headers=headers)
    return FileResponse(
        FRAMES_DIR / f"{newest['id']}.bin",
        media_type="application/octet-stream",
        headers=headers,
    )


@app.get("/demo/frame/{index}")
async def demo_frame(
    index: int,
    authorization: Optional[str] = Header(default=None),
) -> FileResponse:
    _require_token(authorization)
    frames = sorted(DEMO_DIR.glob("*.bin"))
    if index < 0 or index >= len(frames):
        raise HTTPException(status_code=404, detail="Demo frame not found")
    return FileResponse(
        frames[index],
        media_type="application/octet-stream",
        headers={
            "X-Demo-Index": str(index),
            "Cache-Control": "no-cache",
        },
    )
