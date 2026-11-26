USE EcoVoltDW;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ===================== Dimension primary keys =====================

ALTER TABLE dbo.Unit    ADD CONSTRAINT PK_Unit    PRIMARY KEY (UnitKey);
ALTER TABLE dbo.Zone    ADD CONSTRAINT PK_Zone    PRIMARY KEY (ZoneKey);
ALTER TABLE dbo.Status  ADD CONSTRAINT PK_Status  PRIMARY KEY (StatusKey);
ALTER TABLE dbo.Weather ADD CONSTRAINT PK_Weather PRIMARY KEY (WeatherKey);
ALTER TABLE dbo.[Date]  ADD CONSTRAINT PK_Date    PRIMARY KEY (DateKey);
ALTER TABLE dbo.[Time]  ADD CONSTRAINT PK_Time    PRIMARY KEY (TimeKey);
GO

-- ===================== Business key indexes =====================

CREATE UNIQUE NONCLUSTERED INDEX UX_Status_OperationalStatus ON dbo.Status (OperationalStatus);
CREATE UNIQUE NONCLUSTERED INDEX UX_Date_Date ON dbo.[Date] ([Date]);
CREATE UNIQUE NONCLUSTERED INDEX UX_Time_Hour ON dbo.[Time] ([Hour]);
CREATE UNIQUE NONCLUSTERED INDEX UX_Weather_Categories
    ON dbo.Weather (AvgTemperatureCategory, AvgWindSpeedCategory, PrecipitationCategory,
                    CloudCoverCategory, SunshineDurationCategory);

-- SCD2 tables: business key repeats across versions, so indexes are not unique.
CREATE NONCLUSTERED INDEX IX_Unit_UnitID_ValidFrom ON dbo.Unit (UnitID, ValidFrom) INCLUDE (ValidTo, MaxPowerCapacity);
CREATE NONCLUSTERED INDEX IX_Zone_ZoneID_ValidFrom ON dbo.Zone (ZoneID, ValidFrom) INCLUDE (ValidTo);

CREATE UNIQUE NONCLUSTERED INDEX UX_Unit_UnitID_Current ON dbo.Unit (UnitID) WHERE IsCurrent = 1;
CREATE UNIQUE NONCLUSTERED INDEX UX_Zone_ZoneID_Current ON dbo.Zone (ZoneID) WHERE IsCurrent = 1;
GO

-- ===================== Disable nonclustered indexes (e.g. before bulk load) =====================

ALTER INDEX UX_Status_OperationalStatus ON dbo.Status DISABLE;
ALTER INDEX UX_Date_Date ON dbo.[Date] DISABLE;
ALTER INDEX UX_Time_Hour ON dbo.[Time] DISABLE;
ALTER INDEX UX_Weather_Categories ON dbo.Weather DISABLE;
ALTER INDEX IX_Unit_UnitID_ValidFrom ON dbo.Unit DISABLE;
ALTER INDEX IX_Zone_ZoneID_ValidFrom ON dbo.Zone DISABLE;
ALTER INDEX UX_Unit_UnitID_Current ON dbo.Unit DISABLE;
ALTER INDEX UX_Zone_ZoneID_Current ON dbo.Zone DISABLE;
GO

-- ===================== Rebuild nonclustered indexes =====================

ALTER INDEX UX_Status_OperationalStatus ON dbo.Status REBUILD;
ALTER INDEX UX_Date_Date ON dbo.[Date] REBUILD;
ALTER INDEX UX_Time_Hour ON dbo.[Time] REBUILD;
ALTER INDEX UX_Weather_Categories ON dbo.Weather REBUILD;
ALTER INDEX IX_Unit_UnitID_ValidFrom ON dbo.Unit REBUILD;
ALTER INDEX IX_Zone_ZoneID_ValidFrom ON dbo.Zone REBUILD;
ALTER INDEX UX_Unit_UnitID_Current ON dbo.Unit REBUILD;
ALTER INDEX UX_Zone_ZoneID_Current ON dbo.Zone REBUILD;
GO
