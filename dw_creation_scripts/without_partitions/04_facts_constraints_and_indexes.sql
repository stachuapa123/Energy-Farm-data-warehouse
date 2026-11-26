USE EcoVoltDW;
GO

-- ===================== Facts indexes =====================

-- ORDER requires SQL Server 2022+.
IF NOT EXISTS (
	SELECT 1
	FROM sys.indexes
	WHERE object_id = OBJECT_ID(N'dbo.EnergyProduction')
	  AND name = N'CCI_EnergyProduction'
)
	CREATE CLUSTERED COLUMNSTORE INDEX CCI_EnergyProduction ON dbo.EnergyProduction ORDER (DateKey);
GO

-- ===================== Fact primary key and source key =====================

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'PK_EnergyProduction')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT PK_EnergyProduction PRIMARY KEY NONCLUSTERED (EnergyProductionID);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'UX_EnergyProduction_ProductionLogID')
	CREATE UNIQUE NONCLUSTERED INDEX UX_EnergyProduction_ProductionLogID ON dbo.EnergyProduction (ProductionLogID);
GO

-- ===================== Fact foreign keys ======================

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'FK_EnergyProduction_Date')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT FK_EnergyProduction_Date FOREIGN KEY (DateKey) REFERENCES dbo.[Date] (DateKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'FK_EnergyProduction_Time')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT FK_EnergyProduction_Time FOREIGN KEY (TimeKey) REFERENCES dbo.[Time] (TimeKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'FK_EnergyProduction_Unit')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT FK_EnergyProduction_Unit FOREIGN KEY (UnitKey) REFERENCES dbo.Unit (UnitKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'FK_EnergyProduction_Zone')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT FK_EnergyProduction_Zone FOREIGN KEY (ZoneKey) REFERENCES dbo.Zone (ZoneKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'FK_EnergyProduction_Status')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT FK_EnergyProduction_Status FOREIGN KEY (StatusKey) REFERENCES dbo.Status (StatusKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'FK_EnergyProduction_Weather')
	ALTER TABLE dbo.EnergyProduction ADD CONSTRAINT FK_EnergyProduction_Weather FOREIGN KEY (WeatherKey) REFERENCES dbo.Weather (WeatherKey);
GO

-- ===================== Fact foreign key indexes =====================

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'IX_EnergyProduction_UnitKey')
	CREATE NONCLUSTERED INDEX IX_EnergyProduction_UnitKey ON dbo.EnergyProduction (UnitKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'IX_EnergyProduction_ZoneKey')
	CREATE NONCLUSTERED INDEX IX_EnergyProduction_ZoneKey ON dbo.EnergyProduction (ZoneKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.EnergyProduction') AND name = N'IX_EnergyProduction_WeatherKey')
	CREATE NONCLUSTERED INDEX IX_EnergyProduction_WeatherKey ON dbo.EnergyProduction (WeatherKey);
GO

-- ===================== Disable EnergyProduction foreign keys and indexes (e.g. before bulk load) =====================
ALTER TABLE dbo.EnergyProduction NOCHECK CONSTRAINT ALL;

ALTER INDEX IX_EnergyProduction_UnitKey ON dbo.EnergyProduction DISABLE;
ALTER INDEX IX_EnergyProduction_ZoneKey ON dbo.EnergyProduction DISABLE;
ALTER INDEX IX_EnergyProduction_WeatherKey ON dbo.EnergyProduction DISABLE;
GO

-- ===================== Re-enable EnergyProduction foreign keys and rebuild indexes =====================

ALTER INDEX IX_EnergyProduction_UnitKey ON dbo.EnergyProduction REBUILD;
ALTER INDEX IX_EnergyProduction_ZoneKey ON dbo.EnergyProduction REBUILD;
ALTER INDEX IX_EnergyProduction_WeatherKey ON dbo.EnergyProduction REBUILD;

-- Compresses the delta rowgroups of the increment without rebuilding the existing data.
ALTER INDEX CCI_EnergyProduction ON dbo.EnergyProduction REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

ALTER TABLE dbo.EnergyProduction WITH CHECK CHECK CONSTRAINT ALL;
GO
