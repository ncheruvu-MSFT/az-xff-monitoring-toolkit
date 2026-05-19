# Live test against the deployed Azure App Service
$ErrorActionPreference = 'Stop'
$base = 'https://app-xff-net47-cg4l2wl4myrww.azurewebsites.net'

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

Write-Host "=== Sending $($tests.Count) requests to $base ===" -ForegroundColor Cyan
foreach ($t in $tests) {
  $r = Invoke-WebRequest -Uri "$base/Default.aspx" -Headers $t.Headers -UseBasicParsing -TimeoutSec 60
  Write-Host ("  {0,-25} -> HTTP {1}" -f $t.Name, $r.StatusCode)
}

Write-Host ""
Write-Host "=== Reports.aspx?format=json ===" -ForegroundColor Cyan
$json = Invoke-RestMethod -Uri "$base/Reports.aspx?format=json" -UseBasicParsing -TimeoutSec 60
Write-Host "Captured entries: $($json.Count)"
$json | Select-Object @{N='Time';E={$_.TimestampUtc.Substring(11,8)}}, RemoteAddr, XForwardedFor, XRealClientIp, XAzureClientIp, ResolvedClientIp | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Assertions ===" -ForegroundColor Cyan
$pass = 0; $fail = 0
function Assert($name, $cond) {
  if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
  else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;  $script:fail++ }
}
Assert "At least 8 entries captured"               ($json.Count -ge 8)
Assert "Single-hop resolves to 203.0.113.7 (left-most)" (($json | Where-Object { $_.XForwardedFor -like '203.0.113.7,*' } | Select-Object -First 1).ResolvedClientIp -eq '203.0.113.7')
Assert "Multi-hop picks left-most (198.51.100.10)" (($json | Where-Object { $_.XForwardedFor -like '198.51.100.10*' }).ResolvedClientIp -eq '198.51.100.10')
Assert "X-Real-Client-IP captured"                 (($json | Where-Object { $_.XRealClientIp -eq '203.0.113.42' }).Count -ge 1)
Assert "X-Azure-ClientIP captured when sent"       (($json | Where-Object { $_.XAzureClientIp -eq '192.0.2.55' }).Count -ge 1)
Assert "IPv4 port stripped (203.0.113.99)"         (($json | Where-Object { $_.XForwardedFor -like '203.0.113.99:51514*' }).ResolvedClientIp -eq '203.0.113.99')
Assert "Repeat client appears >=3 times"           (($json | Where-Object { $_.ResolvedClientIp -eq '203.0.113.7' }).Count -ge 3)
Assert "App Service appends its IP to XFF chain"   (($json | Where-Object { $_.XForwardedFor -match '20\.\d+\.\d+\.\d+:\d+' }).Count -ge ($json.Count - 1))
Assert "RemoteAddr is App Service load-balancer IP" (($json | Where-Object { $_.RemoteAddr -match '^20\.' }).Count -ge ($json.Count - 1))

Write-Host ""
Write-Host ("Passed: {0}  Failed: {1}" -f $pass, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
Write-Host "Live URLs:" -ForegroundColor Cyan
Write-Host "  $base/Default.aspx"
Write-Host "  $base/Reports.aspx"
Write-Host "  $base/Reports.aspx?format=json"
Write-Host "  $base/Reports.aspx?format=csv"
if ($fail -gt 0) { exit 1 }
