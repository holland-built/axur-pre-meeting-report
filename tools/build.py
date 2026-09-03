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

    -Rows N         rows listed under each count (default 50)
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

  This file is generated from axur-report.sh by build-ps1.py. Edit the HTML
  there, not here, then re-run the generator.
#>
param(
  [string]$Brand, [string]$Domain, [string]$ApiKey,
  [int]$Rows = 50, [string]$MinScore, [string]$Exclude, [string]$ExcludeFile, [string]$Out,
  [string]$Logo, [switch]$NoLogo, [switch]$NoPdf, [switch]$NoOpen, [switch]$ShowRaw
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
$logo = ""; $ours = ""
if ($NoLogo) {
  Write-Host " ... skipped, the names will be written instead"
} else {
  if ($Logo -and (Test-Path -LiteralPath $Logo)) { $logo = Read-Logo $Logo }
  elseif ($Logo)                                 { $logo = Get-Logo $Logo }
  else { $logo = Get-Logo "https://cdn.brandfetch.io/$Domain/w/400/h/400" }
  $ours = Get-Logo "https://cdn.brandfetch.io/infoblox.com/w/400/h/400"
  if ($logo) { Write-Host " ... got $Brand" }
  elseif ($Logo) { Write-Host " ... could not read $Logo, the name will be written instead" }
  else { Write-Host " ... none for $Domain, the name will be written instead" }
}

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
  # Any field whose NAME carries password or hash goes, whatever its type: the
  # hashes, the length and the passwordHas* flags together are a recipe for
  # guessing the password this report says it does not include. passwordType is
  # kept, because PLAIN vs HASH is the point of one of the five searches.
  foreach ($r in $rows) {
    foreach ($n in @($r.PSObject.Properties.Name)) {
      if ($n -ne 'passwordType' -and $n -match '(?i)password|hash') { $r.$n = '[removed]' }
    }
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
###SEARCHES###
Write-Host "-------------------------------------------"

$head = @'
###HTMLHEAD###
'@
$tail = @'
###HTMLTAIL###
'@

$now = Get-Date
$head = $head.Replace('{{BRAND}}', $Brand).Replace('{{DOMAIN}}', $Domain).
              Replace('{{LOGO}}', $logo).Replace('{{OURS}}', $ours).
              Replace('{{DATE_ISO}}',   $now.ToString('yyyy-MM-dd')).
              Replace('{{DATE_LONG}}',  $now.ToString('dd MMMM yyyy')).
              Replace('{{DATE_SHORT}}', $now.ToString('dd MMM yyyy'))
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
    for m in re.finditer(r'^run\s+"([^"]+)"\s+(\S+)\s+"(.*)"\s*$', sh_text, re.M):
        name, source, query = m.group(1), m.group(2), m.group(3)
        q = (query.replace('\\"', '`"')          # shell escape -> PowerShell escape
                  .replace("$DOMAIN", "$Domain")
                  .replace("$BRAND", "$Brand")
                  .replace("$LABEL", "$label"))
        calls.append('  (Invoke-Search %s %s "%s")'
                     % (('"%s"' % name).ljust(28), ('"%s"' % source).ljust(13), q))
    if len(calls) != 5:
        sys.exit("expected 5 searches in axur-report.sh, found %d" % len(calls))
    return "$results = @(\n" + ",\n".join(calls) + "\n)"


def build_powershell(sh_text):
    lines = sh_text.split("\n")
    head = heredoc(lines, "cat <<HTMLHEAD", "HTMLHEAD")
    tail = heredoc(lines, "cat <<'HTMLTAIL'", "HTMLTAIL")

    # the shell interpolates these; PowerShell will .Replace() them instead
    for var, ph in (("BRAND", "{{BRAND}}"), ("DOMAIN", "{{DOMAIN}}"),
                    ("LOGO", "{{LOGO}}"), ("OURS", "{{OURS}}")):
        head = head.replace("${%s}" % var, ph).replace("$" + var, ph)

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
                     .replace("###SEARCHES###", powershell_searches(sh_text)))
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
