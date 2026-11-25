-- Same load as without_partitions; the partitioned CCI must already exist (01_01), the rows are
-- routed to the yearly partitions by DateKey.
USE EcoVoltDW_Part;
GO

-- Initial load of snapshot T1 (year 2024) straight from the source files:
--   PowerMaster bulk-load CSVs : /dw_data/T1/PowerMaster/{Manufacturer,Model,Zone,Unit,ProductionLog}.csv
--   Weather_Data CSV           : /dw_data/T1/Weather/Weather_Data.csv
-- /dw_data is the generator's Data folder mounted into the SQL Server container (docker-compose.yml).
-- The source rows are staged in temporary tables and transformed into the star schema here.
-- Dates are staged as text and converted with explicit styles (120 / 126), so the load does not
-- depend on the server language or DATEFORMAT. All dates and times are UTC.
-- Snapshot T2 (year 2025) is loaded incrementally by 07_incremental_load_T2.sql.

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT ON;
GO

DROP TABLE IF EXISTS #StageManufacturer, #StageModel, #StageZone, #StageUnit,
                     #StageProductionLog, #StageWeather, #Weather;

IF EXISTS (SELECT 1 FROM dbo.UNIT)
   OR EXISTS (SELECT 1 FROM dbo.ZONE)
   OR EXISTS (SELECT 1 FROM dbo.STATUS)
   OR EXISTS (SELECT 1 FROM dbo.WEATHER)
   OR EXISTS (SELECT 1 FROM dbo.[DATE])
   OR EXISTS (SELECT 1 FROM dbo.[TIME])
   OR EXISTS (SELECT 1 FROM dbo.ENERGY_PRODUCTION)
    THROW 50000, 'Target tables must be empty before the initial load (use 07_incremental_load_T2.sql for T2).', 1;

BEGIN TRY
CREATE TABLE #StageManufacturer (
    ManufacturerID    INT          NOT NULL,
    ManufacturerName  VARCHAR(50)  NOT NULL,
    Country           VARCHAR(30)  NOT NULL
);

CREATE TABLE #StageModel (
    ModelID                INT           NOT NULL,
    ManufacturerID         INT           NOT NULL,
    ModelName              VARCHAR(50)   NOT NULL,
    UnitType               VARCHAR(20)   NOT NULL,
    ExpectedLifespanYears  INT           NOT NULL,
    MaxPowerCapacity       DECIMAL(8,2)  NOT NULL
);

CREATE TABLE #StageZone (
    ZoneID       INT          NOT NULL,
    ZoneName     VARCHAR(15)  NOT NULL,
    AreaSizeSqm  INT          NOT NULL
);

CREATE TABLE #StageUnit (
    UnitID                VARCHAR(10)  NOT NULL,
    ModelID               INT          NOT NULL,
    ZoneID                INT          NOT NULL,
    InstallationDateTime  VARCHAR(19)  NOT NULL   -- yyyy-MM-dd HH:mm:ss
);

CREATE TABLE #StageProductionLog (
    ProductionLogID    INT            NOT NULL,
    UnitID             VARCHAR(10)    NOT NULL,
    LogDateTime        VARCHAR(19)    NOT NULL,   -- yyyy-MM-dd HH:mm:ss, start of the hour
    EnergyProduced     DECIMAL(10,3)  NOT NULL,
    OperationalStatus  VARCHAR(15)    NOT NULL
);

CREATE TABLE #StageWeather (
    [Datetime]        VARCHAR(19)   NOT NULL,     -- yyyy-MM-ddTHH:mm:ss, start of the hour
    ZoneID            INT           NOT NULL,
    AvgTemperature    DECIMAL(4,1)  NOT NULL,
    AvgWindSpeed      DECIMAL(4,1)  NOT NULL,
    Precipitation     DECIMAL(5,1)  NOT NULL,
    CloudCover        TINYINT       NOT NULL,
    SunshineDuration  TINYINT       NOT NULL
);

    BEGIN TRANSACTION;

    BULK INSERT #StageManufacturer
    FROM '/dw_data/T1/PowerMaster/Manufacturer.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageModel
    FROM '/dw_data/T1/PowerMaster/Model.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageZone
    FROM '/dw_data/T1/PowerMaster/Zone.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageUnit
    FROM '/dw_data/T1/PowerMaster/Unit.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageProductionLog
    FROM '/dw_data/T1/PowerMaster/ProductionLog.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageWeather
    FROM '/dw_data/T1/Weather/Weather_Data.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    -- ===================== DATE: every day of the readings =====================
    DECLARE @FromDate DATE, @ToDate DATE;
    SELECT @FromDate = MIN(CONVERT(DATE, CONVERT(DATETIME2(0), LogDateTime, 120))),
           @ToDate   = MAX(CONVERT(DATE, CONVERT(DATETIME2(0), LogDateTime, 120)))
    FROM #StageProductionLog;

    -- Day of week from a fixed Monday (1900-01-01), so it does not depend on @@DATEFIRST.
    -- Season: astronomical calendar ranges.
    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @FromDate, @ToDate) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ),
    d AS (SELECT DATEADD(DAY, CAST(i AS INT), @FromDate) AS dt FROM n)
    INSERT dbo.[DATE] (DateKey, [Date], [Year], QuarterNo, [Month], MonthNo, DayOfWeek, DayOfWeekNo, Season)
    SELECT CONVERT(INT, CONVERT(CHAR(8), d.dt, 112)),
           d.dt,
           YEAR(d.dt),
           DATEPART(QUARTER, d.dt),
           CHOOSE(MONTH(d.dt), 'January','February','March','April','May','June',
                               'July','August','September','October','November','December'),
           MONTH(d.dt),
           CHOOSE(x.DayOfWeekNo, 'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'),
           x.DayOfWeekNo,
           CASE WHEN x.MonthDay BETWEEN 321 AND 620  THEN 'Spring'
                WHEN x.MonthDay BETWEEN 621 AND 922  THEN 'Summer'
                WHEN x.MonthDay BETWEEN 923 AND 1220 THEN 'Autumn'
                ELSE 'Winter' END
    FROM d
    CROSS APPLY (SELECT DATEDIFF(DAY, CAST('19000101' AS DATE), d.dt) % 7 + 1 AS DayOfWeekNo,
                        MONTH(d.dt) * 100 + DAY(d.dt)                         AS MonthDay) AS x;

    -- ===================== TIME: 24 hours =====================
    INSERT dbo.[TIME] (TimeKey, [Hour], TimeOfDay)
    SELECT h.[Hour], h.[Hour],
           CASE WHEN h.[Hour] <= 5  THEN 'night'
                WHEN h.[Hour] <= 11 THEN 'morning'
                WHEN h.[Hour] <= 17 THEN 'afternoon'
                ELSE 'evening' END
    FROM (SELECT TOP (24) CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS TINYINT) AS [Hour]
          FROM sys.all_objects) AS h;

    -- ===================== STATUS =====================
    INSERT dbo.STATUS (OperationalStatus, IsOperating)
    VALUES ('Operating', 1), ('Fault', 0), ('Maintenance', 0);

    -- ===================== WEATHER: unknown member (key 0) + 1200 combinations =====================
    INSERT dbo.WEATHER (AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory,
                        CloudCoverCategory, SunshineDurationCategory)
    VALUES ('unknown', 'unknown', 'unknown', 'unknown', 'unknown');

    WITH t AS (SELECT * FROM (VALUES ('freezing',1),('cold',2),('moderate',3),('warm',4),('hot',5)) AS v(Cat, Ord)),
         w AS (SELECT * FROM (VALUES ('calm',1),('light',2),('moderate',3),('strong',4)) AS v(Cat, Ord)),
         p AS (SELECT * FROM (VALUES ('none',1),('light',2),('moderate',3),('heavy',4)) AS v(Cat, Ord)),
         c AS (SELECT * FROM (VALUES ('clear',1),('partly cloudy',2),('overcast',3)) AS v(Cat, Ord)),
         s AS (SELECT * FROM (VALUES ('none',1),('low',2),('medium',3),('high',4),('full',5)) AS v(Cat, Ord))
    INSERT dbo.WEATHER (AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory,
                        CloudCoverCategory, SunshineDurationCategory)
    SELECT t.Cat, w.Cat, p.Cat, c.Cat, s.Cat
    FROM t CROSS JOIN w CROSS JOIN p CROSS JOIN c CROSS JOIN s
    ORDER BY t.Ord, w.Ord, p.Ord, c.Ord, s.Ord;

    -- ===================== ZONE (SCD2, first version open to the past) =====================
    INSERT dbo.ZONE (ZoneID, ZoneName, AreaSizeSqm, ValidFrom, ValidTo, IsCurrent)
    SELECT ZoneID, ZoneName, AreaSizeSqm, '19000101', '99991231', 1
    FROM #StageZone;

    -- ===================== UNIT (SCD2, first version valid from the installation) =====================
    INSERT dbo.UNIT (UnitID, ManufacturerID, ManufacturerName, ManufacturerCountry, ModelID, ModelName,
                     UnitType, MaxPowerCapacity, InstallationDateTime, ExpectedLifespanYears,
                     ValidFrom, ValidTo, IsCurrent)
    SELECT u.UnitID, mf.ManufacturerID, mf.ManufacturerName, mf.Country, m.ModelID, m.ModelName,
           m.UnitType, m.MaxPowerCapacity, i.InstallationDateTime, m.ExpectedLifespanYears,
           i.InstallationDateTime, '99991231', 1
    FROM #StageUnit AS u
    JOIN #StageModel AS m         ON m.ModelID = u.ModelID
    JOIN #StageManufacturer AS mf ON mf.ManufacturerID = m.ManufacturerID
    CROSS APPLY (SELECT CONVERT(DATETIME, CONVERT(DATETIME2(0), u.InstallationDateTime, 120)) AS InstallationDateTime) AS i;

    -- ===================== Weather of every zone-hour, categorised =====================
    SELECT CONVERT(DATETIME, CONVERT(DATETIME2(0), sw.[Datetime], 126)) AS [Datetime],
           sw.ZoneID, sw.AvgTemperature, sw.AvgWindSpeed, sw.Precipitation, sw.CloudCover, sw.SunshineDuration,
           ISNULL(wd.WeatherKey, 0) AS WeatherKey
    INTO #Weather
    FROM #StageWeather AS sw
    CROSS APPLY (SELECT
        CASE WHEN sw.AvgTemperature < 0  THEN 'freezing'
             WHEN sw.AvgTemperature < 10 THEN 'cold'
             WHEN sw.AvgTemperature < 20 THEN 'moderate'
             WHEN sw.AvgTemperature < 30 THEN 'warm'
             ELSE 'hot' END                         AS TemperatureCat,
        CASE WHEN sw.AvgWindSpeed < 3 THEN 'calm'
             WHEN sw.AvgWindSpeed < 6 THEN 'light'
             WHEN sw.AvgWindSpeed < 9 THEN 'moderate'
             ELSE 'strong' END                      AS WindCat,
        CASE WHEN sw.Precipitation = 0    THEN 'none'
             WHEN sw.Precipitation < 2.5  THEN 'light'
             WHEN sw.Precipitation <= 7.6 THEN 'moderate'
             ELSE 'heavy' END                       AS PrecipitationCat,
        CASE WHEN sw.CloudCover <= 2 THEN 'clear'
             WHEN sw.CloudCover <= 5 THEN 'partly cloudy'
             ELSE 'overcast' END                    AS CloudCat,
        CASE WHEN sw.SunshineDuration = 0   THEN 'none'
             WHEN sw.SunshineDuration <= 20 THEN 'low'
             WHEN sw.SunshineDuration <= 40 THEN 'medium'
             WHEN sw.SunshineDuration < 60  THEN 'high'
             ELSE 'full' END                        AS SunshineCat
    ) AS c
    LEFT JOIN dbo.WEATHER AS wd
           ON  wd.AvgTemperatureCategory   = c.TemperatureCat
           AND wd.AvgWindSpeedCategory     = c.WindCat
           AND wd.PrecipitationCategory    = c.PrecipitationCat
           AND wd.CloudCoverCategory       = c.CloudCat
           AND wd.SunshineDurationCategory = c.SunshineCat;

    CREATE UNIQUE CLUSTERED INDEX CX_Weather ON #Weather (ZoneID, [Datetime]);

    -- ===================== ENERGY_PRODUCTION =====================
    -- The version of the unit/zone valid at the reading time is used; the first version of every
    -- business key is treated as open to the past, so no reading can be lost.
    -- MaxPossibleEnergy = MaxPowerCapacity (kW) of that unit version x 1 h.
    INSERT dbo.ENERGY_PRODUCTION WITH (TABLOCK)
          (DateKey, TimeKey, UnitKey, ZoneKey, StatusKey, WeatherKey, ProductionLogID,
           EnergyProduced, MaxPossibleEnergy,
           AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration)
    SELECT CONVERT(INT, CONVERT(CHAR(8), r.LogDate, 112)),
           CAST(DATEPART(HOUR, r.LogDate) AS TINYINT),
           unit.UnitKey,
           zone.ZoneKey,
           st.StatusKey,
           ISNULL(w.WeatherKey, 0),
           pl.ProductionLogID,
           pl.EnergyProduced,
           CAST(unit.MaxPowerCapacity AS DECIMAL(10,3)),
           w.AvgTemperature, w.AvgWindSpeed, w.Precipitation, w.CloudCover, w.SunshineDuration
    FROM #StageProductionLog AS pl
    CROSS APPLY (SELECT CONVERT(DATETIME, CONVERT(DATETIME2(0), pl.LogDateTime, 120)) AS LogDate) AS r
    JOIN #StageUnit AS su ON su.UnitID = pl.UnitID
    CROSS APPLY (SELECT TOP (1) u.UnitKey, u.MaxPowerCapacity
                 FROM dbo.UNIT AS u
                 WHERE u.UnitID = pl.UnitID AND u.ValidTo > r.LogDate
                 ORDER BY u.ValidFrom) AS unit
    CROSS APPLY (SELECT TOP (1) z.ZoneKey
                 FROM dbo.ZONE AS z
                 WHERE z.ZoneID = su.ZoneID AND z.ValidTo > r.LogDate
                 ORDER BY z.ValidFrom) AS zone
    JOIN dbo.STATUS AS st ON st.OperationalStatus = pl.OperationalStatus
    LEFT JOIN #Weather AS w ON w.ZoneID = su.ZoneID AND w.[Datetime] = r.LogDate
    ORDER BY r.LogDate, pl.UnitID;

    IF (SELECT COUNT(*) FROM dbo.ENERGY_PRODUCTION) <> (SELECT COUNT(*) FROM #StageProductionLog)
        THROW 50001, 'Some readings could not be matched with a unit, zone or status.', 1;

    COMMIT TRANSACTION;

    DROP TABLE IF EXISTS #StageManufacturer, #StageModel, #StageZone, #StageUnit,
                         #StageProductionLog, #StageWeather, #Weather;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    DROP TABLE IF EXISTS #StageManufacturer, #StageModel, #StageZone, #StageUnit,
                         #StageProductionLog, #StageWeather, #Weather;

    THROW;
END CATCH;
GO

-- ===================== Test queries: row counts and first 20 rows of each table =====================

USE EcoVoltDW_Part;
GO

-- expected for the default generator output: DATE 366, TIME 24, STATUS 3, WEATHER 1201, ZONE 8, UNIT 39, ENERGY_PRODUCTION 311016
SELECT 'DATE' AS TableName, COUNT(*) AS RowsCount FROM dbo.[DATE]  UNION ALL
SELECT 'TIME',              COUNT(*)              FROM dbo.[TIME]  UNION ALL
SELECT 'STATUS',            COUNT(*)              FROM dbo.STATUS  UNION ALL
SELECT 'WEATHER',           COUNT(*)              FROM dbo.WEATHER UNION ALL
SELECT 'ZONE',              COUNT(*)              FROM dbo.ZONE    UNION ALL
SELECT 'UNIT',              COUNT(*)              FROM dbo.UNIT    UNION ALL
SELECT 'ENERGY_PRODUCTION', COUNT(*)              FROM dbo.ENERGY_PRODUCTION;

SELECT TOP (20) * FROM dbo.[DATE]            ORDER BY DateKey;
SELECT TOP (20) * FROM dbo.[TIME]            ORDER BY TimeKey;
SELECT TOP (20) * FROM dbo.STATUS            ORDER BY StatusKey;
SELECT TOP (20) * FROM dbo.WEATHER           ORDER BY WeatherKey;
SELECT TOP (20) * FROM dbo.ZONE              ORDER BY ZoneKey;
SELECT TOP (20) * FROM dbo.UNIT              ORDER BY UnitKey;
SELECT TOP (20) * FROM dbo.ENERGY_PRODUCTION ORDER BY DateKey, TimeKey, UnitKey;
GO
