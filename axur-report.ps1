<#
  Axur pre-meeting report.

    powershell -ExecutionPolicy Bypass -File axur-report.ps1
    powershell -ExecutionPolicy Bypass -File axur-report.ps1 -Brand "BRAND" -Domain customer.com -ApiKey YOUR_KEY

  Anything you leave off, it asks for.

    -Rows N         rows listed under each count (default 50)
    -MinScore N     drop rows scoring below N (lookalike and phishing only)
    -Exclude LIST   drop rows matching these, comma separated. ".au,known.com"
    -ExcludeFile F  same, read from a file or CSV. One per line, first column,
                    # starts a comment
    -Out FILE       output file (default axur-report-<domain>.html)
    -NoPdf          write only the HTML
    -NoOpen         do not open the report when it is done
    -ShowRaw        show the raw replies

  This file is generated from axur-report.sh by build-ps1.py. Edit the HTML
  there, not here, then re-run the generator.
#>
param(
  [string]$Brand, [string]$Domain, [string]$ApiKey,
  [int]$Rows = 50, [string]$MinScore, [string]$Exclude, [string]$ExcludeFile, [string]$Out,
  [switch]$NoPdf, [switch]$NoOpen, [switch]$ShowRaw
)

$ErrorActionPreference = 'Stop'
$api = "https://api.axur.com/gateway/1.0/api/threat-hunting-api/external"
$PageCap = 40

function Ask($current, $prompt, $hidden) {
  if ($current) { return $current }
  if ($hidden) {
    $s = Read-Host -Prompt $prompt -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto(
      [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
  }
  return Read-Host -Prompt $prompt
}

$Brand  = Ask $Brand  "Brand, as Axur spells it" $false
$Domain = Ask $Domain "Customer domain" $false
$ApiKey = Ask $ApiKey "Axur API key" $true

$Domain = ($Domain -replace '^[a-z]+://', '' -replace '^www\.', '').Split('/')[0].ToLower()
# the fuzzy searches match a domain label, not a brand name
$parts = $Domain.Split('.') | Where-Object { $_ }
if ($parts.Count -gt 2) { $parts = $parts[-3..-1] }
$label = $parts[0]
if (-not $Out) { $Out = "axur-report-$Domain.html" }

$headers = @{ Authorization = "Bearer $ApiKey" }

# Brandfetch serves a real logo to a request carrying a Referer. Baking it in as
# a data URI means it survives the PDF, an offline mailbox, and blocked images.
function Get-Logo($url) {
  try {
    $r = Invoke-WebRequest -Uri $url -Headers @{
      Referer = "https://one.axur.com/"
      "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
    } -TimeoutSec 12
    $ct = $r.Headers['Content-Type']; if ($ct -is [array]) { $ct = $ct[0] }
    if ($ct -notlike 'image/*') { return "" }
    return "data:$(($ct -split ';')[0]);base64,$([Convert]::ToBase64String($r.Content))"
  } catch { return "" }
}
Write-Host -NoNewline "Logo"
$logo = Get-Logo "https://cdn.brandfetch.io/$Domain/w/400/h/400"
$ours = Get-Logo "https://cdn.brandfetch.io/infoblox.com/w/400/h/400"
if ($logo) { Write-Host " ... got $Brand" } else {
  Write-Host " ... none for $Domain, the name will be written instead"
  $logo = "https://cdn.brandfetch.io/$Domain/w/400/h/400"
}
if (-not $ours) { $ours = "https://cdn.brandfetch.io/infoblox.com/w/400/h/400" }

$filtered = @("Phishing pages", "Lookalike domains", "Mail-enabled lookalikes")
$patterns = @($Exclude -split '\s*,\s*' | Where-Object { $_ })

# A customer's own domains run to dozens, so take them from a file as well as
# the command line. One per line, or the first column of a CSV. A "domain"
# header row is skipped, so a sheet exported straight from Excel works.
if ($ExcludeFile) {
  if (-not (Test-Path $ExcludeFile)) { Write-Error "Cannot read $ExcludeFile"; exit 1 }
  $fromFile = Get-Content $ExcludeFile | ForEach-Object {
    ($_ -replace '#.*', '').Split(',')[0].Trim().Trim('"').Trim("'")
  } | Where-Object { $_ -and $_ -notmatch '^(?i)domains?$' }
  $patterns += $fromFile
  Write-Host "Excluding $($patterns.Count) patterns from $ExcludeFile"
}
$anyFilter = ($MinScore -or $patterns.Count)
$partial = @()

# Keep a row unless the score is below the floor or a pattern matches its
# domain or url. A credential has neither, so only the three domain searches
# are ever filtered.
function Test-Keep($row) {
  if ($MinScore) {
    $sc = $row.riskScore
    if ($null -ne $sc -and [double]$sc -lt [double]$MinScore) { return $false }
  }
  foreach ($p in $patterns) {
    foreach ($f in @('domain', 'url', 'sourceUrl', 'accessHost')) {
      $v = $row.$f
      if ($v -and ([string]$v).ToLower().Contains($p.ToLower())) { return $false }
    }
  }
  return $true
}

function Invoke-Search($name, $source, $query) {
  Write-Host -NoNewline ("{0,-26}" -f $name)
  $body = @{ query = $query; source = $source } | ConvertTo-Json -Compress
  $start = $null; $attempt = 0
  while ($true) {
    try {
      $start = Invoke-RestMethod -Method Post -Uri "$api/search" -Headers $headers `
               -ContentType "application/json" -Body $body
      break
    } catch {
      $c = $null
      if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }
      # the gateway allows 30 calls a window, so wait it out rather than failing
      if ($c -eq 429 -and $attempt -lt 3) { $attempt++; Write-Host -NoNewline "w"; Start-Sleep -Seconds 25; continue }
      switch ($c) {
        401 { Write-Host " key rejected (401). Generate a new one in My preferences." }
        403 { Write-Host " no access to this tenant (403)" }
        429 { Write-Host " still rate limited after waiting. Try again in a minute." }
        default { Write-Host " could not start (HTTP $c)" }
      }
      return [pscustomobject]@{ name = $name; query = $query; total = $null; raw = '{"result":{"data":[]}}' }
    }
  }
  $id = $start.searchId
  $total = $null; $raw = $null
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 2; Write-Host -NoNewline "."
    try { $r = Invoke-WebRequest -Uri "$api/search/${id}?page=1&alias=true" -Headers $headers } catch { continue }
    $raw = $r.Content
    $o = $raw | ConvertFrom-Json
    $total = $o.result.status.totalResults
    if ($null -ne $total) { break }
  }
  if ($null -eq $total) { Write-Host " timed out" } else { Write-Host -NoNewline " $total" }
  if ($ShowRaw) { Write-Host ""; Write-Host "  $raw" }

  $doc = if ($raw) { $raw | ConvertFrom-Json } else { $null }
  $rows = @(); if ($doc) { $rows = @($doc.result.data) }

  # A filtered number is only honest if it was counted over every row, so when a
  # filter is on we walk the pages. The API ignores page-size parameters, so
  # page= is the only lever. Same first row twice means paging is unsupported.
  if ($anyFilter -and $filtered -contains $name -and $null -ne $total) {
    $firstKey = if ($rows.Count) { ($rows[0] | ConvertTo-Json -Compress) } else { "" }
    $p = 2
    while ($p -le $PageCap) {
      try { $pg = (Invoke-WebRequest -Uri "$api/search/${id}?page=$p&alias=true" -Headers $headers).Content }
      catch { break }
      $pd = $pg | ConvertFrom-Json
      $pr = @($pd.result.data)
      if (-not $pr.Count) { break }
      if (($pr[0] | ConvertTo-Json -Compress) -eq $firstKey) { break }
      $rows += $pr; Write-Host -NoNewline "+"
      $p++
    }
    if ($p -gt $PageCap) { $script:partial += $name }
  }

  if ($anyFilter -and $filtered -contains $name -and $rows.Count) {
    $kept = @($rows | Where-Object { Test-Keep $_ })
    Write-Host " -> $($kept.Count) after filters"
    $rows = $kept
    $total = $kept.Count   # the tile and the table below it must agree
  } else { Write-Host "" }

  # never let a leaked password reach the report file
  foreach ($r in $rows) {
    foreach ($f in @('password', 'hash')) { if ($null -ne $r.$f) { $r.$f = '[removed]' } }
  }
  $keep = @($rows | Select-Object -First $Rows)
  $reply = @{ result = @{ status = @{ totalResults = $total }; data = $keep } }
  [pscustomobject]@{
    name = $name; query = $query; total = $total
    raw = ($reply | ConvertTo-Json -Depth 12 -Compress)
  }
}

Write-Host ""
Write-Host "Axur pre-meeting report: $Brand"
Write-Host "-------------------------------------------"
$results = @(
  (Invoke-Search "Leaked credentials"       "credential"  "emailDomain=`"$Domain`""),
  (Invoke-Search "In plaintext"             "credential"  "emailDomain=`"$Domain`" AND passwordType=`"PLAIN`""),
  (Invoke-Search "Phishing pages"           "signal-lake" "impersonatedBrandsHigh=`"$Brand`""),
  (Invoke-Search "Lookalike domains"        "signal-lake" "sanitizedDomainLabel=$label~1"),
  (Invoke-Search "Mail-enabled lookalikes"  "signal-lake" "domainLabel=$label~1 AND dnsRecordMX=*")
)
Write-Host "-------------------------------------------"

$head = @'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Threat scan: {{BRAND}}</title>
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
    <div><img class="ib" src="{{OURS}}" alt="Infoblox" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">Infoblox</span></div>
    <div><img class="cust" src="{{LOGO}}" alt="{{BRAND}}" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">{{BRAND}}</span></div>
  </div>

  <h1>Executive summary</h1>
  <div class="rule"></div>
  <p class="intro">Infoblox looked for exposure tied to your brand and your domain across breach
    data, dark web sources and the public web. Below is what was visible on
    $(date '+%d %B %Y'), and what each number means.</p>

  <div class="chips">
    <div class="chip"><b>{{BRAND}}</b><span>Brand name</span></div>
    <div class="chip"><b>{{DOMAIN}}</b><span>Domain</span></div>
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
'@
$tail = @'
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
'@

$head = $head.Replace('{{BRAND}}', $Brand).Replace('{{DOMAIN}}', $Domain).
              Replace('{{LOGO}}', $logo).Replace('{{OURS}}', $ours)
$tail = $tail.Replace('ROWSVALUE', "$Rows")

function Esc($s) { ($s -replace '\\', '\\' -replace '"', '\"') }

$totals = ($results | ForEach-Object {
  '{"name":"' + (Esc $_.name) + '","query":"' + (Esc $_.query) + '","total":' +
  $(if ($null -eq $_.total) { 'null' } else { "$($_.total)" }) + '}'
}) -join ",`n"

$payload = ($results | ForEach-Object {
  '{"name":"' + (Esc $_.name) + '","query":"' + (Esc $_.query) + '","total":' +
  $(if ($null -eq $_.total) { 'null' } else { "$($_.total)" }) + ',"reply":' +
  ($_.raw -replace '</', '<\/') + '}'
}) -join ",`n"

Write-Host -NoNewline "Writing the report "
$doc = $head + "`n" +
       '<script type="application/json" id="totals">[' + "`n" + $totals + "`n" + ']</script>' + "`n" +
       $tail + "`n" +
       '<script type="application/json" id="payload">[' + "`n" + $payload + "`n" + ']</script>' + "`n" +
       '</main></body></html>'
[IO.File]::WriteAllText($Out, $doc, (New-Object Text.UTF8Encoding $false))
$abs = (Resolve-Path $Out).Path
Write-Host "done"
Write-Host "Wrote $abs"
if ($partial.Count) {
  Write-Host "Note: hit the page cap on $($partial -join ', '). Those counts came from a partial pull."
}

# Edge ships with Windows and prints without opening a window
$done = $abs
if (-not $NoPdf) {
  $browser = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($browser) {
    $pdf = [IO.Path]::ChangeExtension($abs, '.pdf')
    Write-Host -NoNewline "Making the PDF"
    & $browser --headless --disable-gpu --no-pdf-header-footer `
               --virtual-time-budget=15000 "--print-to-pdf=$pdf" "file:///$($abs -replace '\\','/')" 2>$null | Out-Null
    if (Test-Path $pdf) { Write-Host " ... wrote $pdf"; $done = $pdf }
    else { Write-Host " ... failed. Open the HTML and press Ctrl+P." }
  } else {
    Write-Host "No Edge or Chrome found, so no PDF. Open the HTML and press Ctrl+P."
  }
}

if ($NoOpen) { Write-Host "Open it with:  Invoke-Item `"$done`"" } else { Invoke-Item $done }
Write-Host ""
