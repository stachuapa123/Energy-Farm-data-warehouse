USE EcoVoltDW;
GO

-- This is not a production ETL load script; it is a highly simplified demonstration.
-- It omits many aspects of a real ETL process and only populates the warehouse with the bundled sample data.
-- It is designed to work correctly for these specific input files and data.

SET XACT_ABORT ON;
GO

DROP TABLE IF EXISTS #StageEnergyProduction, #StageUnit, #StageZone, #StageWeather,
                     #StageStatus, #StageTime, #StageDate;

IF EXISTS (SELECT 1 FROM dbo.Unit)
   OR EXISTS (SELECT 1 FROM dbo.Zone)
   OR EXISTS (SELECT 1 FROM dbo.Status)
   OR EXISTS (SELECT 1 FROM dbo.Weather)
   OR EXISTS (SELECT 1 FROM dbo.[Date])
   OR EXISTS (SELECT 1 FROM dbo.[Time])
   OR EXISTS (SELECT 1 FROM dbo.EnergyProduction)
    THROW 50000, 'Target tables must be empty before loading the sample data.', 1;

BEGIN TRY
CREATE TABLE #StageDate (
    [Date]       DATE         NOT NULL,
    [Year]       SMALLINT     NOT NULL,
    QuarterNo    TINYINT      NOT NULL,
    [Month]      VARCHAR(10)  NOT NULL,
    MonthNo      TINYINT      NOT NULL,
    DayOfWeek    VARCHAR(10)  NOT NULL,
    DayOfWeekNo  TINYINT      NOT NULL,
    Season       VARCHAR(6)   NOT NULL
);

CREATE TABLE #StageTime (
    [Hour]     TINYINT      NOT NULL,
    TimeOfDay  VARCHAR(10)  NOT NULL
);

CREATE TABLE #StageStatus (
    OperationalStatus  VARCHAR(15)  NOT NULL,
    IsOperating        BIT          NOT NULL
);

CREATE TABLE #StageWeather (
    AvgTemperatureCategory    VARCHAR(10)  NOT NULL,
    AvgWindSpeedCategory      VARCHAR(10)  NOT NULL,
    PrecipitationCategory     VARCHAR(10)  NOT NULL,
    CloudCoverCategory        VARCHAR(15)  NOT NULL,
    SunshineDurationCategory  VARCHAR(10)  NOT NULL
);

CREATE TABLE #StageZone (
    ZoneID       INT           NOT NULL,
    ZoneName     VARCHAR(15)   NOT NULL,
    AreaSizeSqm  INT           NOT NULL,
    ValidFrom    DATETIME2(0)  NOT NULL,
    ValidTo      DATETIME2(0)  NOT NULL,
    IsCurrent    BIT           NOT NULL
);

CREATE TABLE #StageUnit (
    UnitID                 VARCHAR(10)   NOT NULL,
    ManufacturerID         INT           NOT NULL,
    ManufacturerName       VARCHAR(50)   NOT NULL,
    ManufacturerCountry    VARCHAR(30)   NOT NULL,
    ModelID                INT           NOT NULL,
    ModelName              VARCHAR(50)   NOT NULL,
    UnitType               VARCHAR(20)   NOT NULL,
    MaxPowerCapacity       DECIMAL(8,2)  NOT NULL,
    InstallationDateTime   DATETIME2(0)  NOT NULL,
    ExpectedLifespanYears  INT           NOT NULL,
    ValidFrom              DATETIME2(0)  NOT NULL,
    ValidTo                DATETIME2(0)  NOT NULL,
    IsCurrent              BIT           NOT NULL
);

CREATE TABLE #StageEnergyProduction (
    ProductionLogID           INT            NOT NULL,
    [Date]                    DATE           NOT NULL,
    [Hour]                    TINYINT        NOT NULL,
    UnitID                    VARCHAR(10)    NOT NULL,
    ZoneID                    INT            NOT NULL,
    OperationalStatus         VARCHAR(15)    NOT NULL,
    AvgTemperatureCategory    VARCHAR(10)    NOT NULL,
    AvgWindSpeedCategory      VARCHAR(10)    NOT NULL,
    PrecipitationCategory     VARCHAR(10)    NOT NULL,
    CloudCoverCategory        VARCHAR(15)    NOT NULL,
    SunshineDurationCategory  VARCHAR(10)    NOT NULL,
    EnergyProduced            DECIMAL(10,3)  NOT NULL,
    MaxPossibleEnergy         DECIMAL(10,3)  NOT NULL,
    AvgTemperature            DECIMAL(5,2)   NULL,
    AvgWindSpeed              DECIMAL(5,2)   NULL,
    Precipitation             DECIMAL(6,2)   NULL,
    CloudCover                DECIMAL(1,0)   NULL,
    SunshineDuration          DECIMAL(2,0)   NULL
);

    BEGIN TRANSACTION;

    BULK INSERT #StageDate
    FROM '/dw_data/bulk/Date.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageTime
    FROM '/dw_data/bulk/Time.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageStatus
    FROM '/dw_data/bulk/Status.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageWeather
    FROM '/dw_data/bulk/Weather.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageZone
    FROM '/dw_data/bulk/Zone.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageUnit
    FROM '/dw_data/bulk/Unit.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageEnergyProduction
    FROM '/dw_data/bulk/EnergyProduction_2024.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    BULK INSERT #StageEnergyProduction
    FROM '/dw_data/bulk/EnergyProduction_2025.csv'
    WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK);

    INSERT dbo.[Date] (DateKey, [Date], [Year], QuarterNo, [Month], MonthNo, DayOfWeek, DayOfWeekNo, Season)
    SELECT CONVERT(INT, CONVERT(CHAR(8), [Date], 112)), [Date], [Year], QuarterNo, [Month], MonthNo,
           DayOfWeek, DayOfWeekNo, Season
    FROM #StageDate;

    INSERT dbo.[Time] (TimeKey, [Hour], TimeOfDay)
    SELECT [Hour], [Hour], TimeOfDay
    FROM #StageTime;

    INSERT dbo.Status (OperationalStatus, IsOperating)
    SELECT OperationalStatus, IsOperating
    FROM #StageStatus
    ORDER BY IsOperating DESC, OperationalStatus;

    INSERT dbo.Weather (AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory,
                        CloudCoverCategory, SunshineDurationCategory)
    SELECT AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory,
           CloudCoverCategory, SunshineDurationCategory
    FROM #StageWeather
    ORDER BY CASE WHEN AvgTemperatureCategory = 'unknown' THEN 0 ELSE 1 END;

    INSERT dbo.Zone (ZoneID, ZoneName, AreaSizeSqm, ValidFrom, ValidTo, IsCurrent)
    SELECT ZoneID, ZoneName, AreaSizeSqm, ValidFrom, ValidTo, IsCurrent
    FROM #StageZone
    ORDER BY ZoneID, ValidFrom;

    INSERT dbo.Unit (UnitID, ManufacturerID, ManufacturerName, ManufacturerCountry, ModelID, ModelName,
                     UnitType, MaxPowerCapacity, InstallationDateTime, ExpectedLifespanYears,
                     ValidFrom, ValidTo, IsCurrent)
    SELECT UnitID, ManufacturerID, ManufacturerName, ManufacturerCountry, ModelID, ModelName,
           UnitType, MaxPowerCapacity, InstallationDateTime, ExpectedLifespanYears,
           ValidFrom, ValidTo, IsCurrent
    FROM #StageUnit
    ORDER BY UnitID, ValidFrom;

    INSERT dbo.EnergyProduction
          (DateKey, TimeKey, UnitKey, ZoneKey, StatusKey, WeatherKey, ProductionLogID,
           EnergyProduced, MaxPossibleEnergy,
           AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration)
    SELECT readingDate.DateKey, readingTime.TimeKey, unit.UnitKey, zone.ZoneKey, st.StatusKey, w.WeatherKey,
           stage.ProductionLogID, stage.EnergyProduced, stage.MaxPossibleEnergy,
           stage.AvgTemperature, stage.AvgWindSpeed, stage.Precipitation, stage.CloudCover, stage.SunshineDuration
    FROM #StageEnergyProduction AS stage
    CROSS APPLY (SELECT DATEADD(HOUR, stage.[Hour], CAST(stage.[Date] AS DATETIME)) AS ReadingTime) AS r
    JOIN dbo.[Date] AS readingDate ON readingDate.[Date] = stage.[Date]
    JOIN dbo.[Time] AS readingTime ON readingTime.[Hour] = stage.[Hour]
    JOIN dbo.Unit   AS unit ON unit.UnitID = stage.UnitID AND unit.ValidFrom <= r.ReadingTime AND r.ReadingTime < unit.ValidTo
    JOIN dbo.Zone   AS zone ON zone.ZoneID = stage.ZoneID AND zone.ValidFrom <= r.ReadingTime AND r.ReadingTime < zone.ValidTo
    JOIN dbo.Status AS st   ON st.OperationalStatus = stage.OperationalStatus
    JOIN dbo.Weather AS w   ON  w.AvgTemperatureCategory   = stage.AvgTemperatureCategory
                            AND w.AvgWindSpeedCategory     = stage.AvgWindSpeedCategory
                            AND w.PrecipitationCategory    = stage.PrecipitationCategory
                            AND w.CloudCoverCategory       = stage.CloudCoverCategory
                            AND w.SunshineDurationCategory = stage.SunshineDurationCategory
    ORDER BY stage.[Date], stage.[Hour], stage.UnitID;

    IF (SELECT COUNT(*) FROM dbo.EnergyProduction) <> (SELECT COUNT(*) FROM #StageEnergyProduction)
        THROW 50001, 'Some readings could not be matched with a date, time, unit version, zone version, status or weather.', 1;

    COMMIT TRANSACTION;

    DROP TABLE IF EXISTS #StageEnergyProduction, #StageUnit, #StageZone, #StageWeather,
                         #StageStatus, #StageTime, #StageDate;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    DROP TABLE IF EXISTS #StageEnergyProduction, #StageUnit, #StageZone, #StageWeather,
                         #StageStatus, #StageTime, #StageDate;

    THROW;
END CATCH;
GO

-- ===================== Test queries: first 20 rows of each table =====================

USE EcoVoltDW;
GO

SELECT TOP (20) * FROM dbo.[Date]            ORDER BY DateKey;
SELECT TOP (20) * FROM dbo.[Time]            ORDER BY TimeKey;
SELECT TOP (20) * FROM dbo.Status            ORDER BY StatusKey;
SELECT TOP (20) * FROM dbo.Weather           ORDER BY WeatherKey;
SELECT TOP (20) * FROM dbo.Zone              ORDER BY ZoneKey;
SELECT TOP (20) * FROM dbo.Unit              ORDER BY UnitKey;
SELECT TOP (20) * FROM dbo.EnergyProduction ORDER BY DateKey, TimeKey, UnitKey;
GO
