<#
.SYNOPSIS
    Build and deploy the .NET Framework 4.7 XFF demo to Azure App Service.

.DESCRIPTION
    1. Restores NuGet packages
    2. Builds the project with MSBuild (publishes to .\publish)
    3. Zips the publish output
    4. Deploys the zip via 'az webapp deploy'
    5. Sets the Application Insights connection string app setting

.PARAMETER ResourceGroup
    App Service resource group.

.PARAMETER AppName
    App Service site name.

.PARAMETER AppInsightsConnectionString
    Optional. Application Insights connection string. If omitted, the script
    looks up the resource named by -AppInsightsName in -AppInsightsResourceGroup.

.PARAMETER AppInsightsName
    Optional. Name of the Application Insights resource to fetch the connection string from.

.PARAMETER AppInsightsResourceGroup
    Optional. RG of the App Insights resource. Defaults to -ResourceGroup.

.EXAMPLE
    .\deploy.ps1 -ResourceGroup rg-xff-test-eastus -AppName app-xff-test-cg4l2wl4myrww `
                 -AppInsightsName ai-xff-test-cg4l2wl4myrww
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,
    [Parameter(Mandatory = $true)] [string] $AppName,
    [string] $AppInsightsConnectionString,
    [string] $AppInsightsName,
    [string] $AppInsightsResourceGroup,
    [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

function Find-MSBuild {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $msb = & $vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
        if ($msb) { return $msb }
    }
    $msb = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($msb) { return $msb.Source }
    throw "MSBuild not found. Install Visual Studio Build Tools with the 'Web development' workload."
}

function Find-NuGet {
    $ng = Get-Command nuget.exe -ErrorAction SilentlyContinue
    if ($ng) { return $ng.Source }
    $local = Join-Path $PSScriptRoot 'nuget.exe'
    if (Test-Path $local) { return $local }
    Write-Host "Downloading nuget.exe..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $local
    return $local
}

# ── 1. Restore packages ────────────────────────────────────────────────────
Write-Host "[1/5] Restoring NuGet packages..." -ForegroundColor Cyan
$nuget = Find-NuGet
& $nuget restore .\XffDemo.Net47.csproj -PackagesDirectory .\packages
if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed" }

# ── 2. Build & publish ─────────────────────────────────────────────────────
Write-Host "[2/5] Building project..." -ForegroundColor Cyan
$msbuild = Find-MSBuild
$publishDir = Join-Path $PSScriptRoot 'publish'
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

& $msbuild .\XffDemo.Net47.csproj `
    "/p:Configuration=$Configuration" `
    /p:DeployOnBuild=true `
    /p:WebPublishMethod=FileSystem `
    /p:PublishUrl=$publishDir `
    /p:DeployDefaultTarget=WebPublish `
    /nologo /v:minimal
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed" }

# ── 3. Zip ─────────────────────────────────────────────────────────────────
Write-Host "[3/5] Packaging zip..." -ForegroundColor Cyan
$zipPath = Join-Path $PSScriptRoot 'xff-demo-net47.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath -Force

# ── 4. Deploy ──────────────────────────────────────────────────────────────
Write-Host "[4/5] Deploying to App Service '$AppName' in RG '$ResourceGroup'..." -ForegroundColor Cyan
az webapp deploy `
    --resource-group $ResourceGroup `
    --name $AppName `
    --src-path $zipPath `
    --type zip `
    --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az webapp deploy failed" }

# ── 5. Set App Insights connection ─────────────────────────────────────────
Write-Host "[5/5] Configuring Application Insights..." -ForegroundColor Cyan
if (-not $AppInsightsConnectionString -and $AppInsightsName) {
    if (-not $AppInsightsResourceGroup) { $AppInsightsResourceGroup = $ResourceGroup }
    $AppInsightsConnectionString = az monitor app-insights component show `
        --app $AppInsightsName `
        --resource-group $AppInsightsResourceGroup `
        --query connectionString -o tsv
}

if ($AppInsightsConnectionString) {
    az webapp config appsettings set `
        --resource-group $ResourceGroup `
        --name $AppName `
        --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$AppInsightsConnectionString" `
                   "ApplicationInsightsAgent_EXTENSION_VERSION=disabled" `
        --only-show-errors | Out-Null
    Write-Host "  Set APPLICATIONINSIGHTS_CONNECTION_STRING." -ForegroundColor Green
    Write-Host "  Disabled codeless agent (ApplicationInsightsAgent_EXTENSION_VERSION=disabled) so the SDK initializer runs." -ForegroundColor Yellow
} else {
    Write-Host "  No App Insights connection string supplied — telemetry disabled." -ForegroundColor Yellow
}

$hostname = az webapp show -g $ResourceGroup -n $AppName --query defaultHostName -o tsv
Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Home:    https://$hostname/Default.aspx"
Write-Host "  Reports: https://$hostname/Reports.aspx"
Write-Host "  CSV:     https://$hostname/Reports.aspx?format=csv"
