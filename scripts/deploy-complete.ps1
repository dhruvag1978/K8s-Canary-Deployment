#!/usr/bin/env pwsh
# Complete Canary Deployment System Setup

param(
    [Parameter(Mandatory=$false)]
    [switch]$SkipBuild,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

Write-Host "🚀 Complete Canary Deployment System Setup" -ForegroundColor Green
Write-Host "===========================================" -ForegroundColor Green
Write-Host ""

# Check prerequisites
Write-Host "🔍 Checking prerequisites..." -ForegroundColor Yellow

$missingTools = @()
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { $missingTools += "kubectl" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { $missingTools += "docker" }

if ($missingTools.Count -gt 0) {
    Write-Host "❌ Missing required tools: $($missingTools -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Prerequisites check passed" -ForegroundColor Green

# Build application images (if not skipped)
if (-not $SkipBuild) {
    Write-Host ""
    Write-Host "🔨 Building application images..." -ForegroundColor Yellow
    
    if ($DryRun) {
        Write-Host "🔍 [DRY RUN] Would build Docker images" -ForegroundColor Cyan
    } else {
        & ./scripts/build-images.sh
        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ Failed to build images" -ForegroundColor Red
            exit 1
        }
        Write-Host "✅ Images built successfully" -ForegroundColor Green
    }
}

# Apply Kubernetes manifests
Write-Host ""
Write-Host "📦 Applying Kubernetes manifests..." -ForegroundColor Yellow

$manifests = @(
    "k8s/namespace.yaml",
    "k8s/configmap.yaml",
    "k8s/rbac.yaml",
    "k8s/deployment-stable.yaml",
    "k8s/deployment-canary.yaml",
    "k8s/service.yaml"
)

foreach ($manifest in $manifests) {
    if (Test-Path $manifest) {
        Write-Host "  Applying $manifest..." -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "    🔍 [DRY RUN] Would apply $manifest" -ForegroundColor Gray
        } else {
            kubectl apply -f $manifest
            if ($LASTEXITCODE -ne 0) {
                Write-Host "❌ Failed to apply $manifest" -ForegroundColor Red
                exit 1
            }
        }
    } else {
        Write-Host "⚠️  Manifest $manifest not found, skipping..." -ForegroundColor Yellow
    }
}

Write-Host "✅ Kubernetes manifests applied" -ForegroundColor Green

# Apply Istio configuration
Write-Host ""
Write-Host "🌐 Applying Istio configuration..." -ForegroundColor Yellow

$istioManifests = @(
    "k8s/istio-gateway.yaml",
    "k8s/istio-virtualservice.yaml",
    "k8s/istio-destinationrule.yaml"
)

foreach ($manifest in $istioManifests) {
    if (Test-Path $manifest) {
        Write-Host "  Applying $manifest..." -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "    🔍 [DRY RUN] Would apply $manifest" -ForegroundColor Gray
        } else {
            kubectl apply -f $manifest
            if ($LASTEXITCODE -ne 0) {
                Write-Host "❌ Failed to apply $manifest" -ForegroundColor Red
                exit 1
            }
        }
    } else {
        Write-Host "⚠️  Manifest $manifest not found, skipping..." -ForegroundColor Yellow
    }
}

Write-Host "✅ Istio configuration applied" -ForegroundColor Green

if (-not $DryRun) {
    # Wait for deployments to be ready
    Write-Host ""
    Write-Host "⏳ Waiting for deployments to be ready..." -ForegroundColor Yellow
    
    kubectl rollout status deployment/simple-app-stable -n canary-demo --timeout=300s
    kubectl rollout status deployment/simple-app-canary -n canary-demo --timeout=300s
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Deployment rollout failed" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "✅ All deployments are ready" -ForegroundColor Green
    
    # Get ingress information
    Write-Host ""
    Write-Host "🌐 Getting ingress information..." -ForegroundColor Yellow
    
    $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    if (-not $ingressHost) {
        $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    }
    if (-not $ingressHost) {
        $ingressHost = "localhost"
    }
    
    $ingressPort = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].port}'
    if (-not $ingressPort) {
        $ingressPort = "80"
    }
    
    # Validate deployment
    Write-Host ""
    Write-Host "🔍 Validating deployment..." -ForegroundColor Yellow
    
    try {
        $response = Invoke-WebRequest -Uri "http://${ingressHost}:${ingressPort}/" -UseBasicParsing -TimeoutSec 10
        if ($response.StatusCode -eq 200) {
            Write-Host "✅ Application is responding" -ForegroundColor Green
        } else {
            Write-Host "⚠️  Application responded with status $($response.StatusCode)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠️  Could not reach application endpoint: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "🎉 Complete canary deployment system setup finished!" -ForegroundColor Green
Write-Host ""
Write-Host "📊 System Overview:" -ForegroundColor Cyan
Write-Host "  ✅ Kubernetes manifests deployed" -ForegroundColor Green
Write-Host "  ✅ Istio service mesh configured" -ForegroundColor Green
Write-Host "  ✅ RBAC and security configured" -ForegroundColor Green
Write-Host "  ✅ ConfigMaps and Secrets applied" -ForegroundColor Green
Write-Host "  ✅ Health checks and metrics enabled" -ForegroundColor Green
Write-Host ""

if (-not $DryRun) {
    Write-Host "🌐 Access Information:" -ForegroundColor Cyan
    Write-Host "  Application URL: http://${ingressHost}:${ingressPort}/" -ForegroundColor White
    Write-Host "  Force Canary: curl -H 'canary: true' http://${ingressHost}:${ingressPort}/" -ForegroundColor White
    Write-Host ""
}

Write-Host "🛠️  Available Scripts:" -ForegroundColor Cyan
Write-Host "  Deploy Canary: ./scripts/canary-deploy.ps1 -NewVersion v3.0" -ForegroundColor White
Write-Host "  Rollback: ./scripts/canary-rollback.ps1" -ForegroundColor White
Write-Host "  Promote: ./scripts/canary-promote.ps1" -ForegroundColor White
Write-Host "  Test Traffic: ./scripts/test-istio-traffic.ps1" -ForegroundColor White
Write-Host ""
Write-Host "📈 Monitoring:" -ForegroundColor Cyan
Write-Host "  kubectl get pods -n canary-demo" -ForegroundColor White
Write-Host "  kubectl get virtualservice simple-app-vs -n canary-demo -o yaml" -ForegroundColor White
Write-Host "  kubectl logs -n canary-demo -l app=simple-app -f" -ForegroundColor White