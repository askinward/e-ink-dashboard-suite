#!/usr/bin/env python3
"""Render the Kobo dashboard from a template + data, outputting raw 8-bit grayscale.

Usage:  render_dashboard.py [--data FILE] [--template FILE]
Output: 608 bytes/line x 800 lines = 486400 bytes raw Gray8 to stdout.
"""

import json, os, sys, datetime, textwrap
from pathlib import Path

HERE = Path(__file__).parent
DATA_FILE = HERE / "dashboard-data.json"
TEMPLATE_FILE = HERE / "template.json"
IMG_DIR = HERE / "images"

WIDTH, HEIGHT = 600, 800
LINE_BYTES = 608
MARGIN = 20

FONT_MAP = {
    ("Sans", "Regular"):     "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    ("Sans", "Bold"):        "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
    ("Sans", "Italic"):      "/usr/share/fonts/liberation/LiberationSans-Italic.ttf",
    ("Sans", "Bold Italic"): "/usr/share/fonts/liberation/LiberationSans-BoldItalic.ttf",
    ("Serif", "Regular"):     "/usr/share/fonts/liberation/LiberationSerif-Regular.ttf",
    ("Serif", "Bold"):        "/usr/share/fonts/liberation/LiberationSerif-Bold.ttf",
    ("Serif", "Italic"):      "/usr/share/fonts/liberation/LiberationSerif-Italic.ttf",
    ("Serif", "Bold Italic"): "/usr/share/fonts/liberation/LiberationSerif-BoldItalic.ttf",
    ("Mono", "Regular"):     "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
}

FONT_CSS = {
    ("Sans", "Regular"):     ("Liberation Sans", "400"),
    ("Sans", "Bold"):        ("Liberation Sans", "700"),
    ("Sans", "Italic"):      ("Liberation Sans", "400", "italic"),
    ("Sans", "Bold Italic"): ("Liberation Sans", "700", "italic"),
    ("Serif", "Regular"):     ("Liberation Serif", "400"),
    ("Serif", "Bold"):        ("Liberation Serif", "700"),
    ("Serif", "Italic"):      ("Liberation Serif", "400", "italic"),
    ("Serif", "Bold Italic"): ("Liberation Serif", "700", "italic"),
    ("Mono", "Regular"):     ("Liberation Mono", "400"),
}

def hex_color(c):
    if isinstance(c, str) and c.startswith("#"):
        c = c.lstrip("#")
        r = int(c[0:2], 16) if len(c) >= 2 else 0
        g = int(c[2:4], 16) if len(c) >= 4 else 0
        b = int(c[4:6], 16) if len(c) >= 6 else 0
        return int(0.299 * r + 0.587 * g + 0.114 * b)
    return 0


def load_data():
    with open(DATA_FILE) as f:
        return json.load(f)


def load_template():
    with open(TEMPLATE_FILE) as f:
        return json.load(f)


def resolve_vars(text, data, now):
    day_names = ["SUNDAY","MONDAY","TUESDAY","WEDNESDAY","THURSDAY","FRIDAY","SATURDAY"]
    month_names = ["","January","February","March","April","May","June",
                   "July","August","September","October","November","December"]
    day_name = day_names[now.weekday()] if now else ""
    date_str = (month_names[now.month] + " " + str(now.day) + ", " + str(now.year)) if now else ""
    battery = str(data.get("battery", 86)) + "%"

    subs = {
        "{day_name}": day_name,
        "{date}": date_str,
        "{battery}": battery,
        "{quote_text}": (data.get("quote") or {}).get("text") or "",
        "{quote_author}": (data.get("quote") or {}).get("author") or "",
        "{updated_at}": (data.get("updated_at") or ""),
        "{current_time}": now.strftime("%H:%M"),
        "{wifi_indicator}": "W" if data.get("wifi_up") else "",
        "{ssh_indicator}": "S" if data.get("sshenabled") else "",
    }
    for k, v in subs.items():
        text = text.replace(k, str(v))
    return text


def wrap_text(text, font, max_width, draw):
    if max_width <= 0: return [text]
    words = text.split()
    if not words: return [""]
    lines = []
    current = words[0]
    for w in words[1:]:
        test = current + " " + w
        bb = draw.textbbox((0, 0), test, font=font)
        if bb[2] - bb[0] <= max_width:
            current = test
        else:
            lines.append(current)
            current = w
    lines.append(current)
    return lines


def get_background(data):
    url = data.get("background") or ""
    if not url:
        return None
    name = url.rsplit("/", 1)[-1]
    p = IMG_DIR / name
    if p.exists():
        return p
    p2 = IMG_DIR / "background.png"
    if p2.exists():
        return p2
    return None


def main():
    data = load_data()
    template = load_template()
    bg_path = get_background(data)
    now = datetime.datetime.now()

    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        sys.exit("Pillow not installed")

    # Load fonts
    font_cache = {}
    for (fam, sty), fpath in FONT_MAP.items():
        try:
            font_cache[(fam, sty)] = ImageFont.truetype(fpath, 12)  # dummy
        except:
            pass

    def get_font(family, style, size):
        key = (family, style, size)
        if key not in font_cache:
            fpath = FONT_MAP.get((family, style))
            if fpath and os.path.exists(fpath):
                font_cache[key] = ImageFont.truetype(fpath, size)
            else:
                font_cache[key] = ImageFont.load_default()
        return font_cache[key]

    # Create canvas
    img = Image.new("L", (WIDTH, HEIGHT), 255)

    # Background image
    if bg_path:
        try:
            bg = Image.open(bg_path).convert("L").resize((WIDTH, HEIGHT), Image.LANCZOS)
            img.paste(bg, (0, 0))
        except:
            pass

    draw = ImageDraw.Draw(img)

    # Process each element
    for el in template.get("elements", []):
        if not el.get("visible", True):
            continue

        el_id = el.get("id", "")
        el_type = el.get("type", "text")
        text_content = el.get("text", "")

        # Skip clock text - it's rendered locally by the Kobo client
        if el_id == "clock-text" or "{current_time}" in text_content:
            continue

        font_fam = el.get("font", "Sans")
        font_sty = el.get("style", "Regular")
        font_sz = el.get("size", 12)
        color = hex_color(el.get("color", "#000000"))
        align = el.get("align", "left")
        wx = el.get("x", 0)
        wy = el.get("y", 0)
        wrap_w = el.get("wrap_width", 0)

        if el_type == "clock_space":
            # clock_space is a reserved area for the FBInk clock overlay on the Kobo.
            # The server skips rendering it so the background shows through.
            # FBInk on the Kobo draws the time text with its own white background.
            continue

        font = get_font(font_fam, font_sty, font_sz)

        if el_type == "text":
            text = el.get("text", "")
            text = resolve_vars(text, data, now)
            prefix = el.get("prefix", "")
            if prefix:
                text = prefix + text
            if not text.strip():
                continue

            sw = 1
            text_fill = 255 if el.get("inverted") else color
            text_stroke = 0 if el.get("inverted") else 255

            if align == "right":
                lines = text.split("\n")
                for i, line in enumerate(lines):
                    bb = draw.textbbox((0, 0), line, font=font)
                    x = wx - (bb[2] - bb[0])
                    draw.text((x, wy + i * (font_sz + 3)), line, font=font, fill=text_fill, stroke_width=sw, stroke_fill=text_stroke)
            elif align == "center":
                lines = text.split("\n")
                for i, line in enumerate(lines):
                    bb = draw.textbbox((0, 0), line, font=font)
                    x = wx - (bb[2] - bb[0]) // 2
                    draw.text((x, wy + i * (font_sz + 3)), line, font=font, fill=text_fill, stroke_width=sw, stroke_fill=text_stroke)
            else:
                if wrap_w > 0:
                    wrapped = wrap_text(text, font, wrap_w, draw)
                else:
                    wrapped = text.split("\n")
                for i, line in enumerate(wrapped):
                    draw.text((wx, wy + i * (font_sz + 3)), line, font=font, fill=text_fill, stroke_width=sw, stroke_fill=text_stroke)

        elif el_type == "list":
            ds = el.get("data_source", "")
            items = data.get(ds, [])
            lfill = 255 if el.get("inverted") else color
            lstroke = 0 if el.get("inverted") else 255
            if not items:
                empty_text = el.get("empty_text", "")
                if empty_text:
                    draw.text((wx, wy), empty_text, font=font, fill=lfill, stroke_width=1, stroke_fill=lstroke)
                continue

            template_str = el.get("item_template", "{text}")
            line_h = el.get("line_height", font_sz + 4)
            max_n = el.get("max_items", 99)
            cur_y = wy

            for idx, item in enumerate(items):
                if idx >= max_n: break
                line = template_str
                for k, v in item.items():
                    if isinstance(v, str):
                        line = line.replace("{" + k + "}", v)
                    else:
                        line = line.replace("{" + k + "}", str(v))
                if ds == "todos":
                    mark = "[x]" if item.get("done") else "[ ]"
                    line = line.replace("{mark}", mark)
                draw.text((wx, cur_y), line, font=font, fill=lfill, stroke_width=1, stroke_fill=lstroke)
                cur_y += line_h

    # Output raw 608x800 8-bit grayscale
    out = bytearray(LINE_BYTES * HEIGHT)
    for y in range(HEIGHT):
        row = img.crop((0, y, WIDTH, y + 1)).tobytes()
        out[y * LINE_BYTES : y * LINE_BYTES + WIDTH] = row

    sys.stdout.buffer.write(out)


if __name__ == "__main__":
    main()
