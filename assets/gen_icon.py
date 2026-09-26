"""Generate assets/AppIcon.icon, an Icon Composer document (macOS 26+).

A squarified treemap of glass tiles over a dark field. `actool` compiles it
to Assets.car (Liquid Glass on macOS 26+) and a flat AppIcon.icns fallback
for older systems; see build.sh.
"""
import json
import pathlib

OUT = pathlib.Path(__file__).parent / "AppIcon.icon"
RADIUS = 58

# name, (x, y, w, h) on the 1024 canvas, top color, bottom color (sRGB 0-1)
TILES = [
    ("orange", (150, 150, 430, 440), (1.00, 0.62, 0.30), (0.96, 0.36, 0.12)),
    ("violet", (616, 150, 258, 250), (0.86, 0.58, 1.00), (0.62, 0.32, 0.95)),
    ("blue",   (616, 436, 258, 154), (0.42, 0.70, 1.00), (0.18, 0.45, 0.98)),
    ("green",  (150, 626, 300, 248), (0.52, 0.92, 0.52), (0.20, 0.72, 0.36)),
    ("amber",  (486, 626, 214, 248), (1.00, 0.86, 0.36), (0.98, 0.66, 0.10)),
    ("teal",   (736, 626, 138, 248), (0.44, 0.94, 0.88), (0.12, 0.72, 0.72)),
]


def color(rgb):
    return "srgb:" + ",".join(f"{c:.5f}" for c in (*rgb, 1.0))


assets = OUT / "Assets"
assets.mkdir(parents=True, exist_ok=True)
layers = []
for name, (x, y, w, h), top, bottom in TILES:
    (assets / f"{name}.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">'
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{RADIUS}" fill="#fff"/>'
        "</svg>\n"
    )
    layers.append({
        "name": name,
        "image-name": f"{name}.svg",
        "glass": True,
        "fill": {
            "linear-gradient": [color(top), color(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
        },
    })

icon = {
    "fill": {
        "linear-gradient": [color((0.13, 0.14, 0.20)), color((0.03, 0.03, 0.06))],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    },
    "groups": [{
        "layers": layers,
        "lighting": "individual",
        "specular": True,
        "shadow": {"kind": "layer-color", "opacity": 0.45},
        "translucency": {"enabled": True, "value": 0.25},
    }],
    "supported-platforms": {"squares": ["macOS"]},
}
(OUT / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
