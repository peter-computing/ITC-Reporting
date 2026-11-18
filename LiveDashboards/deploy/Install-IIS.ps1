<#
.SYNOPSIS
    Installs or updates LiveDashboards on IIS.

.DESCRIPTION
    Run on the IIS server, as Administrator, from the extracted package folder
    (the folder that contains this script and the "site" folder).

    First run:  creates the app pool and the IIS application (or site), copies
                the files, sets folder permissions and starts the app.
    Later runs: updates the files in place. The app goes offline for a few
                seconds (IIS shows app_offline.htm). Your appsettings.json is
                kept unless you pass -OverwriteConfig.

    Prerequisites on the server (the script checks and tells you what's missing):
      - IIS with the "WebSocket Protocol" feature
      - ASP.NET Core 8 Hosting Bundle
        https://dotnet.microsoft.com/download/dotnet/8.0  (Hosting Bundle under "ASP.NET Core Runtime")

.PARAMETER SiteName
    Existing IIS site to add the app under (default "Default Web Site").
    With -NewSite, the name of the site to create.

.PARAMETER AppPath
    Sub-path for the app under SiteName, e.g. "dashboards" -> http://server/dashboards/.
    Ignored with -NewSite.

.PARAMETER NewSite
    Create a dedicated IIS site instead of an application under an existing one.

.PARAMETER Port
    HTTP port for -NewSite (default 8080).

.PARAMETER HostHeader
    Optional host name binding for -NewSite, e.g. "dashboards.contoso.local".

.PARAMETER InstallPath
    Where the files go (default C:\inetpub\LiveDashboards).

.PARAMETER AppPoolName
    Application pool name (default "LiveDashboards").

.PARAMETER ServiceAccount
    Optional domain account for the app pool, e.g. to reach a remote SQL Server
    with Windows authentication. Prompts for the password. Without it, the
    pool runs as "IIS AppPool\<AppPoolName>".

.PARAMETER WindowsAuth
    Require Windows sign-in (any domain user). Turns off anonymous access.

.PARAMETER AllowGroups
    Require Windows sign-in AND limit access to these AD groups/users,
    e.g. -AllowGroups "CONTOSO\Dashboard Viewers","CONTOSO\IT Ops".
    Stored in IIS's server configuration, so it survives updates.

.PARAMETER OverwriteConfig
    Replace the server's appsettings.json with the one in the package.

.PARAMETER InstallMissingFeatures
    Install the IIS WebSocket Protocol feature if it's missing.

.EXAMPLE
    # App under the default site: http://server/dashboards/
    .\Install-IIS.ps1

.EXAMPLE
    # Dedicated site on port 8080
    .\Install-IIS.ps1 -NewSite -SiteName "LiveDashboards" -Port 8080

.EXAMPLE
    # Only members of an AD group can open the dashboards
    .\Install-IIS.ps1 -AllowGroups "CONTOSO\Dashboard Viewers"

.EXAMPLE
    # Dedicated site with a host name, running as a domain service account
    .\Install-IIS.ps1 -NewSite -SiteName "LiveDashboards" -Port 80 -HostHeader dashboards.contoso.local -ServiceAccount CONTOSO\svc-dashboards
#>
[CmdletBinding()]
param(
    [string] $SiteName = "Default Web Site",
    [string] $AppPath = "dashboards",
    [switch] $NewSite,
    [int]    $Port = 8080,
    [string] $HostHeader = "",
    [string] $InstallPath = "C:\inetpub\LiveDashboards",
    [string] $AppPoolName = "LiveDashboards",
    [string] $ServiceAccount = "",
    [switch] $WindowsAuth,
    [string[]] $AllowGroups = @(),
    [switch] $OverwriteConfig,
    [switch] $InstallMissingFeatures
)

$ErrorActionPreference = "Stop"
$SourcePath = Join-Path $PSScriptRoot "site"
$AppPath = $AppPath.Trim("/")

# Guard rails: never repoint the server's default site, never install a sub-app with no path.
if ($NewSite -and -not $PSBoundParameters.ContainsKey("SiteName")) { $SiteName = "LiveDashboards" }
if ($NewSite -and $SiteName -eq "Default Web Site") {
    throw "-NewSite would take over 'Default Web Site'. Pass a different -SiteName, or drop -NewSite to install under it as /$AppPath."
}
if (-not $NewSite -and -not $AppPath) {
    throw "-AppPath can't be empty when installing under an existing site. Use -NewSite for a dedicated site."
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- checks
Write-Step "Checking prerequisites"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell (Run as Administrator)."
}

if (-not (Test-Path (Join-Path $SourcePath "LiveDashboardMultiTab.dll"))) {
    throw "Can't find the published site at '$SourcePath'. Run this script from the extracted package folder."
}

if (-not (Get-Service W3SVC -ErrorAction SilentlyContinue)) {
    throw "IIS is not installed. Install the Web Server (IIS) role first."
}
Write-Ok "IIS is installed"

$ancm = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
if (-not (Test-Path $ancm)) {
    throw "The ASP.NET Core Module is missing. Install the ASP.NET Core 8 Hosting Bundle " +
          "(https://dotnet.microsoft.com/download/dotnet/8.0), then run 'iisreset' and this script again."
}
$runtimes = Join-Path $env:ProgramFiles "dotnet\shared\Microsoft.AspNetCore.App"
if (-not (Get-ChildItem $runtimes -Directory -Filter "8.*" -ErrorAction SilentlyContinue)) {
    throw "ASP.NET Core 8 runtime not found in '$runtimes'. Install the ASP.NET Core 8 Hosting Bundle."
}
Write-Ok "ASP.NET Core 8 Hosting Bundle is installed"

# Optional IIS features. Server SKUs use Windows *features*; client Windows uses optional features.
$isServer = (Get-CimInstance Win32_OperatingSystem).ProductType -ne 1
function Test-IisFeature([string]$serverName, [string]$clientName) {
    if ($isServer) { $f = Get-WindowsFeature $serverName -ErrorAction SilentlyContinue; return [bool]($f -and $f.Installed) }
    $f = Get-WindowsOptionalFeature -Online -FeatureName $clientName -ErrorAction SilentlyContinue
    return [bool]($f -and $f.State -eq "Enabled")
}
function Install-IisFeature([string]$serverName, [string]$clientName) {
    if ($isServer) { Install-WindowsFeature $serverName | Out-Null }
    else { Enable-WindowsOptionalFeature -Online -FeatureName $clientName -All -NoRestart | Out-Null }
}

$useWindowsAuth = $WindowsAuth -or ($AllowGroups.Count -gt 0)
$features = @(@{ Server = "Web-WebSockets"; Client = "IIS-WebSockets"; Label = "WebSocket Protocol"; Required = $false })
if ($useWindowsAuth)          { $features += @{ Server = "Web-Windows-Auth"; Client = "IIS-WindowsAuthentication"; Label = "Windows Authentication"; Required = $true } }
if ($AllowGroups.Count -gt 0) { $features += @{ Server = "Web-Url-Auth";     Client = "IIS-URLAuthorization";      Label = "URL Authorization";      Required = $true } }

foreach ($f in $features) {
    if (Test-IisFeature $f.Server $f.Client) { Write-Ok "$($f.Label) is installed"; continue }
    if ($InstallMissingFeatures) {
        Write-Step "Installing the IIS $($f.Label) feature"
        Install-IisFeature $f.Server $f.Client
        Write-Ok "$($f.Label) installed"
    } elseif ($f.Required) {
        throw "The IIS '$($f.Label)' feature is required for sign-in. Re-run with -InstallMissingFeatures, or install it in Server Manager."
    } else {
        Write-Warn2 "The IIS '$($f.Label)' feature is not installed. Live updates will still work, but use"
        Write-Warn2 "slower long polling. Re-run with -InstallMissingFeatures to add it."
    }
}

Import-Module WebAdministration

# ---------------------------------------------------------------- app pool
Write-Step "Configuring application pool '$AppPoolName'"
$poolPath = "IIS:\AppPools\$AppPoolName"
if (-not (Test-Path $poolPath)) {
    New-WebAppPool -Name $AppPoolName | Out-Null
    Write-Ok "Created"
}
Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value ""            # "No Managed Code" (required for ASP.NET Core)
Set-ItemProperty $poolPath -Name managedPipelineMode   -Value "Integrated"
Set-ItemProperty $poolPath -Name startMode             -Value "AlwaysRunning"  # start with IIS, not on first request
Set-ItemProperty $poolPath -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)   # keep change checks running
Set-ItemProperty $poolPath -Name processModel.maxProcesses -Value 1           # SignalR needs a single worker process
# Recycle once a night at 3:00 AM instead of the default every 29 hours (which drifts into business hours).
Set-ItemProperty $poolPath -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
Clear-ItemProperty $poolPath -Name recycling.periodicRestart.schedule
Set-ItemProperty $poolPath -Name recycling.periodicRestart.schedule -Value @{ value = "03:00:00" }

if ($ServiceAccount) {
    $cred = Get-Credential -UserName $ServiceAccount -Message "Password for the app pool account $ServiceAccount"
    Set-ItemProperty $poolPath -Name processModel -Value @{
        userName     = $cred.UserName
        password     = $cred.GetNetworkCredential().Password
        identityType = 3   # SpecificUser
    }
    $identity = $cred.UserName
    Write-Ok "Runs as $identity"
} else {
    Set-ItemProperty $poolPath -Name processModel.identityType -Value 4   # ApplicationPoolIdentity
    $identity = "IIS AppPool\$AppPoolName"
    Write-Ok "Runs as $identity"
}

# ---------------------------------------------------------------- files
$isUpdate = Test-Path (Join-Path $InstallPath "LiveDashboardMultiTab.dll")
Write-Step ($(if ($isUpdate) { "Updating files in $InstallPath" } else { "Copying files to $InstallPath" }))
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallPath "logs") -Force | Out-Null

$offline = Join-Path $InstallPath "app_offline.htm"
if ($isUpdate) {
    # IIS stops the app and serves this page while files are replaced.
    @"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="5"><title>Updating</title></head>
<body style="font-family:Segoe UI,system-ui,sans-serif;display:grid;place-items:center;height:90vh;color:#52514e">
<p>The dashboards are being updated. This page will reload in a few seconds.</p></body></html>
"@ | Set-Content -Path $offline -Encoding UTF8
    Start-Sleep -Seconds 3   # let the app shut down and release its files
}

$keep = @("app_offline.htm")
if (-not $OverwriteConfig) { $keep += @("appsettings.json", "appsettings.Production.json") }

# /MIR mirrors the package; excluded files are neither copied nor deleted on the server.
$roboArgs = @($SourcePath, $InstallPath, "/MIR", "/R:3", "/W:2", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/XD", "logs", "/XF") + $keep
& robocopy @roboArgs | Out-Null
if ($LASTEXITCODE -ge 8) {
    if (Test-Path $offline) { Remove-Item $offline -Force }
    throw "File copy failed (robocopy exit code $LASTEXITCODE)."
}

# First install, or -OverwriteConfig: put the config files in place.
foreach ($cfg in @("appsettings.json", "appsettings.Production.json")) {
    $src = Join-Path $SourcePath $cfg
    $dst = Join-Path $InstallPath $cfg
    if ((Test-Path $src) -and ($OverwriteConfig -or -not (Test-Path $dst))) {
        Copy-Item $src $dst -Force
        Write-Ok "Installed $cfg"
    }
}
if ($isUpdate -and -not $OverwriteConfig) { Write-Ok "Kept the existing appsettings.json" }

# ---------------------------------------------------------------- permissions
Write-Step "Setting folder permissions for $identity"
& icacls $InstallPath /grant "${identity}:(OI)(CI)RX" /T /C /Q | Out-Null
& icacls (Join-Path $InstallPath "logs") /grant "${identity}:(OI)(CI)M" /T /C /Q | Out-Null
# appsettings.json can hold connection strings: limit it to admins, SYSTEM and the app pool.
$appsettings = Join-Path $InstallPath "appsettings.json"
if (Test-Path $appsettings) {
    & icacls $appsettings /inheritance:r /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F" "${identity}:R" /C /Q | Out-Null
}
Write-Ok "Read access to the app, write access to logs\"

# ---------------------------------------------------------------- site / application
if ($NewSite) {
    Write-Step "Configuring site '$SiteName'"
    if (-not (Test-Path "IIS:\Sites\$SiteName")) {
        $siteArgs = @{ Name = $SiteName; PhysicalPath = $InstallPath; ApplicationPool = $AppPoolName; Port = $Port }
        if ($HostHeader) { $siteArgs.HostHeader = $HostHeader }
        New-Website @siteArgs | Out-Null
        Write-Ok "Created on port $Port"
    } else {
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath    -Value $InstallPath
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPoolName
        Write-Ok "Updated"
    }
    $iisPath = "IIS:\Sites\$SiteName"
    $hostPart = $(if ($HostHeader) { $HostHeader } else { "localhost" })
    $portPart = $(if ($Port -eq 80) { "" } else { ":$Port" })
    $url = "http://$hostPart$portPart/"
} else {
    Write-Step "Configuring application '/$AppPath' under '$SiteName'"
    if (-not (Test-Path "IIS:\Sites\$SiteName")) {
        throw "IIS site '$SiteName' doesn't exist. Use -SiteName with an existing site, or -NewSite to create one."
    }
    if (-not (Get-WebApplication -Site $SiteName -Name $AppPath)) {
        New-WebApplication -Site $SiteName -Name $AppPath -PhysicalPath $InstallPath -ApplicationPool $AppPoolName | Out-Null
        Write-Ok "Created"
    } else {
        Set-ItemProperty "IIS:\Sites\$SiteName\$AppPath" -Name physicalPath    -Value $InstallPath
        Set-ItemProperty "IIS:\Sites\$SiteName\$AppPath" -Name applicationPool -Value $AppPoolName
        Write-Ok "Updated"
    }
    $iisPath = "IIS:\Sites\$SiteName\$AppPath"
    $binding = Get-WebBinding -Name $SiteName -Protocol http | Select-Object -First 1
    $sitePort = 80
    if ($binding) { $sitePort = [int]($binding.bindingInformation.Split(":")[1]) }
    $portPart = $(if ($sitePort -eq 80) { "" } else { ":$sitePort" })
    $url = "http://localhost$portPart/$AppPath/"
}

# Start the app right away (needs the optional IIS "Application Initialization" feature; skipped if absent).
try { Set-ItemProperty $iisPath -Name preloadEnabled -Value $true } catch { }

# ---------------------------------------------------------------- sign-in
# Stored in applicationHost.config (not the app's web.config), so updates never undo it.
$apphost  = "MACHINE/WEBROOT/APPHOST"
$location = $(if ($NewSite) { $SiteName } else { "$SiteName/$AppPath" })
$authBase = "system.webServer/security/authentication"
if ($useWindowsAuth) {
    Write-Step "Requiring Windows sign-in"
    Set-WebConfigurationProperty -PSPath $apphost -Location $location -Filter "$authBase/windowsAuthentication"   -Name enabled -Value $true
    Set-WebConfigurationProperty -PSPath $apphost -Location $location -Filter "$authBase/anonymousAuthentication" -Name enabled -Value $false
    Write-Ok "Anonymous access off, Windows Authentication on"

    $authz = "system.webServer/security/authorization"
    Clear-WebConfiguration -PSPath $apphost -Location $location -Filter $authz -ErrorAction SilentlyContinue
    if ($AllowGroups.Count -gt 0) {
        # Remove the server-wide "allow everyone" rule for this app, then allow only the listed groups.
        try {
            Remove-WebConfigurationProperty -PSPath $apphost -Location $location -Filter $authz -Name "." `
                -AtElement @{ users = "*"; roles = ""; verbs = "" }
        } catch { }
        Add-WebConfiguration -PSPath $apphost -Location $location -Filter $authz `
            -Value @{ accessType = "Allow"; roles = ($AllowGroups -join ",") }
        Write-Ok ("Access limited to: " + ($AllowGroups -join ", "))
    } else {
        Write-Ok "Any signed-in domain user can open the dashboards"
    }
}

# ---------------------------------------------------------------- start
Write-Step "Starting"
if (Test-Path $offline) { Remove-Item $offline -Force }
if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne "Started") { Start-WebAppPool -Name $AppPoolName }
else { Restart-WebAppPool -Name $AppPoolName }
if ($NewSite -and (Get-WebsiteState -Name $SiteName).Value -ne "Started") { Start-Website -Name $SiteName }

# ---------------------------------------------------------------- smoke test
Write-Step "Checking $url"
$healthy = $false
for ($i = 0; $i -lt 10 -and -not $healthy; $i++) {
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest -Uri ($url + "api/dashboards") -UseBasicParsing -UseDefaultCredentials -TimeoutSec 10
        if ($r.StatusCode -eq 200) { $healthy = $true }
    } catch { }
}

Write-Host ""
if ($healthy) {
    Write-Host "LiveDashboards is running: $url" -ForegroundColor Green
} else {
    Write-Warn2 "The app didn't answer at $url yet. To troubleshoot:"
    Write-Warn2 "  1. Open $url in a browser on this server for the detailed error."
    Write-Warn2 "  2. Check Event Viewer > Windows Logs > Application (source 'IIS AspNetCore Module V2')."
    Write-Warn2 "  3. Set stdoutLogEnabled=""true"" in $InstallPath\web.config and read $InstallPath\logs\."
}
Write-Host ""
Write-Host "Remaining setup:" -ForegroundColor Cyan
Write-Host "  - Edit $InstallPath\appsettings.json: connection strings and tabs. Changes apply without a restart."
Write-Host "  - Give '$identity' read access to each database (see Grant-SqlAccess.sql)."
if (-not $ServiceAccount) {
    Write-Host "    If SQL Server is on another machine, grant access to this server's computer account"
    Write-Host "    (DOMAIN\$($env:COMPUTERNAME)`$) instead, or re-run with -ServiceAccount."
}
Write-Host "  - For HTTPS, see README-IIS.md."
if (-not $useWindowsAuth) {
    Write-Host "  - Anyone who can reach this server can open the dashboards. Re-run with -WindowsAuth or -AllowGroups to require sign-in."
}
