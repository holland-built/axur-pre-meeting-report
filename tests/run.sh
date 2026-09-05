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

# ---------- a private directory, cleared on the way out ----------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/axur-tests.XXXXXX") || exit 1
mkdir -p "$WORK/out" "$WORK/log"
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
skip() { echo "  skip  $1 (no PowerShell)"; SKIP=$((SKIP+1)); }

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

# The totals block, as five numbers, so a check reads one short string.
tot() {
  readable "$1" || return
  python3 -c "
import json,sys
s=open(sys.argv[1]).read()
i=s.find('id=\"totals\"'); j=s.find('>',i)+1; k=s.find('</script>',j)
print(','.join(str(t['total']) for t in json.loads(s[j:k])))" "$WORK/out/$1"
}
# The query the first search actually ran.
qy() {
  readable "$1" || return
  python3 -c "
import json,sys
s=open(sys.argv[1]).read(); i=s.find('id=\"payload-1\"'); j=s.find('>',i)+1; k=s.find('</script>',j)
print(json.loads(s[j:k])['query'])" "$WORK/out/$1"
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

# ---- the suite proves its own guard ----
# The old suite reported thirty passes while every run was failing, because it
# read files an earlier run had left behind. Show here that this one cannot.
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
