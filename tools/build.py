#!/usr/bin/env python3
"""Rebuild the Windows script and the guide's download buttons.

The report's HTML lives once, in axur-report.sh. This lifts it out, wraps it in
the PowerShell below, and pushes both scripts back into guide.html so its
download buttons never serve stale code.

    python3 tools/build.py

Run it after editing anything in axur-report.sh.
"""
import pathlib, re, sys

# Paths are anchored to the repo root, so the builder runs from anywhere.
ROOT = pathlib.Path(__file__).resolve().parent.parent
SH   = ROOT / "axur-report.sh"
PS1  = ROOT / "axur-report.ps1"
PAGE = ROOT / "docs" / "index.html"

PS_TEMPLATE = r"""<#
  Axur pre-meeting report.

    powershell -ExecutionPolicy Bypass -File axur-report.ps1
    powershell -ExecutionPolicy Bypass -File axur-report.ps1 -Brand "BRAND" -Domain customer.com -ApiKey YOUR_KEY

  Anything you leave off, it asks for.

    -Config FILE    read customer settings from FILE. Command-line flags win
    -SaveConfig F   save this run's customer settings to F (never the API key)
    -Rows N         rows listed under each count (default 50)
    -Wait SECONDS   how long to let each search finish (default 300)
    -Days N         only records Axur saw in the last N days (default 30).
                    A narrower window is a smaller result and a faster run
    -AllTime        no date limit. Slower, and the count can run to thousands
    -CheckDays      ask the API whether it honours the -Days filter at all,
                    then stop. One search, no report written
    -MaskPasswords  print a password as its first and last character with
                    stars between, instead of in full
    -MinScore N     drop rows scoring below N (lookalike and phishing only)
    -Exclude LIST   drop rows matching these, comma separated. ".au,known.com"
    -ExcludeFile F  same, read from a file or CSV. One per line, first column,
                    # starts a comment
    -Logo SRC       use this for the customer logo instead of looking it up.
                    A file on disk, or a URL
    -NoLogo         do not look up any logo. The names are written instead
    -DropOwn        drop the customer's own domain from the results. Their own
                    sites match the searches but are not impersonating them
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
  [string]$Logo, [switch]$NoLogo, [switch]$DropOwn, [int]$Days = 30, [switch]$AllTime, [switch]$CheckDays,
  [switch]$MaskPasswords, [switch]$NoPdf, [switch]$NoOpen, [switch]$ShowRaw
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

# Bash rejects a negative count; PowerShell's [int] accepts one and then either
# empties the row list or silently drops the date window. Same rule, both sides.
if ($Rows -lt 0) { Write-Host "-Rows takes a number of rows, not $Rows."; exit 1 }
if ($Wait -lt 0) { Write-Host "-Wait takes a number of seconds, not $Wait."; exit 1 }
if ($Days -lt 0) { Write-Host "-Days takes a number of days, not $Days."; exit 1 }

$Brand  = Ask $Brand  "Brand, as Axur spells it" $false
$Domain = Ask $Domain "Customer domain" $false
$ApiKey = Ask $ApiKey "Axur API key" $true

$Domain = ($Domain -replace '^[a-z]+://', '' -replace '^www\.', '').Split('/')[0].ToLower()
# The fuzzy searches match a domain label, not a brand name. Bash takes the
# first component and names the file after it. This kept the last three
# components and named the file after the whole domain, so the same customer
# gave the two platforms a different search and a different filename.
$label = ($Domain.Split('.') | Where-Object { $_ })[0]
if (-not $Out) { $Out = "axur-report-$label.html" }

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

# Epoch milliseconds for the start of the window, which is how every date in
# these replies is expressed. Computed once so all five searches share a cutoff.
$since = $null
if (-not $AllTime -and $Days -gt 0) {
  $since = [long]([DateTimeOffset]::UtcNow.AddDays(-$Days).ToUnixTimeMilliseconds())
}
$dateWarned = $false

# The date clause is the one thing here nobody has confirmed against the real
# API. A field the API does not know can come back two ways: refused, which the
# fallback already handles, or accepted and quietly ignored, which nothing can
# see. Then -Days 30 reports all time and says nothing. This asks the question
# directly: one search with a cutoff a year from now. Nothing can be newer than
# that, so a working filter returns zero.
if ($CheckDays) {
  $future = [long]([DateTimeOffset]::UtcNow.AddDays(365).ToUnixTimeMilliseconds())
  $probe  = 'emailDomain="' + $Domain + '" AND detectionDate>=' + $future
  Write-Host "Asking Axur for records newer than a year from now."
  Write-Host "  $probe"
  $pstart = $null
  try {
    $pstart = Invoke-RestMethod -Method Post -Uri "$api/search" -Headers $headers `
              -ContentType "application/json" `
              -Body (@{ query = $probe; source = "ttps" } | ConvertTo-Json -Compress)
  } catch {
    $pc = $null
    if ($_.Exception.Response) { $pc = [int]$_.Exception.Response.StatusCode }
    Write-Host ""
    Write-Host "The API refused the query (HTTP $pc)."
    Write-Host "That is the safe case: every run drops the date clause and warns once,"
    Write-Host "so the counts cover all time and the report says so."
    exit 0
  }
  if (-not $pstart.searchId) {
    Write-Host ""
    Write-Host "The API answered without a search id, so it would not take the query."
    Write-Host "That is the safe case: every run drops the date clause and warns once."
    exit 0
  }
  $pe = 0; $ptotal = $null
  while ($pe -lt $Wait) {
    try { $pr = Invoke-RestMethod -Uri "$api/search/$($pstart.searchId)?page=1&alias=true" -Headers $headers }
    catch { Start-Sleep -Seconds 3; $pe += 3; continue }
    if (-not $pr.result.status.running) { $ptotal = [int]$pr.result.status.totalResults; break }
    Start-Sleep -Seconds 3; $pe += 3
  }
  Write-Host ""
  if ($null -eq $ptotal) {
    Write-Host "No count came back in $Wait seconds. Try again with a longer -Wait."
    exit 1
  } elseif ($ptotal -eq 0) {
    Write-Host "Returned 0. The filter works, so -Days really does narrow the window."
    exit 0
  } else {
    Write-Host "Returned $ptotal. Nothing can be newer than a year from now, so the API"
    Write-Host "is ignoring the date clause. Every -Days run is silently covering all"
    Write-Host "time. Use -AllTime so the report says so, and tell someone the field"
    Write-Host "name is wrong."
    exit 1
  }
}

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
$custData = ""; $oursData = ""; $ibData = ""
if ($NoLogo) {
  Write-Host " ... skipped, the names will be written instead"
} else {
  if ($Logo -and (Test-Path -LiteralPath $Logo)) { $custData = Read-Logo $Logo }
  elseif ($Logo)                                 { $custData = Get-Logo $Logo }
  else { $custData = Get-Logo "https://cdn.brandfetch.io/$Domain/w/400/h/400" }
  # our own mark is the Axur lockup from axur.com, white because the cover is
  # dark; Infoblox sits beside it, so both companies are named
  $oursData = Get-Logo "https://cdn.prod.website-files.com/686fc31bac575ba9d246a49d/69cc2bab842c735eb0ad0cd1_02ddeb0576365499077ea973c3f145b9_LOGO_WHITE.svg"
  $ibData   = Get-Logo "https://cdn.brandfetch.io/infoblox.com/w/400/h/400"
  if ($custData) { Write-Host " ... got $Brand" }
  elseif ($Logo) { Write-Host " ... could not read $Logo, the name will be written instead" }
  else { Write-Host " ... none for $Domain, the name will be written instead" }
}

$filtered = @("Phishing pages", "Lookalike domains", "Mail-enabled lookalikes")
# lowercased once here, because Test-Keep compares them against every field of
# every row and $p.ToLower() inside that loop redid the work thousands of times
$patterns = @($Exclude -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })

# The customer's own sites are not impersonating the customer, but the searches
# match on the name, so their own domains come back as impersonation sites and
# as lookalikes. -DropOwn takes them out. Not the default: any filter forces a
# full page walk to recount, so a large result runs slower and stops at the cap.
if ($DropOwn) { $patterns += $Domain.ToLower() }

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
# -MaskPasswords rewrites the value before it reaches the file, so the masked
# form is what lands in the report. One character each end is enough to
# recognise a password you already hold and useless to anyone who does not.
function Hide-Passwords($text) {
  if (-not $MaskPasswords) { return $text }
  # A quote or a backslash inside a password arrives escaped. Matching to the
  # next quote stopped inside the escape, left part of the password behind, and
  # for a value ending in a backslash escaped the closing quote and broke the
  # payload. Keep first and last only while the value is plain; mask a value
  # carrying any escape end to end. The last rule needs a backslash, so it
  # cannot re-mask what the first two just wrote.
  $t = [regex]::Replace($text,  '"password"\s*:\s*"([^"\\])[^"\\]*([^"\\])"', '"password":"$1*****$2"')
  $t = [regex]::Replace($t,     '"password"\s*:\s*"([^"\\])?"', '"password":"*"')
  return [regex]::Replace($t,   '"password"\s*:\s*"([^"\\]|\\.)*\\.([^"\\]|\\.)*"', '"password":"*****"')
}

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
  foreach ($f in @(###EXCLUDEFIELDS###)) {
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
  # The date clause narrows the result, which is the whole point of -Days: a
  # smaller result is fewer pages to walk and a faster run. This syntax is not
  # documented anywhere we can check, so it is tried first and the plain query
  # is the fallback rather than the run failing.
  $try = $query
  if ($null -ne $since) { $try = "$query AND detectionDate>=$since" }
  $dateTried = $false
  $start = $null; $attempt = 0
  while ($true) {
    $body = @{ query = $try; source = $source } | ConvertTo-Json -Compress
    try {
      $start = Invoke-RestMethod -Method Post -Uri "$api/search" -Headers $headers `
               -ContentType "application/json" -Body $body
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
      # A rejected query earns the retry; a bad key or a closed tenant does not.
      # Windows used to fail the whole run when the API turned the date clause
      # down with a status code rather than a 200 carrying no searchId.
      if (-not $dateTried -and $try -ne $query -and ($c -eq 400 -or $c -eq 422)) {
        $dateTried = $true
        if (-not $script:dateWarned) {
          Write-Host "  Axur would not take the -Days filter, so the searches cover all time."
          $script:dateWarned = $true
        }
        $try = $query
        continue
      }
      Write-Host -NoNewline ("{0,-26}" -f $name)
      switch ($c) {
        401 { Write-Host " key rejected (401). Generate a new one in My preferences." }
        403 { Write-Host " no access to this tenant (403)" }
        429 { Write-Host " still rate limited after waiting. Try again in a minute." }
        default { Write-Host " could not start (HTTP $c)" }
      }
      return [pscustomobject]@{ name = $name; query = $try; id = $null }
    }
    # A dated query the API will not accept must not take the run down with it.
    # Axur answers 200 with no searchId as readily as it errors, so this sits
    # here rather than in the catch above. Drop the clause, say so once, retry.
    if (-not $start.searchId -and -not $dateTried -and $try -ne $query) {
      $dateTried = $true
      if (-not $script:dateWarned) {
        Write-Host "  Axur would not take the -Days filter, so the searches cover all time."
        $script:dateWarned = $true
      }
      $try = $query
      continue
    }
    break
  }
  Write-Host ("  {0,-26} started" -f $name)
  return [pscustomobject]@{ name = $name; query = $try; id = $start.searchId }
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
    # Ask first, then wait. Sleeping before the first read charged two seconds
    # to every search whether or not it had already finished, so five finished
    # searches still cost ten seconds of doing nothing.
    if ($i -gt 0) { Start-Sleep -Seconds 2 }
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
      # Running out of rows and the request failing both used to end the walk
      # the same quiet way, and the filtered count then went on the cover as a
      # total. A page that never arrived is a short pull, not the end.
      try { $pg = (Invoke-WebRequest -UseBasicParsing -Uri "$api/search/${id}?page=$p&alias=true" -Headers $headers).Content }
      catch { $script:partial += $name; break }
      try { $pr = @(($pg | ConvertFrom-Json).result.data) }
      catch { $script:partial += $name; break }
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
###SEARCHES###
Write-Host "-------------------------------------------"

# The two ways a count can be short. The terminal says them at the end of the
# run; the cover has to say them too, or the customer reads a floor as a total.
$PWNOTE = if ($MaskPasswords) { "Leaked passwords are masked: first and last character at most." }
          else                { "Leaked passwords are included in full." }
$CAVEAT = ""
if ($incomplete.Count) { $CAVEAT = " Some counts were still climbing when the scan stopped, so they are a minimum." }
if ($partial.Count)    { $CAVEAT = "$CAVEAT Filtered counts cover only the rows that were pulled." }

$head = @'
###HTMLHEAD###
'@
$tail = @'
###HTMLTAIL###
'@

$now = Get-Date
$head = $head.Replace('{{BRAND}}', (ConvertTo-HtmlText $Brand)).Replace('{{DOMAIN}}', (ConvertTo-HtmlText $Domain)).
              Replace('{{LOGO}}', (ConvertTo-HtmlText $custData)).Replace('{{OURS}}', (ConvertTo-HtmlText $oursData)).
              Replace('{{IB}}', (ConvertTo-HtmlText $ibData)).
              Replace('{{DATE_ISO}}',   $now.ToString('yyyy-MM-dd')).
              Replace('{{DATE_LONG}}',  $now.ToString('dd MMMM yyyy')).
              Replace('{{DATE_SHORT}}', $now.ToString('dd MMM yyyy')).
              Replace('{{CAVEAT}}', (ConvertTo-HtmlText $CAVEAT)).
              Replace('{{PWNOTE}}', (ConvertTo-HtmlText $PWNOTE))
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
  (Hide-Passwords ($_.raw -replace '</', '<\/')) + '}</script>'
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
  Write-Host "Note: these stopped short while filtering, at the page cap or because a page"
  Write-Host "did not come back, so the filtered count covers only the rows pulled: $($partial -join ', ')"
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
"""


def heredoc(lines, open_marker, close_marker):
    """The text between a heredoc's markers in the shell script."""
    i = next(k for k, l in enumerate(lines) if l.startswith(open_marker))
    j = next(k for k in range(i + 1, len(lines)) if lines[k] == close_marker)
    return "\n".join(lines[i + 1:j])



def powershell_searches(sh_text):
    """The five searches, taken from the shell script so they cannot drift.

    They used to be hand-copied into the PowerShell template, and a fix to the
    lookalike query reached the Mac script only: Windows kept reporting a
    subset larger than its parent.
    """
    calls = []
    for m in re.finditer(r'^start_search\s+"([^"]+)"\s+(\S+)\s+"(.*)"\s*$', sh_text, re.M):
        name, source, query = m.group(1), m.group(2), m.group(3)
        q = (query.replace('\\"', '`"')          # shell escape -> PowerShell escape
                  .replace("$DOMAIN", "$Domain")
                  .replace("$BRAND", "$Brand")
                  .replace("$LABEL", "$label"))
        calls.append('  (Start-Search %s %s "%s")'
                     % (('"%s"' % name).ljust(28), ('"%s"' % source).ljust(13), q))
    if len(calls) != 5:
        sys.exit("expected 5 searches in axur-report.sh, found %d" % len(calls))
    return ("$jobs = @(\n" + ",\n".join(calls) + "\n)\n\n"
            "# now wait: they have all been running on Axur's side since they started\n"
            "$results = @($jobs | ForEach-Object { Complete-Search $_ })")


def exclude_fields(sh_text):
    """The fields an exclusion is matched against, taken from the shell script.

    They were hand-copied into both scripts. That is the drift that
    powershell_searches exists to stop: a fix reached one platform only, and
    Windows quietly filtered on a different set of fields from the Mac.
    """
    m = re.search(r"^\s*for my \$f \(qw\(([^)]*)\)\) \{", sh_text, re.M)
    if not m:
        sys.exit("could not find the exclusion field list in axur-report.sh")
    return ", ".join("'%s'" % f for f in m.group(1).split())


def build_powershell(sh_text):
    lines = sh_text.split("\n")
    head = heredoc(lines, "cat <<HTMLHEAD", "HTMLHEAD")
    tail = heredoc(lines, "cat <<'HTMLTAIL'", "HTMLTAIL")

    # the shell interpolates these; PowerShell will .Replace() them instead
    for var, ph in (("BRAND_H", "{{BRAND}}"), ("DOMAIN_H", "{{DOMAIN}}"),
                    ("LOGO_H", "{{LOGO}}"), ("OURS_H", "{{OURS}}"), ("IB_H", "{{IB}}"),
                    ("CAVEAT", "{{CAVEAT}}"), ("PWNOTE", "{{PWNOTE}}")):
        head = head.replace("${%s}" % var, ph).replace("$" + var, ph)

    # Only the escaped names belong in the page. Mapping the raw names here as
    # well would quietly accept a bare $BRAND in the cover: the shell would emit
    # it unescaped while PowerShell still ran it through ConvertTo-HtmlText, so
    # the injection would come back on one platform with the build still green.
    raw = [v for v in ("BRAND", "DOMAIN", "LOGO", "OURS", "IB") if "$" + v in head]
    if raw:
        sys.exit("HTMLHEAD still writes " + ", ".join("$" + v for v in raw)
                 + " unescaped; use the _H name so the value is escaped once.")

    # The cover carries shell date expressions. PowerShell cannot run those, so
    # without this the customer's report literally reads $(date '+%d %B %Y').
    for expr, ph in (("$(date '+%Y-%m-%d')", "{{DATE_ISO}}"),
                     ("$(date '+%d %B %Y')", "{{DATE_LONG}}"),
                     ("$(date '+%d %b %Y')", "{{DATE_SHORT}}")):
        head = head.replace(expr, ph)
    left = [l for l in head.split("\n") if "$(" in l]
    if left:
        sys.exit("unhandled shell expression in HTMLHEAD, PowerShell cannot run it:\n  "
                 + "\n  ".join(left[:3]))

    # PowerShell reads the cover from a literal here-string, so a shell variable
    # left behind is printed to the customer as its own name. $CAVEAT shipped
    # that way. Map every name above, or the build stops here.
    stray = sorted(set(re.findall(r"\$\{?([A-Z][A-Z0-9_]*)\}?", head)))
    if stray:
        sys.exit("HTMLHEAD still writes " + ", ".join("$" + v for v in stray)
                 + "; PowerShell prints that name instead of a value. Add it to"
                   " the placeholder list above.")

    for name, text in (("HTMLHEAD", head), ("HTMLTAIL", tail)):
        for bad in ("'@", '"@'):
            if any(l.strip().startswith(bad) for l in text.split("\n")):
                sys.exit("%s has a line starting with %s, which would close a "
                         "PowerShell here-string" % (name, bad))

    ps = (PS_TEMPLATE.replace("###HTMLHEAD###", head)
                     .replace("###HTMLTAIL###", tail)
                     .replace("###SEARCHES###", powershell_searches(sh_text))
                     .replace("###EXCLUDEFIELDS###", exclude_fields(sh_text)))
    # Windows tooling is happier with CRLF
    PS1.write_bytes(ps.replace("\r\n", "\n").replace("\n", "\r\n").encode("utf-8"))
    return ps.count("\n") + 1


def check_download_source():
    """The guide fetches both scripts from a fixed tag. Say so if they differ.

    The page used to hold a copy of each script, and this rebuilt them after
    every edit. It fetches from a tag now, so the failure changed shape: the
    guide can point at a tag whose scripts are not these ones, and nothing in
    the page would say so. Compare them here instead.
    """
    page = PAGE.read_text()
    m = re.search(r"var SRC = '([^']+)'", page)
    if not m:
        sys.exit("docs/index.html no longer says where it fetches the scripts from.")
    src = m.group(1)
    tag = src.rstrip("/").rsplit("/", 1)[-1]
    print("guide fetches the scripts from tag %s" % tag)

    try:
        import urllib.request
        for path in (SH, PS1):
            with urllib.request.urlopen(src + path.name, timeout=15) as r:
                remote = r.read()
            local = path.read_bytes()
            state = "matches" if remote == local else "DIFFERS from"
            print("  %-18s %s the file here (%d bytes)" % (path.name, state, len(remote)))
            if remote != local:
                print("     tag a new version and point var SRC at it,"
                      " or the guide hands out the wrong script.")
    except Exception as e:
        print("  could not reach %s (%s). Check it before you publish." % (src, e))


def main():
    sh_text = SH.read_text()
    print("axur-report.ps1: %d lines" % build_powershell(sh_text))
    check_download_source()


if __name__ == "__main__":
    main()
