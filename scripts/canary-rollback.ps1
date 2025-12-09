#!/usr/bin/env pwsh
# Canary Rollback Automation Script

param(
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "canary-demo",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [string]$Reason = "Manual rollback"
)

Write-Host "🔄 Canary Rollback Automation" -ForegroundColor Red
Write-Host "=============================" -ForegroundColor Red
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan
Write-Host "Reason: $Reason" -ForegroundColor Cyan
Write-Host "Force: $Force" -ForegroundColor Cyan
Write-Host "Dry Run: $DryRun" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "🔍 Checking prerequisites..." -ForegroundColor Yellow

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "❌ kubectl not found" -ForegroundColor Red
    exit 1
}

# Check if namespace exists
$namespaceExists = kubectl get namespace $Namespace --ignore-not-found -o name
if (-not $namespaceExists) {
    Write-Host "❌ Namespace '$Namespace' not found" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Prerequisites check passed" -ForegroundColor Green

# Function to get current deployment status
function Get-DeploymentStatus {
    param($Namespace)
    
    try {
        $stableReplicas = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.status.readyReplicas}' 2>$null
        $canaryReplicas = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.status.readyReplicas}' 2>$null
        $stableDesired = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null
        $canaryDesired = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null
        
        $stableImage = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].image}' 2>$null
        $canaryImage = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].image}' 2>$null
        
        return @{
            StableReplicas = [int]$stableReplicas
            CanaryReplicas = [int]$canaryReplicas
            StableDesired = [int]$stableDesired
            CanaryDesired = [int]$canaryDesired
            StableImage = $stableImage
            CanaryImage = $canaryImage
        }
    } catch {
        Write-Host "❌ Failed to get deployment status: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Function to get current traffic weights
function Get-TrafficWeights {
    param($Namespace)
    
    try {
        $vsConfig = kubectl get virtualservice simple-app-vs -n $Namespace -o json | ConvertFrom-Json
        
        # Find the route with weight-based traffic splitting
        $weightRoute = $vsConfig.spec.http | Where-Object { $_.route.Count -gt 1 }
        
        if ($weightRoute) {
            $stableWeight = ($weightRoute.route | Where-Object { $_.destination.subset -eq "stable" }).weight
            $canaryWeight = ($weightRoute.route | Where-Object { $_.destination.subset -eq "canary" }).weight
            
            return @{
                StableWeight = [int]$stableWeight
                CanaryWeight = [int]$canaryWeight
            }
        }
        
        return @{
            StableWeight = 100
            CanaryWeight = 0
        }
    } catch {
        Write-Host "❌ Failed to get traffic weights: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Function to reset traffic to 100% stable
function Reset-TrafficToStable {
    param($Namespace, $DryRun)
    
    Write-Host "⚖️  Resetting traffic to 100% stable..." -ForegroundColor Yellow
    
    $virtualServicePatch = @{
        spec = @{
            http = @(
                @{
                    match = @(
                        @{
                            headers = @{
                                canary = @{
                                    exact = "true"
                                }
                            }
                        }
                    )
                    route = @(
                        @{
                            destination = @{
                                host = "simple-app"
                                subset = "canary"
                            }
                            weight = 100
                        }
                    )
                    fault = @{
                        delay = @{
                            percentage = @{
                                value = 0.1
                            }
                            fixedDelay = "5s"
                        }
                    }
                },
                @{
                    match = @(
                        @{
                            uri = @{
                                prefix = "/"
                            }
                        }
                    )
                    route = @(
                        @{
                            destination = @{
                                host = "simple-app"
                                subset = "stable"
                            }
                            weight = 100
                        },
                        @{
                            destination = @{
                                host = "simple-app"
                                subset = "canary"
                            }
                            weight = 0
                        }
                    )
                    timeout = "30s"
                    retries = @{
                        attempts = 3
                        perTryTimeout = "10s"
                        retryOn = "gateway-error,connect-failure,refused-stream"
                    }
                }
            )
        }
    } | ConvertTo-Json -Depth 10
    
    if ($DryRun) {
        Write-Host "🔍 [DRY RUN] Would reset traffic to 100% stable" -ForegroundColor Cyan
        return $true
    } else {
        try {
            $virtualServicePatch | kubectl patch virtualservice simple-app-vs -n $Namespace --type='merge' -p -
            Write-Host "✅ Traffic reset to 100% stable" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "❌ Failed to reset traffic: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# Function to scale down canary deployment
function Scale-DownCanary {
    param($Namespace, $DryRun)
    
    Write-Host "📉 Scaling down canary deployment..." -ForegroundColor Yellow
    
    if ($DryRun) {
        Write-Host "🔍 [DRY RUN] Would scale canary deployment to 0 replicas" -ForegroundColor Cyan
        return $true
    } else {
        try {
            kubectl scale deployment simple-app-canary -n $Namespace --replicas=0
            Write-Host "✅ Canary deployment scaled to 0 replicas" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "❌ Failed to scale down canary: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# Function to check rollback health
function Test-RollbackHealth {
    param($Namespace)
    
    Write-Host "🏥 Verifying rollback health..." -ForegroundColor Yellow
    
    try {
        # Check stable deployment health
        $stableReady = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.status.readyReplicas}'
        $stableDesired = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.spec.replicas}'
        
        if ($stableReady -eq $stableDesired -and $stableReady -gt 0) {
            Write-Host "✅ Stable deployment is healthy ($stableReady/$stableDesired replicas ready)" -ForegroundColor Green
            
            # Test stable endpoint
            $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
            if (-not $ingressHost) {
                $ingressHost = "localhost"
            }
            
            try {
                $response = Invoke-WebRequest -Uri "http://$ingressHost/" -UseBasicParsing -TimeoutSec 10
                if ($response.StatusCode -eq 200) {
                    Write-Host "✅ Stable endpoint is responding correctly" -ForegroundColor Green
                    return $true
                }
            } catch {
                Write-Host "⚠️  Stable endpoint test failed" -ForegroundColor Yellow
            }
        }
        
        return $false
    } catch {
        Write-Host "❌ Health check failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Function to log rollback event
function Write-RollbackLog {
    param($Namespace, $Reason, $Status)
    
    $logEntry = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        event = "canary_rollback"
        namespace = $Namespace
        reason = $Reason
        status = $Status
        user = $env:USERNAME
        hostname = $env:COMPUTERNAME
    } | ConvertTo-Json
    
    Write-Host "📝 Rollback event logged: $logEntry" -ForegroundColor Gray
}

# Main rollback workflow
Write-Host "📊 Getting current deployment status..." -ForegroundColor Yellow

$deploymentStatus = Get-DeploymentStatus -Namespace $Namespace
if (-not $deploymentStatus) {
    Write-Host "❌ Failed to get deployment status" -ForegroundColor Red
    exit 1
}

$trafficWeights = Get-TrafficWeights -Namespace $Namespace
if (-not $trafficWeights) {
    Write-Host "❌ Failed to get traffic weights" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Current Status:" -ForegroundColor Cyan
Write-Host "  Stable: $($deploymentStatus.StableReplicas)/$($deploymentStatus.StableDesired) replicas ($($trafficWeights.StableWeight)% traffic)" -ForegroundColor Green
Write-Host "  Canary: $($deploymentStatus.CanaryReplicas)/$($deploymentStatus.CanaryDesired) replicas ($($trafficWeights.CanaryWeight)% traffic)" -ForegroundColor Blue
Write-Host "  Stable Image: $($deploymentStatus.StableImage)" -ForegroundColor White
Write-Host "  Canary Image: $($deploymentStatus.CanaryImage)" -ForegroundColor White
Write-Host ""

# Check if rollback is needed
if ($trafficWeights.CanaryWeight -eq 0 -and $deploymentStatus.CanaryDesired -eq 0) {
    Write-Host "ℹ️  No active canary deployment found. Nothing to rollback." -ForegroundColor Yellow
    exit 0
}

# Confirmation prompt (unless forced)
if (-not $Force -and -not $DryRun) {
    Write-Host "⚠️  This will rollback the canary deployment and route 100% traffic to stable." -ForegroundColor Yellow
    $confirmation = Read-Host "Are you sure you want to proceed? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "❌ Rollback cancelled by user" -ForegroundColor Red
        exit 1
    }
}

Write-Host "🎯 Starting rollback workflow..." -ForegroundColor Red

# Step 1: Reset traffic to 100% stable
if (-not (Reset-TrafficToStable -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Failed to reset traffic to stable" -ForegroundColor Red
    Write-RollbackLog -Namespace $Namespace -Reason $Reason -Status "failed"
    exit 1
}

# Step 2: Scale down canary deployment
if (-not (Scale-DownCanary -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Failed to scale down canary deployment" -ForegroundColor Red
    Write-RollbackLog -Namespace $Namespace -Reason $Reason -Status "failed"
    exit 1
}

if (-not $DryRun) {
    # Step 3: Wait for canary to scale down
    Write-Host "⏳ Waiting for canary deployment to scale down..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    
    # Step 4: Health check
    if (-not (Test-RollbackHealth -Namespace $Namespace)) {
        Write-Host "❌ Rollback health check failed" -ForegroundColor Red
        Write-RollbackLog -Namespace $Namespace -Reason $Reason -Status "failed"
        exit 1
    }
}

Write-Host ""
Write-Host "✅ Rollback completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Final Configuration:" -ForegroundColor Cyan
Write-Host "  Stable: 100% traffic" -ForegroundColor Green
Write-Host "  Canary: 0% traffic (scaled down)" -ForegroundColor Gray
Write-Host ""
Write-Host "🧪 Test Command:" -ForegroundColor Cyan
Write-Host "  curl http://localhost/" -ForegroundColor White
Write-Host ""

Write-RollbackLog -Namespace $Namespace -Reason $Reason -Status "success"