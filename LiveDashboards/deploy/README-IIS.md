# Deploying LiveDashboards to IIS

## 1. Build the package (dev PC or build server)

Requirements: .NET 8 SDK.

```powershell
.\deploy\Publish.ps1 -Version 1.0.0
```

This produces `out\LiveDashboards-IIS-1.0.0.zip`, containing:

| Item | Purpose |
|---|---|
| `site\` | The published web app |
| `Install-IIS.ps1` | Installs or updates the app on IIS |
| `Grant-SqlAccess.sql` | Gives the app pool read-only access to your databases |
| `README-IIS.md` | This file |

From Visual Studio instead: right-click the project > **Publish** > **IIS-Folder**. Output goes to `out\site\`.

## 2. Prepare the IIS server (once)

1. **IIS** with the **WebSocket Protocol** feature. The installer can add it with `-InstallMissingFeatures`.
2. **ASP.NET Core 8 Hosting Bundle**: download it from https://dotnet.microsoft.com/download/dotnet/8.0 (it's listed under *ASP.NET Core Runtime* as *Hosting Bundle*). Run `iisreset` after installing it.
3. Optional: **Application Initialization** (IIS feature). With it, the app starts as soon as IIS starts rather than on the first visit.

## 3. Install

Copy the zip to the server, extract it, open **PowerShell as Administrator** in the extracted folder, and run one of these:

```powershell
# As an application under the default site:   http://server/dashboards/
.\Install-IIS.ps1

# Different sub-path:                            http://server/ops/
.\Install-IIS.ps1 -AppPath ops

# As its own site on a port:                     http://server:8080/
.\Install-IIS.ps1 -NewSite -SiteName LiveDashboards -Port 8080

# Own site with a host name, running as a domain service account
.\Install-IIS.ps1 -NewSite -SiteName LiveDashboards -Port 80 -HostHeader dashboards.contoso.local -ServiceAccount CONTOSO\svc-dashboards
```

### Naming the installation

Use `-Name` to give the installation its own name. It sets the web address, the app pool and the install folder in one go:

```powershell
.\Install-IIS.ps1 -Name OpsDashboards
```

| Name | Value |
|---|---|
| Web address | `http://server/opsdashboards/` (lower-case `-Name`) |
| App pool | `OpsDashboards`, so the SQL login is `IIS APPPOOL\OpsDashboards` |
| Install folder | `C:\inetpub\OpsDashboards` |
| Site name (only with `-NewSite`) | `OpsDashboards` |

- Any of these can still be set separately, and `-AppPath`, `-AppPoolName`, `-InstallPath` and `-SiteName` win over `-Name`. For example, `-Name OpsDashboards -AppPath ops` puts it at `/ops/`.
- Names can use letters, digits, `-`, `_` and `.`, with no spaces.
- **Several installations side by side:** each `-Name` gets its own folder, `appsettings.json` and app pool, so different teams can have their own dashboards on one server.
- **Updating:** run the installer again with the **same `-Name`** (and the same other options). A different name creates a second installation rather than updating the first.
- Without `-Name`, the names are `/dashboards/`, `LiveDashboards` and `C:\inetpub\LiveDashboards`, as before.

The script prints the resolved names before it changes anything, so you can stop it (Ctrl+C) if one is wrong.

The script:
- checks the prerequisites and tells you exactly what's missing
- creates an app pool (No Managed Code, always running, no idle shutdown, nightly recycle at 3:00 AM)
- copies the files to `C:\inetpub\LiveDashboards` (change with `-InstallPath`)
- grants the app pool read access to the app folder, write access to `logs\` only, and locks `appsettings.json` down to Administrators, SYSTEM and the app pool
- creates the IIS application or site, starts it, and checks that it answers
- optionally requires Windows sign-in (`-WindowsAuth`) or limits access to AD groups (`-AllowGroups`)

## 4. Configure

1. Edit `C:\inetpub\LiveDashboards\appsettings.json`: set your connection strings and tabs (see the main README). Changes apply without a restart.
2. Give the app pool read access to each database. Open `Grant-SqlAccess.sql` in SSMS, set `@Login` and `@Databases`, and run it:

   | Where SQL Server runs | `@Login` |
   |---|---|
   | Same machine as IIS | `IIS APPPOOL\LiveDashboards` |
   | Another machine | The IIS server's computer account, e.g. `CONTOSO\WEBSERVER01$` |
   | App pool uses `-ServiceAccount` | That account, e.g. `CONTOSO\svc-dashboards` |

   The login gets **read-only** access (`db_datareader`).

   **SQL logins instead of Windows auth:** put `User ID=...;Password=...` in the connection string and leave the app pool identity alone. `appsettings.json` is already locked down for that reason.

## 5. Updating to a new version

Build a new package, extract it on the server, and run `Install-IIS.ps1` again **with the same parameters** you used to install.

- Users see a brief "being updated" page for a few seconds; open dashboards reconnect on their own.
- Your `appsettings.json` is **kept**. To replace it with the package's copy, add `-OverwriteConfig`.

## Recommended for production

**HTTPS.** In IIS Manager > the site > **Bindings**, add an `https` binding with your certificate. To force HTTPS, install the IIS **URL Rewrite** module and add an HTTP→HTTPS redirect rule, or remove the http binding.

**Require sign-in.** Use the installer, so the setting survives updates (it's stored in IIS's server config, not in the app's `web.config`):

```powershell
# Any domain user (Windows sign-in; browsers on the domain sign in automatically)
.\Install-IIS.ps1 -WindowsAuth

# Only members of specific AD groups
.\Install-IIS.ps1 -AllowGroups "CONTOSO\Dashboard Viewers","CONTOSO\IT Ops"
```

Add `-InstallMissingFeatures` if the IIS *Windows Authentication* or *URL Authorization* features aren't installed yet. Pass the same option on later updates; leaving it out doesn't remove existing sign-in settings.

**One worker process.** The installer sets the app pool's maximum worker processes to 1 (no web garden). Live updates need that. For more than one server behind a load balancer, enable sticky sessions, or ask about adding a SignalR backplane.

## Troubleshooting

| Symptom | Fix |
|---|---|
| **HTTP 500.19** | The ASP.NET Core Hosting Bundle isn't installed, or IIS wasn't restarted after installing it. Install it, then run `iisreset`. |
| **HTTP 500.30 / 500.31** | The app failed to start. Look in Event Viewer > Application (source *IIS AspNetCore Module V2*), or set `stdoutLogEnabled="true"` in `web.config` and read `logs\stdout_*.log`. Usually a typo in `appsettings.json`. |
| **Tab shows "Data source unavailable"** | The app pool account can't reach that database. Check the connection string and run `Grant-SqlAccess.sql` for the right login (see step 4). Event Viewer > Application has the exact SQL error. |
| **Header says "Polling every Ns" instead of "Live"** | The browser couldn't load the SignalR client from the CDN (common on locked-down networks). Everything still works, just less instantly. To fix it, host the script locally (see the main README). |
| **Live updates lag by a few seconds** | The IIS WebSocket Protocol feature is missing, so SignalR uses long polling. Re-run the installer with `-InstallMissingFeatures`. |
| **Page loads, but nothing appears under a sub-path** | Use the address with a trailing slash (`/dashboards/`). The app redirects `/dashboards` to it automatically. |
