/* EcoVolt PowerMaster - apply the T2 delta on a database loaded with T1.
   Order: new dimension rows -> UPDATEs of changed dimension rows -> new facts.
   Set @dir to the folder with the *_new.csv files (path on the SQL Server machine). */
USE PowerMaster;
SET NOCOUNT ON;

DECLARE @dir  NVARCHAR(400) = N'C:\EcoVolt\Data\T2_delta\PowerMaster\';
DECLARE @opts NVARCHAR(400) = N''' WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'', KEEPIDENTITY, CHECK_CONSTRAINTS, TABLOCK);';

BEGIN TRANSACTION;

/* 1. new dimension rows */
EXEC (N'BULK INSERT dbo.Model FROM ''' + @dir + N'Model_new.csv' + @opts);
EXEC (N'BULK INSERT dbo.Unit  FROM ''' + @dir + N'Unit_new.csv'  + @opts);

/* 2. changes of existing dimension rows */
UPDATE dbo.Manufacturer SET ManufacturerName = 'Siemens Energy', Country = 'Germany' WHERE ManufacturerID = 2;   -- was 'Siemens Gamesa', 'Spain'
UPDATE dbo.Unit SET ModelID = 16, InstallationDate = '2026-08-09T00:00:00' WHERE UnitID = 'PV-WAW-01';   -- repowered, was ModelID 11, installed 2016-08-08
UPDATE dbo.Zone SET AreaSizeSqm = 1236000 WHERE ZoneID = 1;   -- Gdańsk extended, was 932000
UPDATE dbo.Zone SET AreaSizeSqm = 409000 WHERE ZoneID = 7;   -- Poznań extended, was 385000

/* 3. new fact rows */
EXEC (N'BULK INSERT dbo.ProductionLog FROM ''' + @dir + N'ProductionLog_new.csv' + @opts);

COMMIT;

SELECT 'Manufacturer' AS TableName, COUNT(*) AS RowsCount FROM dbo.Manufacturer UNION ALL
SELECT 'Model', COUNT(*) FROM dbo.Model UNION ALL
SELECT 'Zone', COUNT(*) FROM dbo.Zone UNION ALL
SELECT 'Unit', COUNT(*) FROM dbo.Unit UNION ALL
SELECT 'ProductionLog', COUNT(*) FROM dbo.ProductionLog;
