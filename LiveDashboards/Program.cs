using System.Data;
using System.Collections.Concurrent;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

// ===========================================================================
// LiveDashboard (multi-tab) – read-only SQL Server dashboards with live push
// updates. Each tab is one entry in "LiveDashboards:Dashboards" in
// appsettings.json, with its own connection string, query, grid/detail
// fields, summary tiles, status colors and (optional) currency.
// Edits to appsettings.json apply without a restart; browsers redraw.
// ===========================================================================

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<AppOptions>(builder.Configuration.GetSection("LiveDashboards"));
builder.Services.AddSignalR();
builder.Services.AddSingleton<RowRepository>();
builder.Services.AddSingleton<RefreshStatusStore>();
builder.Services.AddHostedService<ChangeWatcher>();

var app = builder.Build();

// Under an IIS sub-application (e.g. /dashboards) make sure the page is
// always requested with a trailing slash, so its relative URLs resolve
// to /dashboards/api/... rather than /api/...
app.Use(async (ctx, next) =>
{
    if (ctx.Request.PathBase.HasValue && !ctx.Request.Path.HasValue)
    {
        ctx.Response.Redirect($"{ctx.Request.PathBase}/{ctx.Request.QueryString}", permanent: false);
        return;
    }
    await next();
});

app.UseDefaultFiles();   // serves wwwroot/index.html at "/"
app.UseStaticFiles();

// Tab list
app.MapGet("/api/dashboards", (IOptionsMonitor<AppOptions> o) => Results.Ok(new
{
    o.CurrentValue.Title,
    o.CurrentValue.Rotation,
    Dashboards = o.CurrentValue.Dashboards.Select(d => new { d.Id, d.Title, d.RotationSeconds, d.IncludeInRotation })
}));

// One tab's display settings (never exposes SQL or connection strings)
app.MapGet("/api/dashboards/{id}/config", (string id, IOptionsMonitor<AppOptions> o) =>
    o.CurrentValue.Find(id) is { } d
        ? Results.Ok(new
        {
            d.Id, d.Title, d.CurrencyCode, d.KeyField, d.TitleField, d.DefaultSort, d.DefaultSortDescending,
            d.Fields, d.Summary, d.Group, d.Statuses,
            RefreshMs = o.CurrentValue.EffectivePollMs(d),
            MaxRows = o.CurrentValue.EffectiveMaxRows(d)
        })
        : Results.NotFound());

// When the server last checked this tab's source, and whether that worked
app.MapGet("/api/dashboards/{id}/status", (string id, IOptionsMonitor<AppOptions> o, RefreshStatusStore store) =>
    o.CurrentValue.Find(id) is { } d
        ? Results.Ok(store.Get(d.Id))
        : Results.NotFound());

// One tab's rows
app.MapGet("/api/dashboards/{id}/rows", async (string id, IOptionsMonitor<AppOptions> o, RowRepository repo) =>
    o.CurrentValue.Find(id) is { } d
        ? Results.Ok(await repo.GetAllAsync(d, o.CurrentValue.EffectiveMaxRows(d)))
        : Results.NotFound());

app.MapHub<DashboardHub>("/hubs/dashboard");

app.Run();


// ===========================================================================
// Configuration model (appsettings.json → "LiveDashboards")
// ===========================================================================
public sealed class AppOptions
{
    public string Title { get; set; } = "Live Dashboards";
    /// <summary>Default refresh interval (ms) for tabs that don't set their own.</summary>
    public int PollMs { get; set; } = 30000;
    /// <summary>Default row limit for tabs that don't set their own. 0 = no limit.</summary>
    public int MaxRows { get; set; } = 5000;
    /// <summary>Automatic tab rotation (e.g. for a wall screen).</summary>
    public RotationOptions Rotation { get; set; } = new();
    public List<DashboardOptions> Dashboards { get; set; } = [];

    public DashboardOptions? Find(string id) =>
        Dashboards.FirstOrDefault(d => string.Equals(d.Id, id, StringComparison.OrdinalIgnoreCase));

    /// <summary>The tab's own PollMs if set, else the global one. Never below 250 ms.</summary>
    public int EffectivePollMs(DashboardOptions d) => Math.Max(250, d.PollMs ?? PollMs);

    /// <summary>The tab's own MaxRows if set, else the global one. 0 (or less) = no limit.</summary>
    public int EffectiveMaxRows(DashboardOptions d) => Math.Max(0, d.MaxRows ?? MaxRows);
}

public sealed class DashboardOptions
{
    /// <summary>Short URL-safe id, used in links like /#projects.</summary>
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";

    /// <summary>How often (ms) to check this tab's source for changes. Empty = LiveDashboards:PollMs.</summary>
    public int? PollMs { get; set; }

    /// <summary>Most rows this tab loads. Empty = LiveDashboards:MaxRows. 0 = no limit.</summary>
    public int? MaxRows { get; set; }

    /// <summary>How long this tab stays on screen during auto-rotation. Empty = Rotation:IntervalSeconds.</summary>
    public int? RotationSeconds { get; set; }
    /// <summary>Set false to skip this tab during auto-rotation (it can still be opened by hand).</summary>
    public bool IncludeInRotation { get; set; } = true;
    /// <summary>
    /// Which rows to keep when the limit applies, as a SQL ORDER BY list over the
    /// query's columns, e.g. "UpdatedAt DESC" or "Priority, DueDate". Empty = whatever order SQL returns.
    /// </summary>
    public string? MaxRowsOrderBy { get; set; }

    /// <summary>Name of an entry under ConnectionStrings.</summary>
    public string Connection { get; set; } = "";
    /// <summary>The SELECT for this tab. Column names are the field names used below. No ORDER BY.</summary>
    public string Query { get; set; } = "";
    /// <summary>One-row query whose result changes whenever the data changes. Empty = checksum of Query.</summary>
    public string? ChangeQuery { get; set; }
    /// <summary>Treat DATETIME/DATETIME2 values as UTC (recommended if you store SYSUTCDATETIME()).</summary>
    public bool DatesAreUtc { get; set; } = true;

    /// <summary>ISO currency code for fields with Format "currency" (USD, EUR, CAD…). Ignored if the tab has none.</summary>
    public string CurrencyCode { get; set; } = "USD";

    public string KeyField { get; set; } = "Id";
    public string? TitleField { get; set; }
    public string? DefaultSort { get; set; }
    public bool DefaultSortDescending { get; set; }

    public List<FieldOptions> Fields { get; set; } = [];
    public List<SummaryOptions> Summary { get; set; } = [];
    public GroupOptions? Group { get; set; }
    public Dictionary<string, StatusOptions> Statuses { get; set; } = new();
}

public sealed class RotationOptions
{
    /// <summary>Rotate through the tabs automatically. A screen can override this with ?rotate=0 / ?rotate=1 / ?rotate=SECONDS.</summary>
    public bool Enabled { get; set; }
    /// <summary>Seconds each tab stays on screen (unless the tab sets RotationSeconds). Minimum 5.</summary>
    public int IntervalSeconds { get; set; } = 60;
    /// <summary>After a click, key press or scroll, wait this many seconds before rotating again. 0 = never pause.</summary>
    public int PauseOnInteractionSeconds { get; set; } = 120;
}

public sealed class FieldOptions
{
    public string Field { get; set; } = "";
    public string? Label { get; set; }
    /// <summary>text | number | currency | percent | date | datetime | status | boolean | multiline</summary>
    public string Format { get; set; } = "text";
    public bool Grid { get; set; } = true;
    public bool Detail { get; set; } = true;
}

public sealed class SummaryOptions
{
    public string Label { get; set; } = "";
    /// <summary>count | sum | avg | min | max</summary>
    public string Agg { get; set; } = "count";
    public string? Field { get; set; }
    /// <summary>Only include rows where Field equals this value (e.g. Status = "open").</summary>
    public string? Match { get; set; }
    public string? Format { get; set; }
}

public sealed class GroupOptions
{
    /// <summary>Rows sharing this field's value are shown as "related" in the detail pane.</summary>
    public string Field { get; set; } = "";
    /// <summary>Optional numeric field used for the "share of group" meter.</summary>
    public string? ValueField { get; set; }
}

/// <summary>
/// How one status value is displayed. Keys are raw database values (matched
/// case-insensitively); "*" is the fallback for any value not listed.
/// </summary>
public sealed class StatusOptions
{
    public string? Label { get; set; }
    /// <summary>green | yellow | red | gray | blue, or a hex color such as #8e44ad.</summary>
    public string? Color { get; set; }
    /// <summary>Optional icon text inside the dot. Defaults: ✓ green, … yellow, ✕ red.</summary>
    public string? Icon { get; set; }
}

/// <summary>
/// Server → client: "dataChanged"(id) to everyone (drives the tab dots),
/// "refreshed"(status) only to browsers viewing that tab, "configChanged".
/// Client → server: Watch(id) / Unwatch(id) when switching tabs.
/// </summary>
public class DashboardHub : Hub
{
    public static string GroupFor(string id) => "tab:" + id.ToLowerInvariant();
    public Task Watch(string id) => Groups.AddToGroupAsync(Context.ConnectionId, GroupFor(id));
    public Task Unwatch(string id) => Groups.RemoveFromGroupAsync(Context.ConnectionId, GroupFor(id));
}

/// <summary>Last refresh result for one tab, as sent to the browser.</summary>
public sealed record RefreshStatus(
    string Id,
    DateTime? LastCheckedUtc,    // last successful check of the source
    DateTime? LastChangedUtc,    // last time the data actually changed
    bool Ok,
    DateTime? FailingSinceUtc,   // set while the source is unreachable
    int RefreshMs);

public sealed class RefreshStatusStore
{
    private readonly ConcurrentDictionary<string, RefreshStatus> _items = new(StringComparer.OrdinalIgnoreCase);
    public RefreshStatus Get(string id) => _items.TryGetValue(id, out var s) ? s : new(id, null, null, true, null, 0);
    public void Set(RefreshStatus s) => _items[s.Id] = s;
}

// ===========================================================================
// Data access – runs a tab's SELECT and returns rows as dictionaries.
// ===========================================================================
public sealed class RowRepository(IConfiguration config)
{
    public string ConnectionStringFor(DashboardOptions d) =>
        config.GetConnectionString(d.Connection)
        ?? throw new InvalidOperationException(
            $"Dashboard '{d.Id}': no ConnectionStrings:{d.Connection} in appsettings.json");

    /// <summary>
    /// Runs the tab's query, returning at most <paramref name="maxRows"/> rows (0 = all).
    /// If the limit cuts rows off, it also returns the full row count and the
    /// summary tiles computed by SQL over ALL rows, so totals stay correct.
    /// </summary>
    public async Task<RowsResult> GetAllAsync(DashboardOptions d, int maxRows)
    {
        if (string.IsNullOrWhiteSpace(d.Query))
            throw new InvalidOperationException($"Dashboard '{d.Id}': Query is not set");

        var limited = maxRows > 0;
        // Fetch one extra row so we know whether the limit actually cut anything off.
        var sql = !limited ? d.Query
            : $"SELECT TOP ({maxRows + 1}) * FROM ({d.Query}) AS q"
              + (string.IsNullOrWhiteSpace(d.MaxRowsOrderBy) ? "" : $" ORDER BY {d.MaxRowsOrderBy}");

        await using var conn = new SqlConnection(ConnectionStringFor(d));
        await conn.OpenAsync();

        var rows = new List<Dictionary<string, object?>>();
        await using (var cmd = new SqlCommand(sql, conn))
        await using (var r = await cmd.ExecuteReaderAsync())
        {
            while (await r.ReadAsync())
            {
                var row = new Dictionary<string, object?>(r.FieldCount);
                for (var i = 0; i < r.FieldCount; i++)
                {
                    object? v = r.IsDBNull(i) ? null : r.GetValue(i);
                    var isDate = r.GetDataTypeName(i) == "date";
                    if (v is DateTime dt)
                        v = isDate ? dt.ToString("yyyy-MM-dd")                   // plain dates: no time zone shifting
                            : d.DatesAreUtc ? DateTime.SpecifyKind(dt, DateTimeKind.Utc) : dt;
                    row[r.GetName(i)] = v;
                }
                rows.Add(row);
            }
        }

        var truncated = limited && rows.Count > maxRows;
        if (!truncated) return new RowsResult(rows, rows.Count, maxRows, false, null);

        rows.RemoveAt(rows.Count - 1);
        var (total, summary) = await ReadTotalsAsync(conn, d);
        return new RowsResult(rows, total, maxRows, true, summary);
    }

    /// <summary>Full row count plus every summary tile, computed in one query over the whole result.</summary>
    private static async Task<(long Total, List<object?> Summary)> ReadTotalsAsync(SqlConnection conn, DashboardOptions d)
    {
        static string Col(string name) => "[" + name.Replace("]", "]]") + "]";

        await using var cmd = new SqlCommand { Connection = conn };
        var parts = new List<string> { "COUNT_BIG(*)" };
        for (var i = 0; i < d.Summary.Count; i++)
        {
            var s = d.Summary[i];
            var hasField = !string.IsNullOrWhiteSpace(s.Field);
            string? cond = null;
            if (hasField && s.Match is not null)
            {
                cond = $"CAST({Col(s.Field!)} AS nvarchar(4000)) = @m{i}";
                cmd.Parameters.Add($"@m{i}", SqlDbType.NVarChar, 4000).Value = s.Match;
            }
            var agg = (s.Agg ?? "count").ToLowerInvariant();
            var col = hasField ? Col(s.Field!) : "NULL";
            var val = cond is null ? col : $"CASE WHEN {cond} THEN {col} END";
            parts.Add(agg switch
            {
                "sum" when hasField => $"SUM({val})",
                "avg" when hasField => $"AVG(CAST({val} AS float))",
                "min" when hasField => $"MIN({val})",
                "max" when hasField => $"MAX({val})",
                _ when cond is not null => $"SUM(CASE WHEN {cond} THEN 1 ELSE 0 END)",
                _ => "COUNT_BIG(*)",
            });
        }
        cmd.CommandText = $"SELECT {string.Join(", ", parts)} FROM ({d.Query}) AS q";

        await using var r = await cmd.ExecuteReaderAsync();
        await r.ReadAsync();
        var total = Convert.ToInt64(r.GetValue(0));
        var summary = new List<object?>(d.Summary.Count);
        for (var i = 1; i < r.FieldCount; i++) summary.Add(r.IsDBNull(i) ? null : r.GetValue(i));
        return (total, summary);
    }
}

/// <summary>
/// Rows for one tab. When <c>Truncated</c>, <c>TotalRows</c> is the full count and
/// <c>Summary</c> holds each summary tile's value (in config order) over all rows.
/// </summary>
public sealed record RowsResult(
    List<Dictionary<string, object?>> Rows,
    long TotalRows,
    int MaxRows,
    bool Truncated,
    List<object?>? Summary);

// ===========================================================================
// Change watcher. Each tab is checked on its own schedule (its PollMs, or the
// global one). When a tab's data changes, everyone gets "dataChanged"(id);
// browsers viewing that tab also get "refreshed" after every check so they
// can show an accurate "last refreshed" time. One failing source never
// blocks the others.
// ===========================================================================
public sealed class ChangeWatcher(
    IOptionsMonitor<AppOptions> options,
    RowRepository repo,
    RefreshStatusStore store,
    IHubContext<DashboardHub> hub,
    ILogger<ChangeWatcher> log) : BackgroundService
{
    private const int TickMs = 250;   // scheduler resolution

    private readonly ConcurrentDictionary<string, string> _tokens = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, DateTime> _nextDue = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte> _inFlight = new(StringComparer.OrdinalIgnoreCase);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var configSub = options.OnChange(_ =>
        {
            log.LogInformation("Dashboard configuration changed; notifying browsers");
            _tokens.Clear();    // queries may have changed – start fresh
            _nextDue.Clear();   // apply new intervals right away
            _ = hub.Clients.All.SendAsync("configChanged", CancellationToken.None);
        });

        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(TickMs));
        do
        {
            var app = options.CurrentValue;
            var now = DateTime.UtcNow;
            foreach (var d in app.Dashboards.Where(d => !string.IsNullOrWhiteSpace(d.Id)))
            {
                if (_nextDue.TryGetValue(d.Id, out var due) && due > now) continue;
                if (!_inFlight.TryAdd(d.Id, 0)) continue;              // previous check still running
                var interval = app.EffectivePollMs(d);
                _nextDue[d.Id] = now.AddMilliseconds(interval);
                _ = CheckAsync(d, interval, stoppingToken)
                    .ContinueWith(_ => _inFlight.TryRemove(d.Id, out byte removed), TaskScheduler.Default);
            }
        }
        while (await WaitAsync(timer, stoppingToken));
    }

    private static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken ct)
    {
        try { return await timer.WaitForNextTickAsync(ct); }
        catch (OperationCanceledException) { return false; }
    }

    private async Task CheckAsync(DashboardOptions d, int intervalMs, CancellationToken ct)
    {
        var prev = store.Get(d.Id);
        RefreshStatus status;
        try
        {
            var query = string.IsNullOrWhiteSpace(d.ChangeQuery)
                ? $"SELECT COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM ({d.Query}) AS q"
                : d.ChangeQuery;
            var token = await ReadTokenAsync(repo.ConnectionStringFor(d), query, ct);
            var now = DateTime.UtcNow;

            if (!prev.Ok)
                log.LogInformation("Dashboard '{Id}' source is reachable again", d.Id);

            var changed = _tokens.TryGetValue(d.Id, out var last) && last != token;
            _tokens[d.Id] = token;

            status = new RefreshStatus(d.Id, now, changed ? now : prev.LastChangedUtc ?? now, true, null, intervalMs);
            store.Set(status);

            if (changed)
            {
                log.LogInformation("Dashboard '{Id}' data changed", d.Id);
                await hub.Clients.All.SendAsync("dataChanged", d.Id, ct);
            }
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            if (prev.Ok)   // log once per outage, not every poll
                log.LogWarning(ex, "Change check failed for dashboard '{Id}'; will keep retrying", d.Id);
            status = prev with { Ok = false, FailingSinceUtc = prev.FailingSinceUtc ?? DateTime.UtcNow, RefreshMs = intervalMs };
            store.Set(status);
        }
        catch (OperationCanceledException) { return; }

        try { await hub.Clients.Group(DashboardHub.GroupFor(d.Id)).SendAsync("refreshed", status, ct); }
        catch (Exception ex) when (!ct.IsCancellationRequested) { log.LogDebug(ex, "Couldn't send refresh status"); }
    }

    private static async Task<string> ReadTokenAsync(string cs, string query, CancellationToken ct)
    {
        await using var conn = new SqlConnection(cs);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(query, conn);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return "empty";

        var parts = new string[r.FieldCount];
        for (var i = 0; i < r.FieldCount; i++)
            parts[i] = r.IsDBNull(i) ? "null" : Convert.ToString(r.GetValue(i)) ?? "";
        return string.Join('|', parts);
    }
}
