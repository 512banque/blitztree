"""Generate assets/AppIcon.icon, an Icon Composer document (macOS 26+).

A squarified treemap of glass tiles separated by thin dark grout; the corner
tiles run into the system's rounded-square mask. `actool` compiles it to
Assets.car (Liquid Glass on macOS 26+) and a flat AppIcon.icns fallback for
older systems; see build.sh.
"""
import colorsys
import json
import pathlib

OUT = pathlib.Path(__file__).parent / "AppIcon.icon"
S = 1024
GAP = 18  # grout between tiles, and between tiles and the icon edge
RADIUS = 34


def hsb(h, s, b):
    return colorsys.hsv_to_rgb(h, s, b)


def mix(c, other, t):
    return tuple(a + (b - a) * t for a, b in zip(c, other))


def color(rgb):
    return "srgb:" + ",".join(f"{v:.5f}" for v in (*rgb, 1.0))


def gradient(top, bottom, start, stop):
    return {
        "linear-gradient": [color(top), color(bottom)],
        "orientation": {"start": start, "stop": stop},
    }


# name, unit rect (x, y, w, h; top-left origin), base colour
TILES = [
    ("orange", (0.00, 0.00, 0.58, 0.58), hsb(0.055, 0.78, 0.98)),
    ("purple", (0.58, 0.00, 0.42, 0.58), hsb(0.80, 0.55, 0.92)),
    ("blue", (0.00, 0.58, 0.36, 0.42), hsb(0.60, 0.62, 0.92)),
    ("green", (0.36, 0.58, 0.34, 0.42), hsb(0.34, 0.63, 0.85)),
    ("amber", (0.70, 0.58, 0.30, 0.21), hsb(0.125, 0.72, 0.95)),
    ("teal", (0.70, 0.79, 0.30, 0.21), hsb(0.47, 0.60, 0.84)),
]

assets = OUT / "Assets"
assets.mkdir(parents=True, exist_ok=True)
for old in assets.glob("*.svg"):
    old.unlink()

span = S - GAP  # tiles tile a box inset by half a gap; each tile insets another half
layers = []
for name, (x, y, w, h), base in TILES:
    px, py = GAP / 2 + x * span + GAP / 2, GAP / 2 + y * span + GAP / 2
    pw, ph = w * span - GAP, h * span - GAP
    (assets / f"{name}.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}">'
        f'<rect x="{px:.1f}" y="{py:.1f}" width="{pw:.1f}" height="{ph:.1f}" '
        f'rx="{RADIUS}" fill="#fff"/></svg>\n'
    )
    layers.append({
        "name": name,
        "image-name": f"{name}.svg",
        "glass": True,
        "fill": gradient(mix(base, (1, 1, 1), 0.30), mix(base, (0, 0, 0), 0.10),
                         {"x": 0.1, "y": 0.0}, {"x": 0.9, "y": 1.0}),
    })

icon = {
    "fill": gradient((0.09, 0.09, 0.10), (0.05, 0.05, 0.06),
                     {"x": 0.5, "y": 0.0}, {"x": 0.5, "y": 1.0}),
    "groups": [{
        "layers": layers,
        "lighting": "individual",
        "specular": True,
        "shadow": {"kind": "neutral", "opacity": 0.4},
        "translucency": {"enabled": False, "value": 0.3},
    }],
    "supported-platforms": {"squares": ["macOS"]},
}
(OUT / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
