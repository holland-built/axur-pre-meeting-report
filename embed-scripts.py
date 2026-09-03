#!/usr/bin/env python3
"""Push the two scripts back into guide.html's download buttons.

The guide carries each script inside a JavaScript string array so its download
button can hand it over. Edit the scripts, then run this, or the buttons serve
stale code and nothing on the page says so.
"""
import pathlib, sys

def quote(line):
    return "      '" + (line.replace('\\', '\\\\').replace("'", "\\'")
                            .replace('</', '<\\/')) + "',"

def swap(doc, start_marker, end_marker, lines):
    i = doc.index(start_marker)
    j = doc.index(end_marker, i)
    if doc.count(start_marker) != 1:
        sys.exit("marker %r is not unique; the page has drifted" % start_marker)
    body = "\n".join(quote(l) for l in lines)
    return doc[:i + len(start_marker)] + "\n" + body + "\n    " + doc[j:]

page = pathlib.Path("guide.html").read_text()
for path, start, end, sep in (
        ("axur-report.sh",  "    var sh = [", "].join('\\n');",   "\n"),
        ("axur-report.ps1", "    var ps = [", "].join('\\r\\n');", "\r\n")):
    text = pathlib.Path(path).read_text().replace("\r\n", "\n")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    page = swap(page, start, end, lines)
    print("embedded %s: %d lines" % (path, len(lines)))
pathlib.Path("guide.html").write_text(page)
