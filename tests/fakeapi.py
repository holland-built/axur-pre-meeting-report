#!/usr/bin/env python3
"""A stand-in for the Axur API, so the report script can be run end to end.

Behaviour is steered by environment variables so one server covers every test:
  FAKE_CLAMP=1      out-of-range pages return page 1 again (the paging bug)
  FAKE_BADJSON=N    search N's reply is malformed JSON
  FAKE_PAGES=N      how many distinct pages each signal-lake search has
  FAKE_DUPES=1      page 1 of a signal-lake search names one host four times
  FAKE_ODDROW=KIND  with FAKE_DUPES, one odd thing about the repeated rows:
                    Host (capitalised key), surrogate (a lone \\ud83d escape),
                    control (a raw 0x01 byte in the host), nan (riskScore "NaN"),
                    duphost (two "host" keys), duprisk (two "riskScore" keys, 91 then 5),
                    marker (a field named __unfoldable, which is a name the
                    Windows script once used for its own internal mark)
  FAKE_ODDTOTAL=1   totalResults is the word "unknown", not a number
  FAKE_NOTOTAL=1    the status carries no totalResults, so the count is unknown
  FAKE_RUNNING=1    the search never finishes, so its count is only a floor
  FAKE_EXACT=1      totalResults is the number of rows the search really has
  FAKE_LONEFIRST=1  with FAKE_DUPES, the row that stands alone arrives first and
                    outscores every repeated row, so a small --rows cuts the
                    table before the folded group
  FAKE_CREDDUPES=1  page 1 of a credential search names one account six times on
                    six sites, one of them PLAIN and not the newest; one account
                    twice on one site; one account twice with no site at all;
                    and one account once
  FAKE_CREDODD=KIND with FAKE_CREDDUPES, one odd thing about the repeated rows:
                    xss (the first site, and the PLAIN row's site, which is the
                    row that survives the fold, are </script><img src=x onerror=alert(1)>),
                    sitecase (NETFLIX.COM, then https://netflix.com/path with no
                    accessHost, so five sites not six), many (ten sites)
  FAKE_CREDMIX=KIND page 1 of the first credential search holds an account with
                    2 PLAIN rows and 3 hashed rows, a row of that account with
                    no passwordType, and a row whose passwordType is a lone
                    \\ud83d escape; "all" adds an account with hashed rows only
                    and one with readable rows only. The second credential
                    search gets the PLAIN rows alone, as Axur would answer it
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
DUPES    = os.environ.get("FAKE_DUPES") == "1"    # page 1 repeats one host, on different paths and days
LONEFIRST = os.environ.get("FAKE_LONEFIRST") == "1"  # the lone row outscores the repeated ones
ODDROW   = os.environ.get("FAKE_ODDROW", "")      # Host | surrogate | control | nan, see above
NOTOTAL  = os.environ.get("FAKE_NOTOTAL") == "1"  # no totalResults in the status
RUNNING  = os.environ.get("FAKE_RUNNING") == "1"  # running stays true
EXACT    = os.environ.get("FAKE_EXACT") == "1"    # totalResults equals the rows on hand
ODDTOTAL = os.environ.get("FAKE_ODDTOTAL") == "1" # totalResults is not a number
CREDDUPES = os.environ.get("FAKE_CREDDUPES") == "1"  # page 1 repeats one account across sites
CREDODD  = os.environ.get("FAKE_CREDODD", "")      # xss | sitecase | many, see above
CREDMIX  = os.environ.get("FAKE_CREDMIX", "")      # mixed | all, see above
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


def dupes(rows):
    """Page 1 of a signal-lake search: one host four times, on different paths
    and days, and one host standing for itself. The top score is on a repeat,
    so the row that stands for the group is decidable."""
    out = []
    for i, (path, score, days) in enumerate([("/login", 91, 1), ("/verify", 40, 30), ("/reset", 66, 200), ("/pay", 12, 3)]):
        r = dict(rows[0]); r["id"] = "row-dupe-%d" % i
        for f in ("reference", "host", "domain"):
            if f in r: r[f] = "larkspur-login.example"
        for f in ("renderedReference", "accessUrl"):
            if f in r: r[f] = "http://larkspur-login.example" + path
        r["riskScore"] = score
        r["detectionDate"] = 1788429683595 - days * 86400000
        out.append(r)
    if ODDROW == "Host":
        for r in out:
            for f in ("reference", "host", "domain"): r.pop(f, None)
            r["Host"] = "larkspur-login.example"
    elif ODDROW == "surrogate":
        for r in out: r["host"] = "\ud83d.example"
    elif ODDROW == "control":
        for r in out: r["host"] = "larkspur\x01login.example"   # made raw in do_GET
    elif ODDROW == "nan":
        out[0]["riskScore"] = "NaN"; out[2]["riskScore"] = 91
    elif ODDROW == "duphost":
        for r in out: r["hostDUP"] = "larkspur-login.example"   # DUP is cut off in do_GET
    elif ODDROW == "marker":
        # A field named like the Windows script's own internal mark. The rows
        # are the customer's leaked data, so the name is one somebody else can
        # choose; it must mean nothing to either script.
        for r in out: r["__unfoldable"] = True
    elif ODDROW == "duprisk":
        out[0]["riskScoreDUP"] = 5; out[2]["riskScore"] = 91
    lone = dict(rows[1]); lone["riskScore"] = 95 if LONEFIRST else 34
    # The trim keeps the rows the API sent first, and the fold leaves the row
    # that stands for a group where that group started. So to get a table cut
    # before the folded group, the lone row has to arrive first.
    if LONEFIRST: return [lone] + out
    out.append(lone)
    return out

def cred_dupes():
    """Page 1 of a credential search: abelle on six sites, the third of them
    PLAIN and not the newest, so the row that stands for the group is decided
    by the password kind and not the date; cboyd twice on one site; dnoble
    twice with no site named anywhere; eport once."""
    sites = ["netflix.com", "linkedin.com", "github.com", "dropbox.com", "slack.com", "zoom.us"]
    if CREDODD == "many":
        sites += ["adobe.com", "spotify.com", "reddit.com", "twitch.tv"]
    out = []
    for i, site in enumerate(sites):
        plain = (i == 2)
        out.append({
            "id": "row-cred-%d" % i,
            # one row spells the account in capitals: the key is ASCII-lowercased
            "user": "Abelle@Larkspur.com" if i == 1 else "abelle@larkspur.com",
            "password": "readable2" if plain else "hash%d" % i,
            "passwordType": "PLAIN" if plain else "HASH",
            "accessHost": site,
            "accessUrl": "https://%s/login" % site,
            "sourceName": "IntelX",
            "sourceDate": 1788429683595 - (i + 10) * 86400000,
            "detectionDate": 1788429683595 - (i + 1) * 86400000,
        })
    if CREDODD == "xss":
        # on the first row, so it leads the site list; and on the PLAIN row,
        # which stands for the group, so its raw text reaches the report
        for i in (0, 2):
            out[i]["accessHost"] = "</script><img src=x onerror=alert(1)>"
            out[i]["accessUrl"] = "https://</script><img src=x onerror=alert(1)>/login"
    elif CREDODD == "sitecase":
        out[0]["accessHost"] = "NETFLIX.COM"
        del out[1]["accessHost"]
        out[1]["accessUrl"] = "https://netflix.com/path"
    for j in range(2):
        out.append({"id": "row-cred-one-%d" % j, "user": "cboyd@larkspur.com", "password": "hashone%d" % j,
                    "passwordType": "HASH", "accessHost": "netflix.com", "accessUrl": "https://netflix.com/",
                    "sourceName": "IntelX", "sourceDate": 1788429683595, "detectionDate": 1788429683595 - (j + 8) * 86400000})
    for j in range(2):
        out.append({"id": "row-cred-nosite-%d" % j, "user": "dnoble@larkspur.com", "password": "hashnone%d" % j,
                    "passwordType": "HASH", "sourceName": "IntelX",
                    "sourceDate": 1788429683595 - j * 86400000, "detectionDate": 1788429683595 - (j + 20) * 86400000})
    out.append({"id": "row-cred-lone", "user": "eport@larkspur.com", "password": "hashlone",
                "passwordType": "HASH", "accessHost": "zoom.us", "accessUrl": "https://zoom.us/",
                "sourceName": "IntelX", "sourceDate": 1788429683595, "detectionDate": 1788429683595})
    return out

def cred_mix(ordinal):
    """fmixed: 2 PLAIN rows and 3 hashed rows, so the fold's counts are 3 and
    3 - counting accounts would say 1, counting pairings 6. Then a row of
    fmixed with no passwordType and a row whose passwordType is not JSON,
    which belong in neither bucket. With "all": ghash, hashed only, and
    hplain, readable only. The second search sees the PLAIN rows alone."""
    def r(i, user, kind, site):
        out = {"id": "row-mix-%d" % i, "user": user, "password": "readable%d" % i if kind == "PLAIN" else "hash%d" % i,
               "accessHost": site, "accessUrl": "https://%s/login" % site, "sourceName": "IntelX",
               "sourceDate": 1788429683595 - (i + 10) * 86400000, "detectionDate": 1788429683595 - (i + 1) * 86400000}
        if kind is not None: out["passwordType"] = kind
        return out
    sites = ["netflix.com", "linkedin.com", "github.com", "dropbox.com", "slack.com", "zoom.us", "adobe.com"]
    kinds = ["PLAIN", "HASH", "PLAIN", "HASH", "HASH"]
    out = [r(i, "fmixed@larkspur.com", kinds[i], sites[i]) for i in range(5)]
    out.append(r(5, "fmixed@larkspur.com", None, sites[5]))
    out.append(r(6, "iodd@larkspur.com", "\ud83d", sites[6]))
    if CREDMIX == "all":
        out += [r(7 + j, "ghash@larkspur.com", "HASH", sites[j]) for j in range(2)]
        out += [r(9 + j, "hplain@larkspur.com", "PLAIN", sites[j]) for j in range(2)]
    if ordinal == 2:
        out = [x for x in out if x.get("passwordType") == "PLAIN"]
    return out

def body(sid, page):
    meta = SEARCHES[sid]
    rows = [row(i, page) for i in range(1, 4)]
    if DUPES and page == 1 and meta.get("source") == "signal-lake":
        rows = dupes(rows)
    if CREDDUPES and page == 1 and meta.get("source") == "credential":
        rows = cred_dupes()
    if CREDMIX and page == 1 and meta.get("source") == "credential":
        rows = cred_mix((meta["n"] - 1) % 5 + 1)
    rows = strip_scores(rows)
    n = TOTALS[(meta["n"] - 1) % 5]
    if EXACT and meta.get("source") == "signal-lake":
        n = 3 * PAGES + (2 if DUPES else 0)
    status = {"running": RUNNING, "totalResults": "unknown" if ODDTOTAL else n}
    if NOTOTAL: del status["totalResults"]
    return {"id": sid,
            "result": {"status": status,
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
        if ODDROW in ("control", "duphost", "duprisk"):
            # json.dumps escapes the byte and a dict cannot hold a key twice; the
            # point is text JSON forbids, so write the text and then alter it
            raw = json.dumps(body(sid, page), separators=(",", ":"))
            self.send(None, raw=raw.replace("\\u0001", "\x01").replace('DUP":', '":'))
            return
        self.send(body(sid, page))

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
