USE EcoVoltDW;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ===================== Dimension primary keys =====================

ALTER TABLE dbo.UNIT    ADD CONSTRAINT PK_UNIT    PRIMARY KEY (UnitKey);
ALTER TABLE dbo.ZONE    ADD CONSTRAINT PK_ZONE    PRIMARY KEY (ZoneKey);
ALTER TABLE dbo.STATUS  ADD CONSTRAINT PK_STATUS  PRIMARY KEY (StatusKey);
ALTER TABLE dbo.WEATHER ADD CONSTRAINT PK_WEATHER PRIMARY KEY (WeatherKey);
ALTER TABLE dbo.[DATE]  ADD CONSTRAINT PK_DATE    PRIMARY KEY (DateKey);
ALTER TABLE dbo.[TIME]  ADD CONSTRAINT PK_TIME    PRIMARY KEY (TimeKey);
GO

-- ===================== Business key indexes =====================

CREATE UNIQUE NONCLUSTERED INDEX UX_STATUS_OperationalStatus ON dbo.STATUS (OperationalStatus);
CREATE UNIQUE NONCLUSTERED INDEX UX_DATE_Date ON dbo.[DATE] ([Date]);
CREATE UNIQUE NONCLUSTERED INDEX UX_TIME_Hour ON dbo.[TIME] ([Hour]);
-- Lookup of the WeatherKey from a combination of categories (ETL).
CREATE UNIQUE NONCLUSTERED INDEX UX_WEATHER_Categories
    ON dbo.WEATHER (AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory,
                    CloudCoverCategory, SunshineDurationCategory);

-- SCD2 tables: the business key repeats across versions, so these indexes are not unique.
-- (BusinessKey, ValidFrom) supports the lookup "version valid at the reading time".
CREATE NONCLUSTERED INDEX IX_UNIT_UnitID_ValidFrom ON dbo.UNIT (UnitID, ValidFrom) INCLUDE (ValidTo, MaxPowerCapacity);
CREATE NONCLUSTERED INDEX IX_ZONE_ZoneID_ValidFrom ON dbo.ZONE (ZoneID, ValidFrom) INCLUDE (ValidTo);

-- At most one current version per business key (filtered unique index).
CREATE UNIQUE NONCLUSTERED INDEX UX_UNIT_UnitID_Current ON dbo.UNIT (UnitID) WHERE IsCurrent = 1;
CREATE UNIQUE NONCLUSTERED INDEX UX_ZONE_ZoneID_Current ON dbo.ZONE (ZoneID) WHERE IsCurrent = 1;
GO

-- ===================== Disable nonclustered indexes (e.g. before bulk load) =====================
-- Dimensions are small (low cardinality), so in 07_incremental_load_T2.sql they stay enabled
-- (lecture: "Indexes remain enabled" for low-cardinality dimensions). This block shows the syntax.

ALTER INDEX UX_STATUS_OperationalStatus ON dbo.STATUS DISABLE;
ALTER INDEX UX_DATE_Date ON dbo.[DATE] DISABLE;
ALTER INDEX UX_TIME_Hour ON dbo.[TIME] DISABLE;
ALTER INDEX UX_WEATHER_Categories ON dbo.WEATHER DISABLE;
ALTER INDEX IX_UNIT_UnitID_ValidFrom ON dbo.UNIT DISABLE;
ALTER INDEX IX_ZONE_ZoneID_ValidFrom ON dbo.ZONE DISABLE;
ALTER INDEX UX_UNIT_UnitID_Current ON dbo.UNIT DISABLE;
ALTER INDEX UX_ZONE_ZoneID_Current ON dbo.ZONE DISABLE;
GO

-- ===================== Rebuild nonclustered indexes =====================

ALTER INDEX UX_STATUS_OperationalStatus ON dbo.STATUS REBUILD;
ALTER INDEX UX_DATE_Date ON dbo.[DATE] REBUILD;
ALTER INDEX UX_TIME_Hour ON dbo.[TIME] REBUILD;
ALTER INDEX UX_WEATHER_Categories ON dbo.WEATHER REBUILD;
ALTER INDEX IX_UNIT_UnitID_ValidFrom ON dbo.UNIT REBUILD;
ALTER INDEX IX_ZONE_ZoneID_ValidFrom ON dbo.ZONE REBUILD;
ALTER INDEX UX_UNIT_UnitID_Current ON dbo.UNIT REBUILD;
ALTER INDEX UX_ZONE_ZoneID_Current ON dbo.ZONE REBUILD;
GO

-- ===================== Check: dimension indexes =====================

SELECT OBJECT_NAME(i.object_id) AS TableName, i.name AS IndexName, i.type_desc,
       i.is_unique, i.is_primary_key, i.has_filter, i.filter_definition, i.is_disabled
FROM sys.indexes AS i
WHERE OBJECT_NAME(i.object_id) IN (N'UNIT', N'ZONE', N'STATUS', N'WEATHER', N'DATE', N'TIME')
  AND i.index_id > 0
ORDER BY TableName, i.index_id;
GO
