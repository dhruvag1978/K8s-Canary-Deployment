#!/usr/bin/env pwsh
# Canary Promotion Script

param(
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "canary-demo",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun,
    
    [Parameter(Mandatory=$false)]
    [int]$ValidationTimeout = 300
)

Write-Host "🚀 Canary Promotion" -ForegroundColor Green
Write-Host "===================" -ForegroundColor Green
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan
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
        
        $stableVersion = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="APP_VERSION")].value}' 2>$null
        $canaryVersion = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="APP_VERSION")].value}' 2>$null
        
        return @{
            StableReplicas = [int]$stableReplicas
            CanaryReplicas = [int]$canaryReplicas
            StableDesired = [int]$stableDesired
            CanaryDesired = [int]$canaryDesired
            StableImage = $stableImage
            CanaryImage = $canaryImage
            StableVersion = $stableVersion
            CanaryVersion = $canaryVersion
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

# Function to validate canary deployment
function Test-CanaryValidation {
    param($Namespace, $Timeout)
    
    Write-Host "🔍 Validating canary deployment..." -ForegroundColor Yellow
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddSeconds($Timeout)
    
    # Check deployment health
    $canaryReady = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.status.readyReplicas}'
    $canaryDesired = kubectl get deployment simple-app-canary -n $Namespace -o jsonpath='{.spec.replicas}'
    
    if ($canaryReady -ne $canaryDesired -or $canaryReady -eq 0) {
        Write-Host "❌ Canary deployment is not healthy ($canaryReady/$canaryDesired replicas ready)" -ForegroundColor Red
        return $false
    }
    
    # Test canary endpoint multiple times
    $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    if (-not $ingressHost) {
        $ingressHost = "localhost"
    }
    
    $successCount = 0
    $totalTests = 10
    
    Write-Host "🧪 Testing canary endpoint ($totalTests requests)..." -ForegroundColor Yellow
    
    for ($i = 1; $i -le $totalTests; $i++) {
        try {
            $response = Invoke-WebRequest -Uri "http://$ingressHost/" -Headers @{"canary"="true"} -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) {
                $successCount++
                Write-Host "." -NoNewline -ForegroundColor Green
            } else {
                Write-Host "X" -NoNewline -ForegroundColor Red
            }
        } catch {
            Write-Host "X" -NoNewline -ForegroundColor Red
        }
        Start-Sleep -Milliseconds 200
    }
    
    Write-Host ""
    
    $successRate = ($successCount / $totalTests) * 100
    Write-Host "📊 Canary endpoint success rate: $successRate% ($successCount/$totalTests)" -ForegroundColor Cyan
    
    if ($successRate -ge 95) {
        Write-Host "✅ Canary validation passed" -ForegroundColor Green
        return $true
    } else {
        Write-Host "❌ Canary validation failed (success rate below 95%)" -ForegroundColor Red
        return $false
    }
}

# Function to promote canary to stable
function Invoke-CanaryPromotion {
    param($CanaryImage, $CanaryVersion, $Namespace, $DryRun)
    
    Write-Host "🔄 Promoting canary to stable..." -ForegroundColor Yellow
    
    # Update stable deployment with canary image and version
    $deploymentPatch = @{
        spec = @{
            template = @{
                metadata = @{
                    labels = @{
                        version = "stable"
                        "app.version" = $CanaryVersion
                    }
                }
                spec = @{
                    containers = @(
                        @{
                            name = "simple-app"
                            image = $CanaryImage
                            env = @(
                                @{
                                    name = "APP_VERSION"
                                    value = $CanaryVersion
                                }
                            )
                        }
                    )
                }
            }
        }
    } | ConvertTo-Json -Depth 10
    
    if ($DryRun) {
        Write-Host "🔍 [DRY RUN] Would promote canary ($CanaryImage, $CanaryVersion) to stable" -ForegroundColor Cyan
        return $true
    } else {
        try {
            $deploymentPatch | kubectl patch deployment simple-app-stable -n $Namespace --type='merge' -p -
            Write-Host "✅ Stable deployment updated with canary version" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "❌ Failed to promote canary to stable: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
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

# Function to cleanup old canary deployment
function Remove-CanaryDeployment {
    param($Namespace, $DryRun)
    
    Write-Host "🧹 Cleaning up canary deployment..." -ForegroundColor Yellow
    
    if ($DryRun) {
        Write-Host "🔍 [DRY RUN] Would scale canary deployment to 0 replicas" -ForegroundColor Cyan
        return $true
    } else {
        try {
            kubectl scale deployment simple-app-canary -n $Namespace --replicas=0
            Write-Host "✅ Canary deployment scaled to 0 replicas" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "❌ Failed to cleanup canary deployment: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# Function to validate promotion
function Test-PromotionValidation {
    param($Namespace, $ExpectedVersion)
    
    Write-Host "🔍 Validating promotion..." -ForegroundColor Yellow
    
    try {
        # Check stable deployment health
        $stableReady = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.status.readyReplicas}'
        $stableDesired = kubectl get deployment simple-app-stable -n $Namespace -o jsonpath='{.spec.replicas}'
        
        if ($stableReady -ne $stableDesired -or $stableReady -eq 0) {
            Write-Host "❌ Stable deployment is not healthy ($stableReady/$stableDesired replicas ready)" -ForegroundColor Red
            return $false
        }
        
        # Test stable endpoint
        $ingressHost = kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
        if (-not $ingressHost) {
            $ingressHost = "localhost"
        }
        
        $response = Invoke-WebRequest -Uri "http://$ingressHost/" -UseBasicParsing -TimeoutSec 10
        if ($response.StatusCode -eq 200 -and $response.Content -match $ExpectedVersion) {
            Write-Host "✅ Promotion validation passed - stable endpoint serving $ExpectedVersion" -ForegroundColor Green
            return $true
        } else {
            Write-Host "❌ Promotion validation failed - unexpected response" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "❌ Promotion validation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Function to log promotion event
function Write-PromotionLog {
    param($Namespace, $FromVersion, $ToVersion, $Status)
    
    $logEntry = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        event = "canary_promotion"
        namespace = $Namespace
        from_version = $FromVersion
        to_version = $ToVersion
        status = $Status
        user = $env:USERNAME
        hostname = $env:COMPUTERNAME
    } | ConvertTo-Json
    
    Write-Host "📝 Promotion event logged: $logEntry" -ForegroundColor Gray
}

# Main promotion workflow
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
Write-Host "  Stable: $($deploymentStatus.StableVersion) ($($deploymentStatus.StableReplicas)/$($deploymentStatus.StableDesired) replicas, $($trafficWeights.StableWeight)% traffic)" -ForegroundColor Green
Write-Host "  Canary: $($deploymentStatus.CanaryVersion) ($($deploymentStatus.CanaryReplicas)/$($deploymentStatus.CanaryDesired) replicas, $($trafficWeights.CanaryWeight)% traffic)" -ForegroundColor Blue
Write-Host "  Stable Image: $($deploymentStatus.StableImage)" -ForegroundColor White
Write-Host "  Canary Image: $($deploymentStatus.CanaryImage)" -ForegroundColor White
Write-Host ""

# Check if promotion is possible
if ($deploymentStatus.CanaryDesired -eq 0 -or $deploymentStatus.CanaryReplicas -eq 0) {
    Write-Host "❌ No active canary deployment found. Nothing to promote." -ForegroundColor Red
    exit 1
}

if ($deploymentStatus.StableVersion -eq $deploymentStatus.CanaryVersion) {
    Write-Host "ℹ️  Stable and canary are already the same version ($($deploymentStatus.StableVersion)). Nothing to promote." -ForegroundColor Yellow
    exit 0
}

# Validation
if (-not $Force) {
    if (-not (Test-CanaryValidation -Namespace $Namespace -Timeout $ValidationTimeout)) {
        Write-Host "❌ Canary validation failed. Use -Force to override." -ForegroundColor Red
        exit 1
    }
}

# Confirmation prompt (unless forced)
if (-not $Force -and -not $DryRun) {
    Write-Host "⚠️  This will promote canary version $($deploymentStatus.CanaryVersion) to stable, replacing $($deploymentStatus.StableVersion)." -ForegroundColor Yellow
    $confirmation = Read-Host "Are you sure you want to proceed? (y/N)"
    if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
        Write-Host "❌ Promotion cancelled by user" -ForegroundColor Red
        exit 1
    }
}

Write-Host "🎯 Starting promotion workflow..." -ForegroundColor Green

# Step 1: Promote canary to stable
if (-not (Invoke-CanaryPromotion -CanaryImage $deploymentStatus.CanaryImage -CanaryVersion $deploymentStatus.CanaryVersion -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Failed to promote canary to stable" -ForegroundColor Red
    Write-PromotionLog -Namespace $Namespace -FromVersion $deploymentStatus.StableVersion -ToVersion $deploymentStatus.CanaryVersion -Status "failed"
    exit 1
}

if (-not $DryRun) {
    # Step 2: Wait for stable deployment to roll out
    Write-Host "⏳ Waiting for stable deployment to roll out..." -ForegroundColor Yellow
    kubectl rollout status deployment/simple-app-stable -n $Namespace --timeout=300s
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Stable deployment rollout failed" -ForegroundColor Red
        Write-PromotionLog -Namespace $Namespace -FromVersion $deploymentStatus.StableVersion -ToVersion $deploymentStatus.CanaryVersion -Status "failed"
        exit 1
    }
}

# Step 3: Reset traffic to 100% stable
if (-not (Reset-TrafficToStable -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Failed to reset traffic to stable" -ForegroundColor Red
    Write-PromotionLog -Namespace $Namespace -FromVersion $deploymentStatus.StableVersion -ToVersion $deploymentStatus.CanaryVersion -Status "failed"
    exit 1
}

# Step 4: Cleanup canary deployment
if (-not (Remove-CanaryDeployment -Namespace $Namespace -DryRun $DryRun)) {
    Write-Host "❌ Failed to cleanup canary deployment" -ForegroundColor Red
    Write-PromotionLog -Namespace $Namespace -FromVersion $deploymentStatus.StableVersion -ToVersion $deploymentStatus.CanaryVersion -Status "failed"
    exit 1
}

if (-not $DryRun) {
    # Step 5: Validate promotion
    Start-Sleep -Seconds 10
    if (-not (Test-PromotionValidation -Namespace $Namespace -ExpectedVersion $deploymentStatus.CanaryVersion)) {
        Write-Host "❌ Promotion validation failed" -ForegroundColor Red
        Write-PromotionLog -Namespace $Namespace -FromVersion $deploymentStatus.StableVersion -ToVersion $deploymentStatus.CanaryVersion -Status "failed"
        exit 1
    }
}

Write-Host ""
Write-Host "🎉 Promotion completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Final Configuration:" -ForegroundColor Cyan
Write-Host "  Stable: $($deploymentStatus.CanaryVersion) (100% traffic)" -ForegroundColor Green
Write-Host "  Canary: Scaled down" -ForegroundColor Gray
Write-Host ""
Write-Host "🧪 Test Command:" -ForegroundColor Cyan
Write-Host "  curl http://localhost/" -ForegroundColor White
Write-Host ""

Write-PromotionLog -Namespace $Namespace -FromVersion $deploymentStatus.StableVersion -ToVersion $deploymentStatus.CanaryVersion -Status "success"