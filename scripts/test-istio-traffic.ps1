#!/usr/bin/env pwsh
# Test Istio traffic routing for canary deployment

param(
    [int]$Requests = 100,
    [string]$Host = "localhost",
    [int]$Port = 90
)

Write-Host "🧪 Testing Istio traffic routing..." -ForegroundColor Green
Write-Host "Target: http://${Host}:${Port}" -ForegroundColor Cyan
Write-Host "Requests: $Requests" -ForegroundColor Cyan
Write-Host ""

# Check if curl is available
if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
    Write-Host "❌ curl not found. Please install curl first." -ForegroundColor Red
    exit 1
}

# Get Istio ingress gateway info if using defaults
if ($Host -eq "localhost") {
    Write-Host "🔍 Detecting Istio ingress gateway..." -ForegroundColor Yellow
    
    $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    if (-not $ingressHost) {
        $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
    }
    
    if ($ingressHost) {
        $Host = $ingressHost
        Write-Host "✅ Found ingress host: $Host" -ForegroundColor Green
    } else {
        Write-Host "⚠️  No external LoadBalancer found. Using port-forward..." -ForegroundColor Yellow
        Write-Host "Run in another terminal: kubectl port-forward -n istio-system service/istio-ingressgateway 8090:90" -ForegroundColor Yellow
        $Host = "localhost"
        $Port = 8090
    }
}

$url = "http://${Host}:${Port}/"

# Test 1: Regular traffic distribution
Write-Host "📊 Test 1: Regular traffic distribution (should be ~80% stable, ~20% canary)" -ForegroundColor Yellow

$stableCount = 0
$canaryCount = 0
$errorCount = 0

for ($i = 1; $i -le $Requests; $i++) {
    try {
        $response = curl -s -w "%{http_code}" $url 2>$null
        if ($response -match "v1\.0") {
            $stableCount++
        } elseif ($response -match "v2\.0") {
            $canaryCount++
        } else {
            $errorCount++
        }
        
        if ($i % 10 -eq 0) {
            Write-Host "." -NoNewline
        }
    } catch {
        $errorCount++
    }
}

Write-Host ""
Write-Host "Results:" -ForegroundColor Cyan
Write-Host "  Stable (v1.0): $stableCount ($([math]::Round($stableCount/$Requests*100, 1))%)" -ForegroundColor Green
Write-Host "  Canary (v2.0): $canaryCount ($([math]::Round($canaryCount/$Requests*100, 1))%)" -ForegroundColor Blue
Write-Host "  Errors: $errorCount ($([math]::Round($errorCount/$Requests*100, 1))%)" -ForegroundColor Red
Write-Host ""

# Test 2: Header-based canary routing
Write-Host "📊 Test 2: Header-based canary routing (should be 100% canary)" -ForegroundColor Yellow

$canaryHeaderCount = 0
$errorHeaderCount = 0

for ($i = 1; $i -le 10; $i++) {
    try {
        $response = curl -s -H "canary: true" $url 2>$null
        if ($response -match "v2\.0") {
            $canaryHeaderCount++
        } else {
            $errorHeaderCount++
        }
    } catch {
        $errorHeaderCount++
    }
}

Write-Host "Results with 'canary: true' header:" -ForegroundColor Cyan
Write-Host "  Canary (v2.0): $canaryHeaderCount/10 ($($canaryHeaderCount*10)%)" -ForegroundColor Blue
Write-Host "  Errors: $errorHeaderCount/10 ($($errorHeaderCount*10)%)" -ForegroundColor Red
Write-Host ""

# Test 3: Response time analysis
Write-Host "📊 Test 3: Response time analysis" -ForegroundColor Yellow

$responseTimes = @()
for ($i = 1; $i -le 10; $i++) {
    try {
        $time = curl -s -w "%{time_total}" -o /dev/null $url 2>$null
        $responseTimes += [double]$time
    } catch {
        Write-Host "Request $i failed" -ForegroundColor Red
    }
}

if ($responseTimes.Count -gt 0) {
    $avgTime = ($responseTimes | Measure-Object -Average).Average
    $maxTime = ($responseTimes | Measure-Object -Maximum).Maximum
    $minTime = ($responseTimes | Measure-Object -Minimum).Minimum
    
    Write-Host "Response times:" -ForegroundColor Cyan
    Write-Host "  Average: $([math]::Round($avgTime*1000, 2))ms" -ForegroundColor White
    Write-Host "  Min: $([math]::Round($minTime*1000, 2))ms" -ForegroundColor White
    Write-Host "  Max: $([math]::Round($maxTime*1000, 2))ms" -ForegroundColor White
}

Write-Host ""

# Istio configuration check
Write-Host "🔍 Istio Configuration Status:" -ForegroundColor Yellow

try {
    $gateway = kubectl get gateway simple-app-gateway -n canary-demo -o jsonpath='{.metadata.name}' 2>$null
    $virtualservice = kubectl get virtualservice simple-app-vs -n canary-demo -o jsonpath='{.metadata.name}' 2>$null
    $destinationrule = kubectl get destinationrule simple-app-dr -n canary-demo -o jsonpath='{.metadata.name}' 2>$null
    
    Write-Host "  Gateway: $(if($gateway) { '✅ ' + $gateway } else { '❌ Not found' })" -ForegroundColor $(if($gateway) { 'Green' } else { 'Red' })
    Write-Host "  VirtualService: $(if($virtualservice) { '✅ ' + $virtualservice } else { '❌ Not found' })" -ForegroundColor $(if($virtualservice) { 'Green' } else { 'Red' })
    Write-Host "  DestinationRule: $(if($destinationrule) { '✅ ' + $destinationrule } else { '❌ Not found' })" -ForegroundColor $(if($destinationrule) { 'Green' } else { 'Red' })
} catch {
    Write-Host "  ❌ Error checking Istio configuration" -ForegroundColor Red
}

Write-Host ""
Write-Host "🎯 Summary:" -ForegroundColor Green
if ($stableCount + $canaryCount -gt 0) {
    $actualStablePercent = [math]::Round($stableCount/($stableCount + $canaryCount)*100, 1)
    $actualCanaryPercent = [math]::Round($canaryCount/($stableCount + $canaryCount)*100, 1)
    
    Write-Host "  Traffic Distribution: ${actualStablePercent}% stable, ${actualCanaryPercent}% canary" -ForegroundColor White
    
    if ($actualStablePercent -ge 70 -and $actualStablePercent -le 90 -and $actualCanaryPercent -ge 10 -and $actualCanaryPercent -le 30) {
        Write-Host "  ✅ Traffic distribution is within expected range (80/20 ±10%)" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Traffic distribution outside expected range" -ForegroundColor Yellow
    }
}

if ($canaryHeaderCount -eq 10) {
    Write-Host "  ✅ Header-based routing working correctly" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  Header-based routing may have issues" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "💡 Tips:" -ForegroundColor Cyan
Write-Host "  - Adjust traffic weights in k8s/istio-virtualservice.yaml" -ForegroundColor White
Write-Host "  - Monitor with: kubectl get virtualservice simple-app-vs -n canary-demo -o yaml" -ForegroundColor White
Write-Host "  - Check Istio proxy logs: kubectl logs -n canary-demo -l app=simple-app -c istio-proxy" -ForegroundColor White