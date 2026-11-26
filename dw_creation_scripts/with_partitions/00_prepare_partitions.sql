-- Partitioned variant: defines yearly partitions for EnergyProduction.DateKey; the without_partitions setup has no partition function or scheme.
IF DB_ID(N'EcoVoltDW_Part') IS NULL
    CREATE DATABASE EcoVoltDW_Part;
GO

USE EcoVoltDW_Part;
GO

-- Yearly partitions matching the sample data (readings from 2024 to 2025): pre-2024, one partition per year 2024-2026,
-- and 2027+ for future readings.
CREATE PARTITION FUNCTION PF_EnergyProduction_DateKey (INT)
AS RANGE RIGHT FOR VALUES (20240101, 20250101, 20260101, 20270101);
GO

CREATE PARTITION SCHEME PS_EnergyProduction_DateKey
AS PARTITION PF_EnergyProduction_DateKey ALL TO ([PRIMARY]);
GO

-- ALL TO ([PRIMARY]) maps every partition created by the partition function to the PRIMARY filegroup.
-- The partitions remain logically separate, but they are not distributed across different filegroups.
--
-- A filegroup is a logical container for one or more SQL Server data files. Filegroups can help to:
-- - place data files on different storage devices to distribute I/O;
-- - manage large databases with filegroup-level backup and restore operations;
-- - isolate archival data and, when appropriate, mark its filegroup as read-only.
--
-- These benefits require deliberate storage and backup planning. Using multiple filegroups does not
-- automatically improve performance, especially when their files are stored on the same device.
