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
  [string]$Logo, [switch]$NoLogo, [switch]$DropOwn, [switch]$NoPdf, [switch]$NoOpen, [switch]$ShowRaw
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

$head = @'
###HTMLHEAD###
'@
$tail = @'
###HTMLTAIL###
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
                    ("LOGO_H", "{{LOGO}}"), ("OURS_H", "{{OURS}}")):
        head = head.replace("${%s}" % var, ph).replace("$" + var, ph)

    # Only the escaped names belong in the page. Mapping the raw names here as
    # well would quietly accept a bare $BRAND in the cover: the shell would emit
    # it unescaped while PowerShell still ran it through ConvertTo-HtmlText, so
    # the injection would come back on one platform with the build still green.
    raw = [v for v in ("BRAND", "DOMAIN", "LOGO", "OURS") if "$" + v in head]
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


def quote(line):
    return "      '" + (line.replace("\\", "\\\\").replace("'", "\\'")
                            .replace("</", "<\\/")) + "',"


def embed(page, start_marker, lines):
    if page.count(start_marker) != 1:
        sys.exit("marker %r is not unique; docs/index.html has drifted" % start_marker)
    i = page.index(start_marker)
    j = i
    while not page[j:].lstrip().startswith("].join("):
        j = page.index("\n", j) + 1
    body = "\n".join(quote(l) for l in lines)
    return page[:i + len(start_marker)] + "\n" + body + "\n    " + page[j:].lstrip()


def main():
    sh_text = SH.read_text()
    print("axur-report.ps1: %d lines" % build_powershell(sh_text))

    page = PAGE.read_text()
    for path, marker in ((SH, "    var sh = ["), (PS1, "    var ps = [")):
        text = path.read_text().replace("\r\n", "\n")
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        page = embed(page, marker, lines)
        print("embedded %s: %d lines" % (path.name, len(lines)))
    PAGE.write_text(page)


if __name__ == "__main__":
    main()
