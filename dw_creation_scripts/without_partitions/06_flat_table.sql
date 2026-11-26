USE EcoVoltDW;
GO

-- ===================== Flat table (physical copy of the view dbo.FlatTable) =====================

DROP TABLE IF EXISTS dbo.FlatTablePhysical;
GO

CREATE TABLE dbo.FlatTablePhysical (
    ProductionLogID            INT            NOT NULL,
    DateKey                    INT            NOT NULL,
    ReadingDateTime            DATETIME2(0)   NOT NULL,
    EnergyProduced             DECIMAL(10,3)  NOT NULL,
    MaxPossibleEnergy          DECIMAL(10,3)  NOT NULL,
    AvgTemperature             DECIMAL(5,2)   NULL,
    AvgWindSpeed               DECIMAL(5,2)   NULL,
    Precipitation              DECIMAL(6,2)   NULL,
    CloudCover                 DECIMAL(1,0)   NULL,
    SunshineDuration           DECIMAL(2,0)   NULL,
    UnitID                     VARCHAR(10)    NOT NULL,
    UnitType                   VARCHAR(20)    NOT NULL,
    ModelID                    INT            NOT NULL,
    ModelName                  VARCHAR(50)    NOT NULL,
    ManufacturerID             INT            NOT NULL,
    ManufacturerName           VARCHAR(50)    NOT NULL,
    ManufacturerCountry        VARCHAR(30)    NOT NULL,
    MaxPowerCapacity           DECIMAL(8,2)   NOT NULL,
    InstallationDateTime       DATETIME       NOT NULL,
    ExpectedLifespanYears      INT            NOT NULL,
    UnitAge                    INT            NOT NULL,
    AgeCategory                VARCHAR(15)    NOT NULL,
    OlderUnit                  VARCHAR(3)     NOT NULL,
    OldestWindTurbine          VARCHAR(3)     NOT NULL,
    UnitDayKey                 VARCHAR(20)    NOT NULL,
    ZoneID                     INT            NOT NULL,
    ZoneName                   VARCHAR(15)    NOT NULL,
    AreaSizeSqm                INT            NOT NULL,
    OperationalStatus          VARCHAR(15)    NOT NULL,
    IsOperating                TINYINT        NOT NULL,
    AvgTemperatureCategory     VARCHAR(10)    NOT NULL,
    AvgWindSpeedCategory       VARCHAR(10)    NOT NULL,
    PrecipitationCategory      VARCHAR(10)    NOT NULL,
    CloudCoverCategory         VARCHAR(15)    NOT NULL,
    SunshineDurationCategory   VARCHAR(10)    NOT NULL,
    DailyCloudCover            DECIMAL(5,2)   NULL,
    DailyWindSpeed             DECIMAL(5,2)   NULL,
    SkyConditionOfDay          VARCHAR(15)    NOT NULL,
    DailyWindSpeedCategory     VARCHAR(10)    NOT NULL,
    OptimalWeatherDay          VARCHAR(3)     NOT NULL,
    [Date]                     DATE           NOT NULL,
    [Year]                     SMALLINT       NOT NULL,
    QuarterNo                  TINYINT        NOT NULL,
    [Month]                    VARCHAR(10)    NOT NULL,
    MonthNo                    TINYINT        NOT NULL,
    [DayOfWeek]                VARCHAR(10)    NOT NULL,
    DayOfWeekNo                TINYINT        NOT NULL,
    Season                     VARCHAR(6)     NOT NULL,
    [Hour]                     TINYINT        NOT NULL,
    TimeOfDay                  VARCHAR(10)    NOT NULL
);
GO

-- ===================== Descriptions (dbo.SetDesc from 02_extended_properties.sql; same as dbo.FlatTable) =====================
EXEC dbo.SetDesc N'FlatTablePhysical', NULL, N'Semantic layer table (One Big Table, physical copy of the view dbo.FlatTable). One row describes one reading of one unit within one hour.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ProductionLogID',          N'Identifier of the reading in the source system (degenerate dimension); primary key of the cube.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'DateKey',                  N'Day of the reading as yyyymmdd (sort and partition column; hidden in the semantic layer).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ReadingDateTime',          N'Date and hour of the reading (UTC).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'EnergyProduced',           N'Energy produced by the unit within the hour, in kWh.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'MaxPossibleEnergy',        N'Maximum energy at full power capacity within the hour, in kWh.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'AvgTemperature',           N'Average air temperature in the zone within the hour, in degC.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'AvgWindSpeed',             N'Average wind speed in the zone within the hour, in m/s.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'Precipitation',            N'Precipitation in the zone within the hour, in mm.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'CloudCover',               N'Cloud cover in the zone within the hour, in oktas (0-8).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'SunshineDuration',         N'Minutes of sunshine in the zone within the hour (0-60).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'UnitID',                   N'Identifier of the unit (business key).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'UnitType',                 N'Type of the unit: Wind, Solar.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ModelID',                  N'Identifier of the equipment model.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ModelName',                N'Name of the model.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ManufacturerID',           N'Identifier of the manufacturer.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ManufacturerName',         N'Name of the manufacturer (version valid at the reading time).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ManufacturerCountry',      N'Country of the manufacturer (version valid at the reading time).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'MaxPowerCapacity',         N'Maximum power output of the unit, in kW.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'InstallationDateTime',     N'Installation date of the unit''s equipment.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ExpectedLifespanYears',    N'Lifespan declared by the manufacturer, in years.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'UnitAge',                  N'Whole years between the installation and the reading: DATEDIFF(day) / 365.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'AgeCategory',              N'Unit age at the reading: under 1 year, 1-5 years, 5-10 years, over 10 years (half-open intervals).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'OlderUnit',                N'Yes if the unit was over 5 years old at the reading (UnitAge >= 5), otherwise No.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'OldestWindTurbine',        N'Yes for every version of the current wind unit with the earliest installation date, otherwise No.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'UnitDayKey',               N'UnitID_yyyymmdd - counts unit-days (average daily energy per unit).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ZoneID',                   N'Identifier of the zone (business key).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'ZoneName',                 N'Name of the zone.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'AreaSizeSqm',              N'Area of the zone, in square meters (version valid at the reading time).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'OperationalStatus',        N'Status of the unit during the hour: Operating, Fault, Maintenance.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'IsOperating',              N'1 if the unit was operating, otherwise 0.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'AvgTemperatureCategory',   N'Temperature category of the hour: freezing, cold, moderate, warm, hot.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'AvgWindSpeedCategory',     N'Wind speed category of the hour: calm, light, moderate, strong.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'PrecipitationCategory',    N'Precipitation category of the hour: none, light, moderate, heavy.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'CloudCoverCategory',       N'Cloud cover category of the hour: clear, partly cloudy, overcast.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'SunshineDurationCategory', N'Sunshine category of the hour: none, low, medium, high, full.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'DailyCloudCover',          N'Daily mean cloud cover of the zone (one value per zone-hour, not weighted by units).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'DailyWindSpeed',           N'Daily mean wind speed of the zone (one value per zone-hour, not weighted by units).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'SkyConditionOfDay',        N'Daily sky condition of the zone: Sunny (mean cloud cover < 2), Cloudy (> 6), Partly cloudy, Unknown.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'DailyWindSpeedCategory',   N'Daily mean wind speed of the zone: calm [0,3), light [3,6), moderate [6,9), strong (>= 9), unknown.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'OptimalWeatherDay',        N'Yes for a wind unit on a strong-wind day or a solar unit on a Sunny day, otherwise No.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'Date',                     N'Calendar date of the reading.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'Year',                     N'Year of the reading.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'QuarterNo',                N'Quarter of the reading (1-4).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'Month',                    N'Month name of the reading.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'MonthNo',                  N'Month number of the reading.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'DayOfWeek',                N'Day of week of the reading.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'DayOfWeekNo',              N'Day of week number (1 = Monday).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'Season',                   N'Season of the reading: Winter, Spring, Summer, Autumn.';
EXEC dbo.SetDesc N'FlatTablePhysical', N'Hour',                     N'Hour of the reading (0-23, UTC).';
EXEC dbo.SetDesc N'FlatTablePhysical', N'TimeOfDay',                N'Time of day: night, morning, afternoon, evening.';
GO

-- ===================== Load the flat table from the view year by year =====================

INSERT INTO dbo.FlatTablePhysical (
    ProductionLogID, DateKey, ReadingDateTime,
    EnergyProduced, MaxPossibleEnergy, AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration,
    UnitID, UnitType, ModelID, ModelName, ManufacturerID, ManufacturerName, ManufacturerCountry, MaxPowerCapacity,
    InstallationDateTime, ExpectedLifespanYears, UnitAge, AgeCategory, OlderUnit, OldestWindTurbine, UnitDayKey,
    ZoneID, ZoneName, AreaSizeSqm,
    OperationalStatus, IsOperating,
    AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory, CloudCoverCategory, SunshineDurationCategory,
    DailyCloudCover, DailyWindSpeed, SkyConditionOfDay, DailyWindSpeedCategory, OptimalWeatherDay,
    [Date], [Year], QuarterNo, [Month], MonthNo, [DayOfWeek], DayOfWeekNo, Season,
    [Hour], TimeOfDay
)
SELECT
    ProductionLogID, DateKey, ReadingDateTime,
    EnergyProduced, MaxPossibleEnergy, AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration,
    UnitID, UnitType, ModelID, ModelName, ManufacturerID, ManufacturerName, ManufacturerCountry, MaxPowerCapacity,
    InstallationDateTime, ExpectedLifespanYears, UnitAge, AgeCategory, OlderUnit, OldestWindTurbine, UnitDayKey,
    ZoneID, ZoneName, AreaSizeSqm,
    OperationalStatus, IsOperating,
    AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory, CloudCoverCategory, SunshineDurationCategory,
    DailyCloudCover, DailyWindSpeed, SkyConditionOfDay, DailyWindSpeedCategory, OptimalWeatherDay,
    [Date], [Year], QuarterNo, [Month], MonthNo, [DayOfWeek], DayOfWeekNo, Season,
    [Hour], TimeOfDay
FROM dbo.FlatTable
WHERE DateKey BETWEEN 20240101 AND 20241231;
GO

-- ORDER requires SQL Server 2022+.
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FlatTablePhysical ON dbo.FlatTablePhysical ORDER (DateKey);
GO

INSERT INTO dbo.FlatTablePhysical (
    ProductionLogID, DateKey, ReadingDateTime,
    EnergyProduced, MaxPossibleEnergy, AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration,
    UnitID, UnitType, ModelID, ModelName, ManufacturerID, ManufacturerName, ManufacturerCountry, MaxPowerCapacity,
    InstallationDateTime, ExpectedLifespanYears, UnitAge, AgeCategory, OlderUnit, OldestWindTurbine, UnitDayKey,
    ZoneID, ZoneName, AreaSizeSqm,
    OperationalStatus, IsOperating,
    AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory, CloudCoverCategory, SunshineDurationCategory,
    DailyCloudCover, DailyWindSpeed, SkyConditionOfDay, DailyWindSpeedCategory, OptimalWeatherDay,
    [Date], [Year], QuarterNo, [Month], MonthNo, [DayOfWeek], DayOfWeekNo, Season,
    [Hour], TimeOfDay
)
SELECT
    ProductionLogID, DateKey, ReadingDateTime,
    EnergyProduced, MaxPossibleEnergy, AvgTemperature, AvgWindSpeed, Precipitation, CloudCover, SunshineDuration,
    UnitID, UnitType, ModelID, ModelName, ManufacturerID, ManufacturerName, ManufacturerCountry, MaxPowerCapacity,
    InstallationDateTime, ExpectedLifespanYears, UnitAge, AgeCategory, OlderUnit, OldestWindTurbine, UnitDayKey,
    ZoneID, ZoneName, AreaSizeSqm,
    OperationalStatus, IsOperating,
    AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory, CloudCoverCategory, SunshineDurationCategory,
    DailyCloudCover, DailyWindSpeed, SkyConditionOfDay, DailyWindSpeedCategory, OptimalWeatherDay,
    [Date], [Year], QuarterNo, [Month], MonthNo, [DayOfWeek], DayOfWeekNo, Season,
    [Hour], TimeOfDay
FROM dbo.FlatTable
WHERE DateKey BETWEEN 20250101 AND 20251231;
GO

-- The increment goes straight into the existing index; REORGANIZE compresses its delta rowgroups without rebuilding the 2024 data.
ALTER INDEX CCI_FlatTablePhysical ON dbo.FlatTablePhysical REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
GO

-- ===================== Test query: first 20 rows of the flat table =====================
USE EcoVoltDW;
GO

SELECT TOP (20) * FROM dbo.FlatTablePhysical ORDER BY DateKey, [Hour], UnitID;
GO

-- ===================== Check: column descriptions =====================
USE EcoVoltDW;
GO

SELECT
    o.name                  AS ObjectName,
    c.name                  AS ColumnName,
    CAST(ep.value AS NVARCHAR(3750)) AS Description
FROM sys.extended_properties AS ep
JOIN sys.objects AS o ON o.object_id = ep.major_id
LEFT JOIN sys.columns AS c ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
WHERE ep.class = 1
  AND ep.name = N'MS_Description'
  AND ep.major_id = OBJECT_ID(N'dbo.FlatTablePhysical')
ORDER BY ep.minor_id;
GO
