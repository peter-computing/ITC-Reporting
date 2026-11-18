/* =========================================================================
   LiveDashboard (multi-tab) – demo databases
   SQL Server 2016+ / Azure SQL / LocalDB
   Run in SSMS or:  sqlcmd -S localhost -E -i db\setup.sql

   Two separate databases, one per tab, to show distinct data sources:
     LiveDashboardMT_Finance.dbo.Projects  → "Project budgets" tab (currency)
     LiveDashboardMT_Ops.dbo.Tasks         → "Task status" tab (no currency)
   Skip this if you're pointing the tabs at your own tables or views.
   ========================================================================= */

/* ---------- Finance: project budgets (currency-based) ------------------- */
IF DB_ID('LiveDashboardMT_Finance') IS NULL
    CREATE DATABASE LiveDashboardMT_Finance;
GO
USE LiveDashboardMT_Finance;
GO

IF OBJECT_ID('dbo.Projects', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Projects
    (
        Id         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Projects PRIMARY KEY,
        Name       NVARCHAR(100)     NOT NULL,
        Department NVARCHAR(50)      NOT NULL,
        Owner      NVARCHAR(100)     NULL,
        Status     VARCHAR(20)       NOT NULL
                   CONSTRAINT CK_Projects_Status CHECK (Status IN ('on_track','at_risk','over_budget','closed')),
        Budget     DECIMAL(18,2)     NOT NULL CONSTRAINT DF_Projects_Budget DEFAULT (0),
        Spent      DECIMAL(18,2)     NOT NULL CONSTRAINT DF_Projects_Spent  DEFAULT (0),
        DueDate    DATE              NULL,
        Notes      NVARCHAR(1000)    NULL,
        UpdatedAt  DATETIME2(3)      NOT NULL CONSTRAINT DF_Projects_UpdatedAt DEFAULT (SYSUTCDATETIME())
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Projects)
BEGIN
    INSERT INTO dbo.Projects (Name, Department, Owner, Status, Budget, Spent, DueDate, Notes) VALUES
        (N'Badge reader rollout',        N'IT',         N'Lee Nguyen',   'on_track',    76000, 41200, '2026-12-19', N'Buildings A and B complete. Building C pending network drop.'),
        (N'Plant floor laptop refresh',  N'IT',         N'Lee Nguyen',   'at_risk',     54000, 49800, '2027-02-01', N'Vendor price increase on rugged models.'),
        (N'Conveyor guard replacement',  N'Operations', N'Sam Patel',    'over_budget', 31000, 36400, '2026-11-30', N'Additional guards required after safety walk.'),
        (N'Shift handover tooling',      N'Operations', N'Sam Patel',    'on_track',    12500,  4100, '2027-01-20', NULL),
        (N'Forklift fleet recertification', N'Safety',  N'Dana Ortiz',   'on_track',    42000, 18900, '2026-12-05', NULL),
        (N'ISO 45001 audit',             N'Quality',    N'Morgan Reyes', 'at_risk',     39000, 33500, '2026-12-01', N'External auditor added a second site day.'),
        (N'Onboarding portal',           N'HR',         N'Alex Kim',     'closed',      12000, 11650, '2026-10-15', N'Live since October.');
END
GO

/* ---------- Operations: task status (no currency) ----------------------- */
IF DB_ID('LiveDashboardMT_Ops') IS NULL
    CREATE DATABASE LiveDashboardMT_Ops;
GO
USE LiveDashboardMT_Ops;
GO

IF OBJECT_ID('dbo.Tasks', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Tasks
    (
        Id        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Tasks PRIMARY KEY,
        Name      NVARCHAR(100)     NOT NULL,
        Category  NVARCHAR(50)      NOT NULL,
        Owner     NVARCHAR(100)     NULL,
        Location  NVARCHAR(100)     NULL,
        Priority  VARCHAR(10)       NOT NULL CONSTRAINT DF_Tasks_Priority DEFAULT ('Medium')
                  CONSTRAINT CK_Tasks_Priority CHECK (Priority IN ('Low','Medium','High')),
        Status    VARCHAR(20)       NOT NULL
                  CONSTRAINT CK_Tasks_Status CHECK (Status IN ('open','in_progress','blocked','done')),
        DueDate   DATE              NULL,
        Notes     NVARCHAR(1000)    NULL,
        UpdatedAt DATETIME2(3)      NOT NULL CONSTRAINT DF_Tasks_UpdatedAt DEFAULT (SYSUTCDATETIME())
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.Tasks)
BEGIN
    INSERT INTO dbo.Tasks (Name, Category, Owner, Location, Priority, Status, DueDate, Notes) VALUES
        (N'Forklift recertification',     N'Safety',     N'Dana Ortiz',   N'Warehouse',     'High',   'in_progress', '2026-12-05', N'14 of 22 operators recertified.'),
        (N'Lockout/tagout refresher',     N'Safety',     N'Dana Ortiz',   N'Plant floor',   'Medium', 'open',        '2027-01-15', NULL),
        (N'Quarterly all-hands',          N'Operations', N'Sam Patel',    N'Main hall',     'Low',    'done',        '2026-10-30', N'Recording posted to the intranet.'),
        (N'Shift handover redesign',      N'Operations', N'Sam Patel',    N'Plant floor',   'High',   'blocked',     '2026-11-20', N'Waiting on union review of the new checklist.'),
        (N'Badge reader install – Bldg C',N'IT',         N'Lee Nguyen',   N'Building C',    'High',   'in_progress', '2026-12-19', N'Network drop scheduled.'),
        (N'ISO audit document review',    N'Quality',    N'Morgan Reyes', N'Office',        'High',   'in_progress', '2026-12-01', NULL),
        (N'New-hire orientation',         N'HR',         N'Alex Kim',     N'Training room', 'Low',    'done',        '2026-11-03', NULL);
END
GO
