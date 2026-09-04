<#
  Axur pre-meeting report.

    powershell -ExecutionPolicy Bypass -File axur-report.ps1
    powershell -ExecutionPolicy Bypass -File axur-report.ps1 -Brand "BRAND" -Domain customer.com -ApiKey YOUR_KEY

  Anything you leave off, it asks for.

    -Config FILE    read customer settings from FILE. Command-line flags win
    -SaveConfig F   save this run's customer settings to F (never the API key)
    -Rows N         rows listed under each count (default 50)
    -Wait SECONDS   how long to let each search finish (default 300)
    -MinScore N     drop rows scoring below N (lookalike and phishing only)
    -Exclude LIST   drop rows matching these, comma separated. ".au,known.com"
    -ExcludeFile F  same, read from a file or CSV. One per line, first column,
                    # starts a comment
    -Logo SRC       use this for the customer logo instead of looking it up.
                    A file on disk, or a URL
    -NoLogo         do not look up any logo. The names are written instead
    -Out FILE       output file (default axur-report-<domain>.html)
    -NoPdf          write only the HTML
    -NoOpen         do not open the report when it is done
    -ShowRaw        show the raw replies

  This file is generated from axur-report.sh by tools/build.py. Edit the HTML
  there, not here, then re-run the generator.
#>
param(
  [string]$Brand, [string]$Domain, [string]$ApiKey, [string]$Config, [string]$SaveConfig,
  [int]$Rows = 50, [int]$Wait = 300, [string]$MinScore, [string]$Exclude, [string]$ExcludeFile, [string]$Out,
  [string]$Logo, [switch]$NoLogo, [switch]$NoPdf, [switch]$NoOpen, [switch]$ShowRaw
)

$ErrorActionPreference = 'Stop'
$api = "https://api.axur.com/gateway/1.0/api/threat-hunting-api/external"
$PageCap = 40

# The cover writes the brand, the domain and the logo sources into HTML
# attributes. A quote in any of them closes the attribute early and the rest of
# the value becomes markup, so a brand of  Larkspur" onload="...  lands as a live
# event handler in the customer's report. -Config is read without validation, so
# escape here. The searches and the console keep the value as it was given.
function ConvertTo-HtmlText($text) {
  if ($null -eq $text) { return '' }
  return ([string]$text).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Expand-UserPath($path) {
  if (-not $path) { return $path }
  if ($path -eq '~') { return [Environment]::GetFolderPath('UserProfile') }
  if ($path.StartsWith('~/') -or $path.StartsWith('~\')) {
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) $path.Substring(2)
  }
  return $path
}

# Load the config first, but only fill parameters that were not supplied on the
# command line. The API key is deliberately not a recognized config key.
if ($Config) {
  $Config = Expand-UserPath $Config
  if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    Write-Host "Config file not found or not readable: $Config"
    exit 1
  }
  $lineNumber = 0
  foreach ($line in Get-Content -LiteralPath $Config) {
    $lineNumber++
    $text = $line.Trim()
    if (-not $text -or $text.StartsWith('#')) { continue }
    if ($text -notmatch '^([^=]+?)\s*=\s*(.*)$') {
      Write-Host "Warning: ignoring config line $lineNumber without '=' in $Config"
      continue
    }
    $name = $matches[1].Trim(); $value = $matches[2].Trim()
    switch -CaseSensitive ($name) {
      'brand'        { if (-not $PSBoundParameters.ContainsKey('Brand'))       { $Brand = $value } }
      'domain'       { if (-not $PSBoundParameters.ContainsKey('Domain'))      { $Domain = $value } }
      'logo'         { if (-not $PSBoundParameters.ContainsKey('Logo'))        { $Logo = Expand-UserPath $value } }
      'min-score'    { if (-not $PSBoundParameters.ContainsKey('MinScore'))    { $MinScore = $value } }
      'exclude-file' { if (-not $PSBoundParameters.ContainsKey('ExcludeFile')) { $ExcludeFile = Expand-UserPath $value } }
      'rows'         {
        if (-not $PSBoundParameters.ContainsKey('Rows')) {
          $parsedRows = 0
          if (-not [int]::TryParse($value, [ref]$parsedRows)) {
            Write-Host "Rows in config must be a number, not '$value'."; exit 1
          }
          $Rows = $parsedRows
        }
      }
      default { Write-Host "Warning: unknown config key '$name' in $Config; ignoring it" }
    }
  }
}

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

if ($SaveConfig) {
  $SaveConfig = Expand-UserPath $SaveConfig
  $settings = @(
    "brand        = $Brand"
    "domain       = $Domain"
    "logo         = $Logo"
    "min-score    = $MinScore"
    "exclude-file = $ExcludeFile"
    "rows         = $Rows"
  )
  try { Set-Content -LiteralPath $SaveConfig -Value $settings -Encoding UTF8 }
  catch { Write-Host "Could not write config file: $SaveConfig"; exit 1 }
  Write-Host "Saved config: $SaveConfig"
}

$headers = @{ Authorization = "Bearer $ApiKey" }

# Brandfetch serves a real logo to a request carrying a Referer. Baking it in as
# a data URI means it survives the PDF, an offline mailbox, and blocked images.
function Get-Logo($url) {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{
      Referer = "https://one.axur.com/"
      "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
    } -TimeoutSec 12
    $ct = $r.Headers['Content-Type']; if ($ct -is [array]) { $ct = $ct[0] }
    if ($ct -notlike 'image/*') { return "" }
    return "data:$(($ct -split ';')[0]);base64,$([Convert]::ToBase64String($r.Content))"
  } catch { return "" }
}
# -Logo takes a file as readily as a URL, because an SE who has the customer's
# logo to hand should not have to put it on the web to use it.
function Read-Logo($path) {
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  $ext = [IO.Path]::GetExtension($path).ToLower()
  $type = @{ ".png"="image/png"; ".jpg"="image/jpeg"; ".jpeg"="image/jpeg";
             ".gif"="image/gif"; ".webp"="image/webp"; ".svg"="image/svg+xml" }[$ext]
  if (-not $type) { Write-Host "  $path is not an image I know ($ext), ignoring it"; return "" }
  return "data:$type;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
}

Write-Host -NoNewline "Logo"
# PowerShell variable names are case-insensitive, so a local named $logo would
# erase the $Logo parameter before anything reads it.
$custData = ""; $oursData = ""
if ($NoLogo) {
  Write-Host " ... skipped, the names will be written instead"
} else {
  if ($Logo -and (Test-Path -LiteralPath $Logo)) { $custData = Read-Logo $Logo }
  elseif ($Logo)                                 { $custData = Get-Logo $Logo }
  else { $custData = Get-Logo "https://cdn.brandfetch.io/$Domain/w/400/h/400" }
  $oursData = Get-Logo "https://cdn.brandfetch.io/infoblox.com/w/400/h/400"
  if ($custData) { Write-Host " ... got $Brand" }
  elseif ($Logo) { Write-Host " ... could not read $Logo, the name will be written instead" }
  else { Write-Host " ... none for $Domain, the name will be written instead" }
}

$filtered = @("Phishing pages", "Lookalike domains", "Mail-enabled lookalikes")
# lowercased once here, because Test-Keep compares them against every field of
# every row and $p.ToLower() inside that loop redid the work thousands of times
$patterns = @($Exclude -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })

# A customer's own domains run to dozens, so take them from a file as well as
# the command line. One per line, or the first column of a CSV. A "domain"
# header row is skipped, so a sheet exported straight from Excel works.
if ($ExcludeFile) {
  if (-not (Test-Path $ExcludeFile)) { Write-Error "Cannot read $ExcludeFile"; exit 1 }
  $fromFile = Get-Content $ExcludeFile | ForEach-Object {
    ($_ -replace '#.*', '').Split(',')[0].Trim().Trim('"').Trim("'")
  } | Where-Object { $_ -and $_ -notmatch '^(?i)domains?$' }
  $patterns += @($fromFile | ForEach-Object { $_.ToLower() })
  Write-Host "Excluding $($patterns.Count) patterns from $ExcludeFile"
}
$anyFilter = ($MinScore -or $patterns.Count)
$partial = @(); $incomplete = @()

# Keep a row unless the score is below the floor or a pattern matches its
# domain or url. A credential has neither, so only the three domain searches
# are ever filtered.
function Test-Keep($row) {
  if ($MinScore) {
    $sc = $row.riskScore
    # a score of "N/A", or an object, must not take the report down
    $n = 0.0
    if ($null -ne $sc -and [double]::TryParse([string]$sc, [ref]$n)) {
      if ($n -lt [double]$MinScore) { return $false }
    }
  }
  # Match a pattern anywhere in a field that names a site. This list is lifted
  # from axur-report.sh by the builder; edit it there. Read each field once, not
  # once per pattern: the value does not change between patterns.
  foreach ($f in @('domain', 'url', 'sourceUrl', 'accessHost', 'reference', 'renderedReference', 'host', 'accessUrl')) {
    $v = $row.$f
    if (-not $v) { continue }
    $lower = ([string]$v).ToLower()
    foreach ($p in $patterns) {
      if ($lower.Contains($p)) { return $false }
    }
  }
  return $true
}

# Axur runs a search on its own side once started, so the five overlap if they
# are all started first. Waiting for them one at a time cost the sum of five
# waits; starting them together costs about the longest one.
function Start-Search($name, $source, $query) {
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
      if ($c -eq 429 -and $attempt -lt 3) {
        $attempt++
        Write-Host "    rate limited; retrying $name after 25 seconds"
        Start-Sleep -Seconds 25
        continue
      }
      Write-Host -NoNewline ("{0,-26}" -f $name)
      switch ($c) {
        401 { Write-Host " key rejected (401). Generate a new one in My preferences." }
        403 { Write-Host " no access to this tenant (403)" }
        429 { Write-Host " still rate limited after waiting. Try again in a minute." }
        default { Write-Host " could not start (HTTP $c)" }
      }
      return [pscustomobject]@{ name = $name; query = $query; id = $null }
    }
  }
  Write-Host ("  {0,-26} started" -f $name)
  return [pscustomobject]@{ name = $name; query = $query; id = $start.searchId }
}

function Complete-Search($job) {
  $name = $job.name; $query = $job.query; $id = $job.id
  if (-not $id) {
    return [pscustomobject]@{ name = $name; query = $query; total = $null; raw = '{"result":{"data":[]}}' }
  }
  # Axur answers with a total long before it has finished searching: the reply
  # carries running=true and a totalResults still climbing. Taking the first
  # number reports a fraction as if it were the whole.
  $total = $null; $raw = $null; $running = $true
  # At least one attempt. [int]($Wait / 2) is 0 for -Wait 1, so the loop never
  # ran, no reply was ever read, and every search reported "timed out".
  $tries = [Math]::Max(1, [int]($Wait / 2))
  for ($i = 0; $i -lt $tries; $i++) {
    Start-Sleep -Seconds 2
    try { $r = Invoke-WebRequest -UseBasicParsing -Uri "$api/search/${id}?page=1&alias=true" -Headers $headers } catch { continue }
    $raw = $r.Content
    $o = $raw | ConvertFrom-Json
    $total = $o.result.status.totalResults
    $running = [bool]$o.result.status.running
    if (-not $running -and $null -ne $total) { break }
  }
  if ($null -eq $total) { Write-Host ("  {0,-26} timed out" -f $name) }
  elseif ($running) {
    Write-Host ("  {0,-26} at least $total (still searching after ${Wait}s)" -f $name)
    $script:incomplete += $name
  }
  else { Write-Host ("  {0,-26} done: $total" -f $name) }
  if ($ShowRaw) { Write-Host "  $raw" }

  $doc = if ($raw) { $raw | ConvertFrom-Json } else { $null }
  # $found, not $rows: PowerShell variable names are case-insensitive, so a
  # local $rows IS the -Rows parameter. Filling it with the result rows left
  # Select-Object -First holding an array, and the run died on the first search
  # with "Cannot convert 'System.Object[]' to the type 'System.Int32'".
  $found = @(); if ($doc) { $found = @($doc.result.data) }

  # A filtered number is only honest if it was counted over every row, so when a
  # filter is on we walk the pages. The API ignores page-size parameters, so
  # page= is the only lever. The same page twice means paging is unsupported.
  if ($anyFilter -and $filtered -contains $name -and $null -ne $total) {
    # Compare each page with the one before it, not with page one. An API that
    # clamps an out-of-range page to the last page repeats those rows for every
    # page past the end, and matching page one only let the walk run to the cap
    # and count 37 copies of the last page.
    # The reply as it arrived is the page key. Serialising the parsed rows back
    # to JSON to compare them re-did, for every one of up to 40 pages, the most
    # expensive work in the loop; the raw text answers the same question.
    $prevKey = $raw
    # The walk runs one page past the cap. Stopping at the cap and running out
    # of pages look the same from inside the loop, so a result of exactly
    # PageCap pages used to report itself truncated. Asking for one more page
    # settles it, and asking inside the loop means the fetch and the freshness
    # test are written once rather than twice.
    $p = 2
    while ($p -le $PageCap + 1) {
      try { $pg = (Invoke-WebRequest -UseBasicParsing -Uri "$api/search/${id}?page=$p&alias=true" -Headers $headers).Content }
      catch { break }
      $pr = @(($pg | ConvertFrom-Json).result.data)
      if (-not $pr.Count) { break }
      if ($pg -eq $prevKey) { break }
      # a real page beyond the cap is the one thing that means "there was more"
      if ($p -gt $PageCap) { $script:partial += $name; break }
      $prevKey = $pg
      $found += $pr
      $p++
    }
  }

  if ($anyFilter -and $filtered -contains $name -and $found.Count) {
    $kept = @($found | Where-Object { Test-Keep $_ })
    Write-Host ("  {0,-26} filtered count: $($kept.Count)" -f $name)
    $found = $kept
    $total = $kept.Count   # the tile and the table below it must agree
  }

  # never let a leaked password reach the report file
  # Any field whose NAME carries password or hash goes, whatever its type: the
  # hashes, the length and the passwordHas* flags together are a recipe for
  # guessing the password this report says it does not include. passwordType is
  # kept, because PLAIN vs HASH is the point of one of the five searches.
  foreach ($r in $found) {
    foreach ($n in @($r.PSObject.Properties.Name)) {
      if ($n -ne 'passwordType' -and $n -match '(?i)password|hash') { $r.$n = '[removed]' }
    }
  }
  $keep = @($found | Select-Object -First $Rows)
  $reply = @{ result = @{ status = @{ totalResults = $total }; data = $keep } }
  [pscustomobject]@{
    name = $name; query = $query; total = $total
    raw = ($reply | ConvertTo-Json -Depth 12 -Compress)
  }
}

Write-Host ""
Write-Host "Searching for $Brand ($Domain)"
Write-Host "-------------------------------------------"
$jobs = @(
  (Start-Search "Leaked credentials"         "credential"  "emailDomain=`"$Domain`""),
  (Start-Search "In plaintext"               "credential"  "emailDomain=`"$Domain`" AND passwordType=`"PLAIN`""),
  (Start-Search "Phishing pages"             "signal-lake" "impersonatedBrandsHigh=`"$Brand`""),
  (Start-Search "Lookalike domains"          "signal-lake" "sanitizedDomainLabel=$label~1"),
  (Start-Search "Mail-enabled lookalikes"    "signal-lake" "sanitizedDomainLabel=$label~1 AND dnsRecordMX=*")
)

# now wait: they have all been running on Axur's side since they started
$results = @($jobs | ForEach-Object { Complete-Search $_ })
Write-Host "-------------------------------------------"

$head = @'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Threat exposure: {{BRAND}}</title>
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
 .cover{background:var(--black);color:#fff;padding:56px 0 48px;
        background-image:radial-gradient(1100px 520px at 88% -10%,rgba(0,226,236,.14),transparent 62%)}
 /* the marks are 144px, so the gap under them has to carry that weight */
 .cover .top{display:flex;align-items:center;justify-content:space-between;margin-bottom:64px;gap:24px}
 /* Both marks are the same height: neither company outranks the other here. */
 .cover .top img.ib{height:144px;width:auto;display:block}
 /* Brandfetch hands over 400x400, so the customer mark can carry the corner */
 .cover .top img.cust{height:144px;width:auto;max-width:420px;object-fit:contain;display:block;
        background:#fff;border-radius:14px;padding:14px 20px}
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
 /* Paper only. The PDF has no bookmark pane - Chrome writes no outline - and
    the sticky strip stops sticking the moment the page stops moving, so a
    reader ten pages in had no way back. On screen the strip already does this. */
 .totop{display:none}
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
   .cover .top img.ib{height:84px}
   .cover .top img.cust{height:84px;max-width:240px}
   table{table-layout:auto}
 }

 /* =================== paper =================== */
 @media print{
   @page{size:A4;margin:15mm 13mm 16mm}
   @page cover{margin:0}
   .cover{page:cover;min-height:297mm;padding:8mm 0 6mm;break-after:page}
   .cover .wrap{padding:0 13mm}
   .cover .top{margin-bottom:26px}
   .cover .top img.ib{height:96px} .cover .top img.cust{height:96px;max-width:300px;padding:10px 14px}
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
   th .totop{display:inline;float:right;font-weight:400;text-transform:none;
             letter-spacing:0;color:var(--mute);text-decoration:none}
   .rowbox{min-height:0!important}
   .note{break-inside:avoid;margin-top:18px}
   footer{padding-top:14px}
 }
</style></head><body>
<main data-brand="{{BRAND}}" data-domain="{{DOMAIN}}" data-scan="{{DATE_ISO}}">

<div class="cover" id="top"><div class="wrap">
  <div class="top">
    <div><img class="ib" src="{{OURS}}" alt="Infoblox" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">Infoblox</span></div>
    <div><img class="cust" src="{{LOGO}}" alt="{{BRAND}}" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">{{BRAND}}</span></div>
  </div>

  <p class="kicker">Threat exposure &middot; Executive summary</p>
  <h1>What is visible about <span class="brand">{{BRAND}}</span><br>from the outside</h1>
  <div class="rule"></div>
  <p class="intro">Infoblox looked for exposure tied to your brand and your domain across breach data,
    criminal marketplaces and the public web. Each card below is one measurement. The number on the left
    is the count on {{DATE_LONG}}; the text explains what it means and why it matters.</p>

  <div class="facts">
    <div class="fact"><span>Brand searched</span><b>{{BRAND}}</b></div>
    <div class="fact"><span>Domain searched</span><b>{{DOMAIN}}</b></div>
    <div class="fact"><span>Scan date</span><b>{{DATE_SHORT}}</b></div>
    <div class="fact"><span>Data source</span><b>Axur (one.axur.com)</b></div>
  </div>
  <p class="key"><span><span class="dot r"></span>Red: somebody could use this today.</span>
    <span><span class="dot a"></span>Amber: exposure that needs one more step first.</span></p>

  <div id="metrics"></div>

  <div class="toc" id="toc"></div>
  <p class="foot">Counts taken from one.axur.com on the scan date. They move daily. Passwords are never included in this report.$CAVEAT</p>
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
'@
$tail = @'
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
  // One search per block. Parsing them together meant a single bad reply threw
  // once and blanked all five tables, and the empty result was cached, so a
  // retry could not help either. This throws for the caller to catch and report
  // in that search's own box.
  function payloadFor(i){
    var el = document.getElementById('payload-' + (i + 1));
    return el ? JSON.parse(el.textContent) : null;
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
    // 365.25 here against the 365 in the test above put a record exactly a
    // year old between the two and printed "0 years ago". One year, one number.
    var y = Math.floor(days / 365); return y + (y === 1 ? ' year ago' : ' years ago');
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
    // ["Acme Corp","Sentinel"] -> "Acme Corp and Sentinel"; the customer's own name in bold.
    // Axur sometimes sends objects here: [{impersonatedBrand:"Acme Corp",impersonatedLevel:"high"}]
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
      {k:'dnsEntriesRecordMX', h:'Mail set up',        f:'mx',      w:21, wp:22},
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
                 'Mail-enabled lookalikes':'Lookalikes with mail switched on' };
  function heading(name){ return TITLES[name] || name; }
  var MEANS = {
    'Leaked credentials':'One row per exposed account. "Password used on" is the site the password was for, which is often not your own. An account appears more than once if it leaked more than once.',
    'In plaintext':'The subset of the previous table where the password was stored in readable form. These are the ones to reset first. The password itself is withheld from this report.',
    'Phishing pages':'Pages Axur is highly confident are impersonating this brand. Risk runs from 0 to 100 and combines how convincing the page is with what it asks for. Some pages will already be offline; the last column shows when each was seen.',
    'Lookalike domains':'Domain names one character away from yours that somebody has registered. Registration alone is not proof of intent, but it is the first step in most of these attacks. Your own defensive registrations appear here too.',
    'Mail-enabled lookalikes':'The lookalike domains with mail records already published. A domain set up to receive mail is a domain someone is running as a mailbox, not parking, so these are the ones being used rather than merely bought.'
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
      big:n('Leaked credentials'), lab:'leaked records tied to your domain. One account can appear more than once', sev:'a',
      sub:n('In plaintext'), subLab:'of them with the password in readable form, usable today', subSev:'r',
      desc:'Accounts on ' + esc(DOMAIN) + ' whose passwords have already been exposed somewhere outside your company.',
      why:'They come from three places: company breaches, dumps traded on criminal forums, and staff or customer computers infected with password-stealing malware.' },
    { icon:'mask', title:'Impersonation sites', go:sectionOf('Phishing pages'),
      big:n('Phishing pages'), lab:'web pages built to look like ' + esc(Brand), sev:'r',
      desc:'Pages designed so that a customer or an employee hands over a login or a card number, believing they are dealing with you.',
      why:'Only pages Axur is highly confident are impersonating this brand are counted. Pages that merely mention the name are left out.' },
    { icon:'site', title:'Lookalike domains', go:sectionOf('Lookalike domains'),
      big:n('Lookalike domains'), lab:'registered names one character away from yours', sev:'a',
      sub:n('Mail-enabled lookalikes'), subLab:'of them have mail switched on, so somebody is running them', subSev:'r',
      desc:'Domain names one swapped, dropped or doubled letter away from ' + esc(DOMAIN) + '. They exist to be mistaken for you.',
      why:'A parked lookalike is a nuisance. One with mail records published is being run by somebody, and is the more likely to be used against your staff or your customers.' },
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
    // the blocks sit below this script, so wait until the parser has them all
    if (totals.length && !document.getElementById('payload-' + totals.length)) return;
    built = true;
    [].slice.call(secs.querySelectorAll('.rowbox')).forEach(function(box){
      var i = Number(box.getAttribute('data-i')), t = totals[i];
      try {
        var d = payloadFor(i);
        var rs = rows(d).slice(0, ROWLIMIT), total = n(t.name);
        if (!rs.length) { box.innerHTML = '<p class="more">No records returned.</p>'; return; }
        // HIDE gates guessed columns only. COLS is curated by hand, and its
        // passwordType entry is the readable-vs-hashed signal the sanitiser
        // deliberately preserves; filtering it here silently dropped it.
        var cs = COLS[t.name] || guessCols(rs).filter(function(c){ return !HIDE.test(c.k); });
        // "Back to the top" has to be reachable from any page, and the PDF has
        // no bookmark pane: Chrome writes no outline. A fixed element is painted
        // once, not per page, because the cover claims its own named page. A
        // table header is repeated on every page the table covers, so the link
        // rides in the last header cell and lands on every page of every table.
        var ths = cs.map(function(c){ return '<th>' + c.h + '</th>'; });
        ths[ths.length - 1] = ths[ths.length - 1]
          .replace('</th>', '<a class="totop" href="#top">&uarr; Top</a></th>');
        var html = '<table><colgroup><col style="--w:4%">' +
          cs.map(function(c){ return '<col style="--w:' + (c.w * 0.96).toFixed(1) + '%;--wp:' + ((c.wp || c.w) * 0.96).toFixed(1) + '%">'; }).join('') +
          '</colgroup><thead><tr><th class="idx">#</th>' + ths.join('') + '</tr></thead><tbody>';
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
'@

$now = Get-Date
$head = $head.Replace('{{BRAND}}', (ConvertTo-HtmlText $Brand)).Replace('{{DOMAIN}}', (ConvertTo-HtmlText $Domain)).
              Replace('{{LOGO}}', (ConvertTo-HtmlText $custData)).Replace('{{OURS}}', (ConvertTo-HtmlText $oursData)).
              Replace('{{DATE_ISO}}',   $now.ToString('yyyy-MM-dd')).
              Replace('{{DATE_LONG}}',  $now.ToString('dd MMMM yyyy')).
              Replace('{{DATE_SHORT}}', $now.ToString('dd MMM yyyy'))
$tail = $tail.Replace('ROWSVALUE', "$Rows")

function Esc($s) { ($s -replace '\\', '\\' -replace '"', '\"') }

$totals = ($results | ForEach-Object {
  '{"name":"' + (Esc $_.name) + '","query":"' + (Esc $_.query) + '","total":' +
  $(if ($null -eq $_.total) { 'null' } else { "$($_.total)" }) + '}'
}) -join ",`n"

# One block per search, not one array holding all five. A single malformed
# reply used to fail the one JSON.parse that fed every table, so one bad reply
# emptied the whole report. Now it costs only its own table.
$i = 0
$payload = ($results | ForEach-Object {
  $i++
  '<script type="application/json" id="payload-' + $i + '">' +
  '{"name":"' + (Esc $_.name) + '","query":"' + (Esc $_.query) + '","total":' +
  $(if ($null -eq $_.total) { 'null' } else { "$($_.total)" }) + ',"reply":' +
  ($_.raw -replace '</', '<\/') + '}</script>'
}) -join "`n"

Write-Host -NoNewline "Writing the report "
$doc = $head + "`n" +
       '<script type="application/json" id="totals">[' + "`n" + $totals + "`n" + ']</script>' + "`n" +
       $tail + "`n" +
       $payload + "`n" +
       '</main></body></html>'
[IO.File]::WriteAllText($Out, $doc, (New-Object Text.UTF8Encoding $false))
$abs = (Resolve-Path $Out).Path
Write-Host "done"
if ($incomplete.Count) {
  Write-Host "Note: these had not finished when the wait ran out, so their counts are a"
  Write-Host "floor, not a total. Re-run with a longer -Wait: $($incomplete -join ', ')"
}
if ($partial.Count) {
  Write-Host "Note: hit the page cap on $($partial -join ', '). Those counts came from a partial pull."
}

# Edge ships with Windows and prints without opening a window
$done = $abs; $pdfWritten = ""
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
    if (Test-Path $pdf) { Write-Host " ... wrote $pdf"; $done = $pdf; $pdfWritten = $pdf }
    else { Write-Host " ... failed. Open the HTML and press Ctrl+P." }
  } else {
    Write-Host "No Edge or Chrome found, so no PDF. Open the HTML and press Ctrl+P."
  }
}

Write-Host ""
Write-Host "Summary"
foreach ($result in $results) {
  $count = if ($null -eq $result.total) { 'not available' } else { [string]$result.total }
  Write-Host ("  {0,-26} {1}" -f $result.name, $count)
}
Write-Host "Files written"
Write-Host "  HTML: $abs"
if ($pdfWritten) { Write-Host "  PDF:  $pdfWritten" }

if ($NoOpen) { Write-Host "Open it with:  Invoke-Item `"$done`"" } else { Invoke-Item $done }
Write-Host ""
