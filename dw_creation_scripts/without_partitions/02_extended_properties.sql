-- Extended Properties are used to add descriptions to tables and columns in SQL Server. These descriptions can be viewed
-- in SQL Server Management Studio (SSMS) and help to understand the purpose of each table and column.
-- Table and column descriptions (MS_Description) for EcoVolt DW
USE EcoVoltDW;
GO

-- Adds or updates MS_Description; @columnName = NULL describes the table or view itself.
CREATE OR ALTER PROCEDURE dbo.SetDesc @objectName SYSNAME, @columnName SYSNAME = NULL, @description NVARCHAR(3750)
AS
BEGIN
  DECLARE @object_id INT = OBJECT_ID(N'dbo.' + QUOTENAME(@objectName));
  DECLARE @l1t NVARCHAR(128);
  SELECT @l1t = CASE type WHEN 'V' THEN N'VIEW' WHEN 'U' THEN N'TABLE' END
  FROM sys.objects
  WHERE object_id = @object_id;

  IF @l1t IS NULL
    THROW 50000, 'The specified dbo object does not exist or is not a table or view.', 1;

  -- COLUMNPROPERTY resolves columns for both tables and views.
  DECLARE @minor INT = CASE WHEN @columnName IS NULL THEN 0 ELSE COLUMNPROPERTY(@object_id, @columnName, 'ColumnId') END;
  IF @columnName IS NOT NULL AND @minor IS NULL
    THROW 50001, 'The specified column does not exist on the dbo object.', 1;

  DECLARE @exists BIT = CASE WHEN EXISTS (SELECT 1 FROM sys.extended_properties
                                          WHERE class = 1 AND name = N'MS_Description'
                                            AND major_id = @object_id AND minor_id = @minor)
                             THEN 1 ELSE 0 END;
  DECLARE @l2t VARCHAR(128) = CASE WHEN @columnName IS NULL THEN NULL ELSE 'COLUMN' END;

    IF @exists = 1
        EXEC sys.sp_updateextendedproperty @name = N'MS_Description', @value = @description,
             @level0type = N'SCHEMA', @level0name = N'dbo',
             @level1type = @l1t,      @level1name = @objectName,
             @level2type = @l2t,      @level2name = @columnName;
    ELSE
        EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = @description,
             @level0type = N'SCHEMA', @level0name = N'dbo',
             @level1type = @l1t,      @level1name = @objectName,
             @level2type = @l2t,      @level2name = @columnName;
END;
GO

GO

-- ===================== EnergyProduction =====================
EXEC dbo.SetDesc N'EnergyProduction', NULL, N'Fact table. One tuple describes the energy produced by one generation unit within one hour (one smart-meter reading), together with the raw weather measurements of the unit''s zone during that hour.';
EXEC dbo.SetDesc N'EnergyProduction', N'EnergyProductionID', N'Surrogate key.';
EXEC dbo.SetDesc N'EnergyProduction', N'DateKey',            N'FK to Date. Day of the reading.';
EXEC dbo.SetDesc N'EnergyProduction', N'TimeKey',            N'FK to Time. Hour of the reading.';
EXEC dbo.SetDesc N'EnergyProduction', N'UnitKey',            N'FK to Unit. Unit that produced the energy (the version of the unit valid at the time of the reading).';
EXEC dbo.SetDesc N'EnergyProduction', N'ZoneKey',            N'FK to Zone. Zone in which the unit is located (the version of the zone valid at the time of the reading).';
EXEC dbo.SetDesc N'EnergyProduction', N'StatusKey',          N'FK to Status. Operational status of the unit during the hour.';
EXEC dbo.SetDesc N'EnergyProduction', N'WeatherKey',         N'FK to Weather. Weather conditions in the zone of the unit during the hour (0 = unknown).';
EXEC dbo.SetDesc N'EnergyProduction', N'ProductionLogID',    N'Degenerate dimension. Identifier of the reading in the source system PowerMaster.';
EXEC dbo.SetDesc N'EnergyProduction', N'EnergyProduced',     N'Energy produced by the unit within the hour, in kWh. Additive measure.';
EXEC dbo.SetDesc N'EnergyProduction', N'MaxPossibleEnergy',  N'Maximum energy the unit would produce within the hour at full power capacity (MaxPowerCapacity x 1 h), in kWh. Additive measure.';
EXEC dbo.SetDesc N'EnergyProduction', N'AvgTemperature',     N'Average air temperature in the zone within the hour, in degC. Non-additive measure (averaged only).';
EXEC dbo.SetDesc N'EnergyProduction', N'AvgWindSpeed',       N'Average wind speed in the zone within the hour, in m/s. Non-additive measure (averaged only).';
EXEC dbo.SetDesc N'EnergyProduction', N'Precipitation',      N'Precipitation in the zone within the hour, in mm. Non-additive across units in the same zone.';
EXEC dbo.SetDesc N'EnergyProduction', N'CloudCover',         N'Cloud cover in the zone within the hour, in oktas (0-8). Non-additive measure (averaged only).';
EXEC dbo.SetDesc N'EnergyProduction', N'SunshineDuration',   N'Minutes of sunshine in the zone within the hour (0-60). Non-additive across units in the same zone.';

-- ===================== Unit =====================
EXEC dbo.SetDesc N'Unit', NULL, N'Dimension table (SCD2). One tuple describes one generation unit (wind turbine or solar array) with its model and manufacturer, in one version of its attributes.';
EXEC dbo.SetDesc N'Unit', N'UnitKey',               N'PK. Surrogate key.';
EXEC dbo.SetDesc N'Unit', N'UnitID',                N'Business key. Identifier of the unit (e.g. WT-GDA-01, PV-POZ-03).';
EXEC dbo.SetDesc N'Unit', N'ManufacturerID',        N'Identifier of the manufacturer.';
EXEC dbo.SetDesc N'Unit', N'ManufacturerName',      N'Name of the manufacturer (e.g. Vestas, LONGi).';
EXEC dbo.SetDesc N'Unit', N'ManufacturerCountry',   N'Country of origin of the manufacturer.';
EXEC dbo.SetDesc N'Unit', N'ModelID',               N'Identifier of the equipment model.';
EXEC dbo.SetDesc N'Unit', N'ModelName',             N'Name of the model (e.g. V136-4.2 MW).';
EXEC dbo.SetDesc N'Unit', N'UnitType',              N'Type of the unit. Allowed values: Wind, Solar.';
EXEC dbo.SetDesc N'Unit', N'MaxPowerCapacity',      N'Maximum power output of the unit, in kW.';
EXEC dbo.SetDesc N'Unit', N'InstallationDateTime',  N'Date the unit (its current equipment) was installed.';
EXEC dbo.SetDesc N'Unit', N'ExpectedLifespanYears', N'Lifespan of the unit declared by the manufacturer, in years.';
EXEC dbo.SetDesc N'Unit', N'ValidFrom',             N'Date from which the tuple is valid (SCD2 implementation).';
EXEC dbo.SetDesc N'Unit', N'ValidTo',               N'Date until which the tuple is valid; 9999-12-31 for the current tuple (SCD2 implementation).';
EXEC dbo.SetDesc N'Unit', N'IsCurrent',             N'1 if information is current, otherwise 0 (SCD2 implementation).';

-- ===================== Zone =====================
EXEC dbo.SetDesc N'Zone', NULL, N'Dimension table (SCD2). One tuple describes one zone of the farm in one version of its attributes.';
EXEC dbo.SetDesc N'Zone', N'ZoneKey',     N'PK. Surrogate key.';
EXEC dbo.SetDesc N'Zone', N'ZoneID',      N'Business key. Identifier of the zone.';
EXEC dbo.SetDesc N'Zone', N'ZoneName',    N'Name of the zone. Allowed values: Gdansk, Szczecin, Olsztyn, Bialystok, Bydgoszcz, Zielona Gora, Poznan, Warszawa.';
EXEC dbo.SetDesc N'Zone', N'AreaSizeSqm', N'Area of the zone, in square meters.';
EXEC dbo.SetDesc N'Zone', N'ValidFrom',   N'Date from which the tuple is valid (SCD2 implementation).';
EXEC dbo.SetDesc N'Zone', N'ValidTo',     N'Date until which the tuple is valid; 9999-12-31 for the current tuple (SCD2 implementation).';
EXEC dbo.SetDesc N'Zone', N'IsCurrent',   N'1 if information is current, otherwise 0 (SCD2 implementation).';

-- ===================== Status =====================
EXEC dbo.SetDesc N'Status', NULL, N'Dimension table. One tuple describes one operational status of a unit.';
EXEC dbo.SetDesc N'Status', N'StatusKey',         N'PK. Status identifier.';
EXEC dbo.SetDesc N'Status', N'OperationalStatus', N'Status of the unit. Allowed values: Operating, Fault, Maintenance.';
EXEC dbo.SetDesc N'Status', N'IsOperating',       N'1 if the unit was operating (producing energy), otherwise 0.';

-- ===================== Weather =====================
EXEC dbo.SetDesc N'Weather', NULL, N'Dimension table (junk). The tuples correspond to all combinations of the categories of temperature, wind speed, precipitation, cloud cover and sunshine duration (1200) plus the unknown member (WeatherKey = 0).';
EXEC dbo.SetDesc N'Weather', N'WeatherKey',               N'PK. Weather identifier.';
EXEC dbo.SetDesc N'Weather', N'AvgTemperatureCategory',   N'Average air temperature: freezing (<0), cold [0,10), moderate [10,20), warm [20,30), hot (>=30) degC.';
EXEC dbo.SetDesc N'Weather', N'AvgWindSpeedCategory',     N'Average wind speed: calm [0,3), light [3,6), moderate [6,9), strong (>=9) m/s.';
EXEC dbo.SetDesc N'Weather', N'PrecipitationCategory',    N'Precipitation: none (0), light (0,2.5), moderate [2.5,7.6], heavy (>7.6) mm.';
EXEC dbo.SetDesc N'Weather', N'CloudCoverCategory',       N'Cloud cover: clear (0-2), partly cloudy (3-5), overcast (6-8) oktas.';
EXEC dbo.SetDesc N'Weather', N'SunshineDurationCategory', N'Sunshine: none (0), low (1-20), medium (21-40), high (41-59), full (60) minutes.';

-- ===================== Date =====================
EXEC dbo.SetDesc N'Date', NULL, N'Dimension table. One tuple describes one day.';
EXEC dbo.SetDesc N'Date', N'DateKey',     N'PK. Date identifier in the form yyyymmdd.';
EXEC dbo.SetDesc N'Date', N'Date',        N'Calendar date.';
EXEC dbo.SetDesc N'Date', N'Year',        N'Year (4 digits).';
EXEC dbo.SetDesc N'Date', N'QuarterNo',   N'Quarter of the year (1-4).';
EXEC dbo.SetDesc N'Date', N'Month',       N'Month name (January, February, ..., December).';
EXEC dbo.SetDesc N'Date', N'MonthNo',     N'Month''s numeric value.';
EXEC dbo.SetDesc N'Date', N'DayOfWeek',   N'Day of week (Monday, Tuesday, ..., Sunday).';
EXEC dbo.SetDesc N'Date', N'DayOfWeekNo', N'Weekday''s numeric value (1 = Monday, ..., 7 = Sunday).';
EXEC dbo.SetDesc N'Date', N'Season',      N'Season: Spring 21 Mar-20 Jun, Summer 21 Jun-22 Sep, Autumn 23 Sep-20 Dec, Winter 21 Dec-20 Mar.';

-- ===================== Time =====================
EXEC dbo.SetDesc N'Time', NULL, N'Dimension table. One tuple describes one hour (independent of date). All times are UTC.';
EXEC dbo.SetDesc N'Time', N'TimeKey',   N'PK. Time identifier (= Hour).';
EXEC dbo.SetDesc N'Time', N'Hour',      N'Hour (values from 0 to 23).';
EXEC dbo.SetDesc N'Time', N'TimeOfDay', N'Time of day: night (0-5), morning (6-11), afternoon (12-17), evening (18-23).';

GO

-- ===================== Test queries =====================

-- 1. Table descriptions.
USE EcoVoltDW;
GO

SELECT t.name AS TableName, CAST(ep.value AS NVARCHAR(3750)) AS Description
FROM sys.tables AS t
JOIN sys.extended_properties AS ep
  ON ep.class = 1 AND ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = N'MS_Description'
ORDER BY t.name;
GO

-- 2. Column descriptions.
USE EcoVoltDW;
GO

SELECT t.name AS TableName, c.name AS ColumnName, CAST(ep.value AS NVARCHAR(3750)) AS Description
FROM sys.tables AS t
JOIN sys.columns AS c ON c.object_id = t.object_id
JOIN sys.extended_properties AS ep
  ON ep.class = 1 AND ep.major_id = t.object_id AND ep.minor_id = c.column_id AND ep.name = N'MS_Description'
ORDER BY t.name, c.column_id;
GO
