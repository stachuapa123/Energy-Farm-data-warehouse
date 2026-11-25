-- Same view as without_partitions; filters on DateKey target the partition key of the fact.
USE EcoVoltDW_Part;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- Semantic layer view (One Big Table, non-materialized): one row = one reading of one unit within one hour.
-- Surrogate keys and ValidFrom/ValidTo/IsCurrent are not exposed. All dates and times are UTC.

CREATE OR ALTER VIEW dbo.FlatTable
AS
WITH ZoneHourWeather AS (
    -- One value per zone and hour: the fact repeats the zone's weather for every unit of the zone.
    SELECT z.ZoneID, ep.DateKey, ep.TimeKey,
           MAX(ep.CloudCover)   AS CloudCover,
           MAX(ep.AvgWindSpeed) AS AvgWindSpeed
    FROM dbo.ENERGY_PRODUCTION AS ep
    JOIN dbo.ZONE AS z ON z.ZoneKey = ep.ZoneKey
    GROUP BY z.ZoneID, ep.DateKey, ep.TimeKey
),
ZoneDayWeather AS (
    SELECT ZoneID, DateKey,
           AVG(CloudCover)   AS DailyCloudCover,
           AVG(AvgWindSpeed) AS DailyWindSpeed
    FROM ZoneHourWeather
    GROUP BY ZoneID, DateKey
),
OldestWind AS (
    -- Current wind unit with the earliest installation date; flagged on all its versions (by UnitID).
    SELECT TOP (1) UnitID
    FROM dbo.UNIT
    WHERE IsCurrent = 1 AND UnitType = 'Wind'
    ORDER BY InstallationDateTime, UnitID
)
SELECT
    -- Fact
    ep.ProductionLogID,
    ep.DateKey,
    CAST(DATEADD(HOUR, t.[Hour], CAST(d.[Date] AS DATETIME2(0))) AS DATETIME2(0)) AS ReadingDateTime,
    ep.EnergyProduced,
    ep.MaxPossibleEnergy,
    ep.AvgTemperature,
    ep.AvgWindSpeed,
    ep.Precipitation,
    ep.CloudCover,
    ep.SunshineDuration,

    -- Unit
    u.UnitID,
    u.UnitType,
    u.ModelID,
    u.ModelName,
    u.ManufacturerID,
    u.ManufacturerName,
    u.ManufacturerCountry,
    u.MaxPowerCapacity,
    u.InstallationDateTime,
    u.ExpectedLifespanYears,
    age.UnitAge,
    CAST(CASE WHEN age.UnitAge < 1  THEN 'under 1 year'
              WHEN age.UnitAge < 5  THEN '1-5 years'
              WHEN age.UnitAge < 10 THEN '5-10 years'
              ELSE 'over 10 years' END AS VARCHAR(15))                          AS AgeCategory,
    CAST(CASE WHEN age.UnitAge >= 5 THEN 'Yes' ELSE 'No' END AS VARCHAR(3))     AS OlderUnit,
    CAST(CASE WHEN ow.UnitID IS NOT NULL THEN 'Yes' ELSE 'No' END AS VARCHAR(3)) AS OldestWindTurbine,
    CAST(CONCAT(u.UnitID, '_', ep.DateKey) AS VARCHAR(20))                      AS UnitDayKey,

    -- Zone
    z.ZoneID,
    z.ZoneName,
    z.AreaSizeSqm,

    -- Status
    s.OperationalStatus,
    CAST(s.IsOperating AS TINYINT)                                              AS IsOperating,

    -- Weather of the hour
    w.AvgTemperatureCategory,
    w.AvgWindSpeedCategory,
    w.PrecipitationCategory,
    w.CloudCoverCategory,
    w.SunshineDurationCategory,

    -- Weather of the day (zone)
    CAST(zd.DailyCloudCover AS DECIMAL(5,2))                                    AS DailyCloudCover,
    CAST(zd.DailyWindSpeed  AS DECIMAL(5,2))                                    AS DailyWindSpeed,
    CAST(dw.SkyConditionOfDay AS VARCHAR(15))                                   AS SkyConditionOfDay,
    CAST(dw.DailyWindSpeedCategory AS VARCHAR(10))                              AS DailyWindSpeedCategory,
    CAST(CASE WHEN (u.UnitType = 'Wind'  AND dw.DailyWindSpeedCategory = 'strong')
                OR (u.UnitType = 'Solar' AND dw.SkyConditionOfDay = 'Sunny')
              THEN 'Yes' ELSE 'No' END AS VARCHAR(3))                           AS OptimalWeatherDay,

    -- Date
    d.[Date],
    d.[Year],
    d.QuarterNo,
    d.[Month],
    d.MonthNo,
    d.DayOfWeek,
    d.DayOfWeekNo,
    d.Season,

    -- Time
    t.[Hour],
    t.TimeOfDay
FROM dbo.ENERGY_PRODUCTION AS ep
JOIN dbo.[DATE]  AS d ON d.DateKey    = ep.DateKey
JOIN dbo.[TIME]  AS t ON t.TimeKey    = ep.TimeKey
JOIN dbo.UNIT    AS u ON u.UnitKey    = ep.UnitKey
JOIN dbo.ZONE    AS z ON z.ZoneKey    = ep.ZoneKey
JOIN dbo.STATUS  AS s ON s.StatusKey  = ep.StatusKey
JOIN dbo.WEATHER AS w ON w.WeatherKey = ep.WeatherKey
LEFT JOIN ZoneDayWeather AS zd ON zd.ZoneID = z.ZoneID AND zd.DateKey = ep.DateKey
LEFT JOIN OldestWind     AS ow ON ow.UnitID = u.UnitID
CROSS APPLY (
    -- Whole years between the installation of the unit's equipment and the reading
    SELECT DATEDIFF(DAY, u.InstallationDateTime, d.[Date]) / 365 AS UnitAge
) AS age
CROSS APPLY (
    -- Daily weather classes of the zone
    SELECT
        CASE WHEN zd.DailyCloudCover IS NULL THEN 'Unknown'
             WHEN zd.DailyCloudCover < 2     THEN 'Sunny'
             WHEN zd.DailyCloudCover > 6     THEN 'Cloudy'
             ELSE 'Partly cloudy' END AS SkyConditionOfDay,
        CASE WHEN zd.DailyWindSpeed IS NULL THEN 'unknown'
             WHEN zd.DailyWindSpeed < 3     THEN 'calm'
             WHEN zd.DailyWindSpeed < 6     THEN 'light'
             WHEN zd.DailyWindSpeed < 9     THEN 'moderate'
             ELSE 'strong' END AS DailyWindSpeedCategory
) AS dw;
GO

-- ===================== Descriptions (dbo.SetDesc from 02_extended_properties.sql) =====================
EXEC dbo.SetDesc N'FlatTable', NULL, N'Semantic layer view (One Big Table). One row describes one reading of one unit within one hour with denormalized unit, zone, status, weather, date and time attributes.';
EXEC dbo.SetDesc N'FlatTable', N'ProductionLogID',          N'Identifier of the reading in the source system (degenerate dimension); primary key of the cube.';
EXEC dbo.SetDesc N'FlatTable', N'DateKey',                  N'Day of the reading as yyyymmdd (sort and partition column; hidden in the semantic layer).';
EXEC dbo.SetDesc N'FlatTable', N'ReadingDateTime',          N'Date and hour of the reading (UTC).';
EXEC dbo.SetDesc N'FlatTable', N'EnergyProduced',           N'Energy produced by the unit within the hour, in kWh.';
EXEC dbo.SetDesc N'FlatTable', N'MaxPossibleEnergy',        N'Maximum energy at full power capacity within the hour, in kWh.';
EXEC dbo.SetDesc N'FlatTable', N'AvgTemperature',           N'Average air temperature in the zone within the hour, in degC.';
EXEC dbo.SetDesc N'FlatTable', N'AvgWindSpeed',             N'Average wind speed in the zone within the hour, in m/s.';
EXEC dbo.SetDesc N'FlatTable', N'Precipitation',            N'Precipitation in the zone within the hour, in mm.';
EXEC dbo.SetDesc N'FlatTable', N'CloudCover',               N'Cloud cover in the zone within the hour, in oktas (0-8).';
EXEC dbo.SetDesc N'FlatTable', N'SunshineDuration',         N'Minutes of sunshine in the zone within the hour (0-60).';
EXEC dbo.SetDesc N'FlatTable', N'UnitID',                   N'Identifier of the unit (business key).';
EXEC dbo.SetDesc N'FlatTable', N'UnitType',                 N'Type of the unit: Wind, Solar.';
EXEC dbo.SetDesc N'FlatTable', N'ModelID',                  N'Identifier of the equipment model.';
EXEC dbo.SetDesc N'FlatTable', N'ModelName',                N'Name of the model.';
EXEC dbo.SetDesc N'FlatTable', N'ManufacturerID',           N'Identifier of the manufacturer.';
EXEC dbo.SetDesc N'FlatTable', N'ManufacturerName',         N'Name of the manufacturer (version valid at the reading time).';
EXEC dbo.SetDesc N'FlatTable', N'ManufacturerCountry',      N'Country of the manufacturer (version valid at the reading time).';
EXEC dbo.SetDesc N'FlatTable', N'MaxPowerCapacity',         N'Maximum power output of the unit, in kW.';
EXEC dbo.SetDesc N'FlatTable', N'InstallationDateTime',     N'Installation date of the unit''s equipment.';
EXEC dbo.SetDesc N'FlatTable', N'ExpectedLifespanYears',    N'Lifespan declared by the manufacturer, in years.';
EXEC dbo.SetDesc N'FlatTable', N'UnitAge',                  N'Whole years between the installation and the reading: DATEDIFF(day) / 365.';
EXEC dbo.SetDesc N'FlatTable', N'AgeCategory',              N'Unit age at the reading: under 1 year, 1-5 years, 5-10 years, over 10 years (half-open intervals).';
EXEC dbo.SetDesc N'FlatTable', N'OlderUnit',                N'Yes if the unit was over 5 years old at the reading (UnitAge >= 5), otherwise No.';
EXEC dbo.SetDesc N'FlatTable', N'OldestWindTurbine',        N'Yes for every version of the current wind unit with the earliest installation date, otherwise No.';
EXEC dbo.SetDesc N'FlatTable', N'UnitDayKey',               N'UnitID_yyyymmdd - counts unit-days (average daily energy per unit).';
EXEC dbo.SetDesc N'FlatTable', N'ZoneID',                   N'Identifier of the zone (business key).';
EXEC dbo.SetDesc N'FlatTable', N'ZoneName',                 N'Name of the zone.';
EXEC dbo.SetDesc N'FlatTable', N'AreaSizeSqm',              N'Area of the zone, in square meters (version valid at the reading time).';
EXEC dbo.SetDesc N'FlatTable', N'OperationalStatus',        N'Status of the unit during the hour: Operating, Fault, Maintenance.';
EXEC dbo.SetDesc N'FlatTable', N'IsOperating',              N'1 if the unit was operating, otherwise 0.';
EXEC dbo.SetDesc N'FlatTable', N'AvgTemperatureCategory',   N'Temperature category of the hour: freezing, cold, moderate, warm, hot.';
EXEC dbo.SetDesc N'FlatTable', N'AvgWindSpeedCategory',     N'Wind speed category of the hour: calm, light, moderate, strong.';
EXEC dbo.SetDesc N'FlatTable', N'PrecipitationCategory',    N'Precipitation category of the hour: none, light, moderate, heavy.';
EXEC dbo.SetDesc N'FlatTable', N'CloudCoverCategory',       N'Cloud cover category of the hour: clear, partly cloudy, overcast.';
EXEC dbo.SetDesc N'FlatTable', N'SunshineDurationCategory', N'Sunshine category of the hour: none, low, medium, high, full.';
EXEC dbo.SetDesc N'FlatTable', N'DailyCloudCover',          N'Daily mean cloud cover of the zone (one value per zone-hour, not weighted by units).';
EXEC dbo.SetDesc N'FlatTable', N'DailyWindSpeed',           N'Daily mean wind speed of the zone (one value per zone-hour, not weighted by units).';
EXEC dbo.SetDesc N'FlatTable', N'SkyConditionOfDay',        N'Daily sky condition of the zone: Sunny (mean cloud cover < 2), Cloudy (> 6), Partly cloudy, Unknown.';
EXEC dbo.SetDesc N'FlatTable', N'DailyWindSpeedCategory',   N'Daily mean wind speed of the zone: calm [0,3), light [3,6), moderate [6,9), strong (>= 9), unknown.';
EXEC dbo.SetDesc N'FlatTable', N'OptimalWeatherDay',        N'Yes for a wind unit on a strong-wind day or a solar unit on a Sunny day, otherwise No.';
EXEC dbo.SetDesc N'FlatTable', N'Date',                     N'Calendar date of the reading.';
EXEC dbo.SetDesc N'FlatTable', N'Year',                     N'Year of the reading.';
EXEC dbo.SetDesc N'FlatTable', N'QuarterNo',                N'Quarter of the reading (1-4).';
EXEC dbo.SetDesc N'FlatTable', N'Month',                    N'Month name of the reading.';
EXEC dbo.SetDesc N'FlatTable', N'MonthNo',                  N'Month number of the reading.';
EXEC dbo.SetDesc N'FlatTable', N'DayOfWeek',                N'Day of week of the reading.';
EXEC dbo.SetDesc N'FlatTable', N'DayOfWeekNo',              N'Day of week number (1 = Monday).';
EXEC dbo.SetDesc N'FlatTable', N'Season',                   N'Season of the reading: Winter, Spring, Summer, Autumn.';
EXEC dbo.SetDesc N'FlatTable', N'Hour',                     N'Hour of the reading (0-23, UTC).';
EXEC dbo.SetDesc N'FlatTable', N'TimeOfDay',                N'Time of day: night, morning, afternoon, evening.';
GO


-- ===================== Check: column descriptions =====================
USE EcoVoltDW_Part;
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
  AND ep.major_id = OBJECT_ID(N'dbo.FlatTable')
ORDER BY ep.minor_id;
GO

-- ===================== Test query: first 20 rows of the flat table =====================

USE EcoVoltDW_Part;
GO

SELECT TOP (20) * FROM dbo.FlatTable ORDER BY DateKey, [Hour], UnitID;
GO

SELECT COUNT(*) AS RowsCount,
       COUNT(DISTINCT ProductionLogID) AS DistinctReadings
FROM dbo.FlatTable;
GO
