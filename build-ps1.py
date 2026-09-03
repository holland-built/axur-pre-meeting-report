#!/usr/bin/env python3
"""Generate axur-report.ps1 from axur-report.sh.

The report's HTML lives once, in the shell script. This lifts the two heredocs
out of it and embeds them in the PowerShell script, so Windows writes the same
report Mac does. Re-run it after editing any HTML in axur-report.sh.
"""
import re, sys, pathlib

sh = pathlib.Path("axur-report.sh").read_text()
lines = sh.split("\n")

def block(open_marker, close_marker):
    i = next(k for k, l in enumerate(lines) if l.startswith(open_marker))
    j = next(k for k in range(i + 1, len(lines)) if lines[k] == close_marker)
    return "\n".join(lines[i + 1:j])

head = block("cat <<HTMLHEAD", "HTMLHEAD")
tail = block("cat <<'HTMLTAIL'", "HTMLTAIL")

# the shell interpolates these four; PowerShell will .Replace() them instead
for var, ph in (("BRAND", "{{BRAND}}"), ("DOMAIN", "{{DOMAIN}}"),
                ("LOGO", "{{LOGO}}"), ("OURS", "{{OURS}}")):
    head = head.replace("${%s}" % var, ph).replace("$" + var, ph)

for name, text in (("HTMLHEAD", head), ("HTMLTAIL", tail)):
    for bad in ("'@", '"@'):
        if any(l.strip().startswith(bad) for l in text.split("\n")):
            sys.exit("%s has a line starting with %s, which would close a "
                     "PowerShell here-string" % (name, bad))

ps = pathlib.Path("axur-report.ps1.in").read_text()
ps = ps.replace("###HTMLHEAD###", head).replace("###HTMLTAIL###", tail)
# Windows tooling is happier with CRLF, so write the bytes rather than trust
# the platform default.
pathlib.Path("axur-report.ps1").write_bytes(
    ps.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
print("wrote axur-report.ps1: %d lines (head %d, tail %d)"
      % (ps.count("\n") + 1, head.count("\n") + 1, tail.count("\n") + 1))
