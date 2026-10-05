"""
Flow diagrams for the user guide (decision 300).

ONE source -- src/content/guide/alur.json -- is laid out here into drawing primitives, and the same primitives
are written as (a) SVG files for the website's "Alur Kerja" pages and (b) reportlab Drawings for the PDF, so
the website and the PDF always show the same diagram.

Layout is a top-to-bottom flowchart:
  * "start" / "step" / "end" nodes are stacked and joined by arrows;
  * a "choice" is a diamond (a question) whose answers ("branches") run side by side, then join again.
Each node says WHO acts (Pelanggan / Anda / Sistem, colour coded), WHAT is done, and WHICH MENU to open.
"""
import hashlib
import json
import os
from xml.sax.saxutils import escape

from reportlab.pdfbase.pdfmetrics import stringWidth

HERE = os.path.dirname(os.path.abspath(__file__))
GUIDE_DIR_DEFAULT = os.path.normpath(os.path.join(HERE, "..", "..", "src", "content", "guide"))

FONT = "Helvetica"
BOLD = "Helvetica-Bold"
OBLIQUE = "Helvetica-Oblique"

MARGIN = 18
GAP_Y = 28
COL_GAP = 22
DEFAULT_NODE_W = 210
DIAMOND_W = 300
LINE = "#444444"

ACTORS = {
    "pelanggan": {"fill": "#fdf2e3", "stroke": "#b5791a", "chip": "#8a5a00", "label": "PELANGGAN"},
    "anda": {"fill": "#eef2f8", "stroke": "#1a2b4a", "chip": "#1a2b4a", "label": "ANDA"},
    "sistem": {"fill": "#e6f2e8", "stroke": "#2f5233", "chip": "#2f5233", "label": "SISTEM (OTOMATIS)"},
}
END_FILL = "#2f5233"
CHOICE_FILL = "#fff6cf"
CHOICE_STROKE = "#8a6d00"
MENU_COLOR = "#1a4d8f"
NOTE_COLOR = "#555555"


def load(guide_dir=None):
    path = os.path.join(guide_dir or GUIDE_DIR_DEFAULT, "alur.json")
    with open(path, "rb") as handle:
        raw = handle.read()
    return json.loads(raw.decode("utf-8")), hashlib.sha256(raw).hexdigest()[:16]


def _wrap(text, font, size, max_width):
    """Greedy word wrap using real Helvetica metrics (browsers render Arial/Helvetica with the same widths)."""
    words = text.split()
    lines, current = [], ""
    for word in words:
        trial = word if not current else current + " " + word
        if stringWidth(trial, font, size) * 1.03 <= max_width or not current:
            current = trial
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines or [""]


class Layout:
    def __init__(self, flow):
        self.flow = flow
        self.nw = flow.get("width", DEFAULT_NODE_W)
        self.ops = []
        self.groups = []

    # -- measuring -------------------------------------------------------------------------------------
    def measure(self, items):
        width = self.nw
        for item in items:
            if item["kind"] == "choice":
                width = max(width, self._choice_width(item))
        return width

    def _choice_width(self, choice):
        branches = choice["branches"]
        col = max(self.measure(b["items"]) for b in branches) + COL_GAP
        return max(len(branches) * col - COL_GAP, DIAMOND_W)

    def _col(self, choice):
        return max(self.measure(b["items"]) for b in choice["branches"]) + COL_GAP

    # -- primitives --------------------------------------------------------------------------------------
    def rect(self, x, y, w, h, fill, stroke, rx=8, sw=1.4):
        self.ops.append({"t": "rect", "x": x, "y": y, "w": w, "h": h, "rx": rx, "fill": fill, "stroke": stroke, "sw": sw})

    def poly(self, pts, fill, stroke, sw=1.4):
        self.ops.append({"t": "poly", "pts": pts, "fill": fill, "stroke": stroke, "sw": sw})

    def line(self, pts, sw=1.4, color=LINE):
        self.ops.append({"t": "line", "pts": pts, "stroke": color, "sw": sw})

    def text(self, x, y, s, size, font=FONT, fill="#111111", anchor="middle"):
        self.ops.append({"t": "text", "x": x, "y": y, "s": s, "size": size, "font": font, "fill": fill, "anchor": anchor})

    def arrow(self, x, y1, y2):
        """Vertical connector from y1 down to y2 with an arrowhead at y2."""
        self.line([(x, y1), (x, y2 - 5)])
        self.poly([(x, y2), (x - 4.5, y2 - 8), (x + 4.5, y2 - 8)], LINE, LINE, 0.5)

    # -- drawing ---------------------------------------------------------------------------------------
    def node(self, item, cx, y):
        nw = self.nw
        inner = nw - 20
        kind = item["kind"]
        actor = ACTORS[item.get("actor", "anda")]
        title_lines = _wrap(item["title"], BOLD, 10.5, inner)
        menu_lines = _wrap("Menu: " + item["menu"], FONT, 9, inner) if item.get("menu") else []
        note_lines = _wrap(item["note"], OBLIQUE, 8.6, inner) if item.get("note") else []

        if kind in ("start", "end"):
            height = 16 + len(title_lines) * 13.5 + (len(note_lines) * 11.5 + 3 if note_lines else 0)
            fill = actor["stroke"] if kind == "start" else END_FILL
            self.rect(cx - nw / 2, y, nw, height, fill, fill, rx=min(18, height / 2))
            ty = y + 8 + 10.5
            for line in title_lines:
                self.text(cx, ty, line, 10.5, BOLD, "#ffffff")
                ty += 13.5
            ty += 0
            for line in note_lines:
                self.text(cx, ty, line, 8.6, OBLIQUE, "#e9efe9")
                ty += 11.5
            return y + height

        height = 8 + 11 + len(title_lines) * 13.5 + (len(menu_lines) * 12 + 3 if menu_lines else 0) \
            + (len(note_lines) * 11.5 + 3 if note_lines else 0) + 8
        self.rect(cx - nw / 2, y, nw, height, actor["fill"], actor["stroke"])
        self.text(cx - nw / 2 + 10, y + 13, actor["label"], 7, BOLD, actor["chip"], "start")
        ty = y + 11 + 8 + 10.5
        for line in title_lines:
            self.text(cx - nw / 2 + 10, ty, line, 10.5, BOLD, "#111111", "start")
            ty += 13.5
        if menu_lines:
            ty += 3 - 1.5
            for line in menu_lines:
                self.text(cx - nw / 2 + 10, ty, line, 9, FONT, MENU_COLOR, "start")
                ty += 12
            ty += 1.5
        if note_lines:
            ty += 3 - 1.5
            for line in note_lines:
                self.text(cx - nw / 2 + 10, ty, line, 8.6, OBLIQUE, NOTE_COLOR, "start")
                ty += 11.5
        return y + height

    def choice(self, item, cx, y):
        branches = item["branches"]
        n = len(branches)
        col = self._col(item)
        dw = DIAMOND_W
        lines = _wrap(item["question"], BOLD, 10, dw * 0.54)
        dh = max(70, len(lines) * 13 * 2 + 8)
        self.poly([(cx, y), (cx + dw / 2, y + dh / 2), (cx, y + dh), (cx - dw / 2, y + dh / 2)], CHOICE_FILL, CHOICE_STROKE)
        ty = y + dh / 2 - (len(lines) * 13) / 2 + 10
        for line in lines:
            self.text(cx, ty, line, 10, BOLD, "#3d3000")
            ty += 13

        bus_y = y + dh + 16
        self.line([(cx, y + dh), (cx, bus_y)])
        centers = [cx + (i - (n - 1) / 2) * col for i in range(n)]
        self.line([(min(centers), bus_y), (max(centers), bus_y)])
        top = bus_y + 34
        exits = []
        for bx, branch in zip(centers, branches):
            label = branch["label"]
            if branch["items"]:
                self.line([(bx, bus_y), (bx, top - 5)])
                self.poly([(bx, top), (bx - 4.5, top - 8), (bx + 4.5, top - 8)], LINE, LINE, 0.5)
                exits.append(self.sequence(branch["items"], bx, top))
            else:
                exits.append(None)
            self._label(bx, bus_y + 17, label)
        bottoms = [e for e in exits if e is not None]
        merge_y = (max(bottoms) if bottoms else top) + 20
        for bx, bottom in zip(centers, exits):
            self.line([(bx, bus_y if bottom is None else bottom), (bx, merge_y)])
        self.line([(min(centers), merge_y), (max(centers), merge_y)])
        return merge_y

    def _label(self, x, y, label):
        w = stringWidth(label, BOLD, 8.5) + 12
        self.rect(x - w / 2, y - 8, w, 15, "#ffffff", CHOICE_STROKE, rx=7.5, sw=1)
        self.text(x, y + 3, label, 8.5, BOLD, "#3d3000")

    def sequence(self, items, cx, y, track=False):
        first = True
        for item in items:
            start_ops, start_y = len(self.ops), y
            if not first:
                self.arrow(cx, y, y + GAP_Y)
                y += GAP_Y
            first = False
            y = self.choice(item, cx, y) if item["kind"] == "choice" else self.node(item, cx, y)
            if track:
                # One group per top-level item (with the arrow leading into it): the PDF cuts between groups.
                self.groups.append({"start": start_ops, "end": len(self.ops), "top": start_y, "bottom": y})
        return y

    def legend(self, width, y):
        entries = [("pelanggan", "Pelanggan"), ("anda", "Anda (pengguna aplikasi)"), ("sistem", "Sistem (otomatis)")]
        size = 8
        total = 0
        for _, label in entries:
            total += 12 + 4 + stringWidth(label, FONT, size) + 16
        total += 12 + 4 + stringWidth("Pertanyaan", FONT, size)
        x = (width - total) / 2
        for key, label in entries:
            a = ACTORS[key]
            self.rect(x, y, 12, 10, a["fill"], a["stroke"], rx=2, sw=1)
            self.text(x + 16, y + 8, label, size, FONT, "#444444", "start")
            x += 12 + 4 + stringWidth(label, FONT, size) + 16
        self.poly([(x + 6, y - 1), (x + 12, y + 5), (x + 6, y + 11), (x, y + 5)], CHOICE_FILL, CHOICE_STROKE, 1)
        self.text(x + 16, y + 8, "Pertanyaan", size, FONT, "#444444", "start")

    def build(self):
        items = self.flow["items"]
        width = self.measure(items) + 2 * MARGIN
        cx = width / 2
        y = self.sequence(items, cx, MARGIN, track=True)
        self.bottom = y
        self.legend(width, y + 26)
        return width, y + 26 + 10 + MARGIN, self.ops

    def segments(self, max_height):
        """
        Splits the drawing between top-level items into pieces no taller than max_height (drawing units), for
        the PDF where a long flow cannot fit on one page. Returns (width, [(height, ops)]). The legend is kept
        with the last piece; a small "bersambung" marker joins the pieces.
        """
        width, full_height, ops = self.build()
        cx = width / 2
        pieces, current = [], []
        for group in self.groups:
            trial = current + [group]
            span = trial[-1]["bottom"] - trial[0]["top"]
            if current and span + 60 > max_height:
                pieces.append(current)
                current = [group]
            else:
                current = trial
        pieces.append(current)
        legend_ops = ops[self.groups[-1]["end"]:]
        result = []
        for index, piece in enumerate(pieces):
            first_piece, last_piece = index == 0, index == len(pieces) - 1
            pad_top = MARGIN if first_piece else 18
            dy = pad_top - piece[0]["top"] if not first_piece else 0
            seg_ops = []
            if not first_piece:
                seg_ops.append({"t": "text", "x": cx, "y": 10, "s": "(lanjutan dari halaman sebelumnya)", "size": 7.5,
                                "font": OBLIQUE, "fill": "#777777", "anchor": "middle"})
            for group in piece:
                seg_ops += [_shift(op, dy) for op in ops[group["start"]:group["end"]]]
            bottom = piece[-1]["bottom"] + dy
            if last_piece:
                legend_y = self.bottom + 26 + dy
                seg_ops += [_shift(op, dy) for op in legend_ops]
                height = legend_y + 10 + MARGIN
            else:
                seg_ops.append({"t": "text", "x": cx, "y": bottom + 14, "s": "(bersambung di halaman berikutnya)",
                                "size": 7.5, "font": OBLIQUE, "fill": "#777777", "anchor": "middle"})
                height = bottom + 22
            result.append((height, seg_ops))
        return width, result


def layout(flow):
    return Layout(flow).build()


def _shift(op, dy):
    moved = dict(op)
    if "y" in moved:
        moved["y"] = moved["y"] + dy
    if "pts" in moved:
        moved["pts"] = [(x, y + dy) for x, y in moved["pts"]]
    return moved


# ------------------------------------------------------------------------------------------------------------
# Backends
# ------------------------------------------------------------------------------------------------------------
def _n(v):
    return ("%.2f" % v).rstrip("0").rstrip(".")


def to_svg(flow, source_hash):
    width, height, ops = layout(flow)
    out = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s" role="img" '
        'aria-label="%s" font-family="Helvetica, Arial, sans-serif">' % (_n(width), _n(height), _n(width), _n(height), escape(flow["title"], {'"': "&quot;"})),
        "<!-- source: alur.json sha256:%s (dibuat oleh scripts/guide/build_flow_diagrams.py; jangan diedit tangan) -->" % source_hash,
        "<title>%s</title>" % escape(flow["title"]),
        '<rect width="100%" height="100%" fill="#ffffff"/>',
    ]
    for op in ops:
        t = op["t"]
        if t == "rect":
            out.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s" stroke="%s" stroke-width="%s"/>' % (
                _n(op["x"]), _n(op["y"]), _n(op["w"]), _n(op["h"]), _n(op["rx"]), op["fill"], op["stroke"], _n(op["sw"])))
        elif t == "poly":
            pts = " ".join("%s,%s" % (_n(x), _n(y)) for x, y in op["pts"])
            out.append('<polygon points="%s" fill="%s" stroke="%s" stroke-width="%s" stroke-linejoin="round"/>' % (
                pts, op["fill"], op["stroke"], _n(op["sw"])))
        elif t == "line":
            pts = " ".join("%s,%s" % (_n(x), _n(y)) for x, y in op["pts"])
            out.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s"/>' % (pts, op["stroke"], _n(op["sw"])))
        elif t == "text":
            weight = ' font-weight="bold"' if op["font"] == BOLD else ""
            style = ' font-style="italic"' if op["font"] == OBLIQUE else ""
            out.append('<text x="%s" y="%s" font-size="%s"%s%s fill="%s" text-anchor="%s">%s</text>' % (
                _n(op["x"]), _n(op["y"]), _n(op["size"]), weight, style, op["fill"], op["anchor"], escape(op["s"])))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def _ops_to_drawing(ops, width, height, scale):
    from reportlab.graphics.shapes import Drawing, Polygon, PolyLine, Rect, String
    from reportlab.lib import colors

    drawing = Drawing(width, height)
    flip = lambda y: height - y  # noqa: E731 -- SVG y grows downward, PDF y grows upward
    for op in ops:
        t = op["t"]
        if t == "rect":
            drawing.add(Rect(op["x"], flip(op["y"] + op["h"]), op["w"], op["h"], rx=op["rx"], ry=op["rx"],
                             fillColor=colors.HexColor(op["fill"]), strokeColor=colors.HexColor(op["stroke"]),
                             strokeWidth=op["sw"]))
        elif t == "poly":
            flat = []
            for x, y in op["pts"]:
                flat += [x, flip(y)]
            drawing.add(Polygon(flat, fillColor=colors.HexColor(op["fill"]), strokeColor=colors.HexColor(op["stroke"]),
                                strokeWidth=op["sw"]))
        elif t == "line":
            flat = []
            for x, y in op["pts"]:
                flat += [x, flip(y)]
            drawing.add(PolyLine(flat, strokeColor=colors.HexColor(op["stroke"]), strokeWidth=op["sw"]))
        elif t == "text":
            drawing.add(String(op["x"], flip(op["y"]), op["s"], fontName=op["font"], fontSize=op["size"],
                               fillColor=colors.HexColor(op["fill"]), textAnchor=op["anchor"]))
    drawing.width = width * scale
    drawing.height = height * scale
    drawing.scale(scale, scale)
    return drawing


def to_drawings(flow, max_width, max_height):
    """
    reportlab Drawings for the PDF: one per page-sized piece, scaled down (never up) to max_width points wide.
    A flow taller than max_height is cut between its top-level steps.
    """
    layout_ = Layout(flow)
    probe_width = layout_.measure(flow["items"]) + 2 * MARGIN
    scale = min(1.0, max_width / probe_width)
    width, pieces = Layout(flow).segments(max_height / scale)
    return [_ops_to_drawing(ops, width, height, scale) for height, ops in pieces]
