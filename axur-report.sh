#!/bin/bash
# Axur pre-meeting report.
#
#   bash axur-report.sh
#   bash axur-report.sh --brand "BRAND" --domain customer.com --key YOUR_API_KEY
#
# Anything you leave off, it asks for.
#
#   --rows N          rows to pull behind each number (default 50)
#   --min-score N     drop rows scoring below N (lookalike and phishing only)
#   --exclude LIST    drop rows matching these, comma separated. ".au,known.com"
#                     repeatable, so several --exclude add up
#   --exclude-file F  same, read from a file or CSV. One per line, first column,
#                     # starts a comment
#   --out FILE        output file (default axur-report-<domain>.html)
#   --no-pdf          write only the HTML
#   --no-open         do not open the report when it is done
#   --debug           show the raw replies

API="https://api.axur.com/gateway/1.0/api/threat-hunting-api/external"
BRAND=""; DOMAIN=""; KEY=""; ROWS=50; BFID=""; OUT=""; DEBUG=""; NOPDF=""; NOOPEN=""
MINSCORE=""; EXCLUDE=""; EXCLUDEFILE=""; PAGECAP=40

while [ $# -gt 0 ]; do
  case "$1" in
    --brand)      BRAND="$2"; shift 2 ;;
    --domain)     DOMAIN="$2"; shift 2 ;;
    --key)        KEY="$2"; shift 2 ;;
    --rows)       ROWS="$2"; shift 2 ;;
    --min-score)  MINSCORE="$2"; shift 2 ;;
    --exclude)    EXCLUDE="${EXCLUDE:+$EXCLUDE,}$2"; shift 2 ;;
    --exclude-file) EXCLUDEFILE="$2"; shift 2 ;;
    --brandfetch) BFID="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --debug)      DEBUG=1; shift ;;
    --no-pdf)     NOPDF=1; shift ;;
    --no-open)    NOOPEN=1; shift ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ask() { # ask VAR flag "prompt" [hidden]
  eval "V=\$$1"
  [ -n "$V" ] && return
  if [ ! -t 0 ]; then echo "Missing --$2, and there is no terminal to ask on." >&2; exit 1; fi
  if [ -n "$4" ]; then printf '%s: ' "$3" >&2; read -r -s A; printf '\n' >&2
  else printf '%s: ' "$3" >&2; read -r A; fi
  eval "$1=\$A"
}
ask BRAND  brand  "Customer brand, as Axur spells it"
ask DOMAIN domain "Customer domain"
ask KEY    key    "Axur API key (input hidden)" hidden
if [ -z "$BRAND" ] || [ -z "$DOMAIN" ] || [ -z "$KEY" ]; then
  echo "Brand, domain and key are all needed." >&2; exit 1
fi

DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | sed 's#^[a-z]*://##; s/^www\.//; s#/.*##')
LABEL=$(printf '%s' "$DOMAIN" | cut -d. -f1)
[ -z "$OUT" ] && OUT="axur-report-$LABEL.html"

# Brandfetch serves a real logo when the page sends a Referer. A file opened
# straight off disk does not, so the cover writes the name out instead.
if [ -n "$BFID" ]; then
  LOGO="https://cdn.brandfetch.io/$DOMAIN/w/400/h/400?c=$BFID"
  OURS="https://cdn.brandfetch.io/infoblox.com/w/400/h/400?c=$BFID"
else
  LOGO="https://cdn.brandfetch.io/$DOMAIN/w/400/h/400"
  OURS="https://cdn.brandfetch.io/infoblox.com/w/400/h/400"
fi

# A customer's own domains run to dozens, so take them from a file as well as
# the command line. One per line, or the first column of a CSV. A "domain"
# header row is skipped, so a sheet exported straight from Excel works.
if [ -n "$EXCLUDEFILE" ]; then
  if [ ! -r "$EXCLUDEFILE" ]; then
    echo "Cannot read $EXCLUDEFILE" >&2; exit 1
  fi
  FROMFILE=$(sed 's/\r$//; s/#.*//' "$EXCLUDEFILE" \
             | cut -d, -f1 \
             | tr -d '"'"'"'"' \
             | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
             | grep -v '^$' \
             | grep -viE '^domains?$' \
             | paste -sd, -)
  [ -n "$FROMFILE" ] && EXCLUDE="${EXCLUDE:+$EXCLUDE,}$FROMFILE"
  echo "Excluding $(printf '%s' "$EXCLUDE" | tr ',' '\n' | grep -c .) patterns from $EXCLUDEFILE"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
N=0

# Fetch the logo here rather than leaving it to the reader's browser. Brandfetch
# serves the real image to a request carrying a Referer, so curl gets it; baking
# it into the file as a data URI means it also survives the PDF, an offline
# mailbox, and a reader with images blocked. A miss leaves LOGO_DATA empty and
# the cover writes the company name instead, exactly as before.
fetch_logo() { # fetch_logo URL FILE  -> prints a data URI, or nothing
  CT=$(curl -sL --max-time 12 -o "$2" -w '%{content_type}' \
        -H "Referer: https://one.axur.com/" \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36" \
        -H "Accept: image/avif,image/webp,image/png,image/*,*/*;q=0.8" \
        "$1" 2>/dev/null)
  case "$CT" in
    image/*) [ -s "$2" ] && printf 'data:%s;base64,%s' "${CT%%;*}" "$(base64 < "$2" | tr -d '\n')" ;;
  esac
}
printf 'Logo'
LOGO_DATA=$(fetch_logo "$LOGO" "$TMP/logo.bin")
OURS_DATA=$(fetch_logo "$OURS" "$TMP/ours.bin")
[ -n "$LOGO_DATA" ] && LOGO="$LOGO_DATA"
[ -n "$OURS_DATA" ] && OURS="$OURS_DATA"
if [ -n "$LOGO_DATA" ]; then echo " ... got $BRAND"; else echo " ... none for $DOMAIN, the name will be written instead"; fi

run() { # run NAME SOURCE QUERY
  NAME="$1"; SOURCE="$2"; QUERY="$3"; N=$((N+1))
  printf '%-26s' "$NAME"
  ESC=$(printf '%s' "$QUERY" | sed 's/\\/\\\\/g; s/"/\\"/g')
  BODY=$(printf '{"query":"%s","source":"%s"}' "$ESC" "$SOURCE")
  ATTEMPT=0
  while :; do
    RAW=$(curl -s -w '\n%{http_code}' -X POST "$API/search" -H "Authorization: Bearer $KEY" \
          -H "Content-Type: application/json" -d "$BODY")
    CODE=$(printf '%s' "$RAW" | tail -n1); START=$(printf '%s' "$RAW" | sed '$d')
    # the gateway allows 30 calls a window, so wait it out rather than failing
    if [ "$CODE" = "429" ] && [ "$ATTEMPT" -lt 3 ]; then
      ATTEMPT=$((ATTEMPT+1)); printf 'w'; sleep 25; continue
    fi
    break
  done
  [ -n "$DEBUG" ] && printf '\n  HTTP %s %s\n' "$CODE" "$START"
  ID=$(printf '%s' "$START" | sed -n 's/.*"searchId":"\([^"]*\)".*/\1/p')
  if [ -z "$ID" ]; then
    case "$CODE" in
      401) printf ' key rejected (401). Generate a new one in My preferences.\n' ;;
      403) printf ' no access to this tenant (403)\n' ;;
      429) printf ' still rate limited after waiting. Try again in a minute.\n' ;;
      000) printf ' no network reply. Check your connection or proxy.\n' ;;
      *)   printf ' could not start (HTTP %s)\n' "$CODE" ;;
    esac
    printf '{"name":%s,"query":%s,"total":null,"data":[]}' "\"$NAME\"" "\"$(printf '%s' "$QUERY" | sed 's/"/\\"/g')\"" > "$TMP/$N.json"
    return
  fi
  TOTAL=""; OUTJ=""
  for _ in $(seq 1 40); do
    sleep 2; printf '.'
    OUTJ=$(curl -s "$API/search/$ID?page=1&alias=true" -H "Authorization: Bearer $KEY")
    TOTAL=$(printf '%s' "$OUTJ" | sed -n 's/.*"totalResults":\([0-9]*\).*/\1/p')
    [ -n "$TOTAL" ] && break
  done
  if [ -n "$TOTAL" ]; then printf ' %s\n' "$TOTAL"; else printf ' timed out\n'; fi

  # A filtered number is only honest if it was counted over every row, so when
  # a filter is on we walk the pages instead of reading the first one. The API
  # ignores page-size parameters, so page= is the only lever there is. If it
  # hands back the same first row twice, paging is not supported: we stop and
  # the report says the count came from a partial pull.
  PAGES=1; PARTIAL=""
  case "$NAME" in
    "Phishing pages"|"Lookalike domains"|"Mail-enabled lookalikes")
      if [ -n "$MINSCORE$EXCLUDE" ] && [ -n "$TOTAL" ]; then
        FIRSTROW=$(printf '%s' "$OUTJ" | sed -n 's/.*"data":\[[^{]*{\([^}]\{0,120\}\).*/\1/p')
        P=2
        while [ "$P" -le "$PAGECAP" ]; do
          PG=$(curl -s "$API/search/$ID?page=$P&alias=true" -H "Authorization: Bearer $KEY")
          printf '%s' "$PG" | grep -q '"data":\[[[:space:]]*{' || break
          THISROW=$(printf '%s' "$PG" | sed -n 's/.*"data":\[[^{]*{\([^}]\{0,120\}\).*/\1/p')
          [ "$THISROW" = "$FIRSTROW" ] && break
          printf '%s' "$PG" | sed -E 's#</#<\\/#g; s/"(password|hash)"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/"\1":"[removed]"/g' > "$TMP/$N.page$P"
          PAGES=$((PAGES+1)); printf '+'
          P=$((P+1))
        done
        [ "$P" -gt "$PAGECAP" ] && PARTIAL=1
        [ "$PAGES" -gt 1 ] && printf ' %s pages\n' "$PAGES"
      fi ;;
  esac
  [ -n "$PARTIAL" ] && echo "$NAME" >> "$TMP/partial"
  # splice the reply into the report and let the browser parse it
  {
    printf '{"name":"%s","query":"%s","total":%s,"reply":' \
      "$NAME" "$(printf '%s' "$QUERY" | sed 's/"/\\"/g')" "${TOTAL:-null}"
    # Strip the password before it reaches the report file. The pattern allows
    # space around the colon and escaped quotes inside the value: without both,
    # "password": "secret" slipped through untouched.
    printf '%s' "${OUTJ:-null}" | sed -E 's#</#<\\/#g; s/"(password|hash)"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"/"\1":"[removed]"/g'
    printf '}'
  } > "$TMP/$N.json"
}

echo ""
echo "Axur pre-meeting report: $BRAND ($DOMAIN)"
echo "-------------------------------------------"
run "Leaked credentials" credential  "emailDomain=\"$DOMAIN\""
run "In plaintext"       credential  "emailDomain=\"$DOMAIN\" AND passwordType=\"PLAIN\""
run "Phishing pages"     signal-lake "impersonatedBrandsHigh=\"$BRAND\""
run "Lookalike domains"  signal-lake "sanitizedDomainLabel=$LABEL~1"
run "Mail-enabled lookalikes" signal-lake "domainLabel=$LABEL~1 AND dnsRecordMX=*"
echo "-------------------------------------------"

# ---------- exclusions ----------
# --min-score and --exclude only ever touch the three signal-lake searches:
# a leaked credential has no score and no domain to exclude on. When a filter
# runs, the headline number is recounted from the rows that survive it, so the
# count and the table below it always agree.
cat > "$TMP/filter.pl" <<'PERL'
use strict; use warnings;
my ($min, $ex, $file, @more) = @ARGV;
my @pats = grep { length } split /\s*,\s*/, ($ex // '');
open my $fh, '<', $file or die; my $s = do { local $/; <$fh> };

# The rows sit in the first "data":[ ... ] array. Walk it object by object,
# string and escape aware, so a brace inside a value cannot fool the depth count.
my $i = index($s, '"data"'); exit 1 if $i < 0;
$i = index($s, '[', $i); exit 1 if $i < 0;
my $begin = $i + 1;
my (@rows, $depth, $start, $instr, $esc, $end); $depth = 0; $instr = 0; $esc = 0;
for (my $p = $begin; $p < length($s); $p++) {
  my $c = substr($s, $p, 1);
  if ($instr) { if ($esc) { $esc = 0 } elsif ($c eq '\\') { $esc = 1 } elsif ($c eq '"') { $instr = 0 } next }
  if ($c eq '"') { $instr = 1; next }
  if ($c eq '{') { $start = $p unless $depth; $depth++; next }
  if ($c eq '}') { $depth--; push @rows, substr($s, $start, $p - $start + 1) unless $depth; next }
  # the array ends at the first ] seen outside any row; a ] inside a row, such as
  # "impersonatedBrandsHigh":["Equifax"], is skipped because $depth is not 0 there
  if ($c eq ']' && !$depth) { $end = $p; last }
}
exit 1 unless defined $end;
# rows from the later pages, pulled in so the recount covers the whole result
for my $extra (@more) {
  open my $eh, '<', $extra or next; my $e = do { local $/; <$eh> };
  my $j = index($e, '"data"'); next if $j < 0;
  $j = index($e, '[', $j); next if $j < 0;
  my ($d, $st, $ins, $es) = (0, undef, 0, 0);
  for (my $q = $j + 1; $q < length($e); $q++) {
    my $c = substr($e, $q, 1);
    if ($ins) { if ($es) { $es = 0 } elsif ($c eq '\\') { $es = 1 } elsif ($c eq '"') { $ins = 0 } next }
    if ($c eq '"') { $ins = 1; next }
    if ($c eq '{') { $st = $q unless $d; $d++; next }
    if ($c eq '}') { $d--; push @rows, substr($e, $st, $q - $st + 1) unless $d; next }
    last if $c eq ']' && !$d;
  }
}
exit 1 unless @rows;

my @keep;
ROW: for my $r (@rows) {
  if (defined $min && length $min) {
    my ($sc) = $r =~ /"riskScore"\s*:\s*"?([0-9.]+)"?/;
    next ROW if defined $sc && $sc + 0 < $min + 0;
  }
  for my $pat (@pats) {
    my $q = quotemeta $pat;
    # match the pattern anywhere in the domain or url fields only
    for my $f (qw(domain url sourceUrl accessHost)) {
      my ($v) = $r =~ /"$f"\s*:\s*"([^"]*)"/;
      next unless defined $v;
      next ROW if $v =~ /$q/i;
    }
  }
  push @keep, $r;
}

my $kept = scalar @keep;
my $out = substr($s, 0, $begin) . join(',', @keep) . substr($s, $end);
# the headline number is the recount, so the tile and the table agree
$out =~ s/^(\{"name":"[^"]*","query":".*?","total":)[^,]*/$1$kept/s;
print $out;
print STDERR "$kept\n";
PERL

# Silently ignoring a filter would hand the SE an unfiltered report that looks
# filtered, so say so and stop rather than guess what they meant.
if [ -n "$MINSCORE$EXCLUDE" ] && [ ! -x /usr/bin/perl ]; then
  echo "--min-score and --exclude need perl, and /usr/bin/perl is not here." >&2
  echo "Drop the filters, or install perl, rather than send an unfiltered report." >&2
  exit 1
fi
if [ -n "$MINSCORE$EXCLUDE" ]; then
  printf 'Applying filters   '
  for f in "$TMP"/*.json; do
    grep -q '"source":"signal-lake"\|signal-lake' "$f" 2>/dev/null || true
    case "$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$f" | head -1)" in
      "Phishing pages"|"Lookalike domains"|"Mail-enabled lookalikes")
        B=$(basename "$f" .json)
        /usr/bin/perl "$TMP/filter.pl" "$MINSCORE" "$EXCLUDE" "$f" "$TMP/$B".page* 2>"$TMP/kept" > "$f.f"
        if [ -s "$f.f" ]; then mv "$f.f" "$f"; printf '.'; else rm -f "$f.f"; printf 'x'; fi ;;
      *) printf '-' ;;
    esac
  done
  echo ' done'
fi

# ---------- cut the replies down to the rows the report shows ----------
# The API hands back a whole page and ignores every page-size parameter, so the
# rest would be emailed to the customer for nothing. Perl ships with macOS; if
# it is missing the full reply is kept, which only costs file size.
cat > "$TMP/trim.pl" <<'PERL'
#!/usr/bin/perl
# Keep the first N objects of the first "data":[ ... ] array; pass the rest of
# the file through byte for byte. String and escape aware, so a brace inside a
# value cannot fool the count. Scans in runs rather than character by character.
use strict; use warnings;
my ($limit, $file) = @ARGV;
open(my $fh, '<:raw', $file) or do { exit 1 };
local $/; my $s = <$fh>; close $fh;

my $key = '"data":[';
my $start = index($s, $key);
if ($start < 0) { print $s; exit 0 }

my $i = $start + length($key);
my $begin = $i;
my $n = length($s);
my ($depth, $kept) = (0, 0);

# One pass. pos()/\G lets the regex engine skip runs of uninteresting bytes,
# which is what makes this fast enough to run on a megabyte of replies.
sub scan_to_end {
    my ($from, $stop_after) = @_;
    my $d = 0;
    pos($s) = $from;
    while (pos($s) < $n) {
        last unless $s =~ /\G[^"{}\[\]]*/gc;
        my $c = substr($s, pos($s), 1);
        last if $c eq '';
        if ($c eq '"') {                    # skip a whole string, escapes and all
            pos($s) = pos($s) + 1;
            $s =~ /\G(?:[^"\\]|\\.)*/gcs;
            pos($s) = pos($s) + 1;
            next;
        }
        if ($c eq '{' or $c eq '[') { $d++; pos($s) = pos($s) + 1; next }
        if ($c eq '}') {
            $d--; pos($s) = pos($s) + 1;
            if ($d == 0 and $stop_after) { $kept++; return pos($s) if $kept >= $stop_after }
            next;
        }
        if ($c eq ']') { return pos($s) if $d == 0; $d--; pos($s) = pos($s) + 1; next }
        pos($s) = pos($s) + 1;
    }
    return pos($s) // $n;
}

my $end_of_kept = scan_to_end($i, $limit);
my $end_of_array = scan_to_end($end_of_kept, 0);

print substr($s, 0, $begin), substr($s, $begin, $end_of_kept - $begin), substr($s, $end_of_array);
PERL

if [ -x /usr/bin/perl ]; then
  printf 'Trimming rows      '
  for f in "$TMP"/*.json; do
    if /usr/bin/perl "$TMP/trim.pl" "$ROWS" "$f" > "$f.t" 2>/dev/null && [ -s "$f.t" ]; then
      mv "$f.t" "$f"; printf '.'
    else
      rm -f "$f.t"; printf 'x'
    fi
  done
  echo ' done'
fi

# ---------- build the report ----------
printf 'Writing the report ' >&2
{
cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Threat exposure: $BRAND</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
 /* ---------- Infoblox palette ---------- */
 :root{
   --black:#101820; --green:#00BD4D; --cyan:#00E2EC; --offwhite:#F0EFE9; --steel:#D9E1E2; --yellow:#FEDD00;
   /* severity on the dark cover */
   --red-d:#ff5a52; --amber-d:#f5c518;
   /* severity on white paper: the same hues, darkened until they pass 4.5:1 as text */
   --red:#c9362d; --amber:#8a6300;
   --ink:#101820; --body:#3d454c; --mute:#6a7078; --faint:#9aa1a8;
   --line:#e3e6e8; --zebra:#f6f6f3; --paper:#fff;
   --sans:Inter,"Helvetica Neue",Helvetica,Arial,sans-serif;
   --mono:"JetBrains Mono","SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
 }
 *{box-sizing:border-box}
 html,body{margin:0;padding:0}
 body{background:var(--paper);color:var(--ink);font-family:var(--sans);font-size:15px;line-height:1.5;
      -webkit-print-color-adjust:exact;print-color-adjust:exact;font-feature-settings:"cv11","ss01"}
 a{color:inherit;text-underline-offset:3px}
 :focus-visible{outline:2px solid var(--cyan);outline-offset:2px;border-radius:3px}
 .wrap{max-width:1180px;margin:0 auto;padding:0 40px}

 /* =================== page one: the cover =================== */
 .cover{background:var(--black);color:#fff;padding:40px 0 44px;
        background-image:radial-gradient(1100px 520px at 88% -10%,rgba(0,226,236,.14),transparent 62%)}
 .cover .top{display:flex;align-items:center;justify-content:space-between;margin-bottom:36px;gap:24px}
 .cover .top img.ib{height:36px;width:auto;display:block}
 /* Brandfetch hands over 400x400, so the customer mark can carry the corner */
 .cover .top img.cust{height:84px;width:auto;max-width:300px;object-fit:contain;display:block;
        background:#fff;border-radius:10px;padding:10px 14px}
 /* when the logo fails to load the name is written out instead */
 .cover .top .nm{display:none;font-size:24px;font-weight:600;letter-spacing:.2px;color:#fff}
 .kicker{font-family:var(--mono);font-size:11.5px;letter-spacing:.16em;text-transform:uppercase;color:var(--cyan);margin:0 0 8px}
 h1{font-size:34px;font-weight:600;letter-spacing:-.4px;line-height:1.15;margin:0}
 h1 .brand{text-transform:capitalize}
 .rule{height:3px;width:220px;margin:14px 0 18px;background:linear-gradient(90deg,var(--green),var(--cyan))}
 .intro{max-width:70ch;font-size:15px;line-height:1.6;color:#c9cfd3;margin:0 0 22px}

 .facts{display:flex;border:1px solid #2c3640;border-radius:8px;margin-bottom:12px;overflow:hidden}
 .fact{flex:1 1 auto;padding:12px 18px;border-right:1px solid #2c3640;min-width:0}
 .fact:last-child{border-right:0}
 .fact span{display:block;font-size:12px;color:#98a1a8;letter-spacing:.02em}
 .fact b{display:block;font-family:var(--mono);font-size:15px;font-weight:500;color:var(--cyan);margin-top:2px;overflow-wrap:anywhere}
 .key{margin:0 0 18px;font-size:13.5px;color:#aab1b8;display:flex;gap:22px;flex-wrap:wrap}
 .dot{display:inline-block;width:9px;height:9px;border-radius:50%;vertical-align:1px;margin-right:6px}
 .dot.r{background:var(--red-d)} .dot.a{background:var(--amber-d)}

 /* --- summary cards: figure on the left, story on the right, one rule between --- */
 .card{display:grid;grid-template-columns:250px 1fr;column-gap:32px;
       background:var(--offwhite);color:var(--ink);border-radius:10px;padding:22px 26px;margin-bottom:12px}
 .fig{border-right:1px solid #c5cbcd;padding-right:28px;align-self:stretch;display:flex;flex-direction:column;justify-content:center}
 .big{font-size:44px;font-weight:600;line-height:1;letter-spacing:-1px;color:var(--ink)}
 .big.sev-r{color:var(--red)} .big.sev-a{color:var(--amber)}
 .lab{font-size:13.5px;color:var(--body);margin-top:6px;line-height:1.35}
 .meter{height:6px;background:#cfd6d7;border-radius:3px;margin:14px 0 10px;overflow:hidden}
 .meter i{display:block;height:100%;background:var(--red);border-radius:3px}
 .sub{font-size:14px;line-height:1.35;color:var(--body)}
 .sub b{font-size:22px;font-weight:600;letter-spacing:-.4px;color:var(--red);display:block;margin-bottom:2px}
 .txt{min-width:0;display:flex;flex-direction:column;justify-content:center}
 .txt h2{margin:0 0 6px;font-size:16px;font-weight:700;letter-spacing:.02em;text-transform:uppercase;display:flex;align-items:center;gap:9px}
 .txt h2 svg{width:22px;height:22px;flex:none}
 .txt p{margin:0;font-size:14.5px;line-height:1.5;color:var(--body);max-width:66ch}
 .txt p+p{margin-top:5px;color:#525a63;font-size:13.5px}
 .txt .go{margin-top:9px;font-size:13px;color:var(--ink);font-weight:600;text-decoration:none;display:inline-flex;gap:7px;align-items:center}
 .txt .go .n{font-family:var(--mono);font-weight:500;font-size:11.5px;color:var(--mute);letter-spacing:.08em}
 .card.aside{background:transparent;border:1px solid #33404b;color:#d3d7db;grid-template-columns:1fr;padding:18px 26px}
 .card.aside .txt h2{color:#fff}
 .card.aside .txt p{color:#b6bec5}
 .card.aside .txt p+p{color:#8f989f}

 .toc{margin-top:22px;border-top:1px solid #2c3640;padding-top:14px;display:grid;grid-template-columns:auto 1fr;gap:6px 22px;align-items:baseline}
 .toc .h{font-family:var(--mono);font-size:11.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--cyan);grid-column:1/-1;margin-bottom:2px}
 .toc a{color:#e8ebee;text-decoration:none;font-size:13.5px}
 .toc .n{font-family:var(--mono);font-size:12px;color:#8f989f}
 .toc a>.n:first-child{display:none}   /* the number sits in its own grid column on screen, inline on paper */
 .cover .foot{margin-top:22px;font-size:13px;color:#8f989f}

 /* =================== the detail sections =================== */
 .section{padding:0 0 44px}
 .strip{position:sticky;top:0;z-index:3;background:var(--paper);border-bottom:1px solid var(--steel);
        display:flex;align-items:center;gap:14px;height:44px;font-size:12.5px}
 .strip .n{font-family:var(--mono);font-size:11.5px;letter-spacing:.1em;color:var(--mute)}
 .strip .n b{color:var(--ink);font-weight:600}
 .strip .name{font-weight:600;color:var(--ink)}
 .strip .cust{color:var(--mute)}
 .strip .up{margin-left:auto;text-decoration:none;color:var(--ink);font-weight:500;
            border:1px solid var(--steel);border-radius:99px;padding:4px 12px;background:var(--paper)}
 .strip .up:hover{border-color:var(--ink)}
 .bar{height:3px;background:var(--line);margin-bottom:26px}
 .bar i{display:block;height:100%;background:linear-gradient(90deg,var(--green),var(--cyan))}
 .section h2{font-size:24px;font-weight:600;letter-spacing:-.4px;margin:0 0 6px;display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
 .section h2 .num{font-family:var(--mono);font-size:14px;font-weight:500;color:var(--mute);letter-spacing:.06em}
 .section h2 .cnt{margin-left:auto;font-size:14px;font-weight:500;color:var(--body)}
 .section h2 .cnt b{font-weight:600;color:var(--ink)}
 .means{font-size:14.5px;line-height:1.55;color:var(--body);margin:0 0 14px;max-width:78ch}
 .query{display:flex;align-items:baseline;gap:12px;background:var(--offwhite);border-radius:6px;padding:9px 14px;margin:0 0 18px;
        font-family:var(--mono);font-size:12.5px;color:var(--body);overflow-wrap:anywhere}
 .query span{font-size:10.5px;letter-spacing:.14em;text-transform:uppercase;color:var(--mute);flex:none}

 /* --- the table --- */
 table{width:100%;border-collapse:separate;border-spacing:0;font-size:13px;table-layout:fixed}
 col{width:var(--w)}                    /* screen share; paper may use its own, see @media print */
 th{position:sticky;top:44px;z-index:2;background:var(--paper);text-align:left;font-family:var(--mono);font-size:10.5px;letter-spacing:.09em;
    text-transform:uppercase;color:var(--mute);font-weight:500;padding:8px 10px 7px;border-bottom:2px solid var(--ink);
    vertical-align:bottom;line-height:1.3}
 td{padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top;line-height:1.4;overflow-wrap:anywhere}
 tbody tr:nth-child(even) td{background:var(--zebra)}
 td.idx{font-family:var(--mono);font-size:11px;color:var(--faint);text-align:right;padding-left:4px;padding-right:6px;padding-top:10px;white-space:nowrap}
 th.idx{padding-left:4px;padding-right:6px}
 .id{font-family:var(--mono);font-size:12.5px;color:var(--ink)}           /* identifiers: accounts, domains, urls */
 .id .p{color:var(--mute)}                                                  /* the path part of a url, quieter */
 .sec{display:block;font-size:12px;color:var(--mute);margin-top:2px}        /* a second line under a value */
 .date{font-family:var(--mono);font-size:12.5px;white-space:nowrap;color:var(--body);font-variant-numeric:tabular-nums}
 .date .ago{display:block;font-family:var(--sans);font-size:11.5px;color:var(--faint);white-space:normal}
 .none{color:var(--faint)}
 .flag{display:inline-flex;align-items:flex-start;gap:6px}
 .flag::before{content:"";width:8px;height:8px;border-radius:50%;background:var(--faint);flex:none;margin-top:5px}
 .flag.r::before{background:var(--red)} .flag.a::before{background:var(--amber)} .flag.g::before{background:var(--green)}
 .flag.r{color:var(--red);font-weight:500}
 /* risk: the number and a short meter, so 4.7 and 92.1 differ in shape as well as digits */
 .risk{display:flex;align-items:center;gap:8px;white-space:nowrap}
 .risk b{font-family:var(--mono);font-weight:500;font-size:12.5px;width:4ch;text-align:right;font-variant-numeric:tabular-nums;color:var(--mute)}
 .risk i{display:block;width:56px;height:6px;background:var(--steel);border-radius:3px;overflow:hidden;flex:none}
 .risk i::after{content:"";display:block;height:100%;width:var(--v);background:var(--faint);border-radius:3px}
 .risk.a b{color:var(--amber);font-weight:600} .risk.a i::after{background:#e0a800}
 .risk.r b{color:var(--red);font-weight:600} .risk.r i::after{background:var(--red)}
 .brands{line-height:1.4}
 .brands .you{font-weight:600}
 .more{font-size:12.5px;color:var(--mute);margin-top:9px}
 .trail{display:flex;justify-content:space-between;align-items:baseline;margin-top:14px;padding-top:10px;border-top:1px solid var(--line);font-size:13px}
 .trail a{text-decoration:none}
 .trail .up{color:var(--mute)} .trail .next{color:var(--ink);font-weight:600}

 .note{margin:0 0 44px;background:#fff5f4;border:1px solid #f3cfcc;border-radius:8px;padding:13px 16px;font-size:13px;line-height:1.5;color:var(--body);
       display:grid;grid-template-columns:24px 1fr;gap:12px;align-items:start}
 .note svg{width:20px;height:20px;display:block;margin-top:1px}
 .note b{color:var(--red);display:block;font-size:13.5px;margin-bottom:2px}
 footer{padding:0 0 40px;font-size:12.5px;color:var(--mute)}

 /* screen only: A4 is 794px wide, so an unscoped breakpoint would fire on paper too */
 @media screen and (max-width:820px){
   .wrap{padding:0 20px}
   .card{grid-template-columns:1fr;row-gap:14px}
   .fig{border-right:0;border-bottom:1px solid #c5cbcd;padding:0 0 14px}
   .facts{flex-direction:column} .fact{border-right:0;border-bottom:1px solid #2c3640}
   .cover .top img.cust{height:60px;max-width:200px}
   table{table-layout:auto}
 }

 /* =================== paper =================== */
 @media print{
   @page{size:A4;margin:15mm 13mm 16mm}
   @page cover{margin:0}
   .cover{page:cover;min-height:297mm;padding:8mm 0 6mm;break-after:page}
   .cover .wrap{padding:0 13mm}
   .cover .top{margin-bottom:8px}
   .cover .top img.ib{height:26px} .cover .top img.cust{height:54px;max-width:220px;padding:7px 11px}
   .cover .top .nm{font-size:20px}
   .wrap{padding:0;max-width:none}
   body{font-size:12.5px}
   .kicker{font-size:10.5px;margin-bottom:3px}
   h1{font-size:23px} .rule{margin:8px 0 10px}
   .intro{font-size:11.5px;margin-bottom:10px;line-height:1.5}
   .facts{margin-bottom:9px}
   .fact{padding:6px 14px} .fact span{font-size:10px} .fact b{font-size:12px}
   .key{font-size:11px;margin-bottom:9px}
   .card{padding:10px 16px;margin-bottom:6px;grid-template-columns:180px 1fr;column-gap:20px;break-inside:avoid;border-radius:8px}
   .fig{padding-right:18px}
   .big{font-size:28px} .sub b{font-size:15px} .lab,.sub{font-size:10.5px} .meter{margin:7px 0 4px}
   .txt p{font-size:11px} .txt p+p{font-size:10.5px;margin-top:2px} .txt h2{font-size:12px;margin-bottom:3px}
   .txt .go{font-size:11px;margin-top:4px} .txt .go .n{font-size:10px}
   .card.aside{padding:9px 16px}
   /* the section list runs in one line on paper */
   .toc{display:flex;flex-wrap:wrap;gap:3px 18px;margin-top:8px;padding-top:8px;align-items:baseline}
   .toc .h{width:100%;font-size:10.5px;margin-bottom:0}
   .toc a{font-size:11px} .toc>.n{display:none} .toc a>.n:first-child{display:inline}
   .cover .foot{font-size:10.5px;margin-top:6px}
   .flag{overflow-wrap:normal}
   col{width:var(--wp,var(--w))}
   .section{break-before:page;padding-bottom:0}
   .strip{position:static;height:auto;padding:0 0 8px}
   .strip .up{display:none}
   th{position:static;font-size:9.5px;padding:6px 7px 5px}
   td{font-size:11.5px;padding:6px 5px;line-height:1.35}
   .id{font-size:11px} .date{font-size:11px} .date .ago{font-size:10px} .sec{font-size:10.5px}
   .risk{gap:5px} .risk b{font-size:11px} .risk i{width:30px}
   .flag::before{margin-top:4px}
   thead{display:table-header-group}
   tr{break-inside:avoid}
   .trail{display:none}
   .rowbox{min-height:0!important}
   .note{break-inside:avoid;margin-top:18px}
   footer{padding-top:14px}
 }
</style></head><body>
<main data-brand="$BRAND" data-domain="$DOMAIN" data-scan="$(date '+%Y-%m-%d')">

<div class="cover" id="top"><div class="wrap">
  <div class="top">
    <div><img class="ib" src="$OURS" alt="Infoblox" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">Infoblox</span></div>
    <div><img class="cust" src="$LOGO" alt="$BRAND" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">$BRAND</span></div>
  </div>

  <p class="kicker">Threat exposure &middot; Executive summary</p>
  <h1>What is visible about <span class="brand">$BRAND</span><br>from the outside</h1>
  <div class="rule"></div>
  <p class="intro">Infoblox looked for exposure tied to your brand and your domain across breach data,
    criminal marketplaces and the public web. Each card below is one measurement. The number on the left
    is the count on $(date '+%d %B %Y'); the text explains what it means and why it matters.</p>

  <div class="facts">
    <div class="fact"><span>Brand searched</span><b>$BRAND</b></div>
    <div class="fact"><span>Domain searched</span><b>$DOMAIN</b></div>
    <div class="fact"><span>Scan date</span><b>$(date '+%d %b %Y')</b></div>
    <div class="fact"><span>Data source</span><b>Axur (one.axur.com)</b></div>
  </div>
  <p class="key"><span><span class="dot r"></span>Red: somebody could use this today.</span>
    <span><span class="dot a"></span>Amber: exposure that needs one more step first.</span></p>

  <div id="metrics"></div>

  <div class="toc" id="toc"></div>
  <p class="foot">Counts taken from one.axur.com on the scan date. They move daily. Passwords are never included in this report.</p>
</div></div>

<div class="wrap" id="sections"></div>

<div class="wrap">
  <div class="note">
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <rect x="4" y="10.5" width="16" height="10" rx="2.4" stroke="#c9362d" stroke-width="1.7"/>
      <path d="M8 10.5V7.6a4 4 0 0 1 8 0v2.9" stroke="#c9362d" stroke-width="1.7" stroke-linecap="round"/>
    </svg>
    <div><b>Passwords withheld</b>
      Axur stores leaked passwords in clear text. This report shows the account and the site it was used on,
      never the password itself.</div>
  </div>
  <footer>External attack surface (servers and services reachable from the internet) is a separate download:
    one.axur.com/easm, Exposures, Download all.</footer>
</div>
HTMLHEAD

# A few hundred bytes of headline numbers, so the summary paints without
# waiting on the megabytes of replies below it.
echo '<script type="application/json" id="totals">['
FIRST=1
for f in "$TMP"/*.json; do
  [ $FIRST -eq 1 ] || echo ','
  FIRST=0
  sed -n 's/^{"name":"\([^"]*\)","query":"\(.*\)","total":\([^,]*\),.*/{"name":"\1","query":"\2","total":\3}/p' "$f"
done
echo ']</script>'

# The renderer runs BEFORE the megabytes below it, so the summary and the
# reserved section shells are on screen while the parser is still reading.
cat <<'HTMLTAIL' | sed "s/ROWSVALUE/$ROWS/"
<script>
(function(){
  'use strict';
  var ROWLIMIT = ROWSVALUE;
  var HIDE = /password|hash|datahubId|^id$/i;   // never print a leaked password
  var PREF = ['user','accessUrl','accessHost','sourceName','leakDisplayName',
              'domain','url','sourceUrl','riskScore','impersonatedBrandsHigh',
              'contentType','domainCreationDate','detectionDate','sourceDate'];

  // who the report is about, handed over by the cover so this script needs no interpolation
  var main = document.querySelector('main');
  var BRAND = (main && main.getAttribute('data-brand')) || '';
  var DOMAIN = (main && main.getAttribute('data-domain')) || 'your domain';
  var Brand = BRAND ? BRAND.charAt(0).toUpperCase() + BRAND.slice(1) : 'you';
  var SCAN = (function(){
    var s = (main && main.getAttribute('data-scan')) || '', m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : new Date();
  })();

  // The summary reads a few hundred bytes of totals, so it paints at once.
  // The full replies are parsed later, in buildTables, because they run to megabytes.
  var totals = [];
  try { totals = JSON.parse(document.getElementById('totals').textContent) || []; } catch (e) { totals = []; }
  var tot = {};
  totals.forEach(function(t){ tot[t.name] = t.total; });
  var data = null;
  function loadPayload(){
    if (data) return data;
    var el = document.getElementById('payload');
    if (!el) return [];
    try { data = JSON.parse(el.textContent); } catch (e) { data = []; }
    if (!Array.isArray(data)) data = [];
    return data;
  }
  function n(name){ var t = tot[name]; var v = Number(t); return (t === null || t === undefined || t === '' || isNaN(v)) ? null : v; }
  function show(v){ return v === null ? '&mdash;' : v.toLocaleString('en-GB'); }
  function pct(a, b){ return (a && b) ? Math.min(100, Math.round(a / b * 100)) : 0; }

  /* ---------- rendering values for a human ----------
     Every formatter takes whatever Axur sent: missing, null, "", a number, a
     string, an array, an object. None of them may throw. */
  var MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  function str(v){
    if (v === null || v === undefined) return '';
    if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
    return String(v);
  }
  function esc(s){ return str(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
  function blank(v){ return v === null || v === undefined || v === '' || (Array.isArray(v) && !v.length); }
  function arr(v){ if (Array.isArray(v)) return v; return blank(v) ? [] : [v]; }
  function first(r, keys){ for (var i = 0; i < keys.length; i++) { if (!blank(r[keys[i]])) return r[keys[i]]; } return null; }
  function pad2(x){ return (x < 10 ? '0' : '') + x; }
  function dateOf(v){
    if (blank(v)) return null;
    var d;
    if (typeof v === 'number' || /^\d+$/.test(String(v))) { var t = Number(v); if (t < 1e11) t *= 1000; d = new Date(t); }
    else d = new Date(String(v));
    return isNaN(d.getTime()) ? null : d;
  }
  function fmtDate(d){ return pad2(d.getDate()) + ' ' + MON[d.getMonth()] + ' ' + d.getFullYear(); }
  function ago(d){
    var days = Math.round((SCAN - d) / 864e5);
    if (days < 0) return '';
    if (days < 1) return 'scan day';
    if (days < 30) return days + (days === 1 ? ' day ago' : ' days ago');
    if (days < 365) { var mo = Math.round(days / 30.4); return mo + (mo === 1 ? ' month ago' : ' months ago'); }
    var y = Math.floor(days / 365.25); return y + (y === 1 ? ' year ago' : ' years ago');
  }
  function none(){ return '<span class="none">&mdash;</span>'; }
  // an identifier may break before "@" or after ". / - ? & =", never inside a word
  function brk(s){ return esc(s).replace(/@/g, '<wbr>@').replace(/([.\/\-?&=])/g, '$1<wbr>'); }
  function hostOf(url){ var m = /^(?:[a-z]+:\/\/)?([^\/?#]+)/i.exec(str(url)); return m ? m[1] : ''; }
  var CONTENT = { 'Phishing':'Phishing page', 'Scam':'Scam page', 'Financial':'Financial services',
                  'Recruitment':'Job offer', 'Social media':'Social profile', 'Other':'Not classified' };
  var SOURCE = { 'Deep/Dark Web - Telegram':'Telegram channel', 'IntelX':'Breach archive (IntelX)' };

  var F = {
    text: function(v){ return blank(v) ? none() : brk(Array.isArray(v) ? v.join(', ') : v); },
    account: function(v){ return blank(v) ? none() : '<span class="id">' + brk(v) + '</span>'; },
    // the site a password was used on, or the page found: host first, then the path in a quieter colour
    site: function(v, r){
      var url = first(r, ['accessUrl','url','reference','finalUrl','sourceUrl']);
      var host = first(r, ['accessHost','host']) || hostOf(url) || r.domain;
      if (blank(host)) return '<span class="none">Not recorded</span>';
      // the path, without its query string: a session token tells the reader nothing
      var path = '';
      if (!blank(url)) { var m = str(url).replace(/^[a-z]+:\/\//i, '').replace(/^[^\/]*/, '').replace(/[?#].*$/, ''); if (m && m !== '/') path = m; }
      return '<span class="id">' + brk(host) + (path ? '<span class="p">' + brk(path) + '</span>' : '') + '</span>';
    },
    source: function(v){ return blank(v) ? none() : esc(SOURCE[v] || v); },
    pwd: function(v){
      if (blank(v)) return none();
      return str(v).toUpperCase() === 'PLAIN' ? '<span class="flag r">Readable</span>' : '<span class="flag">Hashed</span>';
    },
    date: function(v){
      var d = dateOf(v); if (!d) return none();
      var a = ago(d);
      return '<span class="date">' + fmtDate(d) + (a ? '<span class="ago">' + a + '</span>' : '') + '</span>';
    },
    // ["Equifax","Norton"] -> "Equifax and Norton"; the customer's own name in bold.
    // Axur sometimes sends objects here: [{impersonatedBrand:"Equifax",impersonatedLevel:"high"}]
    brands: function(v){
      var list = arr(v).map(function(b){ return (b && typeof b === 'object') ? (b.impersonatedBrand || b.name || str(b)) : str(b); })
                       .filter(function(b){ return b !== ''; });
      if (!list.length) return none();
      var me = BRAND.toLowerCase();
      var out = list.map(function(b){ return (me && b.toLowerCase().indexOf(me) > -1) ? '<span class="you">' + esc(b) + '</span>' : esc(b); });
      var s = out.length === 1 ? out[0] : out.slice(0, -1).join(', ') + ' and ' + out[out.length - 1];
      return '<span class="brands">' + s + '</span>';
    },
    // what the page asks a visitor for, said in words
    asks: function(v, r){
      var out = [], c = str(r.credentialRequested).toLowerCase(), p = str(r.paymentRequested).toLowerCase();
      if (c === 'yes' || c === 'true') out.push('<span class="flag r">Login details</span>');
      else if (c === 'possibly') out.push('<span class="flag a">Login details (probable)</span>');
      if (p === 'yes' || p === 'true') out.push('<span class="flag r">Payment</span>');
      else if (p === 'possibly') out.push('<span class="flag a">Payment (probable)</span>');
      if (out.length) return out.join('<br>');
      return (blank(r.credentialRequested) && blank(r.paymentRequested)) ? none() : '<span class="none">Nothing</span>';
    },
    content: function(v){ return blank(v) ? none() : esc(CONTENT[v] || v); },
    risk: function(v){
      var x = Number(v);
      if (blank(v) || isNaN(x)) return none();
      x = Math.max(0, Math.min(100, x));
      var band = x >= 70 ? 'r' : x >= 40 ? 'a' : '';
      return '<span class="risk ' + band + '"><b>' + x.toFixed(1) + '</b><i style="--v:' + Math.max(2, Math.round(x)) + '%"></i></span>';
    },
    // the name as people see it first (renderedReference holds the accented form), the xn-- punycode
    // it is registered as underneath. sanitizedDomain is NOT used: it is the homoglyph-stripped form,
    // which for a lookalike is the customer's own domain.
    domain: function(v, r){
      var d = first(r, ['renderedReference','host','domain','reference']), raw = first(r, ['domain','host']);
      if (blank(d)) return none();
      return '<span class="id">' + brk(d) + '</span>' +
        (!blank(raw) && /xn--/i.test(str(raw)) && str(raw) !== str(d) ? '<span class="sec id">' + brk(raw) + '</span>' : '');
    },
    country: function(v){ var l = arr(v).map(str).filter(Boolean); return l.length ? esc(l.join(', ')) : none(); },
    owner: function(v, r){
      var o = str(first(r, ['registrantOrganization','registrant','administratorOrganization'])).trim();
      if (!o) return '<span class="none">Not disclosed</span>';
      if (/privacy|proxy|guardian|redact|withheld|whoisguard|protected/i.test(o)) return '<span class="none">Hidden</span><span class="sec">' + esc(o) + '</span>';
      return esc(o);
    },
    // ["20 alt1.mail.example.com."] -> Yes, alt1.mail.example.com. Axur writes ["n/a"] for none.
    mx: function(v){
      if (v === undefined) return none();                       // the field was not in this record
      var hosts = arr(v).map(function(x){ return str(x).trim().replace(/^\d+\s+/, '').replace(/\.$/, ''); })
                        .filter(function(x){ return x && !/^(n\/a|none|null|-)$/i.test(x); });
      if (!hosts.length) return '<span class="flag">No mail set up</span>';
      return '<span class="flag r">Yes</span><span class="sec id">' + brk(hosts[0]) + (hosts.length > 1 ? ' +' + (hosts.length - 1) : '') + '</span>';
    },
    // the fallback for a column nobody described: dates as dates, lists as lists, never JSON
    any: function(v){
      if (blank(v)) return none();
      if (typeof v === 'number' && v > 1e11) return F.date(v);
      if (Array.isArray(v)) return esc(v.map(function(x){ return (x && typeof x === 'object') ? str(x) : str(x); }).join(', '));
      if (typeof v === 'object') return esc(str(v));
      return esc(v);
    }
  };
  function cell(f, v, r){
    try { return F[f](v, r); } catch (e) { try { return esc(str(v)); } catch (e2) { return ''; } }
  }

  /* ---------- which columns, in which order, at which width ----------
     w is the share of the table on screen, wp the share on A4 paper (both sum to 100).
     Reading order: the thing itself, then what it is for or who it pretends to be, then how bad, then when. */
  var COLS = {
    'Leaked credentials': [
      {k:'user',          h:'Account',                 f:'account', w:30, wp:24},
      {k:'accessHost',    h:'Password used on',        f:'site',    w:25, wp:22},
      {k:'sourceName',    h:'Where it was found',      f:'source',  w:15, wp:13},
      {k:'passwordType',  h:'Password',                f:'pwd',     w:10, wp:12},
      {k:'sourceDate',    h:'Leaked',                  f:'date',    w:10, wp:14.5},
      {k:'detectionDate', h:'Found by Axur',           f:'date',    w:10, wp:14.5} ],
    'In plaintext': [
      {k:'user',          h:'Account',                 f:'account', w:30, wp:28},
      {k:'accessHost',    h:'Password used on',        f:'site',    w:32, wp:26},
      {k:'sourceName',    h:'Where it was found',      f:'source',  w:18, wp:16},
      {k:'sourceDate',    h:'Leaked',                  f:'date',    w:10, wp:15},
      {k:'detectionDate', h:'Found by Axur',           f:'date',    w:10, wp:15} ],
    'Phishing pages': [
      {k:'reference',     h:'Page',                    f:'site',    w:27, wp:24},
      {k:'impersonatedBrandsHigh', h:'Pretends to be', f:'brands',  w:15, wp:14},
      {k:'contentType',   h:'Kind of page',            f:'content', w:11, wp:10},
      {k:'credentialRequested', h:'Asks visitors for', f:'asks',    w:14, wp:12},
      {k:'riskScore',     h:'Risk',                    f:'risk',    w:12, wp:11},
      {k:'domainCreationDate', h:'Domain registered',  f:'date',    w:10.5, wp:14.5},
      {k:'detectionDate', h:'Found by Axur',           f:'date',    w:10.5, wp:14.5} ],
    'Lookalike domains': [
      {k:'domain',        h:'Domain',                  f:'domain',  w:24, wp:22},
      {k:'registrantOrganization', h:'Registered to',  f:'owner',   w:18, wp:16},
      {k:'registrar',     h:'Through',                 f:'text',    w:14, wp:15},
      {k:'countryNames',  h:'Country',                 f:'country', w:10, wp:10},
      {k:'dnsEntriesRecordMX', h:'Can send mail',      f:'mx',      w:21, wp:22},
      {k:'domainCreationDate', h:'Registered',         f:'date',    w:13, wp:15} ],
    // this search returns page hits, so the same domain can fill the table; the page path is what tells rows apart
    'Mail-enabled lookalikes': [
      {k:'reference',     h:'Site',                    f:'site',    w:24, wp:22},
      {k:'dnsEntriesRecordMX', h:'Mail goes through',  f:'mx',      w:24, wp:24},
      {k:'registrantOrganization', h:'Registered to',  f:'owner',   w:16, wp:14},
      {k:'registrar',     h:'Through',                 f:'text',    w:14, wp:12},
      {k:'domainCreationDate', h:'Registered',         f:'date',    w:11, wp:14},
      {k:'detectionDate', h:'Found by Axur',           f:'date',    w:11, wp:14} ]
  };
  // a search this script has never heard of still gets a readable table
  function guessCols(rs){
    var seen = {};
    rs.slice(0, 20).forEach(function(r){ Object.keys(r || {}).forEach(function(k){ seen[k] = 1; }); });
    var all = Object.keys(seen).filter(function(k){ return !HIDE.test(k); });
    var out = PREF.filter(function(k){ return all.indexOf(k) > -1; });
    all.forEach(function(k){ if (out.indexOf(k) < 0 && out.length < 5) out.push(k); });
    return out.slice(0, 5).map(function(k){
      var h = k.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, function(c){ return c.toUpperCase(); });
      return {k:k, h:h, f:/date/i.test(k) ? 'date' : 'any', w:100 / Math.min(5, out.length)};
    });
  }

  /* ---------- copy ---------- */
  var TITLES = { 'Leaked credentials':'Exposed credentials', 'In plaintext':'Passwords in readable form',
                 'Phishing pages':'Impersonation sites', 'Lookalike domains':'Lookalike domains',
                 'Mail-enabled lookalikes':'Lookalikes that can send mail' };
  function heading(name){ return TITLES[name] || name; }
  var MEANS = {
    'Leaked credentials':'One row per exposed account. "Password used on" is the site the password was for, which is often not your own. An account appears more than once if it leaked more than once.',
    'In plaintext':'The subset of the previous table where the password was stored in readable form. These are the ones to reset first. The password itself is withheld from this report.',
    'Phishing pages':'Pages Axur is highly confident are impersonating this brand. Risk runs from 0 to 100 and combines how convincing the page is with what it asks for. Some pages will already be offline; the last column shows when each was seen.',
    'Lookalike domains':'Domain names one character away from yours that somebody has registered. Registration alone is not proof of intent, but it is the first step in most of these attacks. Your own defensive registrations appear here too.',
    'Mail-enabled lookalikes':'The lookalike domains that already have working mail records. Somebody can send email from them that appears to come from your company, today, with no further setup.'
  };

  /* ---------- the summary cards ---------- */
  var ICON = {
    lock:'<rect x="4" y="10" width="16" height="11" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M8 10V7a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="12" cy="15.5" r="1.5" fill="currentColor"/>',
    mask:'<circle cx="12" cy="8" r="3.6" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M4.5 20c0-4 3.4-6.5 7.5-6.5s7.5 2.5 7.5 6.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
    site:'<rect x="3" y="5" width="18" height="14" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M3 9.5h18" stroke="currentColor" stroke-width="1.8"/><path d="M12 12.5v3" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
    risk:'<path d="M12 4 21 20H3z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M12 10v4M12 16.5v.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'
  };
  function sectionOf(name){ for (var i = 0; i < totals.length; i++) { if (totals[i].name === name) return i + 1; } return 0; }
  var CARDS = [
    { icon:'lock', title:'Exposed credentials', go:sectionOf('Leaked credentials'),
      big:n('Leaked credentials'), lab:'work accounts whose password has leaked', sev:'a',
      sub:n('In plaintext'), subLab:'of them with the password in readable form, usable today', subSev:'r',
      desc:'Accounts on ' + esc(DOMAIN) + ' whose passwords have already been exposed somewhere outside your company.',
      why:'They come from three places: company breaches, dumps traded on criminal forums, and staff or customer computers infected with password-stealing malware.' },
    { icon:'mask', title:'Impersonation sites', go:sectionOf('Phishing pages'),
      big:n('Phishing pages'), lab:'web pages built to look like ' + esc(Brand), sev:'r',
      desc:'Pages designed so that a customer or an employee hands over a login or a card number, believing they are dealing with you.',
      why:'Only pages Axur is highly confident are impersonating this brand are counted. Pages that merely mention the name are left out.' },
    { icon:'site', title:'Lookalike domains', go:sectionOf('Lookalike domains'),
      big:n('Lookalike domains'), lab:'registered names one character away from yours', sev:'a',
      sub:n('Mail-enabled lookalikes'), subLab:'of them can already send email that appears to come from you', subSev:'r',
      desc:'Domain names one swapped, dropped or doubled letter away from ' + esc(DOMAIN) + '. They exist to be mistaken for you.',
      why:'A lookalike is only a nuisance until someone sets up email on it. At that point it can send a message that appears to come from your company.' },
    { icon:'risk', title:'External attack surface', aside:true,
      desc:'The servers, services and open doors reachable from the public internet under your name.',
      why:'Not counted in this report. It comes from a different Axur screen and is supplied as a separate file.' }
  ];
  document.getElementById('metrics').innerHTML = CARDS.map(function(c){
    var fig = '';
    if (!c.aside) {
      fig = '<div class="fig"><div class="big sev-' + c.sev + '">' + show(c.big) + '</div><div class="lab">' + c.lab + '</div>';
      if (c.sub !== undefined) {
        fig += '<div class="meter"><i style="width:' + pct(c.sub, c.big) + '%"></i></div>' +
               '<div class="sub"><b>' + show(c.sub) + '</b>' + c.subLab + '</div>';
      }
      fig += '</div>';
    }
    return '<div class="card' + (c.aside ? ' aside' : '') + '">' + fig +
      '<div class="txt"><h2><svg viewBox="0 0 24 24" aria-hidden="true">' + ICON[c.icon] + '</svg>' + c.title + '</h2>' +
      '<p>' + c.desc + '</p><p>' + c.why + '</p>' +
      (c.go ? '<a class="go" href="#s' + c.go + '"><span class="n">SECTION ' + pad2(c.go) + '</span> See the records &rarr;</a>' : '') +
      '</div></div>';
  }).join('');

  document.getElementById('toc').innerHTML = '<div class="h">The records behind the numbers</div>' +
    totals.map(function(t, i){ return '<span class="n">' + pad2(i + 1) + '</span><a href="#s' + (i + 1) + '"><span class="n">' + pad2(i + 1) +
      '&ensp;</span>' + heading(t.name) + ' <span class="n">&middot; ' + show(n(t.name)) + '</span></a>'; }).join('');

  /* ---------- the detail sections ---------- */
  function rows(d){
    var r = d && d.reply && d.reply.result && d.reply.result.data;
    if (!Array.isArray(r) && d && Array.isArray(d.data)) r = d.data;
    return Array.isArray(r) ? r.filter(function(x){ return x && typeof x === 'object'; }) : [];
  }
  var secs = document.getElementById('sections');
  var TOTAL = totals.length;
  var ROWH = 46;   // a typical two-line row, so the page does not jump when the rows land

  // ---- phase one, synchronous: the shell of every section, with its space reserved ----
  totals.forEach(function(t, i){
    var no = pad2(i + 1), s = document.createElement('section');
    s.className = 'section'; s.id = 's' + (i + 1);
    var expect = n(t.name) === null ? 0 : Math.min(ROWLIMIT, n(t.name));
    var reserve = expect ? (expect + 1) * ROWH + 26 : 0;
    s.innerHTML =
      '<div class="strip"><span class="n"><b>' + no + '</b> / ' + pad2(TOTAL) + '</span>' +
        '<span class="name">' + heading(t.name) + '</span><span class="cust">' + esc(Brand) + ' &middot; threat exposure</span>' +
        '<a class="up" href="#top">&uarr; Summary</a></div>' +
      '<div class="bar"><i style="width:' + Math.round((i + 1) / TOTAL * 100) + '%"></i></div>' +
      '<h2><span class="num">' + no + '</span>' + heading(t.name) +
        '<span class="cnt" data-cnt="' + i + '"><b>' + show(n(t.name)) + '</b> records</span></h2>' +
      (MEANS[t.name] ? '<p class="means">' + MEANS[t.name] + '</p>' : '') +
      '<div class="query"><span>Axur search</span>' + esc(t.query) + '</div>' +
      '<div class="rowbox" data-i="' + i + '"' + (reserve ? ' style="min-height:' + reserve + 'px"' : '') + '></div>' +
      '<div class="trail"><a class="up" href="#top">&uarr; Back to the summary</a>' +
      (i + 1 < TOTAL ? '<a class="next" href="#s' + (i + 2) + '">' + pad2(i + 2) + ' &middot; ' + heading(totals[i + 1].name) + ' &rarr;</a>'
                     : '<a class="next" href="#top">Back to the summary &uarr;</a>') + '</div>';
    secs.appendChild(s);
  });

  // ---- phase two: the rows themselves, off the first-paint path ----
  // Idempotent, so the print path can call it without repeating the work.
  var built = false;
  function buildTables(){
    if (built) return;
    var d8 = loadPayload();
    if (!d8.length) return;   // parser has not reached the payload yet; try again later
    built = true;
    [].slice.call(secs.querySelectorAll('.rowbox')).forEach(function(box){
      var i = Number(box.getAttribute('data-i')), d = d8[i], t = totals[i];
      try {
        var rs = rows(d).slice(0, ROWLIMIT), total = n(t.name);
        if (!rs.length) { box.innerHTML = '<p class="more">No records returned.</p>'; return; }
        var cs = (COLS[t.name] || guessCols(rs)).filter(function(c){ return !HIDE.test(c.k); });
        var html = '<table><colgroup><col style="--w:4%">' +
          cs.map(function(c){ return '<col style="--w:' + (c.w * 0.96).toFixed(1) + '%;--wp:' + ((c.wp || c.w) * 0.96).toFixed(1) + '%">'; }).join('') +
          '</colgroup><thead><tr><th class="idx">#</th>' + cs.map(function(c){ return '<th>' + c.h + '</th>'; }).join('') + '</tr></thead><tbody>';
        rs.forEach(function(r, ri){
          html += '<tr><td class="idx">' + (ri + 1) + '</td>' +
            cs.map(function(c){ return '<td>' + cell(c.f, r[c.k], r) + '</td>'; }).join('') + '</tr>';
        });
        html += '</tbody></table><p class="more">' +
          (total === null ? 'Showing ' + rs.length + ' records; the total count was not available.'
                          : (rs.length < total ? 'The first ' + rs.length + ' of ' + show(total) + ' records.' : 'All ' + show(total) + ' records.')) +
          ' "Found by Axur" is the day the record reached Axur, which can be long after the event itself.</p>';
        box.innerHTML = html;
        var cnt = secs.querySelector('.cnt[data-cnt="' + i + '"]');
        if (cnt) cnt.innerHTML = '<b>' + show(total) + '</b> records &middot; ' + (total !== null && rs.length < total ? 'first ' + rs.length + ' shown' : 'all shown');
      } catch (e) {
        box.innerHTML = '<p class="more">These records could not be rendered (' + esc(e && e.message) + ').</p>';
      }
    });
    // The PDF step waits for this before printing.
    document.documentElement.setAttribute('data-report-ready', '1');
  }

  // This script sits above the payload, so the rows cannot be read until the
  // parser has finished the document.
  function kick(){ requestAnimationFrame(function(){ setTimeout(buildTables, 0); }); }
  // Screen: next frame, then a task, so the summary paints first. Not an idle
  // callback, which a headless or background tab can postpone indefinitely.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', kick);
  } else { kick(); }
  // Print and PDF: build synchronously, so nothing is captured half-empty.
  window.addEventListener('beforeprint', buildTables);
})();
</script>
HTMLTAIL

echo '<script type="application/json" id="payload">['
FIRST=1
for f in "$TMP"/*.json; do
  [ $FIRST -eq 1 ] || echo ','
  FIRST=0
  cat "$f"
done
echo ']</script>'

echo '</main></body></html>'
} > "$OUT"


echo ' done' >&2

# full path, so nobody has to guess which folder they were standing in
ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
echo "Wrote $ABS"

# Chrome or Edge can print the report without opening a window
CHROME=""
for C in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
         "$(command -v google-chrome 2>/dev/null)" \
         "$(command -v chromium 2>/dev/null)"; do
  [ -n "$C" ] && [ -x "$C" ] && CHROME="$C" && break
done

DONE=""
if [ "$NOPDF" = "1" ]; then
  DONE="$ABS"
elif [ -n "$CHROME" ]; then
  PDF="${ABS%.html}.pdf"
  printf 'Making the PDF'
  "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
            --virtual-time-budget=15000 --print-to-pdf="$PDF" \
            "file://$ABS" >/dev/null 2>&1
  if [ -s "$PDF" ]; then
    echo " ... wrote $PDF"
    DONE="$PDF"
  else
    echo " ... failed. Open the HTML and press Cmd+P."
    DONE="$ABS"
  fi
else
  echo "No Chrome or Edge found, so no PDF. Open the HTML and press Cmd+P."
  DONE="$ABS"
fi

# open it, so the run ends with the report on screen rather than a path to hunt for
if [ "$NOOPEN" = "1" ]; then
  echo "Open it with:  open \"$DONE\""
elif command -v open >/dev/null 2>&1; then
  open "$DONE"
else
  echo "Open it with:  open \"$DONE\""
fi
echo ""