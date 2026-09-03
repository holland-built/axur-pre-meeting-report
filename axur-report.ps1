param([Parameter(Mandatory=$true)][string]$ApiKey, [switch]$ShowRaw)
# Axur pre-meeting report.
#   powershell -ExecutionPolicy Bypass -File axur-report.ps1 YOUR_API_KEY
#   leave the key off and it will ask for it
#   add -ShowRaw to see the replies
$brand  = "BRAND"
$domain = "customer.com"
$label  = "brand"
$api = "https://api.axur.com/gateway/1.0/api/threat-hunting-api/external"
$headers = @{ Authorization = "Bearer $ApiKey" }

function Invoke-Search($name, $source, $query) {
  Write-Host ("{0,-22}" -f $name) -NoNewline
  $body = @{ query = $query; source = $source } | ConvertTo-Json -Compress
  $start = $null; $attempt = 0
  while ($true) {
    try {
      $start = Invoke-RestMethod -Method Post -Uri "$api/search" -Headers $headers -ContentType "application/json" -Body $body
      if ($ShowRaw) { Write-Host ""; Write-Host "  start reply: $($start | ConvertTo-Json -Compress)" }
      break
    } catch {
      $c = $null
      if ($_.Exception.Response) { $c = [int]$_.Exception.Response.StatusCode }
      # the gateway allows 30 calls a window, so wait it out rather than failing
      if ($c -eq 429 -and $attempt -lt 3) { $attempt++; Write-Host "w" -NoNewline; Start-Sleep -Seconds 25; continue }
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      switch ($c) {
        401 { Write-Host " key rejected (401). Generate a new one in My preferences." }
        403 { Write-Host " no access to this tenant (403)" }
        429 { Write-Host " still rate limited after waiting. Try again in a minute." }
        default { Write-Host " could not start (HTTP $c) $($_.Exception.Message)" }
      }
      return
    }
  }
  $id = $start.searchId
  $total = $null
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 2
    Write-Host "." -NoNewline
    try { $r = Invoke-RestMethod -Uri "$api/search/${id}?page=1" -Headers $headers } catch { continue }
    if ($ShowRaw) { Write-Host ""; Write-Host "  poll reply: $($r.result.status | ConvertTo-Json -Compress)" }
    $total = $r.result.status.totalResults
    if ($null -ne $total) { break }
  }
  if ($null -eq $total) { Write-Host " timed out" } else { Write-Host " $total" }
}

Write-Host ""
Write-Host "Axur pre-meeting report: $brand"
Write-Host "-------------------------------------------"
Invoke-Search "Leaked credentials" "credential"  "emailDomain=`"$domain`""
Invoke-Search "In plaintext"       "credential"  "emailDomain=`"$domain`" AND passwordType=`"PLAIN`""
Invoke-Search "Phishing pages"     "signal-lake" "impersonatedBrandsHigh=`"$brand`""
Invoke-Search "Lookalike domains"  "signal-lake" "sanitizedDomainLabel=$label~1"
Invoke-Search "Can send mail"      "signal-lake" "domainLabel=$label~1 AND dnsRecordMX=*"
Write-Host "-------------------------------------------"
Write-Host "Attack surface: one.axur.com/easm, Exposures, Download all"
Write-Host ""
