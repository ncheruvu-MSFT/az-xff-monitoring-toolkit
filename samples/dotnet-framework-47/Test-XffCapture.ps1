# Test script: send varied XFF requests and verify Reports
$ErrorActionPreference = 'Stop'
$base = 'http://localhost:8088'

$tests = @(
  @{ Name = 'No XFF';                Headers = @{} }
  @{ Name = 'Single hop';            Headers = @{ 'X-Forwarded-For' = '203.0.113.7' } }
  @{ Name = 'Multi-hop chain';       Headers = @{ 'X-Forwarded-For' = '198.51.100.10, 10.0.1.5, 10.0.0.4' } }
  @{ Name = 'With APIM real-client'; Headers = @{ 'X-Forwarded-For' = '203.0.113.42, 10.0.0.4'; 'X-Real-Client-IP' = '203.0.113.42' } }
  @{ Name = 'Azure front-end';       Headers = @{ 'X-Forwarded-For' = '192.0.2.55'; 'X-Azure-ClientIP' = '192.0.2.55'; 'X-Azure-SocketIP' = '192.0.2.55' } }
  @{ Name = 'IPv4 with port';        Headers = @{ 'X-Forwarded-For' = '203.0.113.99:51514, 10.0.0.4' } }
  @{ Name = 'Repeat known client';   Headers = @{ 'X-Forwarded-For' = '203.0.113.7' } }
  @{ Name = 'Repeat known client 2'; Headers = @{ 'X-Forwarded-For' = '203.0.113.7' } }
)

Write-Host "=== Sending $($tests.Count) requests ===" -ForegroundColor Cyan
foreach ($t in $tests) {
  $r = Invoke-WebRequest -Uri "$base/Default.aspx" -Headers $t.Headers -UseBasicParsing -TimeoutSec 30
  Write-Host ("  {0,-25} -> HTTP {1}" -f $t.Name, $r.StatusCode)
}

Write-Host ""
Write-Host "=== Reports.aspx?format=json ===" -ForegroundColor Cyan
$json = Invoke-RestMethod -Uri "$base/Reports.aspx?format=json" -UseBasicParsing -TimeoutSec 30
Write-Host "Captured entries: $($json.Count)"
$json | Select-Object @{N='Time';E={$_.TimestampUtc.Substring(11,8)}}, XForwardedFor, XRealClientIp, XAzureClientIp, ResolvedClientIp | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Assertions ===" -ForegroundColor Cyan
$pass = 0; $fail = 0
function Assert($name, $cond) {
  if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
  else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;  $script:fail++ }
}

Assert "At least 8 entries captured"          ($json.Count -ge 8)
Assert "Single-hop resolves to 203.0.113.7"   (($json | Where-Object { $_.XForwardedFor -eq '203.0.113.7' } | Select-Object -First 1).ResolvedClientIp -eq '203.0.113.7')
Assert "Multi-hop picks left-most (198.51.100.10)" (($json | Where-Object { $_.XForwardedFor -like '198.51.100.10*' }).ResolvedClientIp -eq '198.51.100.10')
Assert "X-Real-Client-IP captured"            (($json | Where-Object { $_.XRealClientIp -eq '203.0.113.42' }).Count -ge 1)
Assert "X-Azure-ClientIP captured"            (($json | Where-Object { $_.XAzureClientIp -eq '192.0.2.55' }).Count -ge 1)
Assert "IPv4 port stripped (203.0.113.99)"    (($json | Where-Object { $_.XForwardedFor -like '203.0.113.99:51514*' }).ResolvedClientIp -eq '203.0.113.99')
Assert "Repeat client appears >=3 times"      (($json | Where-Object { $_.ResolvedClientIp -eq '203.0.113.7' }).Count -ge 3)

Write-Host ""
Write-Host "=== CSV export ===" -ForegroundColor Cyan
$csv = Invoke-WebRequest -Uri "$base/Reports.aspx?format=csv" -UseBasicParsing -TimeoutSec 30
$csvLines = $csv.Content -split "`n" | Where-Object { $_.Trim() }
Write-Host "CSV lines: $($csvLines.Count) (header + $($csvLines.Count - 1) rows)"
Write-Host "Header: $($csvLines[0])"
Assert "CSV has expected columns" ($csvLines[0] -match 'XForwardedFor.*ResolvedClientIp')

Write-Host ""
Write-Host "=== HTML report ===" -ForegroundColor Cyan
$html = (Invoke-WebRequest -Uri "$base/Reports.aspx" -UseBasicParsing -TimeoutSec 30).Content
Assert "HTML report contains 203.0.113.7"     ($html -match '203\.0\.113\.7')
Assert "HTML report contains 198.51.100.10"   ($html -match '198\.51\.100\.10')
Assert "HTML report contains 'Top Resolved'"  ($html -match 'Top Resolved Client IPs')

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ("  Passed: {0}" -f $pass) -ForegroundColor Green
Write-Host ("  Failed: {0}" -f $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
