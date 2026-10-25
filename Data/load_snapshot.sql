/* EcoVolt PowerMaster - BULK load of a full snapshot (T1 or T2).

   1. Run Schemas\PowerMaster_schema.sql (creates an empty database).
   2. Set @dir to the snapshot folder ON THE SQL SERVER MACHINE, e.g.
        C:\EcoVolt\Data\T1\PowerMaster\     or     C:\EcoVolt\Data\T2\PowerMaster\
   3. Run this script.

   To go from T1 to T2 incrementally instead, load T1 here and then run
   Data\T2_delta\PowerMaster\apply_T2_delta.sql.

   Files: UTF-8 (CODEPAGE 65001, SQL Server 2016+), comma separated, LF line
   ends, header in row 1, dates as yyyy-MM-dd HH:mm:ss (UTC).
   KEEPIDENTITY keeps the generated IDs, so T1 and T2 keys stay identical. */
USE PowerMaster;
SET NOCOUNT ON;

DECLARE @dir  NVARCHAR(400) = N'C:\EcoVolt\Data\T1\PowerMaster\';
DECLARE @opts NVARCHAR(400) = N''' WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'', KEEPIDENTITY, CHECK_CONSTRAINTS, TABLOCK);';

/* load parents before children */
EXEC (N'BULK INSERT dbo.Manufacturer  FROM ''' + @dir + N'Manufacturer.csv'  + @opts);
EXEC (N'BULK INSERT dbo.Zone          FROM ''' + @dir + N'Zone.csv'          + @opts);
EXEC (N'BULK INSERT dbo.Model         FROM ''' + @dir + N'Model.csv'         + @opts);
EXEC (N'BULK INSERT dbo.Unit          FROM ''' + @dir + N'Unit.csv'          + @opts);
EXEC (N'BULK INSERT dbo.ProductionLog FROM ''' + @dir + N'ProductionLog.csv' + @opts);

SELECT 'Manufacturer' AS TableName, COUNT(*) AS RowsCount FROM dbo.Manufacturer UNION ALL
SELECT 'Model', COUNT(*) FROM dbo.Model UNION ALL
SELECT 'Zone', COUNT(*) FROM dbo.Zone UNION ALL
SELECT 'Unit', COUNT(*) FROM dbo.Unit UNION ALL
SELECT 'ProductionLog', COUNT(*) FROM dbo.ProductionLog;
