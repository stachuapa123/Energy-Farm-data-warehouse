-- Same incremental load as without_partitions: the 2025 rows go to partition 3 of ENERGY_PRODUCTION and FLAT_TABLE.
USE EcoVoltDW_Part;
GO

-- Incremental load of snapshot T2 (2024-2025): new readings of 2025 and changed dimension rows.
-- Source: the full T2 snapshot files /dw_data/T2/PowerMaster/*.csv and /dw_data/T2/Weather/Weather_Data.csv.
-- Lecture "Incremental / Routine Loading Pipeline":
--   1. disable FK constraints and nonclustered indexes of the fact
--   2. load: DATE (new days), ZONE and UNIT (SCD2), ENERGY_PRODUCTION (new readings)
--   3. rebuild the nonclustered indexes, REORGANIZE the CCI (compress the new rowgroups)
--   4. enable FK constraints WITH CHECK (validates the new rows)
--   5. append the new rows to FLAT_TABLE
-- Dimensions are small (low cardinality), so their indexes stay enabled.
--
-- SCD2 rules (relational design, ETL mapping):
--   * changed attributes      -> new version from @ChangeValidFrom = first day after the readings already in the
--                                warehouse (2025-01-01). The sources keep no change date; with the load date
--                                (2026-01-01) the new versions would get no facts at all.
--   * equipment replaced      -> new version from the new InstallationDateTime (PV-POZ-01 repowering).
--   * previous version        -> ValidTo = ValidFrom of the new version, IsCurrent = 0.
--   * new unit / zone         -> ValidFrom = InstallationDateTime / 1900-01-01.
-- New readings: ProductionLogID greater than the largest ProductionLogID already loaded (T2 keeps the T1 IDs).

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT ON;
GO

-- ===================== 1. Disable fact foreign keys and nonclustered indexes =====================

ALTER TABLE dbo.ENERGY_PRODUCTION NOCHECK CONSTRAINT ALL;

ALTER INDEX IX_ENERGY_PRODUCTION_UnitKey ON dbo.ENERGY_PRODUCTION DISABLE;
ALTER INDEX IX_ENERGY_PRODUCTION_ZoneKey ON dbo.ENERGY_PRODUCTION DISABLE;
ALTER INDEX IX_ENERGY_PRODUCTION_WeatherKey ON dbo.ENERGY_PRODUCTION DISABLE;
GO

-- ===================== 2. Load =====================

DROP TABLE IF EXISTS #StageManufacturer, #StageModel, #StageZone, #StageUnit,
                         #StageProductionLog, #StageWeather, #Weather, #SourceUnit, #ChangedUnit, #ChangedZone;

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
    FROM '/dw_data/T2/PowerMaster/Manufacturer.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageModel
    FROM '/dw_data/T2/PowerMaster/Model.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageZone
    FROM '/dw_data/T2/PowerMaster/Zone.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageUnit
    FROM '/dw_data/T2/PowerMaster/Unit.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageProductionLog
    FROM '/dw_data/T2/PowerMaster/ProductionLog.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageWeather
    FROM '/dw_data/T2/Weather/Weather_Data.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK);

    DECLARE @LastLogID INT = ISNULL((SELECT MAX(ProductionLogID) FROM dbo.ENERGY_PRODUCTION), 0);
    DECLARE @LastDateKey INT = (SELECT MAX(DateKey) FROM dbo.ENERGY_PRODUCTION);
    DECLARE @ChangeValidFrom DATETIME = DATEADD(DAY, 1, CONVERT(DATETIME, CONVERT(CHAR(8), @LastDateKey), 112));
    DECLARE @NewZones INT, @ChangedZones INT, @NewUnits INT, @ChangedUnits INT, @Loaded INT, @Expected INT;

    SELECT @Expected = COUNT(*) FROM #StageProductionLog WHERE ProductionLogID > @LastLogID;

    -- ===================== DATE: add the days of the new readings =====================
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
                        MONTH(d.dt) * 100 + DAY(d.dt)                         AS MonthDay) AS x
    WHERE NOT EXISTS (SELECT 1 FROM dbo.[DATE] AS existing WHERE existing.[Date] = d.dt);

    -- ===================== ZONE (SCD2) =====================
    -- NOT EXISTS (... INTERSECT ...) compares the attributes column by column (NULL-safe).
    SELECT s.ZoneID, s.ZoneName, s.AreaSizeSqm
    INTO #ChangedZone
    FROM #StageZone AS s
    JOIN dbo.ZONE AS z ON z.ZoneID = s.ZoneID AND z.IsCurrent = 1
    WHERE NOT EXISTS (SELECT s.ZoneName, s.AreaSizeSqm
                      INTERSECT
                      SELECT z.ZoneName, z.AreaSizeSqm);

    UPDATE z
    SET    z.ValidTo = @ChangeValidFrom, z.IsCurrent = 0
    FROM   dbo.ZONE AS z
    JOIN   #ChangedZone AS c ON c.ZoneID = z.ZoneID
    WHERE  z.IsCurrent = 1;

    INSERT dbo.ZONE (ZoneID, ZoneName, AreaSizeSqm, ValidFrom, ValidTo, IsCurrent)
    SELECT ZoneID, ZoneName, AreaSizeSqm, @ChangeValidFrom, '99991231', 1
    FROM #ChangedZone;
    SET @ChangedZones = @@ROWCOUNT;

    INSERT dbo.ZONE (ZoneID, ZoneName, AreaSizeSqm, ValidFrom, ValidTo, IsCurrent)
    SELECT s.ZoneID, s.ZoneName, s.AreaSizeSqm, '19000101', '99991231', 1
    FROM #StageZone AS s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.ZONE AS z WHERE z.ZoneID = s.ZoneID);
    SET @NewZones = @@ROWCOUNT;

    -- ===================== UNIT (SCD2): unit + model + manufacturer =====================
    SELECT u.UnitID, mf.ManufacturerID, mf.ManufacturerName, mf.Country AS ManufacturerCountry,
           m.ModelID, m.ModelName, m.UnitType, m.MaxPowerCapacity,
           CONVERT(DATETIME, CONVERT(DATETIME2(0), u.InstallationDateTime, 120)) AS InstallationDateTime,
           m.ExpectedLifespanYears
    INTO #SourceUnit
    FROM #StageUnit AS u
    JOIN #StageModel AS m         ON m.ModelID = u.ModelID
    JOIN #StageManufacturer AS mf ON mf.ManufacturerID = m.ManufacturerID;

    SELECT s.*,
           CASE WHEN s.InstallationDateTime <> cur.InstallationDateTime
                 AND s.InstallationDateTime > cur.ValidFrom
                THEN s.InstallationDateTime        -- equipment replaced
                ELSE @ChangeValidFrom END AS NewValidFrom
    INTO #ChangedUnit
    FROM #SourceUnit AS s
    JOIN dbo.UNIT AS cur ON cur.UnitID = s.UnitID AND cur.IsCurrent = 1
    WHERE NOT EXISTS (SELECT s.ManufacturerID, s.ManufacturerName, s.ManufacturerCountry, s.ModelID, s.ModelName,
                             s.UnitType, s.MaxPowerCapacity, s.InstallationDateTime, s.ExpectedLifespanYears
                      INTERSECT
                      SELECT cur.ManufacturerID, cur.ManufacturerName, cur.ManufacturerCountry, cur.ModelID, cur.ModelName,
                             cur.UnitType, cur.MaxPowerCapacity, cur.InstallationDateTime, cur.ExpectedLifespanYears);

    UPDATE u
    SET    u.ValidTo = c.NewValidFrom, u.IsCurrent = 0
    FROM   dbo.UNIT AS u
    JOIN   #ChangedUnit AS c ON c.UnitID = u.UnitID
    WHERE  u.IsCurrent = 1;

    INSERT dbo.UNIT (UnitID, ManufacturerID, ManufacturerName, ManufacturerCountry, ModelID, ModelName,
                     UnitType, MaxPowerCapacity, InstallationDateTime, ExpectedLifespanYears,
                     ValidFrom, ValidTo, IsCurrent)
    SELECT UnitID, ManufacturerID, ManufacturerName, ManufacturerCountry, ModelID, ModelName,
           UnitType, MaxPowerCapacity, InstallationDateTime, ExpectedLifespanYears,
           NewValidFrom, '99991231', 1
    FROM #ChangedUnit;
    SET @ChangedUnits = @@ROWCOUNT;

    INSERT dbo.UNIT (UnitID, ManufacturerID, ManufacturerName, ManufacturerCountry, ModelID, ModelName,
                     UnitType, MaxPowerCapacity, InstallationDateTime, ExpectedLifespanYears,
                     ValidFrom, ValidTo, IsCurrent)
    SELECT s.UnitID, s.ManufacturerID, s.ManufacturerName, s.ManufacturerCountry, s.ModelID, s.ModelName,
           s.UnitType, s.MaxPowerCapacity, s.InstallationDateTime, s.ExpectedLifespanYears,
           s.InstallationDateTime, '99991231', 1
    FROM #SourceUnit AS s
    WHERE NOT EXISTS (SELECT 1 FROM dbo.UNIT AS u WHERE u.UnitID = s.UnitID);
    SET @NewUnits = @@ROWCOUNT;

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

    -- ===================== ENERGY_PRODUCTION: new readings only =====================
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
    WHERE pl.ProductionLogID > @LastLogID
    ORDER BY r.LogDate, pl.UnitID;

    SET @Loaded = @@ROWCOUNT;

    IF @Loaded <> @Expected
        THROW 50001, 'Some new readings could not be matched with a unit, zone or status.', 1;

    COMMIT TRANSACTION;

    PRINT CONCAT('ValidFrom of changed versions: ', CONVERT(CHAR(10), @ChangeValidFrom, 23));
    PRINT CONCAT('ZONE: ', @NewZones, ' new, ', @ChangedZones, ' changed. UNIT: ', @NewUnits, ' new, ',
                 @ChangedUnits, ' changed. ENERGY_PRODUCTION: ', @Loaded, ' new readings.');

    DROP TABLE IF EXISTS #StageManufacturer, #StageModel, #StageZone, #StageUnit,
                         #StageProductionLog, #StageWeather, #Weather, #SourceUnit, #ChangedUnit, #ChangedZone;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    DROP TABLE IF EXISTS #StageManufacturer, #StageModel, #StageZone, #StageUnit,
                         #StageProductionLog, #StageWeather, #Weather, #SourceUnit, #ChangedUnit, #ChangedZone;

    THROW;
END CATCH;
GO

-- ===================== 3. Rebuild nonclustered indexes, compress the new rowgroups =====================

ALTER INDEX IX_ENERGY_PRODUCTION_UnitKey ON dbo.ENERGY_PRODUCTION REBUILD;
ALTER INDEX IX_ENERGY_PRODUCTION_ZoneKey ON dbo.ENERGY_PRODUCTION REBUILD;
ALTER INDEX IX_ENERGY_PRODUCTION_WeatherKey ON dbo.ENERGY_PRODUCTION REBUILD;

ALTER INDEX CCI_ENERGY_PRODUCTION ON dbo.ENERGY_PRODUCTION REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
GO

-- ===================== 4. Enable fact foreign keys (validates the new rows) =====================

ALTER TABLE dbo.ENERGY_PRODUCTION WITH CHECK CHECK CONSTRAINT ALL;
GO

-- ===================== 5. Append the increment to FLAT_TABLE =====================
-- The increment goes straight into the existing columnstore index; REORGANIZE compresses its delta
-- rowgroups without rebuilding the 2024 data.

DECLARE @FlatLastDateKey INT = ISNULL((SELECT MAX(DateKey) FROM dbo.FLAT_TABLE), 0);

INSERT INTO dbo.FLAT_TABLE WITH (TABLOCK) (
    ProductionLogID,
    DateKey,
    ReadingDateTime,
    EnergyProduced,
    MaxPossibleEnergy,
    AvgTemperature,
    AvgWindSpeed,
    Precipitation,
    CloudCover,
    SunshineDuration,
    UnitID,
    UnitType,
    ModelID,
    ModelName,
    ManufacturerID,
    ManufacturerName,
    ManufacturerCountry,
    MaxPowerCapacity,
    InstallationDateTime,
    ExpectedLifespanYears,
    UnitAge,
    AgeCategory,
    OlderUnit,
    OldestWindTurbine,
    UnitDayKey,
    ZoneID,
    ZoneName,
    AreaSizeSqm,
    OperationalStatus,
    IsOperating,
    AvgTemperatureCategory,
    AvgWindSpeedCategory,
    PrecipitationCategory,
    CloudCoverCategory,
    SunshineDurationCategory,
    DailyCloudCover,
    DailyWindSpeed,
    SkyConditionOfDay,
    DailyWindSpeedCategory,
    OptimalWeatherDay,
    [Date],
    [Year],
    QuarterNo,
    [Month],
    MonthNo,
    [DayOfWeek],
    DayOfWeekNo,
    Season,
    [Hour],
    TimeOfDay
)
SELECT
    ProductionLogID,
    DateKey,
    ReadingDateTime,
    EnergyProduced,
    MaxPossibleEnergy,
    AvgTemperature,
    AvgWindSpeed,
    Precipitation,
    CloudCover,
    SunshineDuration,
    UnitID,
    UnitType,
    ModelID,
    ModelName,
    ManufacturerID,
    ManufacturerName,
    ManufacturerCountry,
    MaxPowerCapacity,
    InstallationDateTime,
    ExpectedLifespanYears,
    UnitAge,
    AgeCategory,
    OlderUnit,
    OldestWindTurbine,
    UnitDayKey,
    ZoneID,
    ZoneName,
    AreaSizeSqm,
    OperationalStatus,
    IsOperating,
    AvgTemperatureCategory,
    AvgWindSpeedCategory,
    PrecipitationCategory,
    CloudCoverCategory,
    SunshineDurationCategory,
    DailyCloudCover,
    DailyWindSpeed,
    SkyConditionOfDay,
    DailyWindSpeedCategory,
    OptimalWeatherDay,
    [Date],
    [Year],
    QuarterNo,
    [Month],
    MonthNo,
    [DayOfWeek],
    DayOfWeekNo,
    Season,
    [Hour],
    TimeOfDay
FROM dbo.FlatTable
WHERE DateKey > @FlatLastDateKey;
GO

ALTER INDEX CCI_FLAT_TABLE ON dbo.FLAT_TABLE REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
GO

-- ===================== Checks =====================

-- expected for the default generator output: DATE 731, ZONE 10, UNIT 46
-- (42 units + 3 versions of the Siemens rename + 1 version of the PV-POZ-01 repowering),
-- ENERGY_PRODUCTION, FlatTable and FLAT_TABLE 665832
SELECT 'DATE' AS TableName, COUNT(*) AS RowsCount FROM dbo.[DATE] UNION ALL
SELECT 'ZONE',              COUNT(*)              FROM dbo.ZONE   UNION ALL
SELECT 'UNIT',              COUNT(*)              FROM dbo.UNIT   UNION ALL
SELECT 'ENERGY_PRODUCTION', COUNT(*)              FROM dbo.ENERGY_PRODUCTION UNION ALL
SELECT 'FlatTable (view)',  COUNT(*)              FROM dbo.FlatTable UNION ALL
SELECT 'FLAT_TABLE',        COUNT(*)              FROM dbo.FLAT_TABLE;

-- SCD2 versions and the readings assigned to each version
SELECT u.UnitID, u.UnitKey, u.ManufacturerName, u.ModelName, u.ValidFrom, u.ValidTo, u.IsCurrent,
       MIN(ep.DateKey) AS FirstReading, MAX(ep.DateKey) AS LastReading, COUNT(ep.EnergyProductionID) AS Readings
FROM dbo.UNIT AS u
LEFT JOIN dbo.ENERGY_PRODUCTION AS ep ON ep.UnitKey = u.UnitKey
WHERE u.UnitID IN (SELECT UnitID FROM dbo.UNIT GROUP BY UnitID HAVING COUNT(*) > 1)
GROUP BY u.UnitID, u.UnitKey, u.ManufacturerName, u.ModelName, u.ValidFrom, u.ValidTo, u.IsCurrent
ORDER BY u.UnitID, u.ValidFrom;

SELECT z.ZoneID, z.ZoneKey, z.ZoneName, z.AreaSizeSqm, z.ValidFrom, z.ValidTo, z.IsCurrent
FROM dbo.ZONE AS z
WHERE z.ZoneID IN (SELECT ZoneID FROM dbo.ZONE GROUP BY ZoneID HAVING COUNT(*) > 1)
ORDER BY z.ZoneID, z.ValidFrom;

SELECT OBJECT_NAME(object_id) AS TableName, partition_number, row_group_id, state_desc, total_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id IN (OBJECT_ID(N'dbo.ENERGY_PRODUCTION'), OBJECT_ID(N'dbo.FLAT_TABLE'))
ORDER BY TableName, partition_number, row_group_id;
GO
