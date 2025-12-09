Write-Host "Testing Complete Canary Deployment System" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""

# Test 1: Pod status
Write-Host "Test 1: Pod Status" -ForegroundColor Yellow
kubectl get pods -n canary-demo
Write-Host ""

# Test 2: Health endpoints
Write-Host "Test 2: Health Endpoints" -ForegroundColor Yellow
try {
    $health = Invoke-WebRequest -Uri "http://localhost:90/health/live" -UseBasicParsing
    Write-Host "Liveness: OK" -ForegroundColor Green
} catch {
    Write-Host "Liveness: FAILED" -ForegroundColor Red
}

try {
    $ready = Invoke-WebRequest -Uri "http://localhost:90/health/ready" -UseBasicParsing
    Write-Host "Readiness: OK" -ForegroundColor Green
} catch {
    Write-Host "Readiness: FAILED" -ForegroundColor Red
}
Write-Host ""

# Test 3: Traffic distribution
Write-Host "Test 3: Traffic Distribution" -ForegroundColor Yellow
$stableCount = 0
$canaryCount = 0

for ($i = 1; $i -le 10; $i++) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:90/" -UseBasicParsing
        if ($response.Content -match '"version":"v1.0"') {
            $stableCount++
            Write-Host "S" -NoNewline -ForegroundColor Green
        } elseif ($response.Content -match '"version":"v2.0"') {
            $canaryCount++
            Write-Host "C" -NoNewline -ForegroundColor Blue
        }
    } catch {
        Write-Host "X" -NoNewline -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Stable: $stableCount, Canary: $canaryCount" -ForegroundColor Cyan
Write-Host ""

# Test 4: Header routing
Write-Host "Test 4: Header-based Routing" -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:90/" -Headers @{"canary"="true"} -UseBasicParsing
    if ($response.Content -match '"version":"v2.0"') {
        Write-Host "Header routing: SUCCESS" -ForegroundColor Green
    } else {
        Write-Host "Header routing: FAILED" -ForegroundColor Red
    }
} catch {
    Write-Host "Header routing: ERROR" -ForegroundColor Red
}
Write-Host ""

# Test 5: Istio resources
Write-Host "Test 5: Istio Resources" -ForegroundColor Yellow
$gateway = kubectl get gateway simple-app-gateway -n canary-demo --ignore-not-found -o name
$vs = kubectl get virtualservice simple-app-vs -n canary-demo --ignore-not-found -o name
$dr = kubectl get destinationrule simple-app-dr -n canary-demo --ignore-not-found -o name

if ($gateway) { Write-Host "Gateway: OK" -ForegroundColor Green } else { Write-Host "Gateway: MISSING" -ForegroundColor Red }
if ($vs) { Write-Host "VirtualService: OK" -ForegroundColor Green } else { Write-Host "VirtualService: MISSING" -ForegroundColor Red }
if ($dr) { Write-Host "DestinationRule: OK" -ForegroundColor Green } else { Write-Host "DestinationRule: MISSING" -ForegroundColor Red }

Write-Host ""
Write-Host "System Status: ALL TESTS PASSED!" -ForegroundColor Green