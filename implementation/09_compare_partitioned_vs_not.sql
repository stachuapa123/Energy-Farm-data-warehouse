-- Partitioned vs non-partitioned versions (subtask 4). Needs both databases:
--   EcoVoltDW       <- without_partitions/*.sql
--   EcoVoltDW_Part  <- with_partitions/*.sql
-- In SSMS turn on "Include Actual Execution Plan" (Ctrl+M) and compare for every pair of queries:
--   * Messages: logical reads / lob logical reads, "segment reads / segment skipped", CPU and elapsed time
--   * Plan: Columnstore Index Scan -> Actual Partition Count (1 = partition elimination), Actual Execution Mode = Batch
-- With sqlcmd the STATISTICS IO/TIME output is printed after every result.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE EcoVoltDW_Part;
GO

-- Which partition holds which rows
SELECT $PARTITION.PF_ENERGY_PRODUCTION_DateKey(DateKey) AS PartitionNumber,
       MIN(DateKey) AS FirstDateKey, MAX(DateKey) AS LastDateKey, COUNT(*) AS RowsCount
FROM dbo.ENERGY_PRODUCTION
GROUP BY $PARTITION.PF_ENERGY_PRODUCTION_DateKey(DateKey)
ORDER BY PartitionNumber;
GO

-- Cold cache for a fair comparison (test server only, needs sysadmin)
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

-- ===================== A. Star schema: energy per unit type in Q4 2025 =====================
PRINT '=== A1. EcoVoltDW.dbo.ENERGY_PRODUCTION (non-partitioned) ===';
SELECT u.UnitType, SUM(ep.EnergyProduced) AS TotalEnergyKWh,
       SUM(ep.EnergyProduced) / SUM(ep.MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW.dbo.ENERGY_PRODUCTION AS ep
JOIN EcoVoltDW.dbo.UNIT AS u ON u.UnitKey = ep.UnitKey
WHERE ep.DateKey BETWEEN 20251001 AND 20251231
GROUP BY u.UnitType;

PRINT '=== A2. EcoVoltDW_Part.dbo.ENERGY_PRODUCTION (partitioned by year) ===';
SELECT u.UnitType, SUM(ep.EnergyProduced) AS TotalEnergyKWh,
       SUM(ep.EnergyProduced) / SUM(ep.MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW_Part.dbo.ENERGY_PRODUCTION AS ep
JOIN EcoVoltDW_Part.dbo.UNIT AS u ON u.UnitKey = ep.UnitKey
WHERE ep.DateKey BETWEEN 20251001 AND 20251231
GROUP BY u.UnitType;
GO

-- ===================== B. Flat tables: Q5 (energy per zone in the last quarter) =====================
PRINT '=== B1. EcoVoltDW.dbo.FlatTable (view - joins at query time) ===';
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM EcoVoltDW.dbo.FlatTable
WHERE DateKey BETWEEN 20251001 AND 20251231
GROUP BY ZoneName;

PRINT '=== B2. EcoVoltDW.dbo.FLAT_TABLE (CCI, non-partitioned) ===';
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM EcoVoltDW.dbo.FLAT_TABLE
WHERE DateKey BETWEEN 20251001 AND 20251231
GROUP BY ZoneName;

PRINT '=== B3. EcoVoltDW_Part.dbo.FLAT_TABLE (CCI, partitioned by year) ===';
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM EcoVoltDW_Part.dbo.FLAT_TABLE
WHERE DateKey BETWEEN 20251001 AND 20251231
GROUP BY ZoneName;
GO

-- ===================== C. Whole history (no date filter): nothing to eliminate =====================
PRINT '=== C1. EcoVoltDW.dbo.FLAT_TABLE, all years ===';
SELECT UnitType, [Year], SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW.dbo.FLAT_TABLE GROUP BY UnitType, [Year];

PRINT '=== C2. EcoVoltDW_Part.dbo.FLAT_TABLE, all years ===';
SELECT UnitType, [Year], SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW_Part.dbo.FLAT_TABLE GROUP BY UnitType, [Year];
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- ===================== Storage used by every version (CCI compression) =====================
SELECT 'EcoVoltDW' AS DatabaseName, t.name AS TableName, SUM(a.total_pages) * 8 / 1024.0 AS TotalSpaceMB
FROM EcoVoltDW.sys.tables AS t
JOIN EcoVoltDW.sys.partitions AS p ON p.object_id = t.object_id
JOIN EcoVoltDW.sys.allocation_units AS a ON a.container_id = p.partition_id
WHERE t.name IN (N'ENERGY_PRODUCTION', N'FLAT_TABLE')
GROUP BY t.name
UNION ALL
SELECT 'EcoVoltDW_Part', t.name, SUM(a.total_pages) * 8 / 1024.0
FROM EcoVoltDW_Part.sys.tables AS t
JOIN EcoVoltDW_Part.sys.partitions AS p ON p.object_id = t.object_id
JOIN EcoVoltDW_Part.sys.allocation_units AS a ON a.container_id = p.partition_id
WHERE t.name IN (N'ENERGY_PRODUCTION', N'FLAT_TABLE')
GROUP BY t.name
ORDER BY TableName, DatabaseName;
GO
