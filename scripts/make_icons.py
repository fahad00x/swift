"""Generates the tvOS Brand Assets (layered app icons + top shelf) for Lumen.

Usage: python3 scripts/make_icons.py Lumen/Assets.xcassets   (needs Pillow)
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = sys.argv[1]  # path to Assets.xcassets
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"
INFO = {"info": {"author": "xcode", "version": 1}}
BRAND = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")

AMBER = (255, 174, 41)
DEEP = (12, 10, 22)

def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

def back(w, h):
    """Opaque background: deep navy with a warm amber glow from the lower left."""
    img = Image.new("RGB", (w, h), DEEP)
    glow = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(glow)
    r = int(max(w, h) * 0.75)
    cx, cy = int(w * 0.18), int(h * 1.05)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(max(w, h) * 0.18))
    warm = Image.new("RGB", (w, h), (120, 52, 20))
    img = Image.composite(warm, img, glow)
    glow2 = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(glow2)
    r2 = int(max(w, h) * 0.45)
    cx2, cy2 = int(w * 0.95), int(h * -0.1)
    d.ellipse([cx2 - r2, cy2 - r2, cx2 + r2, cy2 + r2], fill=150)
    glow2 = glow2.filter(ImageFilter.GaussianBlur(max(w, h) * 0.15))
    cool = Image.new("RGB", (w, h), (40, 46, 110))
    return Image.composite(cool, img, glow2)

def middle(w, h):
    """Soft light rays behind the play mark (transparent)."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    s = min(w, h)
    cx, cy = w / 2, h / 2
    r = s * 0.42
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=AMBER + (90,))
    return img.filter(ImageFilter.GaussianBlur(s * 0.09))

def play_mark(d, cx, cy, s, color):
    """Rounded play triangle inside a ring."""
    ring = s * 0.30
    width = max(2, int(s * 0.035))
    d.ellipse([cx - ring, cy - ring, cx + ring, cy + ring], outline=color, width=width)
    t = s * 0.14
    pts = [(cx - t * 0.7, cy - t), (cx - t * 0.7, cy + t), (cx + t * 1.05, cy)]
    d.polygon(pts, fill=color)

def front(w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    play_mark(d, w / 2, h / 2, min(w, h), (255, 255, 255, 255))
    return img

def top_shelf(w, h):
    img = back(w, h).convert("RGBA")
    mid = middle(h, h)
    img.alpha_composite(mid, (int(w * 0.12), 0))
    d = ImageDraw.Draw(img)
    play_mark(d, int(w * 0.12) + h / 2, h / 2, h * 0.9, (255, 255, 255, 255))
    font = ImageFont.truetype(FONT, int(h * 0.30))
    sub = ImageFont.truetype(FONT, int(h * 0.075))
    x = int(w * 0.12) + h + int(h * 0.05)
    d.text((x, h * 0.28), "Lumen", font=font, fill=(255, 255, 255, 255))
    d.text((x + h * 0.02, h * 0.66), "PLEX  ·  4K  ·  HDR", font=sub, fill=AMBER + (255,))
    return img.convert("RGB")

def imageset(path, images, scales):
    os.makedirs(path, exist_ok=True)
    entries = []
    for scale, im in zip(scales, images):
        name = f"image@{scale}.png" if scale != "1x" else "image.png"
        im.save(os.path.join(path, name))
        entries.append({"idiom": "tv", "scale": scale, "filename": name})
    write_json(os.path.join(path, "Contents.json"), {"images": entries, **INFO})

def imagestack(name, sizes_by_scale):
    stack = os.path.join(BRAND, f"{name}.imagestack")
    layers = [("Front", front), ("Middle", middle), ("Back", back)]
    for layer, fn in layers:
        lp = os.path.join(stack, f"{layer}.imagestacklayer")
        write_json(os.path.join(lp, "Contents.json"), INFO)
        imageset(os.path.join(lp, "Content.imageset"),
                 [fn(w, h) for (_, (w, h)) in sizes_by_scale], [s for (s, _) in sizes_by_scale])
    write_json(os.path.join(stack, "Contents.json"),
               {"layers": [{"filename": f"{l}.imagestacklayer"} for l, _ in layers], **INFO})

write_json(os.path.join(ROOT, "Contents.json"), INFO)
imagestack("App Icon", [("1x", (400, 240)), ("2x", (800, 480))])
imagestack("App Icon - App Store", [("1x", (1280, 768))])
imageset(os.path.join(BRAND, "Top Shelf Image.imageset"),
         [top_shelf(1920, 720), top_shelf(3840, 1440)], ["1x", "2x"])
imageset(os.path.join(BRAND, "Top Shelf Image Wide.imageset"),
         [top_shelf(2320, 720), top_shelf(4640, 1440)], ["1x", "2x"])
write_json(os.path.join(BRAND, "Contents.json"), {
    "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ],
    **INFO,
})
print("ok")
