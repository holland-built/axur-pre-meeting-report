#!/usr/bin/env bash
# The regression suite. Runs both report scripts end to end against a stand-in
# Axur API, and checks what came out.
#
#   tests/run.sh
#
# Nothing here touches the real Axur API or the network. The stand-in listens
# on 127.0.0.1 only, and mkfake.sh refuses to make a copy that still points at
# api.axur.com.
#
# PowerShell is optional. Set PWSH, or put pwsh on the PATH, or leave a build
# in ~/.local/pwsh. Without one the PowerShell checks are skipped, and the
# summary says how many were skipped.
#
# Every run works in its own directory made by mktemp and removed on the way
# out. A check can therefore never pass by reading a file an earlier run left
# behind - the file it reads did not exist one second before the run that
# wrote it.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PORT=${PORT:-8731}

# ---------- find PowerShell, or say it is missing ----------
PWSH=${PWSH:-}
[ -z "$PWSH" ] && PWSH=$(command -v pwsh 2>/dev/null || true)
[ -z "$PWSH" ] && [ -x "$HOME/.local/pwsh/pwsh" ] && PWSH="$HOME/.local/pwsh/pwsh"
[ -n "$PWSH" ] && [ ! -x "$PWSH" ] && PWSH=""

# ---------- find Chrome, or say it is missing ----------
# The row order is decided in the browser when the report is opened, so the
# checks on it need a rendered page. The same candidates the script tries.
CHROME=""
for C in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
         "$(command -v google-chrome 2>/dev/null)" \
         "$(command -v chromium 2>/dev/null)"; do
  [ -n "$C" ] && [ -x "$C" ] && CHROME="$C" && break
done

# ---------- a private directory, cleared on the way out ----------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/axur-tests.XXXXXX") || exit 1
mkdir -p "$WORK/out" "$WORK/log" "$WORK/dom"
SRVPID=""
cleanup() {
  if [ -n "$SRVPID" ]; then kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null; fi
  rm -rf "$WORK"
}
# A signal has to end the run. Cleaning up and carrying on would leave the rest
# of the suite reading a directory that is no longer there.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

# The key never reaches a command line. Both scripts read it from a file, and
# a suite that passed it as an argument would be testing something the scripts
# no longer accept.
KEYFILE="$WORK/key.txt"
printf 'test-key\n' > "$KEYFILE"
chmod 600 "$KEYFILE"

# A server left over from an earlier run answers every request in this one,
# and every case then tests the wrong settings. Say whose it is and stop.
# Any listener, not only one that answers /ready. A different program on the
# port would take every request in the run and each case would test nothing.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >"$WORK/port.txt" 2>/dev/null && [ -s "$WORK/port.txt" ]; then
  echo "Port $PORT is already in use. Stop what is on it, or set PORT to another." >&2
  sed 's/^/  /' "$WORK/port.txt" >&2
  exit 1
fi

"$HERE/mkfake.sh" "$PORT" "$WORK" || exit 1
SH="$WORK/r.sh"
PS1F="$WORK/r.ps1"

PASS=0; FAIL=0; SKIP=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok    $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1: want [$3] got [$2]"; FAIL=$((FAIL+1)); fi
}
skip() { echo "  skip  $1 (${2:-no PowerShell})"; SKIP=$((SKIP+1)); }

# ---------- the stand-in API ----------
# Start it, note its exact process id, and wait until it answers. Killing by
# name would kill another suite running beside this one, and not waiting meant
# the first search of every case raced the server coming up.
up() { [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/ready" 2>/dev/null)" = "200" ]; }
serve() {
  # Stop the one already there and wait for the port to go quiet. Starting the
  # next server while the old one still holds the port meant the new one died
  # unheard, the readiness test answered from the OLD server, and the case ran
  # against the previous settings. Four checks failed that way and none of them
  # was a real fault in the scripts.
  local i
  if [ -n "$SRVPID" ]; then
    kill "$SRVPID" 2>/dev/null
    i=0; while up && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
    kill -9 "$SRVPID" 2>/dev/null
    wait "$SRVPID" 2>/dev/null
    i=0; while up && [ $i -lt 25 ]; do sleep 0.2; i=$((i+1)); done
    SRVPID=""
  fi
  if up; then
    echo "  FAIL  something else is already listening on port $PORT"; FAIL=$((FAIL+1)); return 1
  fi
  # exec, so the backgrounded subshell BECOMES python3 and $! is the pid that
  # holds the port. Without it bash may fork, kill hits the subshell, python3
  # keeps the port, and the next case runs against the previous settings.
  ( cd "$HERE" && exec env "$@" python3 fakeapi.py "$PORT" ) >"$WORK/log/api.log" 2>&1 &
  SRVPID=$!
  i=0
  while [ $i -lt 50 ]; do
    up && return 0
    kill -0 "$SRVPID" 2>/dev/null || break
    sleep 0.2; i=$((i+1))
  done
  echo "  FAIL  the stand-in API did not come up on port $PORT"
  sed 's/^/          /' "$WORK/log/api.log" | tail -3
  FAIL=$((FAIL+1)); return 1
}

# ---------- running a script, and proving it ran ----------
LAST_RC=0; LAST_LOG=""; LAST_MARK=""; RUNN=0
mkdir -p "$WORK/reg"
# Every run gets a word of its own, and the runner puts that word in the brand
# it passes. The brand is written into the report, so the word comes back out
# in the file. A report that does not carry this run's word was written by
# something else, whatever its name, whatever its date, and whatever is in it.
# A file date alone would not do: a script that rewrote an old file in place
# would carry a new date and stale content.
markargs() { # markargs FLAG ARGS... -> the same arguments, marked brand on stdout
  local flag="$1"; shift
  local next=0 x
  for x in "$@"; do
    if [ "$next" = 1 ]; then printf '%s %s\0' "$x" "$LAST_MARK"; next=0
    else printf '%s\0' "$x"; [ "$x" = "$flag" ] && next=1; fi
  done
}
runsh() {
  RUNN=$((RUNN+1)); LAST_LOG="$WORK/log/sh-$RUNN.log"; LAST_MARK="runmark${RUNN}z$$"
  local args=(); while IFS= read -r -d '' x; do args+=("$x"); done < <(markargs --brand "$@")
  ( cd "$WORK/out" && "$SH" "${args[@]}" ) >"$LAST_LOG" 2>&1
  LAST_RC=$?
}
runps() {
  RUNN=$((RUNN+1)); LAST_LOG="$WORK/log/ps-$RUNN.log"; LAST_MARK="runmark${RUNN}z$$"
  local args=(); while IFS= read -r -d '' x; do args+=("$x"); done < <(markargs -Brand "$@")
  ( cd "$WORK/out" && "$PWSH" -NoProfile -File "$PS1F" "${args[@]}" ) >"$LAST_LOG" 2>&1
  LAST_RC=$?
}
# The report has to exist, hold something, and carry the word of the run that
# was supposed to write it. A check that reads a file without asking whether
# this run wrote it is the way the old suite reported 30 passes while every run
# was exiting 1. Names get reused as checks are added, so "it is there" is not
# enough; "it is there and it says who wrote it" is.
mine() { # mine FILE -> 0 when the file carries the running run's own word
  [ -s "$WORK/out/$1" ] || return 1
  grep -qF -- "$LAST_MARK" "$WORK/out/$1"
}
wrote() { # wrote NAME FILE
  if [ "$LAST_RC" != "0" ]; then
    echo "  FAIL  $1: the run exited $LAST_RC"; sed 's/^/          /' "$LAST_LOG" | tail -5
    FAIL=$((FAIL+1)); return 1
  fi
  if [ ! -s "$WORK/out/$2" ]; then
    echo "  FAIL  $1: no report at $2"; FAIL=$((FAIL+1)); return 1
  fi
  if ! mine "$2"; then
    echo "  FAIL  $1: $2 does not carry this run's word, so this run did not write it"
    FAIL=$((FAIL+1)); return 1
  fi
  # From here on the file may be read. A check that reads a report the runner
  # never signed off is a check that proves nothing, so reading is only allowed
  # through this door.
  echo "$LAST_MARK" > "$WORK/reg/$2"
  return 0
}
log() { cat "$LAST_LOG"; }
# Nothing reads a report the runner has not signed off, and a report that is
# not there must not answer "0 matches" and so pass a check that wanted 0.
# These say "no-file" or "not-verified", neither of which is a number, so they
# match nothing any check ever wants.
readable() { # readable FILE -> 0, or prints why not
  local reg="$WORK/reg/$1" f="$WORK/out/$1"
  [ -s "$reg" ] || { echo not-verified; return 1; }
  [ -s "$f" ] || { echo no-file; return 1; }
  # Look at the file itself, every time, not only at the note saying it was
  # signed off. Approving a name once and trusting it afterwards would let
  # anything written to that name later be read as verified, and the earlier
  # reports are read again after later runs.
  grep -qF -- "$(cat "$reg")" "$f" || { echo not-verified; return 1; }
  return 0
}
lines()  { readable "$1" || return; grep -cF -- "$2" "$WORK/out/$1" || true; }
linesx() { readable "$1" || return; grep -cE -- "$2" "$WORK/out/$1" || true; }
hits()   { readable "$1" || return; grep -oF -- "$2" "$WORK/out/$1" | wc -l | tr -d ' '; }

# The totals block, as five numbers, so a check reads one short string. The
# field is total unless another is named; a search without the field prints -.
tot() { # tot FILE [FIELD]
  readable "$1" || return
  python3 -c "
import json,sys
s=open(sys.argv[1]).read(); f=sys.argv[2]
i=s.find('id=\"totals\"'); j=s.find('>',i)+1; k=s.find('</script>',j)
print(','.join('null' if t.get(f,'-') is None else str(t.get(f,'-')) for t in json.loads(s[j:k])))" "$WORK/out/$1" "${2:-total}"
}
# One answer about the rows of one payload block:
#   rows   how many rows the block holds
#   folds  each row's foldCount, or - for a row standing for itself
#   span   asc when a folded row's foldFirst is earlier than its foldLast
#   risk   each row's riskScore, or - when it has none
payq() { # payq FILE N QUESTION
  readable "$1" || return
  python3 -c "
import json,sys
s=open(sys.argv[1]).read(); n=sys.argv[2]; q=sys.argv[3]
i=s.find('id=\"payload-%s\"'%n); j=s.find('>',i)+1; k=s.find('</script>',j)
rs=json.loads(s[j:k], strict=False)['reply']['result']['data']
if q=='rows': print(len(rs))
elif q=='risk': print(','.join(str(r.get('riskScore','-')) for r in rs))
elif q=='folds': print(','.join(str(r.get('foldCount','-')) for r in rs))
elif q=='span': print(','.join(('asc' if r['foldFirst']<r['foldLast'] else 'flat') if 'foldFirst' in r else '-' for r in rs))
else: print('no-such-question')" "$WORK/out/$1" "$2" "$3"
}
# The query the first search actually ran.
qy() {
  readable "$1" || return
  python3 -c "
import json,sys
s=open(sys.argv[1]).read(); i=s.find('id=\"payload-1\"'); j=s.find('>',i)+1; k=s.find('</script>',j)
print(json.loads(s[j:k])['query'])" "$WORK/out/$1"
}

# The page as the browser leaves it, rows built and ordered. Only a report the
# runner has signed off is rendered, and the rendering is read through domq,
# which asks readable again, so the dump of a stale report is never counted.
# The report sets data-report-ready="1" on the html element as the last thing
# it does. Headless Chrome sometimes dumps the page before the rows are built,
# and that dump has empty tables and no such attribute. Reading it would say
# the rows are in the wrong order when they were never written. Render again
# until the page says it finished, and give up loudly rather than quietly.
dom() { # dom FILE -> renders $WORK/out/FILE into $WORK/dom/FILE
  readable "$1" || return
  local i=0
  while [ $i -lt 4 ]; do
    "$CHROME" --headless --disable-gpu --dump-dom --virtual-time-budget=20000 \
              "file://$WORK/out/$1" >"$WORK/dom/$1" 2>/dev/null
    grep -q 'data-report-ready="1"' "$WORK/dom/$1" && return 0
    i=$((i+1))
  done
  : > "$WORK/dom/$1"
  return 1
}
# One answer about one section of the rendered page:
#   brk    how many break rows the table has
#   risk   ok when every score above the break is >= 70 and every one below is < 70
#   dates  ok when the rows below the break run newest first
#   kind   ok when every row above the break is marked Readable
#   place  ok when there is one break and it has a row above AND below it
#   hi     how many rows carry the red high-risk mark
#   fold   yes or no per row: does its first cell carry the fold note
#   note   how many partial-fold notes sit above the table
#   says   the text of that note
domq() { # domq FILE SECTION QUESTION
  readable "$1" || return
  [ -s "$WORK/dom/$1" ] || { echo no-dom; return 1; }
  grep -q 'data-report-ready="1"' "$WORK/dom/$1" || { echo no-dom; return 1; }
  python3 -c '
import re, sys
from datetime import datetime
s = open(sys.argv[1]).read(); sec = sys.argv[2]; q = sys.argv[3]
m = re.search(r"<section[^>]*\bid=\"%s\"[^>]*>(.*?)</section>" % sec, s, re.S)
if not m: print("no-section"); sys.exit()
if q == "note": print(len(re.findall(r"class=\"foldnote\"", m.group(1)))); sys.exit()
if q == "says":
    n = re.search(r"class=\"foldnote\">(.*?)</p>", m.group(1), re.S); print(n.group(1) if n else "no-note"); sys.exit()
m2 = re.search(r"<tbody>(.*?)</tbody>", m.group(1), re.S)
if not m2: print("no-table"); sys.exit()
above, below, brk, seen = [], [], 0, False
for tr in re.split(r"<tr\b", m2.group(1))[1:]:
    if tr.lstrip().startswith("class=\"brk\""): brk += 1; seen = True; continue
    (below if seen else above).append(tr)
if q == "brk": print(brk); sys.exit()
if q == "place":
    print("ok" if brk == 1 and above and below else "bad:brk=%d above=%d below=%d" % (brk, len(above), len(below)))
    sys.exit()
if q == "rows": print(len(above) + len(below)); sys.exit()
if q == "hi": print(sum(1 for t in above + below if t.lstrip().startswith("class=\"hi\""))); sys.exit()
if q == "fold": print(",".join("yes" if "class=\"sec fold\"" in t else "no" for t in above + below)); sys.exit()
# The line under the table. "standing for" is the folded wording; without it
# the section is counting raw records as though they were rows.
if q == "foldwords":
    mm = re.search(r"class=\"more\">(.*?)</p>", m.group(1), re.S)
    print("no-more" if not mm else ("yes" if "standing for" in mm.group(1) else "no"))
    sys.exit()
def risk(tr):
    r = re.search(r"class=\"risk[^\"]*\"><b>([\d.]+)</b>", tr); return float(r.group(1)) if r else None
def date(tr):
    ds = re.findall(r"<span class=\"date\">(\d\d \w\w\w \d{4})", tr)
    return datetime.strptime(ds[-1], "%d %b %Y") if ds else None
if q == "risk":
    bad = [risk(t) for t in above if risk(t) is None or risk(t) < 70] + \
          [risk(t) for t in below if risk(t) is not None and risk(t) >= 70]
    print("ok" if above and below and not bad else "bad:%r" % bad)
elif q == "dates":
    ds = [date(t) for t in below]
    print("ok" if ds and None not in ds and all(a >= b for a, b in zip(ds, ds[1:])) else "bad:%r" % ds)
elif q == "kind":
    print("ok" if above and all("Readable" in t for t in above) else "bad")
else: print("no-such-question")
' "$WORK/dom/$1" "$2" "$3"
}

# Counting inside the query has to happen here, not in a pipe at the check.
# "$(qy f.html | grep -c 'x')" counts the sentinel as zero matches, and zero is
# exactly what three of these checks want, so an unreadable report would have
# passed them. Hand the sentinel straight back instead of counting it.
qyc() { # qyc FILE PATTERN -> matches in the query, or why the report cannot be read
  local q; q=$(qy "$1")
  case "$q" in not-verified|no-file) printf '%s\n' "$q"; return;; esac
  printf '%s\n' "$q" | grep -c -- "$2" || true
}

D=larkspurfinancial.com
echo ""
echo "Working in $WORK"
[ -n "$PWSH" ] && echo "PowerShell: $PWSH" || echo "PowerShell: none found, those checks will be skipped"
[ -n "$CHROME" ] && echo "Chrome: $CHROME" || echo "Chrome: none found, the rendered-page checks will be skipped"
echo ""

# ---------------------------------------------------------------- the checks
echo "-- the generated script is in step with its source --"
# axur-report.ps1 is generated. A hand edit to it, or an edit to axur-report.sh
# that was never built, both show up here as a difference.
# Build into a copy of the repo. Building in place would leave the working
# tree changed by a test run, and a failed run would leave it changed for good.
BT="$WORK/build"; mkdir -p "$BT/tools" "$BT/docs"
cp "$ROOT/axur-report.sh" "$ROOT/axur-report.ps1" "$BT/"
cp "$ROOT/tools/build.py" "$BT/tools/"
cp "$ROOT/docs/index.html" "$BT/docs/"
( cd "$BT" && python3 tools/build.py --generate-only ) >"$WORK/log/build.log" 2>&1
BRC=$?
# Without this a generator that died on line one would leave the copy untouched
# and the comparison below would call that "same".
check "build.py runs" "$BRC" "0"
check "build.py leaves axur-report.ps1 unchanged" \
  "$(cmp -s "$BT/axur-report.ps1" "$ROOT/axur-report.ps1" && echo same || echo differs)" "same"

echo "-- the key is never a command-line argument --"
KOUT=$( cd "$WORK/out" && "$SH" --key K --brand L --domain $D --no-pdf --no-open 2>&1 ); KRC=$?
check "sh  --key is refused"    "$(printf '%s' "$KOUT" | grep -c 'key is gone')" "1"
check "sh  --key exits nonzero" "$([ "$KRC" -ne 0 ] && echo yes || echo no)" "yes"
check "ps1 has no -ApiKey parameter" "$(grep -c '\[string\]\$ApiKey' "$ROOT/axur-report.ps1")" "0"
# Counting the calls meant every new curl call broke this check and the count
# got bumped. Assert the rule instead: every call to the API carries the file.
APICALLS=$(grep -c 'curl .*"\$API' "$SH")
WITHHDR=$(grep 'curl .*"\$API' "$SH" | grep -c -- '-H "@\$AUTH"')
# 0 of 0 would read as every call being safe when the pattern had simply stopped
# matching. Say out loud that there are calls to check.
check "sh  the script calls the API at all" "$([ "$APICALLS" -ge 1 ] && echo yes || echo no)" "yes"
check "sh  every API call uses the header file" "$WITHHDR/$APICALLS" "$APICALLS/$APICALLS"
check "sh  no bare key anywhere" "$(grep -c 'Authorization: Bearer \$KEY' "$SH")" "0"

serve FAKE_X=1
echo "-- brand injection is escaped --"
# The runner appends its own word to the brand, so the value to look for here
# is the brand plus that word, escaped the same way.
runsh --brand 'L" onload="x' --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out a.html
if wrote "sh  attribute intact" a.html; then
  check "sh  attribute intact" "$(lines a.html "data-brand=\"L&quot; onload=&quot;x $LAST_MARK\"")" "1"
fi
if [ -n "$PWSH" ]; then
  runps -Brand 'L" onload="x' -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out b.html
  if wrote "ps1 attribute intact" b.html; then
    check "ps1 attribute intact" "$(lines b.html "data-brand=\"L&quot; onload=&quot;x $LAST_MARK\"")" "1"
  fi
else skip "ps1 attribute intact"; fi

echo "-- the report calls nothing on the network --"
EXTERNAL='(src|href)[[:space:]]*=[[:space:]]*.?(https?:)?//|url\([[:space:]]*.?(https?:)?//|@import[[:space:]]'
check "sh  no logo CDN url"      "$(lines a.html 'cdn.brandfetch.io')" "0"
check "sh  no external resource" "$(linesx a.html "$EXTERNAL")" "0"
if [ -n "$PWSH" ]; then
  check "ps1 no logo CDN url"      "$(lines b.html 'cdn.brandfetch.io')" "0"
  check "ps1 no external resource" "$(linesx b.html "$EXTERNAL")" "0"
else skip "ps1 no logo CDN url"; skip "ps1 no external resource"; fi
runsh --brand L --domain $D --key-file "$KEYFILE" --logo /nope/x.png --no-pdf --no-open --wait 6 --out c.html
if wrote "sh  missing --logo file" c.html; then
  check "sh  missing --logo file falls back to no logo" "$(lines c.html "cdn.brandfetch.io/$D")" "0"
fi

echo "-- five payload blocks, all tables independent --"
check "sh  blocks" "$(lines a.html 'id="payload-')" "5"
if [ -n "$PWSH" ]; then check "ps1 blocks" "$(lines b.html 'id="payload-')" "5"
else skip "ps1 blocks"; fi

echo "-- one malformed reply costs only its own table --"
serve FAKE_BADJSON=3
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out d.html
if wrote "sh  four blocks still parse" d.html; then
  check "sh  four blocks still parse" "$(python3 -c "
import json,sys
s=open(sys.argv[1]).read(); ok=0
for n in range(1,6):
    i=s.find('id=\"payload-%d\"'%n); j=s.find('>',i)+1; k=s.find('</script>',j)
    try: json.loads(s[j:k]); ok+=1
    except Exception: pass
print(ok)" "$WORK/out/d.html")" "4"
fi

echo "-- a filter that fails stops the run --"
serve FAKE_TRUNC=3
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 60 --out e.html
check "sh  exit status" "$LAST_RC" "1"
check "sh  no report written" "$([ -e "$WORK/out/e.html" ] && echo yes || echo no)" "no"

echo "-- a clamping API does not count the last page forty times --"
serve FAKE_CLAMP=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 0 --out f.html
if wrote "sh  totals" f.html; then check "sh  totals" "$(tot f.html)" "3412,2906,9,9,9"; fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -MinScore 0 -Out g.html
  if wrote "ps1 totals" g.html; then check "ps1 totals" "$(tot g.html)" "3412,2906,9,9,9"; fi
else skip "ps1 totals"; fi

echo "-- the page cap: 40 pages is whole, 45 is short --"
for N in 40 45; do
  serve FAKE_PAGES=$N
  [ "$N" = 40 ] && WANT=0 || WANT=1
  runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 0 --out "h$N.html"
  if wrote "sh  $N pages" "h$N.html"; then
    check "sh  $N pages" "$(log | grep -c 'page cap')" "$WANT"
  fi
  if [ -n "$PWSH" ]; then
    runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -MinScore 0 -Out "i$N.html"
    if wrote "ps1 $N pages" "i$N.html"; then
      check "ps1 $N pages" "$(log | grep -c 'page cap')" "$WANT"
    fi
  else skip "ps1 $N pages"; fi
done

echo "-- an exclusion sees the field the table names the site in --"
serve FAKE_SHAPE=reference
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --exclude ".EXAMPLE" --out j.html
if wrote "sh  totals" j.html; then check "sh  totals" "$(tot j.html)" "3412,2906,0,0,0"; fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Exclude ".EXAMPLE" -Out k.html
  if wrote "ps1 totals" k.html; then check "ps1 totals" "$(tot k.html)" "3412,2906,0,0,0"; fi
else skip "ps1 totals"; fi

echo "-- a short wait still reads a reply --"
serve FAKE_X=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 1 --out l.html
if wrote "sh  --wait 1" l.html; then check "sh  --wait 1" "$(log | grep -c 'timed out')" "0"; fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 1 -Out m.html
  if wrote "ps1 -Wait 1" m.html; then check "ps1 -Wait 1" "$(log | grep -c 'timed out')" "0"; fi
else skip "ps1 -Wait 1"; fi

echo "-- an output path that cannot be written --"
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out /nope/deep/x.html
check "sh  exit status" "$LAST_RC" "1"

echo "-- the date window --"
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out dw.html
if wrote "sh  default has a date clause" dw.html; then
  check "sh  default has a date clause" "$(qyc dw.html 'detectionDate>=')" "1"
fi
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --all-time --out dw2.html
if wrote "sh  --all-time has none" dw2.html; then
  check "sh  --all-time has none" "$(qyc dw2.html 'detectionDate')" "0"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out dw3.html
  if wrote "ps1 default has a date clause" dw3.html; then
    check "ps1 default has a date clause" "$(qyc dw3.html 'detectionDate>=')" "1"
  fi
else skip "ps1 default has a date clause"; fi

echo "-- the API refuses the date clause --"
serve FAKE_NODATE=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out dn.html
if wrote "sh  warns once" dn.html; then
  check "sh  warns once"      "$(log | grep -c 'would not take')" "1"
  check "sh  still completes" "$(qyc dn.html 'detectionDate')" "0"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out dn2.html
  if wrote "ps1 warns once" dn2.html; then
    check "ps1 warns once"      "$(log | grep -c 'would not take')" "1"
    check "ps1 still completes" "$(qyc dn2.html 'detectionDate')" "0"
  fi
else skip "ps1 warns once"; skip "ps1 still completes"; fi

echo "-- masked passwords --"
serve FAKE_X=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --mask-passwords --out mk.html
if wrote "sh  masked shape" mk.html; then
  check "sh  masked shape"     "$(hits mk.html 'h*****2')" "15"
  check "sh  no real password" "$(lines mk.html 'hunter2')" "0"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -MaskPasswords -Out mk2.html
  if wrote "ps1 masked shape" mk2.html; then
    check "ps1 masked shape"     "$(hits mk2.html 'h*****2')" "15"
    check "ps1 no real password" "$(lines mk2.html 'hunter2')" "0"
  fi
else skip "ps1 masked shape"; skip "ps1 no real password"; fi

echo "-- risk first, then a break, then date --"
# Section 03 is the phishing table, which carries a score; section 01 is the
# credentials table, which does not. The fake API spreads its dates one day
# apart, so newest-first is something the rows can get wrong.
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out ord.html
if wrote "sh  ordered report" ord.html; then
  if [ -n "$CHROME" ]; then
    dom ord.html
    check "sh  phishing: one break row"                  "$(domq ord.html s3 brk)"   "1"
    check "sh  phishing: >= 70 above the break, < 70 below" "$(domq ord.html s3 risk)"  "ok"
    check "sh  phishing: below the break, newest first"  "$(domq ord.html s3 dates)" "ok"
    check "sh  credentials: one break row"               "$(domq ord.html s1 brk)"   "1"
    check "sh  credentials: readable above the break"    "$(domq ord.html s1 kind)"  "ok"
    check "sh  phishing: the break has a row on each side" "$(domq ord.html s3 place)" "ok"
    check "sh  credentials: the break has a row on each side" "$(domq ord.html s1 place)" "ok"
    # The red mark means a high score, and the JavaScript adds it when the
    # report is opened, so this has to look at the rendered page. Reading the
    # file on disk would find no mark either way and prove nothing.
    check "sh  credentials: no row is marked high risk"  "$(domq ord.html s1 hi)" "0"
    check "sh  phishing: the lead row is marked"         "$(domq ord.html s3 hi)" "1"
  else
    for c in "phishing: one break row" "phishing: >= 70 above the break, < 70 below" \
             "phishing: below the break, newest first" "credentials: one break row" \
             "credentials: readable above the break" "phishing: the break has a row on each side" \
             "credentials: the break has a row on each side" \
             "credentials: no row is marked high risk" "phishing: the lead row is marked"; \
             do skip "sh  $c" "no Chrome"; done
  fi
fi
# The same count from the PowerShell report proves the JavaScript was lifted.
if [ -n "$PWSH" ] && [ -n "$CHROME" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out ord2.html
  if wrote "ps1 ordered report" ord2.html; then
    dom ord2.html
    check "ps1 phishing: one break row"    "$(domq ord2.html s3 brk)" "1"
    check "ps1 credentials: one break row" "$(domq ord2.html s1 brk)" "1"
  fi
elif [ -n "$PWSH" ]; then skip "ps1 phishing: one break row" "no Chrome"; skip "ps1 credentials: one break row" "no Chrome"
else skip "ps1 phishing: one break row"; skip "ps1 credentials: one break row"; fi

# ---- the suite proves its own guard ----
# The old suite reported thirty passes while every run was failing, because it
# read files an earlier run had left behind. Show here that this one cannot.
echo "-- nothing reaches the cut-off, so there is no break to draw --"
# Every score under 70. The sentence still applies to the search, but there is
# no lead row, and a break with nothing above it announces a division that is
# not there.
serve FAKE_LOWRISK=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out low.html
if wrote "sh  low-risk report" low.html; then
  if [ -n "$CHROME" ]; then
    dom low.html
    check "sh  phishing: no break row"     "$(domq low.html s3 brk)"  "0"
    check "sh  phishing: the rows are all still there" "$(domq low.html s3 rows)" "3"
  else skip "sh  phishing: no break row" "no Chrome"; skip "sh  phishing: the rows are all still there" "no Chrome"; fi
fi

echo "-- a repeated name folds into one row --"
# Page 1 of each site search names one host four times and one host once.
# Folded before the cap, --rows 2 keeps both rows and the first says "4 times".
# Folded after it, the cap would keep two repeats and the row would say "2
# times" for a site seen four times.
serve FAKE_DUPES=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --rows 2 --out fo.html
if wrote "sh  folded report" fo.html; then
  check "sh  --rows 2 keeps two folded rows"             "$(payq fo.html 3 rows)"  "2"
  check "sh  the folded row counts its four repeats"     "$(payq fo.html 3 folds)" "4,-"
  check "sh  foldFirst is earlier than foldLast"         "$(payq fo.html 3 span)"  "asc,-"
  check "sh  pulled is the raw count, folded the folded" "$(tot fo.html pulled)/$(tot fo.html folded)" "-,-,5,5,5/-,-,2,2,2"
  check "sh  total is unchanged by the fold"             "$(tot fo.html)" "3412,2906,1184,78,31"
  check "sh  foldPartial when pulled is under total"     "$(tot fo.html foldPartial)" "-,-,1,1,1"
  if [ -n "$CHROME" ]; then
    dom fo.html
    check "sh  the folded row carries the note, the lone row does not" "$(domq fo.html s3 fold)" "yes,no"
    check "sh  the partial note sits above the table"    "$(domq fo.html s3 note)" "1"
  else skip "sh  the folded row carries the note, the lone row does not" "no Chrome"; skip "sh  the partial note sits above the table" "no Chrome"; fi
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Rows 2 -Out fo2.html
  if wrote "ps1 folded report" fo2.html; then
    check "ps1 -Rows 2 keeps two folded rows"            "$(payq fo2.html 3 rows)"  "2"
    check "ps1 the folded row counts its four repeats"   "$(payq fo2.html 3 folds)" "4,-"
    check "ps1 foldFirst is earlier than foldLast"       "$(payq fo2.html 3 span)"  "asc,-"
    check "ps1 pulled is the raw count, folded the folded" "$(tot fo2.html pulled)/$(tot fo2.html folded)" "-,-,5,5,5/-,-,2,2,2"
    check "ps1 total is unchanged by the fold"           "$(tot fo2.html)" "3412,2906,1184,78,31"
    check "ps1 foldPartial when pulled is under total"   "$(tot fo2.html foldPartial)" "-,-,1,1,1"
  fi
else
  for c in "-Rows 2 keeps two folded rows" "the folded row counts its four repeats" "foldFirst is earlier than foldLast" \
           "pulled is the raw count, folded the folded" "total is unchanged by the fold" "foldPartial when pulled is under total"; do skip "ps1 $c"; done
fi
# A filter walks every page and Axur's count matches the rows, so the fold
# saw the whole result and there is nothing partial to say above the table.
serve FAKE_DUPES=1 FAKE_EXACT=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 0 --out fp.html
if wrote "sh  folded after a full walk" fp.html; then
  check "sh  no foldPartial when every row was pulled"   "$(tot fp.html foldPartial)" "-,-,-,-,-"
  check "sh  pulled is the recount, folded is fewer"     "$(tot fp.html pulled)/$(tot fp.html folded)/$(tot fp.html)" "-,-,11,11,11/-,-,8,8,8/3412,2906,11,11,11"
  if [ -n "$CHROME" ]; then
    dom fp.html
    check "sh  no partial note above the table"          "$(domq fp.html s3 note)" "0"
  else skip "sh  no partial note above the table" "no Chrome"; fi
fi

echo "-- foldPartial: the fold saw only part of the result --"
# A filtered walk that hit the page cap. The filter recounts total from the
# rows in hand, so pulled equals total by construction and cannot say so; the
# note has to come from the walk itself, and reported keeps Axur's count.
serve FAKE_PAGES=45
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 0 --out fc.html
if wrote "sh  filtered walk at the cap" fc.html; then
  check "sh  foldPartial on a filtered walk that hit the cap" "$(tot fc.html foldPartial)" "-,-,1,1,1"
  check "sh  reported keeps Axur's count after a recount"     "$(tot fc.html reported)/$(tot fc.html)" "-,-,1184,78,31/3412,2906,120,120,120"
fi
# The note names what the fold covers: the rows the filter kept, not the rows
# pulled. --min-score 40 drops the scores of 34 and 12, so the two differ.
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 40 --out fk.html
if wrote "sh  filtered and partial" fk.html; then
  if [ -n "$CHROME" ]; then
    dom fk.html
    check "sh  the note names the kept rows as what the fold covers" "$(domq fk.html s3 says)" \
      "Axur reports 1,184 records; 120 of them were pulled, and the filter kept $(tot fk.html pulled | cut -d, -f3). Those $(tot fk.html pulled | cut -d, -f3) folded into $(tot fk.html folded | cut -d, -f3) rows. The \"times\" counts and dates cover those $(tot fk.html pulled | cut -d, -f3) records only; more may exist."
    check "sh  the filter did drop rows"  "$([ "$(tot fk.html pulled | cut -d, -f3)" -lt 120 ] && echo yes || echo no)" "yes"
  else skip "sh  the note names the kept rows as what the fold covers" "no Chrome"; skip "sh  the filter did drop rows" "no Chrome"; fi
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -MinScore 0 -Out fc2.html
  if wrote "ps1 filtered walk at the cap" fc2.html; then
    check "ps1 foldPartial on a filtered walk that hit the cap" "$(tot fc2.html foldPartial)" "-,-,1,1,1"
    check "ps1 reported keeps Axur's count after a recount"     "$(tot fc2.html reported)/$(tot fc2.html)" "-,-,1184,78,31/3412,2906,120,120,120"
  fi
else skip "ps1 foldPartial on a filtered walk that hit the cap"; skip "ps1 reported keeps Axur's count after a recount"; fi
# The count is unknown: the status carries no totalResults.
serve FAKE_NOTOTAL=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out fu.html
if wrote "sh  count unknown" fu.html; then
  check "sh  foldPartial when the count is unknown"          "$(tot fu.html foldPartial)/$(tot fu.html reported)" "-,-,1,1,1/-,-,null,null,null"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out fu2.html
  if wrote "ps1 count unknown" fu2.html; then
    check "ps1 foldPartial when the count is unknown"        "$(tot fu2.html foldPartial)/$(tot fu2.html reported)" "-,-,1,1,1/-,-,null,null,null"
  fi
else skip "ps1 foldPartial when the count is unknown"; fi
# Still running when the wait ran out. Filtered, and with Axur's count equal
# to the rows on hand, so neither the recount nor the row count can be what
# sets the note: only the floor can.
serve FAKE_RUNNING=1 FAKE_EXACT=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --min-score 0 --out fs.html
if wrote "sh  still running" fs.html; then
  check "sh  foldPartial when the search was still running"  "$(tot fs.html foldPartial)/$(tot fs.html examined)/$(tot fs.html reported)" "-,-,1,1,1/-,-,9,9,9/-,-,9,9,9"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -MinScore 0 -Out fs2.html
  if wrote "ps1 still running" fs2.html; then
    check "ps1 foldPartial when the search was still running" "$(tot fs2.html foldPartial)/$(tot fs2.html examined)/$(tot fs2.html reported)" "-,-,1,1,1/-,-,9,9,9/-,-,9,9,9"
  fi
else skip "ps1 foldPartial when the search was still running"; fi

echo "-- the two scripts agree on odd rows --"
# A capitalised key is not the key Axur sends; a lone surrogate escape and a
# raw control character are not JSON. None of them folds, on either side.
for K in Host surrogate control; do
  serve FAKE_DUPES=1 FAKE_ODDROW=$K
  runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out "od$K.html"
  if wrote "sh  $K: no row folds" "od$K.html"; then
    check "sh  $K: no row folds"  "$(payq "od$K.html" 3 folds)" "-,-,-,-,-"
  fi
  if [ -n "$PWSH" ]; then
    runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out "od${K}2.html"
    if wrote "ps1 $K: no row folds" "od${K}2.html"; then
      check "ps1 $K: no row folds" "$(payq "od${K}2.html" 3 folds)" "-,-,-,-,-"
    fi
  else skip "ps1 $K: no row folds"; fi
done
# A key written twice in one row: fold.pl would take the first value and
# PowerShell's parser the last, so neither folds on it. With two hosts nothing
# folds; with two scores that row stands alone and the other three fold.
serve FAKE_DUPES=1 FAKE_ODDROW=duphost
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out oddh.html
if wrote "sh  two hosts: no row folds" oddh.html; then
  check "sh  two hosts: no row folds"   "$(payq oddh.html 3 folds)" "-,-,-,-,-"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out oddh2.html
  if wrote "ps1 two hosts: no row folds" oddh2.html; then
    check "ps1 two hosts: no row folds" "$(payq oddh2.html 3 folds)" "-,-,-,-,-"
  fi
else skip "ps1 two hosts: no row folds"; fi
serve FAKE_DUPES=1 FAKE_ODDROW=duprisk
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out oddr.html
if wrote "sh  two scores: the row stands alone" oddr.html; then
  check "sh  two scores: the row stands alone"   "$(payq oddr.html 3 folds)/$(payq oddr.html 3 risk)" "-,3,-/5,91,34"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out oddr2.html
  if wrote "ps1 two scores: the row stands alone" oddr2.html; then
    check "ps1 two scores: the row stands alone" "$(payq oddr2.html 3 folds)/$(payq oddr2.html 3 risk)" "-,3,-/5,91,34"
  fi
else skip "ps1 two scores: the row stands alone"; fi
# A count that is not a number is no count: foldPartial, and the run completes.
serve FAKE_DUPES=1 FAKE_ODDTOTAL=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out oddt.html
if wrote "sh  count is a word" oddt.html; then
  check "sh  a count that is a word sets foldPartial"   "$(tot oddt.html foldPartial)/$(tot oddt.html reported)" "-,-,1,1,1/-,-,null,null,null"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out oddt2.html
  if wrote "ps1 count is a word" oddt2.html; then
    check "ps1 a count that is a word sets foldPartial" "$(tot oddt2.html foldPartial)/$(tot oddt2.html reported)" "-,-,1,1,1/-,-,null,null,null"
  fi
else skip "ps1 a count that is a word sets foldPartial"; fi
# "NaN" is not a JSON number. Taken as one it never loses a comparison, and
# the row carrying it would stand for the group.
serve FAKE_DUPES=1 FAKE_ODDROW=nan
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out odnan.html
if wrote "sh  NaN does not win" odnan.html; then
  check "sh  NaN does not win"   "$(payq odnan.html 3 risk)" "91,34"
fi
if [ -n "$PWSH" ]; then
  runps -Brand L -Domain $D -KeyFile "$KEYFILE" -NoLogo -NoPdf -NoOpen -Wait 6 -Out odnan2.html
  if wrote "ps1 NaN does not win" odnan2.html; then
    check "ps1 NaN does not win" "$(payq odnan2.html 3 risk)" "91,34"
  fi
else skip "ps1 NaN does not win"; fi

echo "-- without repeats, nothing folds --"
serve FAKE_X=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --out nf.html
if wrote "sh  unfolded report" nf.html; then
  check "sh  no row carries a fold count"                "$(payq nf.html 3 folds)" "-,-,-"
  check "sh  folded equals pulled"                       "$(tot nf.html pulled)/$(tot nf.html folded)" "-,-,3,3,3/-,-,3,3,3"
  if [ -n "$CHROME" ]; then
    dom nf.html
    check "sh  no row carries the fold note"             "$(domq nf.html s3 fold)" "no,no,no"
  else skip "sh  no row carries the fold note" "no Chrome"; fi
fi

echo "-- the wording follows the search, not the rows on screen --"
# The row that stands alone outscores the repeated ones, so it sorts to the top
# and --rows 1 cuts the table before the folded group. Deciding from the rows on
# screen, the section would say "the first 1 of 82 records" and count raw
# records as though they were rows, which is the confusion the fold removes.
serve FAKE_DUPES=1 FAKE_LONEFIRST=1
runsh --brand L --domain $D --key-file "$KEYFILE" --no-logo --no-pdf --no-open --wait 6 --rows 1 --out lone.html
if wrote "sh  lone-first report" lone.html; then
  if [ -n "$CHROME" ]; then
    dom lone.html
    check "sh  the shown row stands alone"       "$(domq lone.html s3 fold)"      "no"
    check "sh  the section still says it folded" "$(domq lone.html s3 foldwords)" "yes"
  else skip "sh  the shown row stands alone" "no Chrome"; skip "sh  the section still says it folded" "no Chrome"; fi
fi

echo "-- the suite refuses a report this run did not write --"
# A report left by another run: it exists, it is not empty, its date is new,
# and it does not carry this run's word.
printf '<html>a report from somewhere else</html>\n' > "$WORK/out/stale.html"
check "a report without this run's word is refused" "$(mine stale.html && echo yes || echo no)" "no"
check "an unsigned report cannot be read"           "$(lines stale.html 'report')" "not-verified"
check "a missing report cannot be read"             "$(lines gone.html 'anything')" "not-verified"
# The same for a check that wants zero. Counting matches inside an unreadable
# report used to answer 0, and 0 is what three of the date checks want.
check "an unsigned report fails a zero check"       "$(qyc stale.html 'detectionDate')" "not-verified"
check "a missing report fails a zero check"         "$(qyc gone.html 'detectionDate')" "not-verified"
# And a rendered page: an unsigned report is never rendered or read back.
check "an unsigned report is not rendered"          "$(domq stale.html s1 brk)" "not-verified"
# And the door works the other way: these two were signed off and still read.
check "a signed report still reads"                 "$(lines a.html 'id="payload-')" "5"
check "a signed query still reads"                  "$(qyc dw.html 'detectionDate>=')" "1"
# Signing off a name once must not sign off whatever is written to that name
# afterwards. Overwrite a report that has already been read, and it closes.
printf '<html>something else at a name already read</html>\n' > "$WORK/out/a.html"
check "a signed name with new content closes"       "$(lines a.html 'id="payload-')" "not-verified"

echo ""
echo "passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ]
