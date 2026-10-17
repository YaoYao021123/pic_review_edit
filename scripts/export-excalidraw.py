#!/usr/bin/env python3
"""Writes all the whiteboard pages as ONE .excalidraw file you can open and edit on https://excalidraw.com

    python3 scripts/export-excalidraw.py            # -> docs/marketing/xiaohongshu/excalidraw/lucet-story.excalidraw

The pages sit on one canvas in story order, five to a row, each inside a named frame ("1 phone", "2 sliders" ...).

On excalidraw.com: open the menu (top left) -> Open, or just drag the file onto the page. The shapes are the same as
in the video (drawn by docs/marketing/xiaohongshu/sketches.html). Text is placed approximately; nudge anything that looks off.
Real pictures from docs/marketing/xiaohongshu/pics/ are embedded in the file.
Excalidraw's own look differs a little from the video's (its line style and handwriting font), and this is a one-way export:
edits made on excalidraw.com do not flow back into sketches.html.
"""
import base64
import html
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from sketch_pics import BOARDS, find_pics, pics_param
XHS = ROOT / "docs/marketing/xiaohongshu"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
out = XHS / "excalidraw"
out.mkdir(exist_ok=True)
for old in out.glob("*.excalidraw"):
    old.unlink()                                   # pages that no longer exist
pics = find_pics()
COLS, PAGE, GAP = 5, 1080, 200                     # five pages to a row; every page is 1080 x 1080
combined = {"type": "excalidraw", "version": 2, "source": "https://excalidraw.com", "elements": [],
            "appState": {"viewBackgroundColor": "#fbf8ef", "gridSize": None}, "files": {}}
for board, anchors in BOARDS:
    with tempfile.TemporaryDirectory() as profile, tempfile.TemporaryFile() as dump:
        chrome = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", f"--user-data-dir={profile}", "--dump-dom",
                                   f"file://{XHS}/sketches.html?board={board}&export=1&pics={pics_param(pics)}"], stdout=dump, stderr=subprocess.DEVNULL)
        dom = ""
        for _ in range(300):                       # Chrome prints the page but then keeps running: wait for the drawing, then stop it
            time.sleep(0.1)
            dump.seek(0); dom = dump.read().decode("utf-8", "replace")
            if "</pre>" in dom:
                break
        chrome.kill(); chrome.wait()
    m = re.search(r'<pre id="excalidraw">(.*?)</pre>', dom, re.S)
    if not m:
        raise SystemExit(f"{board}: Chrome did not return the drawing")
    doc = json.loads(html.unescape(m.group(1)))
    if set(doc.pop("anchors")) != {k for k, _ in anchors}:
        raise SystemExit(f"{board}: the anchors in sketches.html and scripts/lib/sketch_pics.py (BOARDS) differ")
    for e in doc["elements"]:                      # pictures travel inside the file, so it opens anywhere
        if e["type"] == "image":
            path = Path(pics[e["fileId"][4:]]["path"])
            mime = {"png": "image/png", "webp": "image/webp"}.get(path.suffix[1:], "image/jpeg")
            doc["files"][e["fileId"]] = {"mimeType": mime, "id": e["fileId"], "created": 1, "lastRetrieved": 1,
                                         "dataURL": f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"}
    n = sum(1 for e in combined["elements"] if e["type"] == "frame")
    ox, oy = n % COLS * (PAGE + GAP), n // COLS * (PAGE + GAP)
    frame_id = f"frame-{board}"
    for e in doc["elements"]:                      # move the page to its place on the canvas and put it in its frame
        e["x"] += ox; e["y"] += oy; e["frameId"] = frame_id
    frame = {"id": frame_id, "type": "frame", "name": f"{n + 1} {board}", "x": ox, "y": oy, "width": PAGE, "height": PAGE, "angle": 0,
             "strokeColor": "#bbbbbb", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
             "roughness": 0, "opacity": 100, "groupIds": [], "frameId": None, "roundness": None, "seed": 1, "version": 1,
             "versionNonce": 1, "isDeleted": False, "boundElements": None, "updated": 1, "link": None, "locked": False}
    combined["elements"] += doc["elements"] + [frame]      # a frame comes after the shapes inside it
    combined["files"].update(doc["files"])
    print(f"{n + 1:>2} {board:<10} {len(doc['elements'])} shapes")
(out / "lucet-story.excalidraw").write_text(json.dumps(combined, ensure_ascii=False, indent=1))
print(f"-> {out / 'lucet-story.excalidraw'}")
