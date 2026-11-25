/* EcoVolt PowerMaster - BULK load of a full snapshot (T1 or T2), Linux/Docker version.

   1. Run Schemas/PowerMaster_schema.sql (creates an empty database).
   2. Copy the Data folder into the container (docker cp) and set @dir below.
   3. Run this script.

   Linux note: CODEPAGE = '65001' is not supported on SQL Server for Linux;
   only 'RAW' is allowed. Files: UTF-8, comma separated, LF line ends,
   header in row 1. KEEPIDENTITY keeps the generated IDs. */
USE PowerMaster;
SET NOCOUNT ON;

DECLARE @dir  NVARCHAR(400) = N'/var/opt/mssql/import/T1/PowerMaster/';   -- use .../T2/PowerMaster/ for T2
DECLARE @opts NVARCHAR(400) = N''' WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''RAW'', KEEPIDENTITY, CHECK_CONSTRAINTS, TABLOCK);';

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