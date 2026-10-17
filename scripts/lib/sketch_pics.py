"""Finds the pictures that go into the whiteboard sketches (docs/marketing/xiaohongshu/pics/<slot>.png|jpg).

A slot is a place in a sketch where a real picture (usually an app screenshot) can sit: auto, presets, crop, save.
Put your own file with that name in the folder to replace it; remove it to get the hand-drawn icon back.
"""
import json
import subprocess
from pathlib import Path
from urllib.parse import quote

PICS = Path(__file__).resolve().parents[2] / "docs/marketing/xiaohongshu/pics"
SLOTS = ("auto", "presets", "crop", "save")


def find_pics():
    found = {}
    for slot in SLOTS:
        for ext in ("png", "jpg", "jpeg", "webp"):
            path = PICS / f"{slot}.{ext}"
            if path.exists():
                out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], capture_output=True, text=True).stdout
                w, h = (int(line.split()[-1]) for line in out.splitlines() if "pixel" in line)
                found[slot] = {"path": str(path), "src": path.as_uri(), "w": w, "h": h}
                break
    return found


def pics_param(found):
    """The &pics=… part of a sketches.html address."""
    return quote(json.dumps({k: {"src": v["src"], "w": v["w"], "h": v["h"]} for k, v in found.items()}))


# What you say -> when a sketch element appears. One entry per board of sketches.html, in the order the story is told.
# Each board lists its "anchors" (the names used in sketches.html) and a pattern for the words that start them.
# build-talking-video.py searches the recognised speech for the patterns in order; export-excalidraw.py checks that
# these names match the ones in sketches.html. If you change a board, change its anchors here too.
BOARDS = [
    ("phone", [("mimo", r"Mimo|米莫|咪摩"), ("back", r"传回|回手机"), ("small", r"小小的|小屏")]),
    ("sliders", [("pro", r"专业软件|Lightroom|莱特"), ("many", r"几十个|滑块"), ("names", r"曝光[，、,]|去朦胧"), ("lost", r"先动哪|不知道先")]),
    ("idea", [("simple", r"简单得像|像手机"), ("teach", r"有人在旁边|讲给你听|旁边")]),
    ("origin", [("chatgpt", r"ChatGPT"), ("runs", r"能跑"), ("claude", r"Claude ?Code"), ("hunt", r"挑毛病")]),
    ("audit", [("files", r"两千个|2000|2千"), ("slow", r"7 ?秒|七秒|将近"), ("fast", r"百分之一|0\.01"), ("lut", r"LUT|lut"), ("works", r"正常用|能用了")]),
    ("sentences", [("loop", r"普通的话|一句话"), ("blue", r"蓝色"), ("loose", r"太松|紧凑"), ("info", r"信息不够"), ("boxes", r"方框"), ("rounds", r"一轮一轮|一轮")]),
    ("mistake", [("latte", r"拿铁|白桌子"), ("wrong", r"偏亮"), ("fix", r"降一档|一档半|曝光降"), ("real", r"本来就应该|本来就该"), ("test", r"加上测试|测试")]),
    ("auto", [("auto", r"自动"), ("read", r"读这张|先读"), ("restraint", r"克制|白底"), ("undo", r"撤销"), ("six", r"六个滑块|六个")]),
    ("presets", [("presets", r"预设"), ("thumbs", r"小图|这张照片做成"), ("crop", r"裁剪"), ("drag", r"在照片上拖|直接在照片")]),
    ("save", [("save", r"存进|直接存进"), ("icloud", r"iCloud|icloud"), ("iphone", r"iPhone|手机上"), ("live", r"实况|三秒")]),
    ("inspire", [("filter", r"一键滤镜"), ("xiaoyang", r"张小样|摄影博主|小样"), ("few", r"几条视频|讲不完"), ("inapp", r"放进了? ?App|放进")]),
    ("learn", [("pixels", r"像素|用你自己的照片"), ("hist", r"直方图|小山"), ("aperture", r"光圈"), ("highlight", r"亮部"), ("thirteen", r"十三课|13 ?课")]),
    ("name", [("name", r"Lucet|路塞|露塞"), ("lat", r"拉丁|发光"), ("gather", r"收集"), ("photo", r"留住的光|被留住")]),
    ("honest", [("early", r"早期版本"), ("apple", r"Apple 芯片|苹果芯片"), ("zh", r"只有中文"), ("notar", r"公证"), ("safe", r"不会改动|原片"), ("none", r"没有账号|账号"), ("upload", r"上传")]),
    ("invite", [("try", r"欢迎来试试|来试试|试试"), ("tell", r"都告诉我|告诉我"), ("ai", r"用 ?AI|AI 做"), ("tag", r"自有光彩|每一个瞬间")]),
]
MAX_SPAN = 30.0           # seconds: an element you only say much later than the board's first word is not drawn then
