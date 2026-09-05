#!/usr/bin/env python3
"""A stand-in for the Axur API, so the report script can be run end to end.

Behaviour is steered by environment variables so one server covers every test:
  FAKE_CLAMP=1      out-of-range pages return page 1 again (the paging bug)
  FAKE_BADJSON=N    search N's reply is malformed JSON
  FAKE_PAGES=N      how many distinct pages each signal-lake search has
"""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

CLAMP    = os.environ.get("FAKE_CLAMP") == "1"
BADJSON  = os.environ.get("FAKE_BADJSON", "")
TRUNC    = os.environ.get("FAKE_TRUNC", "")   # search N's reply is cut off mid-array
PAGES    = int(os.environ.get("FAKE_PAGES", "3"))
SHAPE    = os.environ.get("FAKE_SHAPE", "")
# a plausible spread per search, so a screenshot does not show five identical numbers
TOTALS   = [3412, 2906, 1184, 78, 31]  # "reference" = signal-lake rows, which carry no "domain"
SLOW     = float(os.environ.get("FAKE_SLOW", "0"))
NOSCORE  = os.environ.get("FAKE_NOSCORE") == "1"
LOWRISK  = os.environ.get("FAKE_LOWRISK") == "1"   # every score under the high-risk cut-off
NODATE   = os.environ.get("FAKE_NODATE") == "1"   # reject any query with a date clause
LOG      = open(os.environ.get("FAKE_LOG", "/dev/null"), "a")

SEARCHES = {}   # id -> {"n": ordinal, "query": ..., "source": ...}

def row(seq, page):
    """One result row, shaped like the real thing."""
    if SHAPE == "reference":
        # what signal-lake actually returns for a phishing page: no "domain",
        # no "url" - the site is named by "reference"
        return {
            "id": "row-p%d-%d" % (page, seq),
            "reference": "larkspurfinancial.com.%d-p%d.example" % (seq, page),
            "renderedReference": "http://larkspurfinancial.com.%d-p%d.example/login" % (seq, page),
            "host": "larkspurfinancial.com.%d-p%d.example" % (seq, page),
            "accessUrl": "http://larkspurfinancial.com.%d-p%d.example/login" % (seq, page),
            "riskScore": [55, 91, 34, 78, 12, 66][(seq + page) % 6],
            "detectionDate": 1788429683595 - (seq + page) * 86400000,
        }
    return {
        "id": "row-p%d-%d" % (page, seq),
        "domain": "larkspur%d-p%d.example" % (seq, page),
        "reference": "larkspur%d-p%d.example" % (seq, page),
        "renderedReference": "http://larkspur%d-p%d.example/login" % (seq, page),
        "host": "larkspur%d-p%d.example" % (seq, page),
        "accessUrl": "http://larkspur%d-p%d.example/login" % (seq, page),
        "riskScore": [55, 91, 34, 78, 12, 66][(seq + page) % 6],
        "detectionDate": 1788429683595 - (seq + page) * 86400000,
        "passwordType": ["HASH", "PLAIN", "HASH", "PLAIN"][seq % 4],
        "password": "hunter2",
    }

def strip_scores(rows):
    if NOSCORE:
        for r in rows: r.pop("riskScore", None)
    elif LOWRISK:
        for r in rows: r["riskScore"] = min(r.get("riskScore", 0), 55)
    return rows


def body(sid, page):
    meta = SEARCHES[sid]
    rows = strip_scores([row(i, page) for i in range(1, 4)])
    n = TOTALS[(meta["n"] - 1) % 5]
    return {"id": sid,
            "result": {"status": {"running": False, "totalResults": n},
                       "data": rows}}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, obj, raw=None):
        text = raw if raw is not None else json.dumps(obj, separators=(",", ":"))
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        if NODATE and "detectionDate" in req.get("query", ""):
            self.send({"error": "Field not found: detectionDate"}); return
        sid = "search-%d" % (len(SEARCHES) + 1)
        SEARCHES[sid] = {"n": len(SEARCHES) + 1, **req}
        LOG.write("POST auth=%r\n" % self.headers.get("Authorization"))
        LOG.flush()
        self.send({"searchId": sid})

    def do_GET(self):
        if SLOW: time.sleep(SLOW)
        u = urlparse(self.path)
        sid = u.path.rsplit("/", 1)[-1]
        page = int(parse_qs(u.query).get("page", ["1"])[0])
        LOG.write("GET %s page=%d auth=%r\n" % (sid, page, self.headers.get("Authorization")))
        LOG.flush()
        if sid not in SEARCHES:
            self.send({"error": "no such search"}); return
        ordinal = (SEARCHES[sid]["n"] - 1) % 5 + 1   # five searches per run
        if BADJSON and ordinal == int(BADJSON) and page == 1:
            self.send(None, raw='{"id":"%s","result":{"status":{"running":false,'
                                '"totalResults":300},"data":[{"broken":]}}' % sid)
            return
        if TRUNC and ordinal == int(TRUNC) and page == 1:
            full = json.dumps(body(sid, 1), separators=(",", ":"))
            self.send(None, raw=full[:len(full) - 40])   # a truncated reply, as a dropped connection gives
            return
        if page > PAGES:
            if CLAMP:
                page = PAGES                  # clamps to the last page, as real paging APIs do
            else:
                self.send({"id": sid, "result": {"status": {"running": False,
                          "totalResults": 300}, "data": []}})
                return
        self.send(body(sid, page))

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
