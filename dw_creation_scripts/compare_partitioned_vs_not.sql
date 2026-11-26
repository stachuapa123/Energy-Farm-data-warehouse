-- Partitioned vs non-partitioned versions; needs both databases (EcoVoltDW and EcoVoltDW_Part).
-- Compare the STATISTICS IO/TIME output and the actual execution plans of every pair of queries.
USE EcoVoltDW_Part;
GO

SELECT $PARTITION.PF_EnergyProduction_DateKey(DateKey) AS PartitionNumber,
       MIN(DateKey) AS FirstDateKey, MAX(DateKey) AS LastDateKey, COUNT(*) AS RowsCount
FROM dbo.EnergyProduction
GROUP BY $PARTITION.PF_EnergyProduction_DateKey(DateKey)
ORDER BY PartitionNumber;
GO

CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

-- ===================== A. Star schema: energy per unit type in Q4 2025 =====================
PRINT '=== A1. EcoVoltDW.dbo.EnergyProduction (non-partitioned) ===';
SELECT u.UnitType, SUM(ep.EnergyProduced) AS TotalEnergyKWh,
       SUM(ep.EnergyProduced) / SUM(ep.MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW.dbo.EnergyProduction AS ep
JOIN EcoVoltDW.dbo.Unit AS u ON u.UnitKey = ep.UnitKey
WHERE ep.DateKey BETWEEN 20251001 AND 20251231
GROUP BY u.UnitType;

PRINT '=== A2. EcoVoltDW_Part.dbo.EnergyProduction (partitioned by year) ===';
SELECT u.UnitType, SUM(ep.EnergyProduced) AS TotalEnergyKWh,
       SUM(ep.EnergyProduced) / SUM(ep.MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW_Part.dbo.EnergyProduction AS ep
JOIN EcoVoltDW_Part.dbo.Unit AS u ON u.UnitKey = ep.UnitKey
WHERE ep.DateKey BETWEEN 20251001 AND 20251231
GROUP BY u.UnitType;
GO

-- ===================== B. Flat tables: Q5 (energy per zone in the last quarter) =====================
PRINT '=== B1. EcoVoltDW.dbo.FlatTable (view - joins at query time) ===';
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM EcoVoltDW.dbo.FlatTable
WHERE DateKey BETWEEN 20251001 AND 20251231
GROUP BY ZoneName;

PRINT '=== B2. EcoVoltDW.dbo.FlatTablePhysical (CCI, non-partitioned) ===';
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM EcoVoltDW.dbo.FlatTablePhysical
WHERE DateKey BETWEEN 20251001 AND 20251231
GROUP BY ZoneName;

PRINT '=== B3. EcoVoltDW_Part.dbo.FlatTablePhysical (CCI, partitioned by year) ===';
SELECT ZoneName, SUM(EnergyProduced) AS TotalEnergyKWh
FROM EcoVoltDW_Part.dbo.FlatTablePhysical
WHERE DateKey BETWEEN 20251001 AND 20251231
GROUP BY ZoneName;
GO

-- ===================== C. Whole history (no date filter): nothing to eliminate =====================
PRINT '=== C1. EcoVoltDW.dbo.FlatTablePhysical, all years ===';
SELECT UnitType, [Year], SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW.dbo.FlatTablePhysical GROUP BY UnitType, [Year];

PRINT '=== C2. EcoVoltDW_Part.dbo.FlatTablePhysical, all years ===';
SELECT UnitType, [Year], SUM(EnergyProduced) / SUM(MaxPossibleEnergy) AS CapacityFactor
FROM EcoVoltDW_Part.dbo.FlatTablePhysical GROUP BY UnitType, [Year];
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- ===================== Storage used by every version (CCI compression) =====================
SELECT 'EcoVoltDW' AS DatabaseName, t.name AS TableName, SUM(a.total_pages) * 8 / 1024.0 AS TotalSpaceMB
FROM EcoVoltDW.sys.tables AS t
JOIN EcoVoltDW.sys.partitions AS p ON p.object_id = t.object_id
JOIN EcoVoltDW.sys.allocation_units AS a ON a.container_id = p.partition_id
WHERE t.name IN (N'EnergyProduction', N'FlatTablePhysical')
GROUP BY t.name
UNION ALL
SELECT 'EcoVoltDW_Part', t.name, SUM(a.total_pages) * 8 / 1024.0
FROM EcoVoltDW_Part.sys.tables AS t
JOIN EcoVoltDW_Part.sys.partitions AS p ON p.object_id = t.object_id
JOIN EcoVoltDW_Part.sys.allocation_units AS a ON a.container_id = p.partition_id
WHERE t.name IN (N'EnergyProduction', N'FlatTablePhysical')
GROUP BY t.name
ORDER BY TableName, DatabaseName;
GO
