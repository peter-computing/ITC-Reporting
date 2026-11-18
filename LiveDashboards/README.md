# LiveDashboard (multi-tab build)

Read-only web dashboards on **ASP.NET Core 8 + SQL Server + SignalR**. Each **tab is its own dashboard with its own data source**: its own connection string, query, grid and detail fields, summary tiles and status colors. A tab is currency-based or not purely through its config.

Every tab updates live, on its own refresh interval. If a tab you're not looking at changes, it gets a blue "updated" dot, and when you open it the changed rows flash. Each tab keeps its own selection, sort and filter while you switch between them.

The header shows when the active tab was **last refreshed**, meaning the last time the server confirmed its data was current. That includes checks where nothing changed, so a quiet table still shows a recent time.

```
SQL source A ─(every 5s)─┐                          ┌─► "dataChanged"(id)  → all browsers (tab dots)
SQL source B ─(every 1s)─┼─► ChangeWatcher ─SignalR─┤
SQL source C ─(every 30s)┘                          └─► "refreshed"(status) → browsers viewing that tab
```

## Run it

Requirements: .NET 8 SDK and SQL Server (Express, LocalDB, full SQL Server or Azure SQL).

```powershell
sqlcmd -S localhost -E -i db\setup.sql     # two demo databases (skip if using your own)
dotnet run                                 # http://localhost:5082
```

The demo has two tabs, each reading from a separate database:

| Tab | Database | Kind |
|---|---|---|
| Project budgets | `LiveDashboardMT_Finance.dbo.Projects` | Currency: budget and spent totals |
| Task status | `LiveDashboardMT_Ops.dbo.Tasks` | No currency: counts and statuses only |

**To try it out:** open the dashboard and run the statements in `db/test-external-change.sql` in SSMS. A change to the tab you're on appears within about a second. A change to the other tab puts the blue dot on it.

## Deploy to IIS (production)

```powershell
.\deploy\Publish.ps1 -Version 1.0.0                         # on a PC with the .NET 8 SDK → out\LiveDashboards-IIS-1.0.0.zip
# copy the zip to the IIS server, extract, then as Administrator:
.\Install-IIS.ps1 -AllowGroups "CONTOSO\Dashboard Viewers"   # → http://server/dashboards/
```

The same `Install-IIS.ps1` call updates an existing install. See **`deploy/README-IIS.md`** for prerequisites, the install options (sub-path or dedicated site, service account, sign-in), SQL permissions, HTTPS and troubleshooting.

## Auto-rotate

The dashboard can cycle through the tabs on its own, which is handy on a wall screen or TV.

```json
"LiveDashboards": {
  "Rotation": {
    "Enabled": true,
    "IntervalSeconds": 60,              // time on each tab
    "PauseOnInteractionSeconds": 120    // after a click, key press or scroll, wait this long before rotating again (0 = never pause)
  },
  "Dashboards": [
    { "Id": "projects", "RotationSeconds": 30, ... },      // this tab stays up for 30 s instead of 60
    { "Id": "admin", "IncludeInRotation": false, ... }     // skipped by rotation, still clickable
  ]
}
```

- **Controls:** the bottom of the sidebar shows the next tab, a countdown bar and a pause/play button. Pausing is remembered in that browser until someone presses play.
- **Pauses for people:** any click, key press, scroll or touch pauses rotation for `PauseOnInteractionSeconds`, so it never switches tabs on someone who's reading. Moving the mouse doesn't count, so a TV with a mouse resting on it keeps rotating.
- **Per-screen override:** add `?rotate=` to the address. It beats the config for that screen only:

  | Address | Effect |
  |---|---|
  | `http://server/dashboards/?rotate=30` | Rotate every 30 s on this screen (minimum 5) |
  | `http://server/dashboards/?rotate=1` | Rotate using the configured interval, even if `Enabled` is false |
  | `http://server/dashboards/?rotate=0` | Never rotate on this screen |

  A common setup is to keep `Enabled: false` for everyone and bookmark `?rotate=60` on the wall display.
- Rotation only runs when two or more tabs are included.

## Last refreshed

The header shows the active tab's refresh status:

| What you see | Meaning |
|---|---|
| **Last refreshed 2:14:05 PM** (3 seconds ago) · checks every 5s | Normal. The server checked the source at that time. |
| ⚠ **Last refreshed 2:14:05 PM** (2 minutes ago) · overdue | No check has come through for over 3× the tab's interval (at least interval + 10 s). Usually a network or server issue. |
| ✕ **Data source unavailable** since 2:10 PM, showing data from 2:09:58 PM | The server can't reach this tab's database. It keeps retrying, and the grid keeps the last data it loaded. |

Hover the timestamp to see the full date, plus when the rows were last actually loaded.

**Links:** each tab has its own URL (`http://server:5082/#tasks`), so you can bookmark or share a specific tab.

**Keyboard:** ↑/↓ switches tabs when the tab sidebar has focus (←/→ also works). In the grid, ↑/↓, PgUp/PgDn and Home/End move the selection.

**Detail pane:** close it with **×** (or Esc) to give the grid the full width. Reopen it with the **Details** button in the grid toolbar, by pressing Enter on the selected row, or by double-clicking a row. Each browser remembers whether it was open or closed.

## Configuration (`appsettings.json`)

### Connection strings: one per data source

```json
"ConnectionStrings": {
  "Finance":    "Server=sql01;Database=Finance;Trusted_Connection=True;TrustServerCertificate=True;ApplicationIntent=ReadOnly;",
  "Operations": "Server=sql02;Database=Ops;Trusted_Connection=True;TrustServerCertificate=True;ApplicationIntent=ReadOnly;"
}
```

Tabs can share a connection or each use their own, even on different servers.

### Tabs

```json
"LiveDashboards": {
  "Title": "Live Dashboards",
  "PollMs": 30000,                      // default refresh interval (30 s) for tabs that don't set their own
  "MaxRows": 5000,                      // default row limit for tabs that don't set their own (0 = no limit)
  "Dashboards": [
    { "Id": "projects", "Title": "Project budgets", "PollMs": 5000, "MaxRows": 1000, "MaxRowsOrderBy": "Budget DESC", "Connection": "Finance",    "Query": "...", "CurrencyCode": "USD", "Fields": [...], ... },
    { "Id": "tasks",    "Title": "Task status",                     "Connection": "Operations", "Query": "...", "Fields": [...], ... }
  ]
}
```

- **Tab order** = order in the list.
- **Add a tab** by adding an entry. **Remove one** by deleting it.
- Changes apply without a restart, and open browsers redraw.
- With only one entry, the tab sidebar hides itself and the dashboard uses the full width.

### Per-tab settings

| Setting | Meaning |
|---|---|
| `Id` | Short, URL-safe name (used in `/#id` links and server logs) |
| `Title` | Tab label |
| `RotationSeconds` | How long this tab stays on screen during auto-rotate. Leave it out to use `Rotation:IntervalSeconds`. |
| `IncludeInRotation` | `false` to skip this tab during auto-rotate (default `true`). |
| `PollMs` | How often to check this tab's source for changes, in milliseconds (e.g. `5000` = every 5 s, `60000` = every minute). Leave it out to use the global `LiveDashboards:PollMs` (default 30 s). Minimum 250. |
| `Connection` | Name of an entry under `ConnectionStrings` |
| `MaxRows` | Most rows this tab loads. Leave it out to use the global `LiveDashboards:MaxRows` (default 5000). `0` = no limit. See [Row limits](#row-limits). |
| `MaxRowsOrderBy` | Which rows to keep when the limit applies, as a SQL sort over the query's columns, e.g. `UpdatedAt DESC` or `Priority, DueDate`. |
| `Query` | The SELECT for this tab, from a table or view. **Its column names are the field names.** Don't end it with `ORDER BY`; use `MaxRowsOrderBy` to choose which rows are kept, and the grid sorts what's shown. |
| `ChangeQuery` | One-row query that changes when the data changes. If left empty, the app checksums `Query`. |
| `CurrencyCode` | ISO code (`USD`, `EUR`, `CAD`, `GBP`…) for this tab's `currency` fields. Ignored by tabs without any. |
| `DatesAreUtc` | Show DATETIME values in the viewer's local time (default `true`). `DATE` columns are never shifted. |
| `KeyField` / `TitleField` | Unique column / heading of the detail pane |
| `DefaultSort` / `DefaultSortDescending` | Initial sort |
| `Fields` | Which columns appear in the grid and which in the detail pane (below) |
| `Summary` | Tiles across the top |
| `Group` | Related-rows section in the detail pane (optional) |
| `Statuses` | Status labels, colors and icons |

### Currency vs. non-currency tabs

There's no switch. A tab is currency-based when it uses `currency` fields and `sum` tiles:

```json
"Fields":  [ { "Field": "Budget", "Format": "currency", "Grid": true, "Detail": true } ],
"Summary": [ { "Label": "Total budget", "Agg": "sum", "Field": "Budget", "Format": "currency" } ],
"Group":   { "Field": "Department", "ValueField": "Budget" }
```

A non-currency tab uses `count` tiles and no currency fields, and leaves out `ValueField` on `Group`:

```json
"Summary": [ { "Label": "Blocked", "Agg": "count", "Field": "Status", "Match": "blocked" } ],
"Group":   { "Field": "Category" }
```

### Fields: grid vs. detail pane

```json
{ "Field": "Owner", "Label": "Owner", "Format": "text", "Grid": false, "Detail": true }
```

| Property | Values |
|---|---|
| `Format` | `text`, `number`, `currency`, `percent` (0.25 → 25%), `date`, `datetime`, `status`, `boolean`, `multiline` |
| `Grid` / `Detail` | `true` to show in that place |

- Order in the list = order on screen.
- Columns not listed are hidden.
- If `Fields` is empty, every column shows in both places.

### Status colors (per tab)

```json
"Statuses": {
  "on_track":    { "Label": "On track",    "Color": "green"  },
  "at_risk":     { "Label": "At risk",     "Color": "yellow" },
  "over_budget": { "Label": "Over budget", "Color": "red"    },
  "on_hold":     { "Label": "On hold",     "Color": "#8e44ad", "Icon": "⏸" },
  "*":           {                         "Color": "gray"   }
}
```

- `Color` can be `green`, `yellow`, `red`, `gray`, `blue`, or a hex code.
- `Icon` is optional. The defaults are ✓ for green, … for yellow and ✕ for red; use `""` for a plain dot.
- Matching ignores case, and `*` is the fallback for any value not listed.
- Each tab has its own map, so "done" can be green on one tab and mean something else on another.

### Row limits

Each tab loads at most `MaxRows` rows. The limit is applied in SQL (`SELECT TOP`), so the extra rows never leave the database.

```json
"MaxRows": 1000,
"MaxRowsOrderBy": "UpdatedAt DESC"     // keep the 1,000 most recently updated rows
```

When a tab hits its limit:
- The grid says so: **"1,000 of 8,412 rows"**, with a *limit* badge. Hover it for details.
- **Summary tiles stay correct.** They're calculated by SQL over all 8,412 rows, not just the 1,000 shown.
- The filter box, sorting and the detail pane's related rows work on the rows loaded. The detail pane notes this.

Suggested limits: about 1,000 for an instant feel, and up to around 5,000 per tab. More tabs don't lower the per-tab limit, because background tabs aren't loaded until you open them. A tighter `WHERE` in `Query` (open items, last 30 days) is often better than a high limit, since nobody scans 5,000 rows.

### Summary tiles

`Agg` can be `count`, `sum`, `avg`, `min` or `max`. `Match` limits a tile to rows where `Field` equals that value. Use an empty list to hide a tab's tiles.

## Read-only by design

- The app has no write endpoints. Its only SQL statements are each tab's `Query` and `ChangeQuery`.
- In production, give each login only `db_datareader` on its source (plus `VIEW CHANGE TRACKING` if you use Change Tracking).
- Queries and connection strings are never sent to the browser.

## Notes

- **Choosing refresh intervals:** each check is one small query against that tab's source. Fast-moving operational data can use 1–2 s. Heavier views or busy production servers are better at 15–60 s. A check is never started while the previous one for the same tab is still running, so a slow source can't pile up queries.
- **Change detection:** each source is checked independently, on its own schedule. A source that's down is logged once and retried; the other tabs keep working. For large tables, enable SQL Server Change Tracking and set that tab's `ChangeQuery` to `SELECT CHANGE_TRACKING_CURRENT_VERSION()`.
- **Background tabs** aren't re-queried until you open them. The server only tells the browser that they changed, so many tabs stay cheap.
- **SignalR client** loads from the jsDelivr CDN. If it's blocked, the page falls back to polling the active tab at that tab's interval (never faster than every 2 s). In that mode, tabs refresh when opened rather than showing the dot. To host the client locally: `libman install @microsoft/signalr@8.0.7 -p unpkg -d wwwroot/lib/signalr --files dist/browser/signalr.min.js`, then change the `<script src>` in `index.html`.
- **IIS:** install the ASP.NET Core Hosting Bundle and enable the **WebSocket Protocol** feature.

## Files

| File | Purpose |
|---|---|
| `Program.cs` | Endpoints, config model, SignalR hub, per-tab `ChangeWatcher` and refresh status |
| `appsettings.json` | Connection strings and all tab configuration |
| `wwwroot/index.html` | Layout and styles (follows the OS light or dark setting) |
| `wwwroot/app.js` | Tabs, grid, detail pane, tiles, live updates |
| `db/setup.sql` | Two demo databases |
| `db/test-external-change.sql` | Statements to test live updates on both tabs |
| `web.config` | IIS hosting settings (in-process, WebSockets, no caching of the page) |
| `Properties/PublishProfiles/IIS-Folder.pubxml` | Folder publish profile for IIS (also usable from Visual Studio) |
| `deploy/Publish.ps1` | Builds the IIS deployment zip |
| `deploy/Install-IIS.ps1` | Installs or updates the app on an IIS server |
| `deploy/Grant-SqlAccess.sql` | Read-only SQL access for the app pool account |
| `deploy/README-IIS.md` | Deployment guide |
