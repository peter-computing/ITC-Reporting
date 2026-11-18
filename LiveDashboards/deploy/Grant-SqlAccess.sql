/* =========================================================================
   Grant LiveDashboards read-only access to SQL Server.
   Run in SSMS as a sysadmin (or a login that can create logins and users).

   1. Set @Login below to the account the IIS app pool runs as:
        - SQL Server on the SAME machine as IIS:   IIS APPPOOL\LiveDashboards
        - SQL Server on ANOTHER machine:           CONTOSO\WEBSERVER01$   (the IIS server's computer account)
        - App pool running as a domain account:     CONTOSO\svc-dashboards
   2. List every database the dashboards read from in @Databases.
   3. Run it. It's safe to run again.

   The login only gets db_datareader (SELECT on all tables and views), plus
   VIEW CHANGE TRACKING where Change Tracking is enabled. It can't write anything.
   For tighter control, replace db_datareader with GRANT SELECT on specific views.
   ========================================================================= */

DECLARE @Login     sysname       = N'IIS APPPOOL\LiveDashboards';
DECLARE @Databases nvarchar(max) = N'LiveDashboardMT_Finance,LiveDashboardMT_Ops';

SET NOCOUNT ON;
DECLARE @sql nvarchar(max);

IF SUSER_ID(@Login) IS NULL
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@Login) + N' FROM WINDOWS WITH DEFAULT_DATABASE = [master];';
    EXEC (@sql);
    PRINT 'Created login ' + @Login;
END
ELSE PRINT 'Login ' + @Login + ' already exists';

DECLARE @db sysname;
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Databases, N',') WHERE LTRIM(RTRIM(value)) <> N'';
OPEN dbs;
FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NULL
        PRINT 'Skipped ' + @db + ': database not found';
    ELSE
    BEGIN
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
            IF USER_ID(@login) IS NULL
                EXEC (N''CREATE USER '' + QUOTENAME(@login) + N'' FOR LOGIN '' + QUOTENAME(@login));
            EXEC (N''ALTER ROLE db_datareader ADD MEMBER '' + QUOTENAME(@login));
            -- Needed only if a tab''s ChangeQuery uses CHANGE_TRACKING_CURRENT_VERSION()
            IF EXISTS (SELECT 1 FROM sys.change_tracking_tables)
            BEGIN
                DECLARE @t nvarchar(max) = N'''';
                SELECT @t += N''GRANT VIEW CHANGE TRACKING ON '' + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N''.'' + QUOTENAME(o.name)
                           + N'' TO '' + QUOTENAME(@login) + N'';''
                FROM sys.change_tracking_tables ct JOIN sys.objects o ON o.object_id = ct.object_id;
                EXEC (@t);
            END';
        EXEC sp_executesql @sql, N'@login sysname', @login = @Login;
        PRINT 'Granted read access on ' + @db;
    END
    FETCH NEXT FROM dbs INTO @db;
END
CLOSE dbs; DEALLOCATE dbs;
