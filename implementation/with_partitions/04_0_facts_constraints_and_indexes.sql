-- Compared with without_partitions, ENERGY_PRODUCTION's partitioned CCI is created earlier by 01_01; this script handles remaining fact indexes and constraints.
USE EcoVoltDW_Part;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- ===================== Facts indexes =====================

-- CCI_ENERGY_PRODUCTION is created before the bulk load in 01_01_fact_CCI_partitioned.sql.

-- ===================== Fact primary key and source key =====================

-- NONCLUSTERED: the CCI is the clustered index of the table.
-- Aligned with the partition scheme, so every unique index must contain the partitioning column DateKey.
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'PK_ENERGY_PRODUCTION')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT PK_ENERGY_PRODUCTION PRIMARY KEY NONCLUSTERED (EnergyProductionID, DateKey);

-- One reading of the source system cannot be loaded twice on the same day (aligned unique index).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'UX_ENERGY_PRODUCTION_ProductionLogID')
	CREATE UNIQUE NONCLUSTERED INDEX UX_ENERGY_PRODUCTION_ProductionLogID ON dbo.ENERGY_PRODUCTION (ProductionLogID, DateKey);
GO

-- ===================== Fact foreign keys ======================

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'FK_ENERGY_PRODUCTION_DATE')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT FK_ENERGY_PRODUCTION_DATE FOREIGN KEY (DateKey) REFERENCES dbo.[DATE] (DateKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'FK_ENERGY_PRODUCTION_TIME')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT FK_ENERGY_PRODUCTION_TIME FOREIGN KEY (TimeKey) REFERENCES dbo.[TIME] (TimeKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'FK_ENERGY_PRODUCTION_UNIT')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT FK_ENERGY_PRODUCTION_UNIT FOREIGN KEY (UnitKey) REFERENCES dbo.UNIT (UnitKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'FK_ENERGY_PRODUCTION_ZONE')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT FK_ENERGY_PRODUCTION_ZONE FOREIGN KEY (ZoneKey) REFERENCES dbo.ZONE (ZoneKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'FK_ENERGY_PRODUCTION_STATUS')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT FK_ENERGY_PRODUCTION_STATUS FOREIGN KEY (StatusKey) REFERENCES dbo.STATUS (StatusKey);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'FK_ENERGY_PRODUCTION_WEATHER')
	ALTER TABLE dbo.ENERGY_PRODUCTION ADD CONSTRAINT FK_ENERGY_PRODUCTION_WEATHER FOREIGN KEY (WeatherKey) REFERENCES dbo.WEATHER (WeatherKey);
GO

-- ===================== Fact foreign key indexes =====================
-- Created without an ON clause, nonclustered indexes of a partitioned table are aligned with its scheme.
-- "Less is more": no index on DateKey (the CCI is already ordered by it), TimeKey (24 values)
-- or StatusKey (3 values) - too unselective to help.

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'IX_ENERGY_PRODUCTION_UnitKey')
	CREATE NONCLUSTERED INDEX IX_ENERGY_PRODUCTION_UnitKey ON dbo.ENERGY_PRODUCTION (UnitKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'IX_ENERGY_PRODUCTION_ZoneKey')
	CREATE NONCLUSTERED INDEX IX_ENERGY_PRODUCTION_ZoneKey ON dbo.ENERGY_PRODUCTION (ZoneKey);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION') AND name = N'IX_ENERGY_PRODUCTION_WeatherKey')
	CREATE NONCLUSTERED INDEX IX_ENERGY_PRODUCTION_WeatherKey ON dbo.ENERGY_PRODUCTION (WeatherKey);
GO

-- ===================== Disable ENERGY_PRODUCTION foreign keys and indexes (e.g. before bulk load) =====================
-- 07_incremental_load_T2.sql runs exactly these steps around the load of 2025.

ALTER TABLE dbo.ENERGY_PRODUCTION NOCHECK CONSTRAINT ALL;

ALTER INDEX IX_ENERGY_PRODUCTION_UnitKey ON dbo.ENERGY_PRODUCTION DISABLE;
ALTER INDEX IX_ENERGY_PRODUCTION_ZoneKey ON dbo.ENERGY_PRODUCTION DISABLE;
ALTER INDEX IX_ENERGY_PRODUCTION_WeatherKey ON dbo.ENERGY_PRODUCTION DISABLE;
GO

-- ===================== Re-enable ENERGY_PRODUCTION foreign keys and rebuild indexes =====================

ALTER INDEX IX_ENERGY_PRODUCTION_UnitKey ON dbo.ENERGY_PRODUCTION REBUILD;
ALTER INDEX IX_ENERGY_PRODUCTION_ZoneKey ON dbo.ENERGY_PRODUCTION REBUILD;
ALTER INDEX IX_ENERGY_PRODUCTION_WeatherKey ON dbo.ENERGY_PRODUCTION REBUILD;

-- Compresses delta rowgroups after the bulk load without rebuilding the existing data.
ALTER INDEX CCI_ENERGY_PRODUCTION
	ON dbo.ENERGY_PRODUCTION
	REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

ALTER TABLE dbo.ENERGY_PRODUCTION WITH CHECK CHECK CONSTRAINT ALL;
GO

-- ===================== Check: fact indexes and rowgroups =====================

SELECT i.name AS IndexName, i.type_desc, i.is_unique, i.is_primary_key, i.is_disabled
FROM sys.indexes AS i
WHERE i.object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION')
ORDER BY i.index_id;

SELECT partition_number, row_group_id, state_desc, total_rows, deleted_rows
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION')
ORDER BY partition_number, row_group_id;
GO
