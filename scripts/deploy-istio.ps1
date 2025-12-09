#!/usr/bin/env pwsh
# Deploy Istio service mesh configuration for canary deployment

Write-Host "🚀 Deploying Istio service mesh configuration..." -ForegroundColor Green

# Check if kubectl is available
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "❌ kubectl not found. Please install kubectl first." -ForegroundColor Red
    exit 1
}

# Check if Istio is installed
Write-Host "📋 Checking Istio installation..." -ForegroundColor Yellow
$istioNamespace = kubectl get namespace istio-system --ignore-not-found -o name
if (-not $istioNamespace) {
    Write-Host "❌ Istio system namespace not found. Please install Istio first." -ForegroundColor Red
    Write-Host "Run: istioctl install --set values.defaultRevision=default" -ForegroundColor Yellow
    exit 1
}

# Check if Istio gateway is running
$gatewayPods = kubectl get pods -n istio-system -l app=istio-ingressgateway --field-selector=status.phase=Running -o name
if (-not $gatewayPods) {
    Write-Host "❌ Istio ingress gateway not running. Please check Istio installation." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Istio installation verified" -ForegroundColor Green

# Enable Istio sidecar injection for the namespace
Write-Host "🔧 Enabling Istio sidecar injection for canary-demo namespace..." -ForegroundColor Yellow
kubectl label namespace canary-demo istio-injection=enabled --overwrite

# Apply Istio configuration manifests
Write-Host "📦 Applying Istio Gateway..." -ForegroundColor Yellow
kubectl apply -f k8s/istio-gateway.yaml

Write-Host "📦 Applying Istio VirtualService..." -ForegroundColor Yellow
kubectl apply -f k8s/istio-virtualservice.yaml

Write-Host "📦 Applying Istio DestinationRule..." -ForegroundColor Yellow
kubectl apply -f k8s/istio-destinationrule.yaml

# Restart deployments to inject Istio sidecars
Write-Host "🔄 Restarting deployments to inject Istio sidecars..." -ForegroundColor Yellow
kubectl rollout restart deployment/simple-app-stable -n canary-demo
kubectl rollout restart deployment/simple-app-canary -n canary-demo

# Wait for deployments to be ready
Write-Host "⏳ Waiting for deployments to be ready..." -ForegroundColor Yellow
kubectl rollout status deployment/simple-app-stable -n canary-demo --timeout=300s
kubectl rollout status deployment/simple-app-canary -n canary-demo --timeout=300s

# Get Istio ingress gateway external IP/port
Write-Host "🌐 Getting Istio ingress gateway information..." -ForegroundColor Yellow
$ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
if (-not $ingressHost) {
    $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
}
if (-not $ingressHost) {
    $ingressHost = "localhost"
    Write-Host "⚠️  LoadBalancer not available, using localhost. You may need to port-forward." -ForegroundColor Yellow
}

$ingressPort = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].port}'
if (-not $ingressPort) {
    $ingressPort = "80"
}

Write-Host "✅ Istio service mesh configuration deployed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Access your application at: http://${ingressHost}:${ingressPort}" -ForegroundColor Cyan
Write-Host ""
Write-Host "🧪 Test canary routing with header:" -ForegroundColor Cyan
Write-Host "curl -H 'canary: true' http://${ingressHost}:${ingressPort}/" -ForegroundColor White
Write-Host ""
Write-Host "📈 Monitor traffic distribution:" -ForegroundColor Cyan
Write-Host "kubectl get virtualservice simple-app-vs -n canary-demo -o yaml" -ForegroundColor White
Write-Host ""

# Validation checks
Write-Host "🔍 Running validation checks..." -ForegroundColor Yellow

# Check if pods have Istio sidecars
$stablePods = kubectl get pods -n canary-demo -l version=stable -o jsonpath='{.items[*].spec.containers[*].name}'
$canaryPods = kubectl get pods -n canary-demo -l version=canary -o jsonpath='{.items[*].spec.containers[*].name}'

if ($stablePods -match "istio-proxy" -and $canaryPods -match "istio-proxy") {
    Write-Host "✅ Istio sidecars injected successfully" -ForegroundColor Green
} else {
    Write-Host "⚠️  Istio sidecars may not be injected properly" -ForegroundColor Yellow
}

# Check Istio configuration status
$gatewayStatus = kubectl get gateway simple-app-gateway -n canary-demo -o jsonpath='{.status}'
$vsStatus = kubectl get virtualservice simple-app-vs -n canary-demo -o jsonpath='{.status}'

Write-Host "📋 Configuration Summary:" -ForegroundColor Cyan
Write-Host "  Gateway: simple-app-gateway" -ForegroundColor White
Write-Host "  VirtualService: simple-app-vs (80% stable, 20% canary)" -ForegroundColor White
Write-Host "  DestinationRule: simple-app-dr" -ForegroundColor White
Write-Host "  Ingress: http://${ingressHost}:${ingressPort}" -ForegroundColor White