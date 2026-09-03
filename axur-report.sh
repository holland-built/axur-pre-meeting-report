#!/bin/bash
# Axur pre-meeting report.
#
#   bash axur-report.sh
#   bash axur-report.sh --brand "BRAND" --domain customer.com --key YOUR_API_KEY
#
# Anything you leave off, it asks for.
#
#   --rows N          rows to pull behind each number (default 50)
#   --out FILE        output file (default axur-report-<domain>.html)
#   --no-pdf          write only the HTML
#   --no-open         do not open the report when it is done
#   --debug           show the raw replies

API="https://api.axur.com/gateway/1.0/api/threat-hunting-api/external"
BRAND=""; DOMAIN=""; KEY=""; ROWS=50; BFID=""; OUT=""; DEBUG=""; NOPDF=""; NOOPEN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --brand)      BRAND="$2"; shift 2 ;;
    --domain)     DOMAIN="$2"; shift 2 ;;
    --key)        KEY="$2"; shift 2 ;;
    --rows)       ROWS="$2"; shift 2 ;;
    --brandfetch) BFID="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --debug)      DEBUG=1; shift ;;
    --no-pdf)     NOPDF=1; shift ;;
    --no-open)    NOOPEN=1; shift ;;
    -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
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
  # splice the reply into the report and let the browser parse it
  {
    printf '{"name":"%s","query":"%s","total":%s,"reply":' \
      "$NAME" "$(printf '%s' "$QUERY" | sed 's/"/\\"/g')" "${TOTAL:-null}"
    # strip the password field before it ever reaches the report file
    printf '%s' "${OUTJ:-null}" | sed 's#</#<\\/#g; s/"password":"[^"]*"/"password":"[removed]"/g'
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
<title>Threat scan: $BRAND</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=optional" rel="stylesheet">
<style>
 :root{
   --ink:#171717;--body:#4d4d4d;--mute:#6a7078;--faint:#9aa1a8;--line:#e6e8ea;--soft:#fafafa;
   --dark:#23282d;--darker:#15181b;--tile:#1b1f23;--card:#e9ebec;
   --green:#12d15f;--teal:#39d3c3;--amber:#f5c518;--red:#ff5a52;
 }
 ::selection{background:#bff0e4;color:#0d1f1a}
 html{scrollbar-color:#c4c8cc #fff}
 ::-webkit-scrollbar{width:11px;height:11px}
 ::-webkit-scrollbar-track{background:var(--soft)}
 ::-webkit-scrollbar-thumb{background:#c4c8cc;border-radius:99px;border:3px solid var(--soft)}
 ::-webkit-scrollbar-thumb:hover{background:#a4a9ae}
 :focus-visible{outline:2px solid var(--teal);outline-offset:2px;border-radius:3px}
 a{text-underline-offset:3px}
 *{box-sizing:border-box}
 html,body{margin:0;padding:0}
 body{background:#fff;color:var(--ink);font-family:Inter,-apple-system,sans-serif;
      font-size:15px;line-height:1.5;-webkit-print-color-adjust:exact;print-color-adjust:exact}

 /* ---------- page one: the executive summary ---------- */
 .cover{background:linear-gradient(150deg,#3a4046 0%,#23282d 42%,#15181b 100%);
        color:#fff;padding:44px 40px 48px}
 .cover .top{display:flex;align-items:center;justify-content:space-between;margin-bottom:34px}
 .cover .top img.ib{height:34px;width:auto}
 .cover .top img.cust{height:46px;width:auto;max-width:170px;object-fit:contain;
        background:#fff;border-radius:8px;padding:6px}
 /* one logo source. When it fails the name is written out instead. */
 .cover .top .nm{display:none;font-size:21px;font-weight:600;letter-spacing:.4px}
 h1{font-size:33px;font-weight:600;letter-spacing:.5px;margin:0;text-transform:uppercase}
 .rule{height:3px;width:250px;margin:10px 0 20px;
       background:linear-gradient(90deg,var(--green),var(--teal))}
 .intro{max-width:74ch;font-size:14px;line-height:1.6;color:#d3d7db;margin:0 0 26px}

 .chips{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;
        background:rgba(255,255,255,.05);border-radius:10px;padding:14px;margin-bottom:22px}
 .chip{background:var(--tile);border-radius:8px;padding:14px 12px;text-align:center}
 .chip b{display:block;color:var(--teal);font-size:15px;font-weight:600;word-break:break-word}
 .chip span{display:block;color:#d3d7db;font-size:13px;margin-top:3px}
 .key{margin:0 0 16px;font-size:14px;line-height:1.6;color:#d3d7db}
 .key .r,.key .a{font-size:15px;margin-right:2px}

 .metric{display:flex;align-items:center;gap:18px;background:var(--card);color:var(--ink);
         border-radius:10px;padding:16px 18px;margin-bottom:14px}
 .metric .ico{flex:none;width:62px;height:62px;border-radius:50%;background:#fff;
              display:flex;align-items:center;justify-content:center}
 .metric .txt{flex:1;min-width:0}
 .metric h2{margin:0;font-size:16px;font-weight:700;letter-spacing:.3px;text-transform:uppercase}
 .metric p{margin:3px 0 0;font-size:14px;line-height:1.5;color:#414850;max-width:52ch}
 .metric .tiles{display:flex;gap:12px;flex:none}
 .tile{background:var(--tile);border-radius:8px;padding:12px 16px;text-align:center;min-width:104px;
       display:block;text-decoration:none;color:inherit}
 a.tile{transition:transform .12s ease-out,box-shadow .12s ease-out}
 a.tile:hover{transform:translateY(-2px);box-shadow:0 0 0 1.5px var(--teal)}
 a.tile:focus-visible{outline:2px solid var(--teal);outline-offset:3px}
 a.tile::after{content:"";display:block;height:2px;width:26px;margin:7px auto 0;border-radius:2px;
               background:var(--teal);opacity:.55}
 .tile b{display:block;font-size:27px;font-weight:700;line-height:1.1;font-variant-numeric:tabular-nums}
 .tile span{display:block;font-size:13px;color:#d3d7db;margin-top:3px}
 .g{color:var(--green)} .t{color:var(--teal)} .a{color:var(--amber)} .r{color:var(--red)}
 .tile small{display:block;font-size:12px;line-height:1.4;color:#aab1b8;margin-top:5px;
       max-width:112px}
 .metric .why{margin:6px 0 0;font-size:13px;line-height:1.5;color:#525a63;max-width:52ch}

 /* one door into the evidence, then a numbered trail through it */
 .enter{display:flex;align-items:center;gap:16px;margin-top:20px;padding:15px 18px;
        border:1px dashed #4a5157;border-radius:10px;color:#fff;text-decoration:none}
 .enter .lab{font-family:"JetBrains Mono",monospace;font-size:11px;letter-spacing:.14em;
             text-transform:uppercase;color:var(--teal)}
 .enter .say{flex:1;font-size:13.5px;font-weight:500}
 .enter .arr{font-size:18px;color:var(--teal)}

 .step{display:flex;align-items:center;gap:10px;margin-bottom:8px}
 .step .n{font-family:"JetBrains Mono",monospace;font-size:20px;font-weight:600}
 .step .of{font-family:"JetBrains Mono",monospace;font-size:11px;color:var(--mute)}
 .step .bar{flex:1;height:2px;background:var(--line);border-radius:2px;overflow:hidden}
 .step .bar i{display:block;height:2px;background:linear-gradient(90deg,var(--green),var(--teal))}
 .means{font-size:14px;line-height:1.55;color:var(--body);margin:0 0 9px;max-width:70ch}
 .trail{display:flex;justify-content:space-between;align-items:baseline;
        margin-top:12px;padding-top:9px;border-top:1px solid var(--line)}
 .trail a{font-size:13px;text-decoration:none}
 .trail .up{color:var(--mute)}
 .trail .next{color:var(--ink);font-weight:600}
 .metric.aside{background:transparent;color:#d3d7db;border:1px solid #3d444b;padding:14px 18px}
 .metric.aside .ico{background:rgba(255,255,255,.06)}
 .metric.aside h2{color:#fff}
 .metric.aside p{color:#c2c8ce}
 .metric.aside .why{color:#98a0a8}
 .cover .foot{margin-top:22px;font-size:13px;color:#aab1b8}

 /* ---------- the detail pages ---------- */
 .detail{padding:34px 40px 44px}
 .detail > h2{font-size:21px;font-weight:600;letter-spacing:-.4px;color:var(--ink);
              margin:0 0 6px}
 section{margin-bottom:30px}
 section h3{font-size:16px;font-weight:600;margin:0 0 2px;letter-spacing:-.2px}
 .q{font-family:"JetBrains Mono",monospace;font-size:12.5px;color:var(--body);
    margin:0 0 10px;word-break:break-all}
 table{width:100%;border-collapse:collapse;font-size:13px;table-layout:fixed}
 th{text-align:left;font-family:"JetBrains Mono",monospace;font-size:11px;letter-spacing:.09em;
    text-transform:uppercase;color:var(--mute);font-weight:500;padding:7px 8px;
    border-bottom:1.5px solid var(--ink);background:var(--soft);height:34px;box-sizing:border-box}
 /* One line per row on screen, so the space reserved for a table is the space it takes.
    Print undoes this, because a customer reading the PDF needs the whole value. */
 td{padding:7px 8px;border-bottom:1px solid var(--line);vertical-align:middle;
    height:34px;box-sizing:border-box;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 td:hover{overflow:visible;white-space:normal;word-break:break-word;position:relative;
          background:#fffbe6;z-index:1}
 tbody tr:nth-child(even) td{background:var(--soft)}
 .more{font-size:12.5px;color:var(--mute);margin-top:7px}
 .warn{margin-top:26px;background:#fff5f5;border:1px solid #f7d4d6;border-radius:8px;
        padding:13px 16px;font-size:12.5px;line-height:1.5;color:var(--body);
        display:grid;grid-template-columns:24px 1fr;gap:12px;align-items:start}
 .warn svg{width:20px;height:20px;display:block;margin-top:1px}
 .warn b{color:#a80000;font-size:13.5px;font-weight:600;display:block;margin-bottom:2px;
         letter-spacing:-.2px}
 footer{margin-top:26px;padding-top:12px;border-top:1px solid var(--line);font-size:12.5px;color:var(--mute)}

 /* The hover lift carries no meaning, so it goes rather than shortens. */
 @media (prefers-reduced-motion:reduce){
   *,*::before,*::after{transition:none!important;animation:none!important}
 }

 @media (max-width:760px){
   .cover{padding:28px 20px 34px}
   .chips{grid-template-columns:1fr}
   .metric{flex-direction:column;align-items:flex-start;gap:12px}
   .metric .tiles{width:100%;flex-wrap:wrap}
   .tile{flex:1 1 140px;min-width:0}
   .tile small{max-width:none}
   .detail{padding:24px 18px 30px}
   .cover .top img.cust{max-width:120px}
 }

 @media print{
   a.tile::after{display:none}
   @page{size:A4;margin:0}
   .cover{min-height:297mm;page-break-after:always}
   .detail{padding:14mm}
   section{break-inside:auto}
   thead{display:table-header-group}
   tr{break-inside:avoid}
   /* the reservation is a screen device; on paper the rows set their own height */
   .rowbox{min-height:0!important}
   td{white-space:normal;word-break:break-word;height:auto;vertical-align:top}
 }
</style></head><body>
<main>

<div class="cover" id="top">
  <div class="top">
    <div><img class="ib" src="$OURS" alt="Infoblox" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">Infoblox</span></div>
    <div><img class="cust" src="$LOGO" alt="$BRAND" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">$BRAND</span></div>
  </div>

  <h1>Executive summary</h1>
  <div class="rule"></div>
  <p class="intro">Infoblox looked for exposure tied to your brand and your domain across breach
    data, dark web sources and the public web. Below is what was visible on
    $(date '+%d %B %Y'), and what each number means.</p>

  <div class="chips">
    <div class="chip"><b>$BRAND</b><span>Brand name</span></div>
    <div class="chip"><b>$DOMAIN</b><span>Domain</span></div>
    <div class="chip"><b>$(date '+%d %b %Y')</b><span>Scan date</span></div>
  </div>

  <p class="key"><span class="r">&#9679;</span> Red is what somebody could use today.
    <span class="a">&#9679;</span> Amber is exposure that needs a further step first.</p>

  <div id="metrics"></div>

  <a class="enter" href="#s1">
    <span class="lab">Evidence</span>
    <span class="say">Step through the records behind every number, in order</span>
    <span class="arr">&darr;</span>
  </a>

  <p class="foot">Counts taken from one.axur.com. They move daily. Passwords are never included
    in this report.</p>
</div>

<div class="detail">
  <h2>The records behind the numbers</h2>
  <p class="means">Each page below shows a sample of the records counted on the summary,
    with the exact search that found them. The count is the whole set; the table is a sample.</p>
  <div id="sections"></div>
  <div class="warn">
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <rect x="4" y="10.5" width="16" height="10" rx="2.4" stroke="#d40000" stroke-width="1.7"/>
      <path d="M8 10.5V7.6a4 4 0 0 1 8 0v2.9" stroke="#d40000" stroke-width="1.7"
            stroke-linecap="round"/>
    </svg>
    <div><b>Passwords withheld</b>
      Axur stores leaked passwords in clear text. This report shows the account and the site it
      was used on, never the password itself.</div>
  </div>
  <footer>Attack surface is a separate download: one.axur.com/easm, Exposures, Download all.</footer>
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
  var ROWLIMIT = ROWSVALUE;
  var HIDE = /password|hash|datahubId|^id$/i;   // never print a leaked password
  var PREF = ['user','accessUrl','accessHost','sourceName','leakDisplayName',
              'domain','url','sourceUrl','riskScore','impersonatedBrandsHigh',
              'contentType','domainCreationDate','detectionDate','sourceDate'];
  // The summary reads a few hundred bytes of totals, so it paints at once.
  // The full replies are parsed later, in buildTables, because they run to megabytes.
  var totals = JSON.parse(document.getElementById('totals').textContent);
  var tot = {};
  totals.forEach(function(t){ tot[t.name] = t.total; });
  var data = null, by = null;
  function loadPayload(){
    if (data) return data;
    var el = document.getElementById('payload');
    if (!el) return [];
    data = JSON.parse(el.textContent);
    by = {};
    data.forEach(function(d){ by[d.name] = d; });
    return data;
  }
  function n(name){ var t = tot[name]; return (t === null || t === undefined) ? null : Number(t); }
  function show(v){ return v === null ? '&mdash;' : v.toLocaleString(); }

  var ICON = {
    lock: '<circle cx="17" cy="24" r="11" fill="none" stroke="#e05a52" stroke-width="2.4"/>' +
          '<rect x="10" y="17" width="24" height="15" rx="4" fill="#fff" stroke="#e05a52" stroke-width="2.4"/>' +
          '<circle cx="17" cy="24.5" r="1.8" fill="#e05a52"/><circle cx="22" cy="24.5" r="1.8" fill="#e05a52"/>' +
          '<circle cx="27" cy="24.5" r="1.8" fill="#e05a52"/>',
    mask: '<circle cx="22" cy="14" r="6" fill="#3a3f45"/>' +
          '<path d="M10 34c0-6.6 5.4-11 12-11s12 4.4 12 11" fill="#3a3f45"/>',
    site: '<rect x="7" y="11" width="30" height="22" rx="3" fill="none" stroke="#3a3f45" stroke-width="2.4"/>' +
          '<path d="M7 18h30" stroke="#3a3f45" stroke-width="2.4"/>' +
          '<path d="M22 22v6" stroke="#e05a52" stroke-width="2.6" stroke-linecap="round"/>' +
          '<circle cx="22" cy="31" r="1.4" fill="#e05a52"/>',
    risk: '<path d="M22 8 38 34H6z" fill="none" stroke="#e05a52" stroke-width="2.6" stroke-linejoin="round"/>' +
          '<path d="M18 20l8 8M26 20l-8 8" stroke="#e05a52" stroke-width="2.4" stroke-linecap="round"/>'
  };

  var ROWS = [
    { icon:'lock', title:'Exposed credentials', anchor:'s1',
      desc:'Work accounts on this domain whose passwords have already been exposed somewhere outside your company.',
      why:'They come from three places: company breaches, dumps traded on criminal forums, and staff or customer computers infected with password-stealing malware.',
      tiles:[ {v:n('Leaked credentials'), l:'Total', c:'a', go:'s1',
               note:'Every exposed account we can see.'},
              {v:n('In plaintext'),       l:'In readable form', c:'r', go:'s2',
               note:'The password itself is readable, so anyone holding it can try to log in today.'} ] },
    { icon:'mask', title:'Impersonation sites', anchor:'s3',
      desc:'Web pages built to look like you, so a customer or an employee hands over a login or a card number.',
      why:'Only pages Axur is highly confident are impersonating this brand are counted. Pages that only mention the name are left out.',
      tiles:[ {v:n('Phishing pages'), l:'Sites', c:'r', go:'s3',
               note:'Pages seen impersonating the brand.'} ] },
    { icon:'site', title:'Lookalike domains', anchor:'s4',
      desc:'Domain names one character away from yours, such as a swapped or doubled letter. They exist to be mistaken for you.',
      why:'A lookalike is only a nuisance until someone sets up email on it. At that point it can send a message that appears to come from your company.',
      tiles:[ {v:n('Lookalike domains'), l:'Registered', c:'a', go:'s4',
               note:'Lookalike names somebody has bought.'},
              {v:n('Mail-enabled lookalikes'), l:'Mail-enabled', c:'r', go:'s5',
               note:'Of those, the ones with email already switched on. These can send a convincing fake today.'} ] },
    { icon:'risk', title:'External attack surface', anchor:null, aside:true,
      desc:'The servers, services and open doors reachable from the public internet under your name.',
      why:'Not counted here. It comes from a different screen: one.axur.com/easm, Exposures, then Download all.',
      tiles:[] }
  ];

  var m = document.getElementById('metrics');
  m.innerHTML = ROWS.map(function(r){
    return '<div class="metric' + (r.aside ? ' aside' : '') + '">' +
      '<div class="ico"><svg width="44" height="44" viewBox="0 0 44 44">' + ICON[r.icon] + '</svg></div>' +
      '<div class="txt"><h2>' + r.title + '</h2><p>' + r.desc + '</p>' +
        '<p class="why">' + r.why + '</p></div>' +
      (r.tiles.length ? '<div class="tiles">' + r.tiles.map(function(t){
        // the note under each number, so nobody has to guess what the label means
        var tag = t.go ? 'a' : 'div', href = t.go ? ' href="#' + t.go + '"' : '';
        return '<' + tag + ' class="tile"' + href + '><b class="' + t.c + '">' + show(t.v) +
               '</b><span>' + t.l + '</span><small>' + t.note + '</small></' + tag + '>';
      }).join('') + '</div>' : '') + '</div>';
  }).join('');

  // ---- the detail tables ----
  function rows(d){
    var r = d.reply && d.reply.result && d.reply.result.data;
    return Array.isArray(r) ? r : [];
  }
  function cols(rs){
    var seen = {};
    rs.slice(0, 20).forEach(function(r){ Object.keys(r).forEach(function(k){ seen[k] = 1; }); });
    var all = Object.keys(seen).filter(function(k){ return !HIDE.test(k); });
    var out = PREF.filter(function(k){ return all.indexOf(k) > -1; });
    all.forEach(function(k){ if (out.indexOf(k) < 0 && out.length < 5) out.push(k); });
    return out.slice(0, 5);
  }
  function label(k){
    return k.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/^./, function(c){ return c.toUpperCase(); });
  }
  function fmt(v){
    if (v === null || v === undefined) return '';
    if (typeof v === 'number' && v > 1000000000000) return new Date(v).toISOString().slice(0,10);
    if (typeof v === 'object') return JSON.stringify(v).slice(0, 80);
    return String(v).slice(0, 120);
  }

  // what each table is actually showing, in plain words
  var MEANS = {
    'Leaked credentials':
      'One row per exposed account. The source column names where it turned up. An account can appear more than once if it leaked more than once.',
    'In plaintext':
      'The subset of the rows above where the password was stored in readable form. These are the ones to reset first. The password itself is withheld from this report.',
    'Phishing pages':
      'Pages Axur is highly confident are impersonating this brand. Some will already be offline; the date shows when each was seen.',
    'Lookalike domains':
      'Domain names one character away from yours that somebody has registered. Registration alone is not proof of intent, but it is the first step in most of these attacks.',
    'Mail-enabled lookalikes':
      'The lookalike domains that already have working mail records. Somebody can send email from them that appears to come from your company, today, with no further setup.'
  };

  // the summary and the detail must call the same thing by the same name
  var TITLES = { 'Leaked credentials':'Exposed credentials',
                 'In plaintext':'Passwords in readable form',
                 'Phishing pages':'Impersonation sites' };
  function heading(name){ return TITLES[name] || name; }

  var secs = document.getElementById('sections');
  var TOTAL = totals.length;
  var ROWH = 34;   // one row is one line: .rowbox td never wraps on screen

  // ---- phase one, synchronous: the shell of every section, with its space reserved ----
  // Reserving the height here is what stops the page jumping when the rows land.
  totals.forEach(function(t, i){
    var s = document.createElement('section');
    s.id = 's' + (i + 1);

    var step = '<div class="step"><span class="n">' + ('0' + (i + 1)).slice(-2) + '</span>' +
               '<span class="of">of ' + ('0' + TOTAL).slice(-2) + '</span>' +
               '<span class="bar"><i style="width:' +
                 Math.round((i + 1) / TOTAL * 100) + '%"></i></span></div>';
    var head = step + '<h3>' + heading(t.name) + '</h3>' +
               (MEANS[t.name] ? '<p class="means">' + MEANS[t.name] + '</p>' : '') +
               '<p class="q">' + t.query + '</p>';

    // both directions live in the footer, so no floating button is needed and
    // nothing turns into dead chrome in the PDF
    var trail = '<div class="trail"><a class="up" href="#top">&uarr; Back to the summary</a>' +
      (i + 1 < TOTAL
        ? '<a class="next" href="#s' + (i + 2) + '">' + ('0' + (i + 2)).slice(-2) +
          ' &middot; ' + heading(totals[i + 1].name) + ' &rarr;</a>'
        : '<a class="next" href="#top">Back to the summary &uarr;</a>') + '</div>';

    var expect = t.total === null ? 0 : Math.min(ROWLIMIT, Number(t.total));
    var reserve = expect ? (expect + 1) * ROWH + 26 : 0;

    s.innerHTML = head +
      '<div class="rowbox" data-i="' + i + '"' +
      (reserve ? ' style="min-height:' + reserve + 'px"' : '') + '></div>' + trail;
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
      var d = d8[Number(box.getAttribute('data-i'))];
      if (!d) return;
      var rs = rows(d).slice(0, ROWLIMIT);
      if (!rs.length) { box.innerHTML = '<p class="more">No rows returned.</p>'; return; }
      var cs = cols(rs);
      var html = '<table><thead><tr>' +
        cs.map(function(c){ return '<th>' + label(c) + '</th>'; }).join('') + '</tr></thead><tbody>';
      rs.forEach(function(r){
        html += '<tr>' + cs.map(function(c){ return '<td>' + fmt(r[c]) + '</td>'; }).join('') + '</tr>';
      });
      html += '</tbody></table><p class="more">Showing ' + rs.length +
              ' of ' + (d.total === null ? '?' : Number(d.total).toLocaleString()) + '.</p>';
      box.innerHTML = html;
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