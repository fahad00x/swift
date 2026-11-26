"""Generates Lumen's app icons: the folded-light "L" mark.

tvOS  : layered App Icon imagestacks (Back / Middle / Front, for the parallax effect) + Top Shelf images
iOS   : the 1024 App Store / home-screen icon

Usage (needs Pillow):
    python3 scripts/make_icons.py Lumen/Assets.xcassets [LumenMobile/Assets.xcassets]

The mark: a ribbon L, lit from above (bright at the top, deepening toward the fold),
folding into a floor ribbon that catches the light. All geometry is in a 1024 box.
"""
import json, os, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

TV_ROOT = sys.argv[1]
IOS_ROOT = sys.argv[2] if len(sys.argv) > 2 else None
FONTS = [
    "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf",
    os.path.expanduser("~/Library/Fonts/InterDisplay-Bold.otf"),
    "/Library/Fonts/InterDisplay-Bold.otf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]
INFO = {"info": {"author": "xcode", "version": 1}}
BRAND = os.path.join(TV_ROOT, "App Icon & Top Shelf Image.brandassets")

BG = (8, 8, 10)
WARM = (70, 36, 4)
AMBER_TOP = (255, 196, 70)
AMBER = (240, 150, 20)
AMBER_LO = (150, 80, 4)
FLOOR_A = (255, 184, 48)
FLOOR_B = (255, 205, 90)
SS = 4  # supersampling factor

# The mark's box is shifted so the letter sits in the optical center:
# side margins nearly equal, nudged a touch high because the floor ribbon makes it bottom-heavy.
DX, DY = -55, -12
X0, X1, X2 = 318 + DX, 524 + DX, 770 + DX
YT, YB, YH = 150 + DY, 868 + DY, 662 + DY
VERT = [(X0, YT + 70), (X1, YT), (X1, YB), (X0, YB)]
FLOOR = [(X0, YB), (X1, YH), (X2 + 70, YH), (X2, YB)]


def font(size):
    for f in FONTS:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    raise SystemExit("No bold font found; add one to FONTS")


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def grad(size, stops, axis, a, b):
    w, h = size
    n = h if axis == "y" else w
    line = []
    for i in range(n):
        t = min(1, max(0, (i - a) / max(1, b - a)))
        for j in range(len(stops) - 1):
            t0, c0 = stops[j]
            t1, c1 = stops[j + 1]
            if t <= t1 or j == len(stops) - 2:
                u = 0 if t1 == t0 else min(1, max(0, (t - t0) / (t1 - t0)))
                line.append(tuple(int(c0[k] + (c1[k] - c0[k]) * u) for k in range(3)))
                break
    strip = Image.new("RGB", (1, n) if axis == "y" else (n, 1))
    strip.putdata(line)
    return strip.resize((w, h))


def poly(size, pts):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def background(w, h):
    img = Image.new("RGB", (w, h), BG)
    s = max(w, h)
    g = Image.new("L", (w, h), 0)
    ImageDraw.Draw(g).ellipse([w * .5 - s * .55, h * .95 - s * .35, w * .5 + s * .55, h * .95 + s * .35], fill=60)
    g = g.filter(ImageFilter.GaussianBlur(s * .12))
    return Image.composite(Image.new("RGB", (w, h), WARM), img, g)


def mark_layers(W, H, ox, oy, S):
    """Return (vertical, floor) RGBA layers of the mark placed in an S box at (ox, oy)."""
    k = S / 1024.0
    P = lambda pts: [(ox + x * k, oy + y * k) for x, y in pts]
    size = (W, H)

    # vertical ribbon, lit from the top
    vmask = poly(size, P(VERT))
    vcol = grad(size, [(0, AMBER_TOP), (0.35, AMBER), (1, AMBER_LO)], "y", int(oy + YT * k), int(oy + YB * k))
    # shadow the floor ribbon casts where it folds over
    sh = Image.new("L", size, 0)
    d = ImageDraw.Draw(sh)
    for i in range(40):
        y = YH - 230 + i * 230 / 40
        d.rectangle(P([(X0, y), (X1, y + 230 / 40 + 1)]), fill=int(150 * (i / 39) ** 2.4))
    vcol = Image.composite(Image.new("RGB", size, (0, 0, 0)), vcol, sh)
    vert = vcol.convert("RGBA")
    vert.putalpha(vmask)

    # floor ribbon, catches the light, with a soft crease at the fold
    fmask = poly(size, P(FLOOR))
    fcol = grad(size, [(0, FLOOR_A), (1, FLOOR_B)], "x", int(ox + X0 * k), int(ox + (X2 + 70) * k))
    seam = Image.new("L", size, 0)
    ImageDraw.Draw(seam).line(P([(X0, YB), (X1, YH)]), fill=110, width=max(1, int(10 * k)))
    seam = seam.filter(ImageFilter.GaussianBlur(6 * k))
    fcol = Image.composite(Image.new("RGB", size, (60, 30, 0)), fcol, seam)
    floor = fcol.convert("RGBA")
    floor.putalpha(fmask)
    return vert, floor


def render(w, h, place, layers=("back", "vert", "floor")):
    """place(W, H) -> (ox, oy, S) in supersampled pixels."""
    W, H = w * SS, h * SS
    ox, oy, S = place(W, H)
    vert, floor = mark_layers(W, H, ox, oy, S)
    img = background(W, H).convert("RGBA") if "back" in layers else Image.new("RGBA", (W, H), (0, 0, 0, 0))
    if "vert" in layers:
        img.alpha_composite(vert)
    if "floor" in layers:
        img.alpha_composite(floor)
    img = img.resize((w, h), Image.LANCZOS)
    return img.convert("RGB") if "back" in layers else img


def tv_place(W, H):
    S = int(H * 0.86)
    return (W - S) // 2, (H - S) // 2 + int(H * 0.01), S


def square_place(W, H):
    return 0, 0, W


def top_shelf(w, h):
    W, H = w * 2, h * 2
    S = int(H * 0.78)
    x = int(W * 0.14)
    img = background(W, H).convert("RGBA")
    vert, floor = mark_layers(W, H, x, (H - S) // 2, S)
    img.alpha_composite(vert)
    img.alpha_composite(floor)
    d = ImageDraw.Draw(img)
    tx = x + S + int(H * 0.02)
    d.text((tx, H * 0.27), "Lumen", font=font(int(H * 0.30)), fill=(255, 255, 255, 255))
    d.text((tx + H * 0.015, H * 0.66), "PLEX  ·  4K  ·  HDR", font=font(int(H * 0.065)), fill=FLOOR_A + (255,))
    return img.resize((w, h), Image.LANCZOS).convert("RGB")


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
    layers = [("Front", ("floor",)), ("Middle", ("vert",)), ("Back", ("back",))]
    for layer, parts in layers:
        lp = os.path.join(stack, f"{layer}.imagestacklayer")
        write_json(os.path.join(lp, "Contents.json"), INFO)
        imageset(os.path.join(lp, "Content.imageset"),
                 [render(w, h, tv_place, parts) for (_, (w, h)) in sizes_by_scale],
                 [s for (s, _) in sizes_by_scale])
    write_json(os.path.join(stack, "Contents.json"),
               {"layers": [{"filename": f"{l}.imagestacklayer"} for l, _ in layers], **INFO})


write_json(os.path.join(TV_ROOT, "Contents.json"), INFO)
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

if IOS_ROOT:
    icon_set = os.path.join(IOS_ROOT, "AppIcon.appiconset")
    os.makedirs(icon_set, exist_ok=True)
    render(1024, 1024, square_place).save(os.path.join(icon_set, "icon-1024.png"))
    write_json(os.path.join(icon_set, "Contents.json"), {
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        **INFO,
    })
print("ok")
