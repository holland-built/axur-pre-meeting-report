<#
  Axur pre-meeting report.

    powershell -ExecutionPolicy Bypass -File axur-report.ps1
    powershell -ExecutionPolicy Bypass -File axur-report.ps1 -Brand "BRAND" -Domain customer.com -KeyFile C:\axur-key.txt

  Anything you leave off, it asks for.

    -Config FILE    read customer settings from FILE. Command-line flags win
    -SaveConfig F   save this run's customer settings to F (never the API key)
    -KeyFile FILE   read the API key from the first line of FILE. There is no
                    -ApiKey flag: an argument is visible to anyone who can list
                    processes, and it lands in the PowerShell history file
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
  [string]$Brand, [string]$Domain, [string]$KeyFile, [string]$Config, [string]$SaveConfig,
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

# A file is the only way to hand the key over without a console. The key itself
# is never written anywhere by this script, and the file is not copied.
$ApiKey = $null
if ($KeyFile) {
  $KeyFile = Expand-UserPath $KeyFile
  if (-not (Test-Path -LiteralPath $KeyFile)) {
    Write-Host "Key file not found: $KeyFile"; exit 1
  }
  $ApiKey = (Get-Content -LiteralPath $KeyFile -TotalCount 1).Trim()
  if (-not $ApiKey) { Write-Host "Key file is empty: $KeyFile"; exit 1 }
}
$ApiKey = Ask $ApiKey "Axur API key" $true

$Domain = ($Domain -replace '^[a-z]+://', '' -replace '^www\.', '').Split('/')[0].ToLower()
# The fuzzy searches match a domain label, not a brand name. Bash takes the
# first component and names the file after it. This kept the last three
# components and named the file after the whole domain, so the same customer
# gave the two platforms a different search and a different filename.
# $label is the one value that goes into a query without quotes around it, so
# quoting it is no defence. Keep only what a real domain label can hold.
$label = (($Domain.Split('.') | Where-Object { $_ })[0] -replace '[^A-Za-z0-9-]', '')

# Brand and domain are dropped straight into an Axur query, inside its own
# double quotes. A quote in the brand closes that string and the rest becomes
# query syntax, so a brand of  Larkspur" OR emailDomain="  searches somebody
# else's tenant data into this customer's report. Escape for the query language
# here; Start-Search serialises the finished query to JSON, which is the layer
# above and a separate job.
$brandQ  = $Brand.Replace('\','\\').Replace('"','\"')
$domainQ = $Domain.Replace('\','\\').Replace('"','\"')

if (-not $Out) { $Out = "axur-report-$label.html" }

# -Out is a path the script overwrites without asking, and the report holds
# leaked passwords. A value of ..\..\secrets.html, or an absolute path from a
# -Config file somebody was handed, writes there. Keep the write inside the
# folder the run started in.
$outParent = Split-Path -Parent $Out
if (-not $outParent) { $outParent = '.' }
try { $outFull = (Resolve-Path -LiteralPath $outParent).Path }
catch { Write-Host "There is no folder $outParent to write $Out into."; exit 1 }
$here = (Get-Location).Path
if ($outFull -ne $here -and -not $outFull.StartsWith($here + [IO.Path]::DirectorySeparatorChar)) {
  Write-Host "-Out must stay inside $here, and $outFull is outside it."; exit 1
}

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
  $probe  = 'emailDomain="' + $domainQ + '" AND detectionDate>=' + $future
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
# The searches that fold: the three above on the site, these two on the account.
# Which searches fold by what. $filtered happens to hold the same three names
# as $bySite today, but it is the list the score and exclusion filters apply
# to, which is a different question; naming it here keeps a change to one from
# silently changing the other.
$bySite    = @("Phishing pages", "Lookalike domains", "Mail-enabled lookalikes")
$byAccount = @("Leaked credentials", "In plaintext")
$foldable  = $bySite + $byAccount
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
function Hide-PasswordValues($text) {
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

function Hide-Passwords($text) {
  if (-not $MaskPasswords) { return $text }
  return Hide-PasswordValues $text
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

# Fold the rows that name the same host into one. The same rule as fold.pl in
# axur-report.sh: the key is the first non-empty of host, domain, reference
# with any scheme and path taken off, lowercased in ASCII only so the two
# scripts cannot disagree on a letter. Only the three site searches fold.
function ConvertTo-AsciiLower($s) {
  return [regex]::Replace([string]$s, '[A-Z]', [Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value.ToLowerInvariant() })
}
# A property by its exact name. $row.host would also answer for "Host", and
# fold.pl, which reads the lowercase names Axur sends, would not.
function Get-Prop($row, $name) {
  if ($null -eq $row -or $row -isnot [psobject]) { return $null }
  foreach ($p in $row.PSObject.Properties) { if ($p.Name -ceq $name) { return $p.Value } }
  return $null
}
function Get-FoldKey($row) {
  foreach ($f in @('host', 'domain', 'reference')) {
    $v = Get-Prop $row $f
    if ($v -isnot [string] -or $v -eq '') { continue }
    $k = $v -replace '^[A-Za-z][A-Za-z0-9+.-]*://', '' -replace '(?s)[/?#].*', ''
    return (ConvertTo-AsciiLower $k)
  }
  return ''
}
# The credential key: the account, lowercased in ASCII only. No account, or
# an empty one, is never folded.
function Get-UserKey($row) {
  $v = Get-Prop $row 'user'
  if ($v -isnot [string] -or $v -eq '') { return '' }
  return (ConvertTo-AsciiLower $v)
}
# The site of a credential row. This rule is shared word for word with siteof
# in fold.pl, inside axur-report.sh; change one and change the other:
#   - take the first non-empty of accessHost, accessUrl, url
#   - strip any scheme, then cut at the first of / ? #
#   - ASCII-lowercase it
#   - an empty result is NOT a site, and never counts
#   - two sites are the same only if the resulting text is byte-for-byte equal
function Get-Site($row) {
  foreach ($f in @('accessHost', 'accessUrl', 'url')) {
    $v = Get-Prop $row $f
    if ($v -isnot [string] -or $v -eq '') { continue }
    $k = $v -replace '^[A-Za-z][A-Za-z0-9+.-]*://', '' -replace '(?s)[/?#].*', ''
    return (ConvertTo-AsciiLower $k)
  }
  return ''
}
# 1 when passwordType reads PLAIN, matched on its ASCII letters only; else 0.
function Get-Plain($row) {
  $v = Get-Prop $row 'passwordType'
  if ($v -isnot [string]) { return 0 }
  if ((ConvertTo-AsciiLower $v) -ceq 'plain') { return 1 }
  return 0
}
# A number, from a number or from a string written the way JSON writes a
# number; $null otherwise. .NET would also take "NaN" and "Infinity", which
# fold.pl's grammar does not, and NaN never loses a comparison.
function Get-Num($v) {
  if ($null -eq $v) { return $null }
  $t = [string]$v
  if ($t -notmatch '^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$') { return $null }
  $n = 0.0
  if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
  return $null
}
# fold.pl leaves a row alone when a string in it is not JSON: a raw control
# character, an escape JSON does not have, or a surrogate escape without its
# other half. This parser repairs the surrogate to U+FFFD and lets the rest
# through, so once a reply is parsed there is nothing left to see. Look at the
# text before it is parsed instead: walk the rows of the first "data" array
# with the same string-aware brace count fold.pl uses, and test every string
# token. A row that names a field the fold reads twice is bad as well: this
# parser keeps the last value and fold.pl the first, so the two would guess
# differently. One $true or $false per row, in order.
$foldReads = @('host', 'domain', 'reference', 'riskScore', 'detectionDate',
               'user', 'passwordType', 'accessHost', 'accessUrl', 'url')
function Test-JsonString($tok) {
  if ($tok -match '[\x00-\x1f]') { return $false }
  $high = $false; $highEnd = -1
  foreach ($e in [regex]::Matches($tok, '(?s)\\(u[0-9a-fA-F]{4}|.)')) {
    $v = $e.Groups[1].Value
    if ($v.Length -eq 5) {
      $cp = [Convert]::ToInt32($v.Substring(1), 16)
      if ($cp -ge 0xD800 -and $cp -le 0xDBFF) { if ($high) { return $false }; $high = $true; $highEnd = $e.Index + 6; continue }
      if ($cp -ge 0xDC00 -and $cp -le 0xDFFF) { if (-not $high -or $e.Index -ne $highEnd) { return $false }; $high = $false; continue }
      if ($high) { return $false }
      continue
    }
    if ($high -or $v -notmatch '^["\\/bfnrt]$') { return $false }
  }
  return (-not $high)
}
function Get-BadRows($text) {
  $bad = New-Object System.Collections.ArrayList
  $i = $text.IndexOf('"data"'); if ($i -lt 0) { return $bad }
  $i = $text.IndexOf('[', $i); if ($i -lt 0) { return $bad }
  $depth = 0; $rowBad = $false; $expectKey = $false; $seen = $null
  foreach ($m in [regex]::Matches($text.Substring($i + 1), '(?s)"(?:[^"\\]|\\.)*"|[{}\[\],]')) {
    $t = $m.Value
    if ($t -eq ',') { if ($depth -eq 1) { $expectKey = $true }; continue }
    if ($t[0] -eq '"') {
      if ($depth -gt 0 -and -not (Test-JsonString $t)) { $rowBad = $true }
      if ($depth -eq 1 -and $expectKey) {
        # a key at the row's own level; decode it only when it carries an escape
        $k = if ($t.Contains('\')) { try { $t | ConvertFrom-Json } catch { $t } } else { $t.Substring(1, $t.Length - 2) }
        if ($foldReads -ccontains $k) { if ($seen.Contains($k)) { $rowBad = $true } else { [void]$seen.Add($k) } }
        $expectKey = $false
      }
      continue
    }
    if ($t -eq '{' -or $t -eq '[') {
      if ($depth -eq 0) { $rowBad = $false; $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal); $expectKey = ($t -eq '{') }
      $depth++; continue
    }
    if ($depth -eq 0) { break }        # the ] that ends the array
    $depth--
    if ($depth -eq 0) { [void]$bad.Add($rowBad) }
  }
  return $bad
}
# Mark the rows Get-BadRows found, so Merge-Rows leaves them unfolded. The
# mark is taken off again before the rows reach the report.
function Set-Unfoldable($rows, $text) {
  $bad = Get-BadRows $text
  for ($j = 0; $j -lt $rows.Count -and $j -lt $bad.Count; $j++) {
    if ($bad[$j] -and $rows[$j] -is [psobject]) {
      $rows[$j] | Add-Member -NotePropertyName __unfoldable -NotePropertyValue $true -Force
    }
  }
}
# The row that stands for the group: highest score, then newest date, then
# the one seen first. A missing score sits below every score, and a missing
# date before every date. A credential row has no score; a readable password
# is its score, 1 against 0, so a PLAIN row beats one that is not.
function Test-Better($sc, $d, $bestSc, $bestD) {
  if ($null -ne $sc -and $null -eq $bestSc) { return $true }
  if ($null -eq $sc -and $null -ne $bestSc) { return $false }
  if ($null -ne $sc -and $sc -ne $bestSc) { return ($sc -gt $bestSc) }
  if ($null -ne $d -and $null -eq $bestD) { return $true }
  if ($null -eq $d -and $null -ne $bestD) { return $false }
  if ($null -ne $d -and $d -ne $bestD) { return ($d -gt $bestD) }
  return $false
}
function Merge-Rows($name, $found) {
  if ($foldable -notcontains $name) { return @($found) }
  $cred = ($byAccount -contains $name)
  # Every group keeps the place of its first row, so the order the API chose
  # survives for the rows that are not folded.
  $slots = New-Object System.Collections.ArrayList
  # Ordinal, not the default hashtable: that one folds case, and the agreed
  # rule lowercases ASCII only, so a key in another script must stay itself.
  $groups = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
  foreach ($row in $found) {
    $k = if (Get-Prop $row '__unfoldable') { '' } elseif ($cred) { Get-UserKey $row } else { Get-FoldKey $row }
    if ($row -is [psobject]) { $row.PSObject.Properties.Remove('__unfoldable') }
    if ($k -eq '') { [void]$slots.Add(@{ row = $row }); continue }
    if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.ArrayList; [void]$slots.Add(@{ key = $k }) }
    [void]$groups[$k].Add($row)
  }
  $out = @()
  foreach ($s in $slots) {
    if ($s.ContainsKey('row')) { $out += $s.row; continue }
    $g = $groups[$s.key]
    if ($g.Count -lt 2) { $out += $g[0]; continue }
    $best = $null; $bestSc = $null; $bestD = $null; $first = $null; $last = $null
    # The distinct sites in the order the rows arrived: an ordered list, with
    # an ordinal set beside it saying what is already in it. A hashtable or a
    # dictionary promises no order when it is walked.
    $sites = New-Object System.Collections.ArrayList
    $siteSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($r in $g) {
      $sc = if ($cred) { Get-Plain $r } else { Get-Num (Get-Prop $r 'riskScore') }
      $d = Get-Num (Get-Prop $r 'detectionDate')
      if ($null -ne $d) {
        if ($null -eq $first -or $d -lt $first) { $first = $d }
        if ($null -eq $last -or $d -gt $last) { $last = $d }
      }
      if ($null -eq $best -or (Test-Better $sc $d $bestSc $bestD)) { $best = $r; $bestSc = $sc; $bestD = $d }
      if ($cred) { $st = Get-Site $r; if ($st -cne '' -and $siteSeen.Add($st)) { [void]$sites.Add($st) } }
    }
    # foldCount is always 2 or more; a row standing for itself carries no markers
    $best | Add-Member -NotePropertyName foldCount -NotePropertyValue ([int]$g.Count) -Force
    if ($null -ne $first) {
      $best | Add-Member -NotePropertyName foldFirst -NotePropertyValue ([long]$first) -Force
      $best | Add-Member -NotePropertyName foldLast -NotePropertyValue ([long]$last) -Force
    }
    # foldSites holds the first 8; foldSiteCount is the true count of them all
    if ($sites.Count) {
      $best | Add-Member -NotePropertyName foldSites -NotePropertyValue ([string[]]@($sites | Select-Object -First 8)) -Force
      $best | Add-Member -NotePropertyName foldSiteCount -NotePropertyValue ([int]$sites.Count) -Force
    }
    $out += $best
  }
  return @($out)
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
  $total = $null; $raw = $null; $running = $true; $o = $null
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
    # A count that is not a number is no count. The shell script reads digits
    # only and treats anything else as unknown; the same here, or a value like
    # "unknown" would be written into the report's JSON bare and break it.
    $total = $o.result.status.totalResults
    if ($null -eq (Get-Num $total)) { $total = $null }
    $running = [bool]$o.result.status.running
    if (-not $running -and $null -ne $total) { break }
  }
  # Axur's own count, kept before any recount so the report can compare it
  # with the rows that were actually in hand.
  $reported = $total
  if ($null -eq $total) { Write-Host ("  {0,-26} timed out" -f $name) }
  elseif ($running) {
    Write-Host ("  {0,-26} at least $total (still searching after ${Wait}s)" -f $name)
    $script:incomplete += $name
  }
  else { Write-Host ("  {0,-26} done: $total" -f $name) }
  # -ShowRaw used to print the reply as it arrived, so every leaked password
  # went to the console, the scrollback, and any transcript or log the console
  # was writing to. Mask them here whatever -MaskPasswords says: the point of
  # -ShowRaw is the shape of the reply, never the passwords in it.
  if ($ShowRaw) { Write-Host ("  " + (Hide-PasswordValues $raw)) }

  # E2: $raw was parsed here a second time. One parse, one object.
  $doc = $o
  # $found, not $rows: PowerShell variable names are case-insensitive, so a
  # local $rows IS the -Rows parameter. Filling it with the result rows left
  # Select-Object -First holding an array, and the run died on the first search
  # with "Cannot convert 'System.Object[]' to the type 'System.Int32'".
  $found = @(); if ($doc) { $found = @($doc.result.data) }
  if ($foldable -contains $name) { Set-Unfoldable $found $raw }

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
      Set-Unfoldable $pr $pg
      $found += $pr
      $p++
    }
  }

  $examined = $null
  if ($foldable -contains $name) { $examined = $found.Count }
  if ($anyFilter -and $filtered -contains $name -and $found.Count) {
    $kept = @($found | Where-Object { Test-Keep $_ })
    Write-Host ("  {0,-26} filtered count: $($kept.Count)" -f $name)
    $found = $kept
    $total = $kept.Count   # the tile and the table below it must agree
  }

  # Fold after the filter has counted and before -Rows cuts, so the cap counts
  # folded rows. pulled is the rows after the filter, folded the rows they
  # became. foldPartial says the fold saw only part of the result: the count
  # is unknown, the search was still running so the count is a floor, the
  # page walk stopped short, or fewer rows were examined than Axur reported -
  # which also covers a walk that ended because a page came back twice.
  $pulled = $null; $folded = $null; $foldPartial = $false
  if ($foldable -contains $name) {
    $pulled = $found.Count
    $found = @(Merge-Rows $name $found)
    $folded = $found.Count
    # the same test as fold.pl: a count that is not a number is unknown
    $repNum = Get-Num $reported
    $foldPartial = ($null -eq $repNum) -or ($script:incomplete -contains $name) -or
                   ($script:partial -contains $name) -or ($examined -lt $repNum)
  }

  $keep = @($found | Select-Object -First $Rows)
  $reply = @{ result = @{ status = @{ totalResults = $total }; data = $keep } }
  [pscustomobject]@{
    name = $name; query = $query; total = $total
    reported = $reported; examined = $examined; pulled = $pulled; folded = $folded; foldPartial = $foldPartial
    raw = ($reply | ConvertTo-Json -Depth 12 -Compress)
  }
}

Write-Host ""
Write-Host "Searching for $Brand ($Domain)"
Write-Host "-------------------------------------------"
$jobs = @(
  (Start-Search "Leaked credentials"         "credential"  "emailDomain=`"$domainQ`""),
  (Start-Search "In plaintext"               "credential"  "emailDomain=`"$domainQ`" AND passwordType=`"PLAIN`""),
  (Start-Search "Phishing pages"             "signal-lake" "impersonatedBrandsHigh=`"$brandQ`""),
  (Start-Search "Lookalike domains"          "signal-lake" "sanitizedDomainLabel=$label~1"),
  (Start-Search "Mail-enabled lookalikes"    "signal-lake" "sanitizedDomainLabel=$label~1 AND dnsRecordMX=*")
)

# now wait: they have all been running on Axur's side since they started
$results = @($jobs | ForEach-Object { Complete-Search $_ })
Write-Host "-------------------------------------------"

# The two ways a count can be short. The terminal says them at the end of the
# run; the cover has to say them too, or the customer reads a floor as a total.
$PWNOTE = if ($MaskPasswords) { "Leaked passwords are masked: first and last character at most." }
          else                { "Leaked passwords are included in full." }
$CAVEAT = ""
if ($incomplete.Count) { $CAVEAT = " Some counts were still climbing when the scan stopped, so they are a minimum." }
if ($partial.Count)    { $CAVEAT = "$CAVEAT Filtered counts cover only the rows that were pulled." }

$head = @'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Threat exposure: {{BRAND}}</title>
<!-- No web fonts. This file holds leaked passwords, and a stylesheet fetched
     from fonts.googleapis.com tells Google the moment the customer opens it,
     from which address, on which machine. The stacks below are fonts the
     reader already has. -->
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
   --sans:-apple-system,BlinkMacSystemFont,"Segoe UI","Helvetica Neue",Helvetica,Arial,sans-serif;
   --mono:ui-monospace,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
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
 /* The report is about the customer, so their mark leads. The two that made it
    sit under it, on one line: Infoblox left, Axur right. */
 .cover .top{display:flex;flex-direction:column;gap:26px;margin-bottom:56px}
 .cover .top .who{display:flex;justify-content:center}
 .cover .top .by{display:flex;align-items:center;justify-content:space-between;gap:24px;
                 border-top:1px solid #2c3640;padding-top:22px}
 .cover .top img.ax{width:230px;height:auto;display:block}
 .cover .top .nm.sm{font-size:17px}
 /* Both marks are the same height: neither company outranks the other here. */
 /* the lockup is 146x17, so width sets it; height would make it 1200px wide */
 .cover .top img.ib{height:60px;width:auto;display:block}
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
 /* the three worst rows in a scored table, called out where the eye lands */
 tbody tr.hi td{background:#fdf3f1}
 tbody tr.hi td.idx{box-shadow:inset 3px 0 0 var(--red)}
 td.idx{font-family:var(--mono);font-size:11px;color:var(--faint);text-align:right;padding-left:4px;padding-right:6px;padding-top:10px;white-space:nowrap}
 th.idx{padding-left:4px;padding-right:6px}
 .id{font-family:var(--mono);font-size:12.5px;color:var(--ink)}           /* identifiers: accounts, domains, urls */
 .id .p{color:var(--mute)}                                                  /* the path part of a url, quieter */
 .sec{display:block;font-size:12px;color:var(--mute);margin-top:2px}        /* a second line under a value */
 .date{font-family:var(--mono);font-size:12.5px;white-space:nowrap;color:var(--body);font-variant-numeric:tabular-nums}
 .date .ago{display:block;font-family:var(--sans);font-size:11.5px;color:var(--faint);white-space:normal}
 .none{color:var(--faint)}
 /* the live password: monospace so it can be read and typed back exactly,
    and breakable, because some of them are long */
 .secret{font-family:var(--mono);font-size:12.5px;color:var(--ink);
         overflow-wrap:anywhere;word-break:break-word}
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
 .foldnote{font-size:12.5px;color:var(--mute);margin:0 0 8px}                /* above a table whose fold saw only part of the result */
 /* the break between the rows that lead and the rest. It sets its own
    background because the zebra rule above would stripe it like a data row.
    break-after:avoid keeps it on the same printed page as the first row it
    introduces; tr{break-inside:avoid} alone only stops the break row itself
    splitting, and headless Chrome would leave it stranded at a page foot. */
 tbody tr.brk td{background:var(--paper);color:var(--mute);font-size:12px;font-style:italic;line-height:1.4;
                 padding:9px 10px 7px;border-top:2px solid var(--ink);border-bottom:1px solid var(--line)}
 tr.brk{break-inside:avoid;break-after:avoid}
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
   .cover .top img.ib{height:44px}
   .cover .top img.ax{width:170px}
   .cover .top img.cust{height:84px;max-width:240px}
   table{table-layout:auto}
 }

 /* =================== paper =================== */
 @media print{
   @page{size:A4;margin:15mm 13mm 16mm}
   @page cover{margin:0}
   .cover{page:cover;min-height:297mm;padding:6mm 0 4mm;break-after:page}
   .cover .wrap{padding:0 13mm}
   .cover .top{gap:8px;margin-bottom:12px}
   .cover .top .by{padding-top:9px}
   .cover .top img.ib{height:30px} .cover .top img.ax{width:132px}
   .cover .top img.cust{height:54px;max-width:190px;padding:6px 9px}
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
    <div class="who"><img class="cust" src="{{LOGO}}" alt="{{BRAND}}" referrerpolicy="origin"
         onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
         class="nm">{{BRAND}}</span></div>
    <div class="by">
      <div><img class="ib" src="{{IB}}" alt="Infoblox" referrerpolicy="origin"
           onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
           class="nm sm">Infoblox</span></div>
      <div><img class="ax" src="{{OURS}}" alt="Axur, an Infoblox company" referrerpolicy="origin"
           onerror="this.style.display='none';this.nextElementSibling.style.display='block'"><span
           class="nm sm">Axur</span></div>
    </div>
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
  <p class="key"><span><span class="dot r"></span>Red: ready to use as it stands, if it is still live.</span>
    <span><span class="dot a"></span>Amber: exposure that needs one more step first.</span></p>

  <div id="metrics"></div>

  <div class="toc" id="toc"></div>
  <p class="foot">Counts taken from one.axur.com on the scan date. They move daily. {{PWNOTE}}{{CAVEAT}}</p>
</div></div>

<div class="wrap" id="sections"></div>

<div class="wrap">
  <div class="note">
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <rect x="4" y="10.5" width="16" height="10" rx="2.4" stroke="#c9362d" stroke-width="1.7"/>
      <path d="M8 10.5V7.6a4 4 0 0 1 8 0v2.9" stroke="#c9362d" stroke-width="1.7" stroke-linecap="round"/>
    </svg>
    <div><b>This file contains live passwords</b>
      The Password column is the real one, as Axur holds it. Every account listed here should be reset.
      Send this file the way you would send the credentials themselves, and delete it when the reset is done.</div>
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
  // 70 is where this report already colours a score red, so the order and
  // the colour say the same thing from one constant; change HIGH and both
  // move together.
  var HIGH = 70;
  var HIDE = /datahubId|^id$/i;   // internal identifiers, not evidence
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
  // A repeated site is folded into one row after the rows were pulled, so a
  // fold over the first page alone is a fold over part of the result. The
  // filtering caveat on the cover is a different thing; this sits beside it.
  if (totals.some(function(t){ return Number(t.foldPartial) === 1; })) {
    var foot = document.querySelector('.cover .foot');
    if (foot) foot.appendChild(document.createTextNode(' A repeated site or account is shown as one row; where only part of a result was pulled, the "times" count and the dates cover that part only.'));
  }
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
    // The live password. esc() is what keeps a value like <img onerror=...>
    // from becoming markup in the report, so it stays even though nothing is
    // being withheld any more.
    secret: function(v){
      if (blank(v)) return none();
      return '<span class="secret">' + esc(v) + '</span>';
    },
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
      var band = x >= HIGH ? 'r' : x >= 40 ? 'a' : '';
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
  // "200 times, 04 Jan 2026 to 02 Sep 2026" under the name of a row that
  // stands for a group. A row standing for itself carries no markers and no note.
  function foldNote(r){
    var c = Number(r && r.foldCount);
    if (!(c >= 2)) return '';
    var a = dateOf(r.foldFirst), b = dateOf(r.foldLast), when = '';
    if (a && b) when = fmtDate(a) === fmtDate(b) ? fmtDate(a) : fmtDate(a) + ' to ' + fmtDate(b);
    else if (a || b) when = fmtDate(a || b);
    var note = '<span class="sec fold">' + c + ' times' + (when ? ', ' + when : '') + '</span>';
    // "6 sites: netflix.com, linkedin.com, and 4 more" under a folded account.
    // foldSites holds the first 8 sites; foldSiteCount is the count of them
    // all, so "and N more" is counted from it, never from the list's length.
    // Every name passes through esc(): it is text Axur sent, not markup.
    var sc = Number(r.foldSiteCount), sl = Array.isArray(r.foldSites) ? r.foldSites.filter(function(x){ return typeof x === 'string' && x !== ''; }) : [];
    if (sc >= 1 && sl.length) {
      var shown = sl.slice(0, 2).map(esc), more = sc - shown.length;
      note += '<span class="sec fold">' + sc + (sc === 1 ? ' site: ' : ' sites: ') + shown.join(', ') +
              (more > 0 ? ', and ' + more + ' more' : '') + '</span>';
    }
    return note;
  }
  // how many records the rows on show stand for
  function standFor(rs){ return rs.reduce(function(a, r){ var c = Number(r && r.foldCount); return a + (c >= 2 ? c : 1); }, 0); }

  /* ---------- which columns, in which order, at which width ----------
     w is the share of the table on screen, wp the share on A4 paper (both sum to 100).
     Reading order: the thing itself, then what it is for or who it pretends to be, then how bad, then when. */
  var COLS = {
    'Leaked credentials': [
      {k:'user',          h:'Account',                 f:'account', w:24, wp:20},
      {k:'password',      h:'Password',                f:'secret',  w:16, wp:16},
      {k:'passwordType',  h:'Kind',                    f:'pwd',     w:12, wp:12},
      {k:'accessHost',    h:'Password used on',        f:'site',    w:20, wp:18},
      {k:'sourceName',    h:'Where it was found',      f:'source',  w:12, wp:11},
      {k:'sourceDate',    h:'Leaked',                  f:'date',    w:8,  wp:11},
      {k:'detectionDate', h:'Found by Axur',           f:'date',    w:8,  wp:12} ],
    'In plaintext': [
      {k:'user',          h:'Account',                 f:'account', w:26, wp:24},
      {k:'password',      h:'Password',                f:'secret',  w:16, wp:15},
      {k:'accessHost',    h:'Password used on',        f:'site',    w:24, wp:20},
      {k:'sourceName',    h:'Where it was found',      f:'source',  w:15, wp:14},
      {k:'sourceDate',    h:'Leaked',                  f:'date',    w:9,  wp:13},
      {k:'detectionDate', h:'Found by Axur',           f:'date',    w:10, wp:14} ],
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
      {k:'dnsEntriesRecordMX', h:'Receives mail at',   f:'mx',      w:21, wp:22},
      {k:'domainCreationDate', h:'Registered',         f:'date',    w:13, wp:15} ],
    // this search returns page hits, so the same domain can fill the table; the page path is what tells rows apart
    'Mail-enabled lookalikes': [
      {k:'reference',     h:'Site',                    f:'site',    w:24, wp:22},
      {k:'dnsEntriesRecordMX', h:'Receives mail at',   f:'mx',      w:24, wp:24},
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
                 'Mail-enabled lookalikes':'Lookalikes set up to receive mail' };
  function heading(name){ return TITLES[name] || name; }
  var MEANS = {
    'Leaked credentials':'One row per exposed account, however many times it leaked. The row says how many times and across how many sites. "Password used on" is the site the password was for, which is often not your own, and is the site of the record the row stands for.',
    'In plaintext':'The accounts from section 01 whose password was stored in readable form. These are the ones to reset first. They are not listed again here: section 01 puts them at the top of its table.',
    'Phishing pages':'Pages Axur is highly confident are impersonating this brand. Risk runs from 0 to 100 and combines how convincing the page is with what it asks for. Some pages will already be offline; the last column shows when each was seen.',
    'Lookalike domains':'Domain names one character away from yours that somebody has registered. Registration alone is not proof of intent, and many are never used. Your own defensive registrations appear here too.',
    'Mail-enabled lookalikes':'The lookalike domains with mail records already published. The record says the domain is configured to receive mail. It does not say anyone reads it: a registrar default, a defensive registration and a working mailbox all look the same here.'
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
      big:n('Leaked credentials'), lab:'leaked records tied to your domain. An account that leaked more than once is counted every time, and shown as one row', sev:'a',
      sub:n('In plaintext'), subLab:'of them with the password in readable form, usable today', subSev:'r',
      desc:'Accounts on ' + esc(DOMAIN) + ' whose passwords have already been exposed somewhere outside your company.',
      why:'They reach Axur from three places: company breaches, dumps traded on criminal forums, and staff or customer computers infected with password-stealing malware. A row does not always say which.' },
    { icon:'mask', title:'Impersonation sites', go:sectionOf('Phishing pages'),
      big:n('Phishing pages'), lab:'web pages built to look like ' + esc(Brand), sev:'r',
      desc:'Pages built to look like you, so a customer or an employee deals with them believing they are dealing with you.',
      why:'Only pages Axur is highly confident are impersonating this brand are counted. Pages that merely mention the name are left out. What each page asks the visitor for is not part of the count; open the rows to see.' },
    { icon:'site', title:'Lookalike domains', go:sectionOf('Lookalike domains'),
      big:n('Lookalike domains'), lab:'registered names one character away from yours', sev:'a',
      sub:n('Mail-enabled lookalikes'), subLab:'of them are configured to receive mail, so a reply from one would land somewhere', subSev:'r',
      desc:'Domain names one swapped, dropped or doubled letter away from ' + esc(DOMAIN) + '. They are close enough to be mistaken for you.',
      why:'A mail record is the setup a convincing reply address needs, so this is the shorter list to look at first. It is a DNS setting, not activity: it does not show that mail has been sent, received or read.' },
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
  // Risk first, then a visible break, then date. The rows that matter should
  // be at the top of their section rather than wherever the API put them, and
  // when the table is truncated it is the worst rows that survive. Below the
  // break the rest run newest first, by the day Axur found them.
  function riskOf(r){ var v = Number(r && r.riskScore); return (r && r.riskScore !== undefined && r.riskScore !== null && r.riskScore !== '' && !isNaN(v)) ? v : null; }
  // The two searches that fold by account rather than by site.
  var CRED = {'Leaked credentials': 1, 'In plaintext': 1};
  function newestFirst(list){
    return list.slice().sort(function(a, b){
      var x = dateOf(a && a.detectionDate), y = dateOf(b && b.detectionDate);
      if (!x && !y) return 0;
      if (!x) return 1;
      if (!y) return -1;
      return y - x;
    });
  }
  // {lead, rest, why, scored}: the rows above the break, the rows below it,
  // the sentence the break carries, and whether this table was ordered by
  // score at all. An empty why means no break is drawn.
  function split(name, list){
    var lead = [], rest = [], why = '', scored = false;
    if (name === 'Leaked credentials') {
      // no score here; a readable password is the one to reset first
      var plain = function(r){ return r && String(r.passwordType || '').toUpperCase() === 'PLAIN'; };
      lead = newestFirst(list.filter(plain));
      rest = newestFirst(list.filter(function(r){ return !plain(r); }));
      why = 'Above this line: accounts whose password is readable. Below it: the rest, newest first.';
    } else if (list.some(function(r){ return riskOf(r) !== null; })) {
      scored = true;
      lead = list.filter(function(r){ return riskOf(r) !== null && riskOf(r) >= HIGH; })
                 .sort(function(a, b){ return riskOf(b) - riskOf(a); });
      rest = newestFirst(list.filter(function(r){ return riskOf(r) === null || riskOf(r) < HIGH; }));
      why = 'Above this line: risk ' + HIGH + ' or more, highest first, the point at which this report ' +
            'colours a score red. Below it: everything else, newest first.';
    } else {
      rest = newestFirst(list);
    }
    return { lead: lead, rest: rest, why: why, scored: scored };
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
        // "In plaintext" is "Leaked credentials" with a filter on it, so its rows
        // are already in the table above. Printing them twice made the reader
        // check whether the two lists differed. The count still leads the cover;
        // section 01 carries the evidence, with the readable ones at the top of
        // it and the Kind column saying which is which.
        var sp = split(t.name, rows(d));
        var rs = sp.lead.concat(sp.rest).slice(0, ROWLIMIT), total = n(t.name);
        // What survives the cut. When lead alone is longer than --rows, no
        // break is drawn and no date-ordered row is shown; the "first N of M
        // records" line below the table is what tells the reader the table
        // was cut. That is deliberate, not an oversight.
        var nlead = Math.min(sp.lead.length, rs.length), nrest = rs.length - nlead;
        if (t.name === 'In plaintext') {
          box.innerHTML = '<p class="more">These ' + show(total) + ' accounts are the readable ' +
            'ones from section 01. They are listed there, at the top of the table, marked ' +
            '<span class="flag r">Readable</span> in the Kind column. They are not repeated here.</p>';
          var c0 = secs.querySelector('.cnt[data-cnt="' + i + '"]');
          if (c0) c0.innerHTML = '<b>' + show(total) + '</b> records &middot; listed in section 01';
          return;
        }
        if (!rs.length) { box.innerHTML = '<p class="more">No records returned.</p>'; return; }
        // HIDE gates guessed columns only; COLS is curated by hand.
        var cs = COLS[t.name] || guessCols(rs).filter(function(c){ return !HIDE.test(c.k); });
        // "Back to the top" has to be reachable from any page, and the PDF has
        // no bookmark pane: Chrome writes no outline. A fixed element is painted
        // once, not per page, because the cover claims its own named page. A
        // table header is repeated on every page the table covers, so the link
        // rides in the last header cell and lands on every page of every table.
        var ths = cs.map(function(c){ return '<th>' + c.h + '</th>'; });
        ths[ths.length - 1] = ths[ths.length - 1]
          .replace('</th>', '<a class="totop" href="#top">&uarr; Top</a></th>');
        // What the rows on screen stand for, and whether this SEARCH folded
        // anything. The second question is not the first: a lone row can sort
        // to the top and a small --rows can cut the table before the folded
        // group, and the section would then fall back to counting raw records
        // as though they were rows, which is the confusion this feature exists
        // to remove. Ask the search's own numbers.
        var stand = standFor(rs), folded = Number(t.folded) < Number(t.pulled);
        // The fold ran over the rows in hand. When that is fewer than the
        // total, the counts and dates in the rows cover those records only,
        // and the reader is told so here, above the table they are about.
        var html = '';
        if (Number(t.foldPartial) === 1) {
          // examined is what was pulled from Axur and compared with its count;
          // pulled is what survived the filter, and is all the fold ever saw.
          var rep = Number(t.reported), ex = Number(t.examined), pu = Number(t.pulled), fo = Number(t.folded);
          html += '<p class="foldnote">' +
            (isNaN(rep) || t.reported === null ? 'Axur did not give a count for this search; ' + show(ex) + ' records were pulled'
                                               : 'Axur reports ' + show(rep) + ' records; ' + show(ex) + ' of them were pulled') +
            (ex === pu ? ' and folded into ' + show(fo) + ' rows. '
                       : ', and the filter kept ' + show(pu) + '. Those ' + show(pu) + ' folded into ' + show(fo) + ' rows. ') +
            'The "times" counts and dates cover those ' + show(pu) + ' records only; more may exist.</p>';
        }
        html += '<table><colgroup><col style="--w:4%">' +
          cs.map(function(c){ return '<col style="--w:' + (c.w * 0.96).toFixed(1) + '%;--wp:' + ((c.wp || c.w) * 0.96).toFixed(1) + '%">'; }).join('') +
          '</colgroup><thead><tr><th class="idx">#</th>' + ths.join('') + '</tr></thead><tbody>';
        rs.forEach(function(r, ri){
          // The break sits after the last lead row, and needs a row on both
          // sides of it. A table where nothing reaches the cut-off has a why
          // but no lead row, and without the nlead test the break was drawn at
          // the very top with nothing above it, announcing a division that was
          // not there.
          if (ri === nlead && sp.why && nlead > 0 && nrest > 0) {
            html += '<tr class="brk"><td colspan="' + (cs.length + 1) + '">' + sp.why + '</td></tr>';
          }
          // The mark is red, and red in this report means a high score. It
          // belongs to a table ordered by score, not to a row that happens to
          // carry a number: the credentials table leads on readable passwords,
          // and a score arriving on one of its rows must not paint it red.
          html += '<tr' + (ri < 3 && ri < nlead && sp.scored ? ' class="hi"' : '') +
            '><td class="idx">' + (ri + 1) + '</td>' +
            cs.map(function(c, ci){ return '<td>' + cell(c.f, r[c.k], r) + (ci === 0 ? foldNote(r) : '') + '</td>'; }).join('') + '</tr>';
        });
        // A folded row stands for more than itself, so "first N of M records"
        // would undercount what is on show. Say the rows, what they stand for, and the total.
        var line;
        if (folded) {
          line = rs.length + ' rows, standing for ' +
            (total === null ? show(stand) + ' records; the total count was not available.'
                            : (stand < total ? show(stand) + ' of ' + show(total) + ' records.' : 'all ' + show(total) + ' records.')) +
            // The credential searches fold by account, the rest by site, so the
            // sentence has to name the thing this table actually folded.
            (CRED[t.name] ? ' An account seen more than once is one row, and the row says how many times and where.'
                          : ' A site seen more than once is one row, and the row says how many times.');
        } else {
          line = total === null ? 'Showing ' + rs.length + ' records; the total count was not available.'
                                : (rs.length < total ? 'The first ' + rs.length + ' of ' + show(total) + ' records.' : 'All ' + show(total) + ' records.');
        }
        html += '</tbody></table><p class="more">' + line +
          ' "Found by Axur" is the day the record reached Axur, which can be long after the event itself.</p>';
        box.innerHTML = html;
        var cnt = secs.querySelector('.cnt[data-cnt="' + i + '"]');
        if (cnt) cnt.innerHTML = '<b>' + show(total) + '</b> records &middot; ' +
          (folded ? rs.length + ' rows shown, standing for ' + show(stand)
                  : (total !== null && rs.length < total ? 'first ' + rs.length + ' shown' : 'all shown'));
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
              Replace('{{IB}}', (ConvertTo-HtmlText $ibData)).
              Replace('{{DATE_ISO}}',   $now.ToString('yyyy-MM-dd')).
              Replace('{{DATE_LONG}}',  $now.ToString('dd MMMM yyyy')).
              Replace('{{DATE_SHORT}}', $now.ToString('dd MMM yyyy')).
              Replace('{{CAVEAT}}', (ConvertTo-HtmlText $CAVEAT)).
              Replace('{{PWNOTE}}', (ConvertTo-HtmlText $PWNOTE))
$tail = $tail.Replace('ROWSVALUE', "$Rows")

# The files about to be written hold the customer's leaked passwords in full.
# Left to the folder's inherited rights they are readable by everyone the
# folder is shared with. Strip the inheritance and leave one entry: this user.
function Protect-File($path) {
  try {
    if ($IsLinux -or $IsMacOS) { & chmod 600 $path 2>$null | Out-Null; return }
    $acl = Get-Acl -LiteralPath $path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
      $me, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $path -AclObject $acl
  } catch {
    Write-Host "Warning: could not restrict who can read $path. It holds leaked passwords."
  }
}

function Esc($s) { ($s -replace '\\', '\\' -replace '"', '\"') }

# The headline record of one search, without its closing brace: the totals
# block prints it alone, the payload prints it with the reply behind it.
# total is not the last field, so the report cuts the record at "reply".
function Get-HeadJson($r) {
  $h = '{"name":"' + (Esc $r.name) + '","query":"' + (Esc $r.query) + '","total":' +
       $(if ($null -eq $r.total) { 'null' } else { "$($r.total)" })
  if ($null -ne $r.examined) {
    $h += ',"reported":' + $(if ($null -eq $r.reported) { 'null' } else { "$($r.reported)" }) +
          ',"examined":' + $r.examined + ',"pulled":' + $r.pulled + ',"folded":' + $r.folded
  }
  if ($r.foldPartial) { $h += ',"foldPartial":1' }
  return $h
}

$totals = ($results | ForEach-Object { (Get-HeadJson $_) + '}' }) -join ",`n"

# One block per search, not one array holding all five. A single malformed
# reply used to fail the one JSON.parse that fed every table, so one bad reply
# emptied the whole report. Now it costs only its own table.
$i = 0
$payload = ($results | ForEach-Object {
  $i++
  '<script type="application/json" id="payload-' + $i + '">' +
  (Get-HeadJson $_) + ',"reply":' +
  (Hide-Passwords ($_.raw -replace '</', '<\/')) + '}</script>'
}) -join "`n"

Write-Host -NoNewline "Writing the report "
$doc = $head + "`n" +
       '<script type="application/json" id="totals">[' + "`n" + $totals + "`n" + ']</script>' + "`n" +
       $tail + "`n" +
       $payload + "`n" +
       '</main></body></html>'
# Create the file empty and locked down before the passwords go into it, so
# there is no moment where it exists with the folder's wider rights.
[IO.File]::WriteAllText($Out, '', (New-Object Text.UTF8Encoding $false))
Protect-File $Out
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
    if (Test-Path $pdf) { Protect-File $pdf; Write-Host " ... wrote $pdf"; $done = $pdf; $pdfWritten = $pdf }
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
