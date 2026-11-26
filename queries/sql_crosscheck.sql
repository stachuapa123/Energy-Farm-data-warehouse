USE EcoVoltDW;
GO

-- Validation of the loaded data and the 10 queries of the requirements specification in SQL
-- (cross-check for the Cube Playground results).

-- ===================== Validation =====================

-- Expected: Date 731, Time 24, Status 3, Weather 1201, Zone 10, Unit 45
SELECT 'Date' AS TableName, COUNT(*) AS RowsCount FROM dbo.[Date]  UNION ALL
SELECT 'Time',              COUNT(*)              FROM dbo.[Time]  UNION ALL
SELECT 'Status',            COUNT(*)              FROM dbo.Status  UNION ALL
SELECT 'Weather',           COUNT(*)              FROM dbo.Weather UNION ALL
SELECT 'Zone',              COUNT(*)              FROM dbo.Zone    UNION ALL
SELECT 'Unit',              COUNT(*)              FROM dbo.Unit;
GO

-- Expected: 665832 rows and the same total energy in all three
SELECT 'EnergyProduction' AS Source, COUNT(*) AS RowsCount, SUM(EnergyProduced) AS TotalEnergyKWh FROM dbo.EnergyProduction
UNION ALL SELECT 'FlatTable (view)',  COUNT(*), SUM(EnergyProduced) FROM dbo.FlatTable
UNION ALL SELECT 'FlatTablePhysical', COUNT(*), SUM(EnergyProduced) FROM dbo.FlatTablePhysical;
GO

-- Expected: 0
SELECT COUNT(*) AS ReadingsWithoutWeather
FROM dbo.EnergyProduction
WHERE WeatherKey = 0;
GO

-- Expected: 0
SELECT COUNT(*) AS ReadingsWithWrongUnitVersion
FROM dbo.EnergyProduction AS ep
JOIN dbo.Unit AS u ON u.UnitKey = ep.UnitKey
JOIN dbo.[Date] AS d ON d.DateKey = ep.DateKey
CROSS APPLY (SELECT DATEADD(HOUR, ep.TimeKey, CAST(d.[Date] AS DATETIME)) AS ReadingTime) AS r
WHERE r.ReadingTime >= u.ValidTo
   OR (r.ReadingTime < u.ValidFrom
       AND EXISTS (SELECT 1 FROM dbo.Unit AS p WHERE p.UnitID = u.UnitID AND p.ValidFrom < u.ValidFrom));
GO

-- Expected: old SCD2 versions hold the 2024 readings, new versions the 2025 readings
SELECT u.UnitID, u.UnitKey, u.ManufacturerName, u.ManufacturerCountry, u.ValidFrom, u.ValidTo, u.IsCurrent,
       MIN(ep.DateKey) AS FirstReading, MAX(ep.DateKey) AS LastReading, COUNT(ep.EnergyProductionID) AS Readings
FROM dbo.Unit AS u
LEFT JOIN dbo.EnergyProduction AS ep ON ep.UnitKey = u.UnitKey
WHERE u.UnitID IN (SELECT UnitID FROM dbo.Unit GROUP BY UnitID HAVING COUNT(*) > 1)
GROUP BY u.UnitID, u.UnitKey, u.ManufacturerName, u.ManufacturerCountry, u.ValidFrom, u.ValidTo, u.IsCurrent
ORDER BY u.UnitID, u.ValidFrom;

SELECT z.ZoneID, z.ZoneKey, z.ZoneName, z.AreaSizeSqm, z.ValidFrom, z.ValidTo, z.IsCurrent,
       COUNT(ep.EnergyProductionID) AS Readings
FROM dbo.Zone AS z
LEFT JOIN dbo.EnergyProduction AS ep ON ep.ZoneKey = z.ZoneKey
WHERE z.ZoneID IN (SELECT ZoneID FROM dbo.Zone GROUP BY ZoneID HAVING COUNT(*) > 1)
GROUP BY z.ZoneID, z.ZoneKey, z.ZoneName, z.AreaSizeSqm, z.ValidFrom, z.ValidTo, z.IsCurrent
ORDER BY z.ZoneID, z.ValidFrom;
GO

-- Expected: capacity factor wind ~28 %, solar ~11 %; availability wind ~98 %, solar ~99.6 %
SELECT UnitType,
       CAST(SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS DECIMAL(6,4)) AS CapacityFactor,
       CAST(1.0 * SUM(IsOperating) / COUNT(*) AS DECIMAL(6,4))             AS Availability
FROM dbo.FlatTablePhysical
GROUP BY UnitType;
GO

-- Expected: Sunny about 4x Cloudy
SELECT SkyConditionOfDay,
       CAST(SUM(EnergyProduced) / COUNT(DISTINCT UnitDayKey) AS DECIMAL(12,1)) AS AvgDailyEnergyPerUnit,
       COUNT(DISTINCT UnitDayKey) AS UnitDays
FROM dbo.FlatTablePhysical
WHERE UnitType = 'Solar'
GROUP BY SkyConditionOfDay;
GO

SELECT ZoneName,
       COUNT(DISTINCT CASE WHEN DailyWindSpeedCategory = 'strong' THEN [Date] END) AS StrongWindDays,
       COUNT(DISTINCT CASE WHEN SkyConditionOfDay = 'Sunny'  THEN [Date] END)       AS SunnyDays,
       COUNT(DISTINCT CASE WHEN SkyConditionOfDay = 'Cloudy' THEN [Date] END)       AS CloudyDays
FROM dbo.FlatTablePhysical
GROUP BY ZoneName
ORDER BY ZoneName;
GO

-- Expected: all COMPRESSED
SELECT OBJECT_NAME(object_id) AS TableName, partition_number, row_group_id, state_desc, total_rows, deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id IN (OBJECT_ID(N'dbo.EnergyProduction'), OBJECT_ID(N'dbo.FlatTablePhysical'))
ORDER BY TableName, partition_number, row_group_id;
GO

SELECT OBJECT_NAME(p.object_id) AS TableName, p.partition_number, s.segment_id,
       s.row_count, s.min_data_id, s.max_data_id
FROM sys.column_store_segments AS s
JOIN sys.partitions AS p ON p.hobt_id = s.hobt_id
JOIN sys.columns    AS c ON c.object_id = p.object_id AND c.column_id = s.column_id
WHERE c.name = N'DateKey'
  AND p.object_id IN (OBJECT_ID(N'dbo.EnergyProduction'), OBJECT_ID(N'dbo.FlatTablePhysical'))
ORDER BY TableName, p.partition_number, s.segment_id;
GO

-- ===================== The 10 queries =====================

DECLARE @MaxDate  DATE = (SELECT MAX([Date]) FROM dbo.FlatTablePhysical);
DECLARE @CurMonth DATE = CASE WHEN @MaxDate = EOMONTH(@MaxDate)
                              THEN DATEFROMPARTS(YEAR(@MaxDate), MONTH(@MaxDate), 1)
                              ELSE DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(@MaxDate), MONTH(@MaxDate), 1)) END;
DECLARE @QStart   DATE = DATEFROMPARTS(YEAR(@MaxDate), (DATEPART(QUARTER, @MaxDate) - 1) * 3 + 1, 1);
IF @MaxDate <> EOMONTH(DATEADD(MONTH, 2, @QStart))
    SET @QStart = DATEADD(MONTH, -3, @QStart);

SELECT @CurMonth AS CurrentMonth, @QStart AS LastQuarterStart;

/* ---------------------------------------------------------------------
   PROBLEM 1: Why did energy production fluctuate this month?
   --------------------------------------------------------------------- */

/* Q1. Total energy in the current month vs the previous month */
SELECT [Year], MonthNo, [Month],
       SUM(EnergyProduced) AS TotalEnergyKWh,
       SUM(EnergyProduced) / NULLIF(LAG(SUM(EnergyProduced)) OVER (ORDER BY [Year], MonthNo), 0) - 1
           AS EnergyChangeVsPreviousMonth
FROM dbo.FlatTablePhysical
WHERE [Date] >= DATEADD(MONTH, -1, @CurMonth) AND [Date] < DATEADD(MONTH, 1, @CurMonth)
GROUP BY [Year], MonthNo, [Month]
ORDER BY [Year], MonthNo;

/* Q2. Top 5 generating units in the current month */
SELECT TOP (5) UnitID, UnitType,
       SUM(EnergyProduced) AS TotalEnergyKWh,
       SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor
FROM dbo.FlatTablePhysical
WHERE [Date] >= @CurMonth AND [Date] < DATEADD(MONTH, 1, @CurMonth)
GROUP BY UnitID, UnitType
ORDER BY TotalEnergyKWh DESC;

/* Q3. Average daily energy of solar units on Sunny vs Cloudy days */
SELECT SkyConditionOfDay,
       SUM(EnergyProduced) / COUNT(DISTINCT UnitDayKey) AS AvgDailyEnergyPerUnitKWh,
       COUNT(DISTINCT UnitDayKey) AS UnitDays
FROM dbo.FlatTablePhysical
WHERE UnitType = 'Solar' AND SkyConditionOfDay IN ('Sunny', 'Cloudy')
GROUP BY SkyConditionOfDay;

/* Q4. Average daily energy of wind turbines per daily wind speed range */
SELECT DailyWindSpeedCategory,
       SUM(EnergyProduced) / COUNT(DISTINCT UnitDayKey) AS AvgDailyEnergyPerUnitKWh,
       AVG(AvgWindSpeed) AS AvgWindSpeedMs,
       COUNT(DISTINCT UnitDayKey) AS UnitDays
FROM dbo.FlatTablePhysical
WHERE UnitType = 'Wind'
GROUP BY DailyWindSpeedCategory
ORDER BY CASE DailyWindSpeedCategory WHEN 'calm' THEN 1 WHEN 'light' THEN 2
                                     WHEN 'moderate' THEN 3 WHEN 'strong' THEN 4 ELSE 5 END;

/* Q5. Total energy per zone in the last quarter */
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM dbo.FlatTablePhysical
WHERE [Date] >= @QStart AND [Date] < DATEADD(MONTH, 3, @QStart)
GROUP BY ZoneName
ORDER BY TotalEnergyKWh DESC;

/* ---------------------------------------------------------------------
   PROBLEM 2: Impact of equipment aging on performance
   --------------------------------------------------------------------- */

/* Q6. Units over 5 years old vs units installed less than 1 year ago */
SELECT AgeGroup,
       SUM(EnergyProduced)                          AS TotalEnergyKWh,
       AVG(EnergyProduced)                          AS AvgHourlyEnergyKWh,
       SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor
FROM dbo.FlatTablePhysical
CROSS APPLY (SELECT CASE WHEN OlderUnit = 'Yes' THEN 'over 5 years'
                         WHEN AgeCategory = 'under 1 year' THEN 'under 1 year' END AS AgeGroup) AS g
WHERE g.AgeGroup IS NOT NULL
GROUP BY AgeGroup;

/* Q7. Average (hourly) energy of older units when the temperature is >= 30 degC */
SELECT ISNULL(UnitType, 'All') AS UnitType,
       AVG(EnergyProduced) AS AvgHourlyEnergyKWh,
       COUNT(*)            AS Readings
FROM dbo.FlatTablePhysical
WHERE OlderUnit = 'Yes' AND AvgTemperatureCategory = 'hot'
GROUP BY ROLLUP (UnitType);

/* Q8. Which unit type declines more with age: capacity factor per age category */
SELECT UnitType, AgeCategory,
       SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor,
       COUNT(DISTINCT UnitID) AS Units
FROM dbo.FlatTablePhysical
GROUP BY UnitType, AgeCategory
ORDER BY UnitType,
         CASE AgeCategory WHEN 'under 1 year' THEN 1 WHEN '1-5 years' THEN 2
                          WHEN '5-10 years' THEN 3 ELSE 4 END;

/* Q9. Lowest producing units on optimal weather days (5 per unit type) */
WITH PerUnit AS (
    SELECT UnitID, UnitType, ModelName, ManufacturerName,
           SUM(EnergyProduced) / COUNT(DISTINCT UnitDayKey) AS AvgDailyEnergyPerUnitKWh,
           SUM(EnergyProduced) / SUM(MaxPossibleEnergy)     AS CapacityFactor,
           COUNT(DISTINCT UnitDayKey)                       AS OptimalDays
    FROM dbo.FlatTablePhysical
    WHERE OptimalWeatherDay = 'Yes'
    GROUP BY UnitID, UnitType, ModelName, ManufacturerName
)
SELECT *
FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY UnitType ORDER BY CapacityFactor) AS RankLowest
      FROM PerUnit) AS r
WHERE RankLowest <= 5
ORDER BY UnitType, RankLowest;

/* Q10. Oldest wind turbine: current month vs the same month last year */
SELECT UnitID, [Year], [Month],
       SUM(EnergyProduced) AS TotalEnergyKWh
FROM dbo.FlatTablePhysical
WHERE OldestWindTurbine = 'Yes'
  AND (   ([Date] >= @CurMonth AND [Date] < DATEADD(MONTH, 1, @CurMonth))
       OR ([Date] >= DATEADD(YEAR, -1, @CurMonth) AND [Date] < DATEADD(MONTH, 1, DATEADD(YEAR, -1, @CurMonth))))
GROUP BY UnitID, [Year], [Month]
ORDER BY [Year];
GO
