$stableCount = 0
$canaryCount = 0

Write-Host "Testing Istio traffic distribution..." -ForegroundColor Yellow

for ($i = 1; $i -le 20; $i++) {
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "PowerShell-Test-$i")
        $response = $webClient.DownloadString("http://localhost/")
        $webClient.Dispose()
        
        if ($response -match '"version":"v1.0"') {
            $stableCount++
            Write-Host "S" -NoNewline -ForegroundColor Green
        } elseif ($response -match '"version":"v2.0"') {
            $canaryCount++
            Write-Host "C" -NoNewline -ForegroundColor Blue
        }
        
        Start-Sleep -Milliseconds 200
    } catch {
        Write-Host "X" -NoNewline -ForegroundColor Red
    }
}

Write-Host ""
Write-Host ""
Write-Host "Results:" -ForegroundColor Cyan
Write-Host "  Stable (v1.0): $stableCount" -ForegroundColor Green
Write-Host "  Canary (v2.0): $canaryCount" -ForegroundColor Blue

Write-Host ""
Write-Host "Testing header-based routing..." -ForegroundColor Yellow

$webClient = New-Object System.Net.WebClient
$webClient.Headers.Add("canary", "true")
$response = $webClient.DownloadString("http://localhost/")
$webClient.Dispose()

if ($response -match '"version":"v2.0"') {
    Write-Host "Header routing: SUCCESS - Got canary version" -ForegroundColor Green
} else {
    Write-Host "Header routing: FAILED" -ForegroundColor Red
}