<#
.SYNOPSIS
    Builds LiveDashboards and produces a ready-to-deploy IIS package.

.DESCRIPTION
    Run on any machine with the .NET 8 SDK (a dev PC or build server).
    Output:
        out\LiveDashboards-IIS-<version>\        the package folder
            site\                                 published web app (copy this to IIS)
            Install-IIS.ps1                       installer / updater for the IIS server
            Grant-SqlAccess.sql                   gives the app pool read access to SQL Server
            README-IIS.md                         deployment instructions
        out\LiveDashboards-IIS-<version>.zip      the same, zipped

.EXAMPLE
    .\deploy\Publish.ps1
.EXAMPLE
    .\deploy\Publish.ps1 -Version 1.2.0
#>
[CmdletBinding()]
param(
    [string] $Version = "1.0.0",
    [string] $Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root    = Split-Path -Parent $PSScriptRoot          # project folder
$project = Join-Path $root "LiveDashboardMultiTab.csproj"
$outRoot = Join-Path $root "out"
$pkgName = "LiveDashboards-IIS-$Version"
$pkgDir  = Join-Path $outRoot $pkgName
$siteDir = Join-Path $pkgDir "site"
$zipPath = Join-Path $outRoot "$pkgName.zip"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "The .NET SDK was not found. Install the .NET 8 SDK from https://dotnet.microsoft.com/download/dotnet/8.0"
}
$sdk = (& dotnet --version)
Write-Host "Using .NET SDK $sdk"

if (Test-Path $pkgDir)  { Remove-Item $pkgDir -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
New-Item -ItemType Directory -Path $siteDir -Force | Out-Null

Write-Host "Publishing $Configuration build to $siteDir ..."
& dotnet publish $project `
    -c $Configuration `
    -r win-x64 `
    --self-contained false `
    -p:Version=$Version `
    -o $siteDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed (exit code $LASTEXITCODE)" }

# Logs folder for optional stdout logging (see web.config)
New-Item -ItemType Directory -Path (Join-Path $siteDir "logs") -Force | Out-Null

# Installer + docs alongside the site
Copy-Item (Join-Path $PSScriptRoot "Install-IIS.ps1")      $pkgDir
Copy-Item (Join-Path $PSScriptRoot "Grant-SqlAccess.sql")  $pkgDir
Copy-Item (Join-Path $PSScriptRoot "README-IIS.md")        $pkgDir

Compress-Archive -Path (Join-Path $pkgDir "*") -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Package ready:" -ForegroundColor Green
Write-Host "  Folder: $pkgDir"
Write-Host "  Zip:    $zipPath"
Write-Host ""
Write-Host "Next: copy the zip to the IIS server, extract it, and run Install-IIS.ps1 as Administrator."
