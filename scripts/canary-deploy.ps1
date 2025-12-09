#!/usr/bin/env pwsh
# Canary Deployment Orchestration Script

param(
    [Parameter(Mandatory=$true)]
    [string]$NewVersion,
    
    [Parameter(Mandatory=$false)]
    [int]$CanaryWeight = 20,
    
    [Parameter(Mandatory=$false)]
    [int]$StableWeight = 80,
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "canary-demo",
    
    [Parameter(Mandatory=$false)]
    [string]$ImageTag = $NewVersion,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [int]$HealthCheckTimeout = 300
)

Write-Host "🚀 Canary Deployment Orchestration" -ForegroundColor Green
Write-Host "=================================" -ForegroundColor Green
Write-Host "New Version: $NewVersion" -ForegroundColor Cyan
Write-Host "Canary Weight: $CanaryWeight%" -ForegroundColor Cyan
Write-Host "Stable Weight: $StableWeight%" -ForegroundColor Cyan
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan
Write-Host "Dry Run: $DryRun" -ForegroundColor Cyan
Write-Host ""

# Validate inputs
if ($CanaryWeight + $StableWeight -ne 100) {
    Write-Host "❌ Error: Canary weight ($CanaryWeight) + Stable weight ($StableWeight) must equal 100" -ForegroundColor Red
    exit 1
}

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

# Check if Istio resources exist
$virtualService = kubectl get virtualservice simple-app-vs -n $Namespace --ignore-not-found -o name
if (-not $virtualService) {
    Write-Host "❌ VirtualService 'simple-app-vs' not found in namespace '$Namespace'" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Prerequisites check passed" -ForegroundColor Green

# Function to update canary deployment
function Update-CanaryDeployment {
    param($Version, $ImageTag, $Namespace, $DryRun)
    
    Write-Host "📦 Updating canary deployment to version $Version..." -ForegroundColor Yellow
    
    $deploymentPatch = @{
        spec = @{
            template = @{
                metadata = @{
                    labels = @{
                        version = "canary"
                        "app.version" = $Version
                    }
                }
                spec = @{
                    containers = @(
                        @{
                            name = "simple-app"
                            image = "simple-canary-app:$ImageTag"
                            env = @(
                                @{
                                    name = "APP_VERSION"
                                    value = $Version
                                }
                            )
                        }
                    )
                }
            }
        }
    } | ConvertTo-Json -Depth 10
    
    if ($DryRun) {
        Write-Host "🔍 [DRY RUN] Would update canary deployment with:" -ForegroundColor Cyan
        Write-Host $deploymentPatch -ForegroundColor Gray
        return $true
    } else {
        try {
            $deploymentPatch | kubectl patch deployment simple-app-canary -n $Namespace --type='merge' -p -
            return $true
        } catch {
            Write-Host "❌ Failed to update canary deployment: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# Function to update traffic weights
function Update-TrafficWeights {
    param($CanaryWeight, $StableWeight, $Namespace, $DryRun)
    
    Write-Host "⚖️  Updating traffic weights (Stable: $StableWeight%, Canary: $CanaryWeight%)..." -ForegroundColor Yellow
    
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
                            weight = $StableWeight
                        },
                        @{
                            destination = @{
                                host = "simple-app"
                                subset = "canary"
                            }
                            weight = $CanaryWeight
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
        Write-Host "🔍 [DRY RUN] Would update VirtualService with:" -ForegroundColor Cyan
        Write-Host $virtualServicePatch -ForegroundColor Gray
        return $true
    } else {
        try {
            $virtualServicePatch | kubectl patch virtualservice simple-app-vs -n $Namespace --type='merge' -p -
            return $true
        } catch {
            Write-Host "❌ Failed to update traffic weights: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# Function to check deployment health
function Test-DeploymentHealth {
    param($Namespace, $Timeout)
    
    Write-Host "🏥 Checking deployment health..." -ForegroundColor Yellow
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddSeconds($Timeout)
    
    while ((Get-Date) -lt $timeoutTime) {
        try {
            # Check if canary deployment is ready
            $canaryReady = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.status.readyReplicas}'
            $canaryDesired = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.spec.replicas}'
            
            if ($canaryReady -eq $canaryDesired -and $canaryReady -gt 0) {
                Write-Host "✅ Canary deployment is healthy ($canaryReady/$canaryDesired replicas ready)" -ForegroundColor Green
                
                # Test canary endpoint
                $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
                if (-not $ingressHost) {
                    $ingressHost = "localhost"
                }
                
                try {
                    $response = Invoke-WebRequest -Uri "http://$ingressHost/" -Headers @{"canary"="true"} -UseBasicParsing -TimeoutSec 10
                    if ($response.StatusCode -eq 200 -and $response.Content -match $NewVersion) {
                        Write-Host "✅ Canary endpoint is responding correctly" -ForegroundColor Green
                        return $true
                    }
                } catch {
                    Write-Host "⚠️  Canary endpoint test failed, retrying..." -ForegroundColor Yellow
                }
            }
            
            Write-Host "⏳ Waiting for canary deployment to be ready... ($canaryReady/$canaryDesired)" -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        } catch {
            Write-Host "⚠️  Health check failed, retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    
    Write-Host "❌ Health check timed out after $Timeout seconds" -ForegroundColor Red
    return $false
}

# Main deployment workflow
Write-Host "🎯 Starting canary deployment workflow..." -ForegroundColor Green

# Step 1: Update canary deployment
if (-not (Update-CanaryDeployment -Version $NewVersion -ImageTag $ImageTag -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Canary deployment update failed" -ForegroundColor Red
    exit 1
}

if (-not $DryRun) {
    # Step 2: Wait for deployment to be ready
    Write-Host "⏳ Waiting for canary deployment to roll out..." -ForegroundColor Yellow
    kubectl rollout status deployment/simple-app-canary -n $Namespace --timeout=300s
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Canary deployment rollout failed" -ForegroundColor Red
        exit 1
    }
    
    # Step 3: Health check
    if (-not (Test-DeploymentHealth -Namespace $Namespace -Timeout $HealthCheckTimeout)) {
        Write-Host "❌ Canary deployment health check failed" -ForegroundColor Red
        exit 1
    }
}

# Step 4: Update traffic weights
if (-not (Update-TrafficWeights -CanaryWeight $CanaryWeight -StableWeight $StableWeight -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Traffic weight update failed" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "🎉 Canary deployment completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Current Configuration:" -ForegroundColor Cyan
Write-Host "  Canary Version: $NewVersion ($CanaryWeight%)" -ForegroundColor Blue
Write-Host "  Stable Version: Current ($StableWeight%)" -ForegroundColor Green
Write-Host ""
Write-Host "🧪 Test Commands:" -ForegroundColor Cyan
Write-Host "  Regular traffic: curl http://localhost/" -ForegroundColor White
Write-Host "  Force canary: curl -H 'canary: true' http://localhost/" -ForegroundColor White
Write-Host ""
Write-Host "📈 Monitor:" -ForegroundColor Cyan
Write-Host "  kubectl get pods -n $Namespace" -ForegroundColor White
Write-Host "  kubectl get virtualservice simple-app-vs -n $Namespace -o yaml" -ForegroundColor White