#!/usr/bin/env python3
"""
Writes src/content/guide/diagrams/<id>.svg for every flow in src/content/guide/alur.json (decision 300).

    python3 scripts/guide/build_flow_diagrams.py            # (re)write the SVG files
    python3 scripts/guide/build_flow_diagrams.py --check    # exit 1 when a file is missing or out of date

Run it after editing alur.json, and commit the SVG files together with it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flow_diagrams  # noqa: E402


def main():
    check = "--check" in sys.argv
    guide_dir = flow_diagrams.GUIDE_DIR_DEFAULT
    data, source_hash = flow_diagrams.load(guide_dir)
    out_dir = os.path.join(guide_dir, "diagrams")
    os.makedirs(out_dir, exist_ok=True)
    stale = []
    for flow in data["flows"]:
        path = os.path.join(out_dir, flow["id"] + ".svg")
        svg = flow_diagrams.to_svg(flow, source_hash)
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if current != svg:
            stale.append(flow["id"])
            if not check:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(svg)
    if check and stale:
        print("Diagram usang atau belum ada: %s. Jalankan build_flow_diagrams.py." % ", ".join(stale))
        sys.exit(1)
    print("%d diagram, %d diperbarui" % (len(data["flows"]), 0 if check else len(stale)))


if __name__ == "__main__":
    main()
