-- Partitioned variant: defines yearly partitions for ENERGY_PRODUCTION.DateKey (and FLAT_TABLE.DateKey);
-- the without_partitions setup has no partition function or scheme.
-- Separate database (EcoVoltDW_Part), so both variants can live on one server and be compared
-- with ../09_compare_partitioned_vs_not.sql.
IF DB_ID(N'EcoVoltDW_Part') IS NULL
    CREATE DATABASE EcoVoltDW_Part;
GO

USE EcoVoltDW_Part;
GO

-- DateKey has the form yyyymmdd, so it is already date-ordered: the fact table needs no extra DATE column
-- to be partitioned by date. RANGE RIGHT: each boundary (1 January) belongs to the partition on its right.
--   partition 1: < 2024 (empty)   2: 2024 (~311k rows)   3: 2025 (~355k rows)
--   partition 4: 2026 (empty, ready for the next load)    5: >= 2027
-- Yearly partitions hold far more than the 102,400 rows a compressed columnstore rowgroup needs;
-- monthly partitions (~28k rows) would be too small for a columnstore.
CREATE PARTITION FUNCTION PF_ENERGY_PRODUCTION_DateKey (INT)
AS RANGE RIGHT FOR VALUES (20240101, 20250101, 20260101, 20270101);
GO

CREATE PARTITION SCHEME PS_ENERGY_PRODUCTION_DateKey
AS PARTITION PF_ENERGY_PRODUCTION_DateKey ALL TO ([PRIMARY]);
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
