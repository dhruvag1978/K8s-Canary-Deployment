# Quick Setup Guide

## 🛠️ Tech Stack

- **Application**: Node.js 18+ with Express
- **Containerization**: Docker
- **Orchestration**: Kubernetes (Docker Desktop/K3s)
- **Service Mesh**: Istio 1.20+
- **Automation**: PowerShell scripts
- **Monitoring**: Prometheus-compatible metrics

## 📋 Prerequisites

```bash
# Required tools
docker --version          # Docker 20+
kubectl version --client  # Kubernetes CLI
node --version            # Node.js 18+ (for local dev)
```

## ⚡ Quick Start Commands

### 1. Install Istio

```bash
# Download Istio
curl -L https://istio.io/downloadIstio | sh -

# Add to PATH (Linux/Mac)
export PATH=$PWD/istio-1.20.1/bin:$PATH

# Windows: Add istio-1.20.1/bin to PATH manually

# Install Istio
istioctl install --set values.defaultRevision=default -y

# Verify
kubectl get pods -n istio-system
```

### 2. Deploy Complete System

```powershell
# Windows PowerShell
./scripts/deploy-complete.ps1

# Or step by step:
./scripts/build-images.sh
kubectl apply -f k8s/
./scripts/deploy-istio.ps1
```

### 3. Test System

```powershell
# Test traffic distribution
powershell -ExecutionPolicy Bypass -File test-system.ps1

# Test canary routing
Invoke-WebRequest -Uri "http://localhost/" -Headers @{"canary"="true"} -UseBasicParsing
```

## 🔄 Canary Operations

```powershell
# Deploy new canary version
./scripts/canary-deploy.ps1 -NewVersion "v3.0" -CanaryWeight 30

# Monitor
kubectl get pods -n canary-demo
kubectl logs -n canary-demo -l app=simple-app -f

# Rollback if issues
./scripts/canary-rollback.ps1

# Promote if successful
./scripts/canary-promote.ps1
```

## 🧪 Testing Commands

```bash
# Check system status
kubectl get all -n canary-demo
kubectl get gateway,virtualservice,destinationrule -n canary-demo

# Test endpoints
curl http://localhost/
curl http://localhost/health/live
curl http://localhost/health/ready
curl http://localhost/metrics
curl http://localhost/version

# Force canary
curl -H "canary: true" http://localhost/

# Traffic distribution test
for i in {1..20}; do curl -s http://localhost/ | jq -r .version; done
```

## 🔍 Troubleshooting Commands

```bash
# Check pod status
kubectl describe pods -n canary-demo

# Check Istio sidecars (should show 2/2)
kubectl get pods -n canary-demo

# Check Istio config
kubectl get virtualservice simple-app-vs -n canary-demo -o yaml

# Check logs
kubectl logs -n canary-demo -l app=simple-app
kubectl logs -n istio-system -l app=istiod

# Port forward if needed
kubectl port-forward -n istio-system service/istio-ingressgateway 8080:80
```

## 📊 Monitoring Commands

```bash
# Application metrics
curl http://localhost/metrics

# Kubernetes resources
kubectl top pods -n canary-demo
kubectl get events -n canary-demo

# Istio proxy stats
kubectl exec -n canary-demo deployment/simple-app-stable -c istio-proxy -- pilot-agent request GET stats/prometheus
```

## 🧹 Cleanup Commands

```bash
# Remove application
kubectl delete namespace canary-demo

# Remove Istio (optional)
istioctl uninstall --purge -y
kubectl delete namespace istio-system
```

## 🚀 Actual Commands Used in This Project

### Step 1: Build Docker Images
```powershell
docker build -t simple-canary-app:v1.0 --build-arg APP_VERSION=v1.0 ./app
docker build -t simple-canary-app:v2.0 --build-arg APP_VERSION=v2.0 ./app
```

### Step 2: Apply Kubernetes Manifests
```powershell
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/deployment-stable.yaml
kubectl apply -f k8s/deployment-canary.yaml
kubectl apply -f k8s/service.yaml
```

### Step 3: Configure Istio (Manual Commands)
```powershell
# Enable Istio injection
kubectl label namespace canary-demo istio-injection=enabled

# Apply Istio configurations
kubectl apply -f k8s/istio-gateway.yaml
kubectl apply -f k8s/istio-virtualservice.yaml
kubectl apply -f k8s/istio-destinationrule.yaml

# Restart deployments to inject sidecars
kubectl rollout restart deployment/simple-app-stable -n canary-demo
kubectl rollout restart deployment/simple-app-canary -n canary-demo

# Wait for rollout
kubectl rollout status deployment/simple-app-stable -n canary-demo --timeout=300s
kubectl rollout status deployment/simple-app-canary -n canary-demo --timeout=300s
```

### Step 4: Test the System
```powershell
# Check pod status (should show 2/2 containers)
kubectl get pods -n canary-demo

# Test stable version
Invoke-WebRequest -Uri "http://localhost/" -UseBasicParsing

# Test canary version with header
Invoke-WebRequest -Uri "http://localhost/" -Headers @{"canary"="true"} -UseBasicParsing

# Test health endpoints
Invoke-WebRequest -Uri "http://localhost/health/live" -UseBasicParsing
Invoke-WebRequest -Uri "http://localhost/health/ready" -UseBasicParsing
Invoke-WebRequest -Uri "http://localhost/metrics" -UseBasicParsing

# Run traffic distribution test
powershell -ExecutionPolicy Bypass -File test-system.ps1
```

### Step 5: Verify Istio Configuration
```powershell
# Check Istio resources
kubectl get gateway,virtualservice,destinationrule -n canary-demo

# Check deployments
kubectl get deployments -n canary-demo

# Check services
kubectl get service istio-ingressgateway -n istio-system
```

## 🚀 One-Liner Setup (Alternative)

```bash
# Complete setup (after Istio is installed)
git clone <your-repo> && cd <repo-name> && ./scripts/deploy-complete.ps1 && powershell -ExecutionPolicy Bypass -File test-system.ps1
```

## 📱 Quick Validation

```bash
# Verify everything is working
kubectl get pods -n canary-demo | grep "2/2.*Running" && echo "✅ Pods ready with Istio sidecars"
curl -s http://localhost/ | jq -r .version && echo "✅ Stable version accessible"
curl -s -H "canary: true" http://localhost/ | jq -r .version && echo "✅ Canary routing works"
```

## 🎯 Expected Results

- **Pods**: 3 pods running (2 stable, 1 canary) with 2/2 containers each
- **Traffic**: ~80% to stable (v1.0), ~20% to canary (v2.0)
- **Header Routing**: `canary: true` header → 100% canary (v2.0)
- **Health**: All endpoints responding with 200 status
- **Metrics**: Prometheus format metrics available at `/metrics`

## 📸 Validation Results

### System Test Results

![System Validation](canary%20deployment.png)

**Successful Test Output:**
- ✅ Pod Status: All pods running with Istio sidecars (2/2 containers)
- ✅ Health Endpoints: Liveness and readiness probes working
- ✅ Traffic Distribution: Canary routing operational
- ✅ Header-based Routing: SUCCESS
- ✅ Istio Resources: Gateway, VirtualService, DestinationRule configured
- ✅ System Status: ALL TESTS PASSED!

### Traffic Distribution Results

![Traffic Test Results](canary%20deployment.2png.png)

**Traffic Split Validation:**
- **Stable (v1.0)**: 17 requests (85%)
- **Canary (v2.0)**: 3 requests (15%)
- **Result**: Within acceptable range of 80/20 target
- **Header Routing**: Confirmed working for forced canary testing

> These results confirm the canary deployment system is working correctly with proper traffic splitting and Istio service mesh integration.