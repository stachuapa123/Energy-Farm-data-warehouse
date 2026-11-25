-- Partitioned variant: creates ENERGY_PRODUCTION's CCI on PS_ENERGY_PRODUCTION_DateKey before loading;
-- without_partitions builds an unpartitioned CCI after the load (04_facts_constraints_and_indexes.sql).
USE EcoVoltDW_Part;
GO

-- ORDER requires SQL Server 2022+.
IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ENERGY_PRODUCTION')
      AND name = N'CCI_ENERGY_PRODUCTION'
)
BEGIN
    CREATE CLUSTERED COLUMNSTORE INDEX CCI_ENERGY_PRODUCTION
        ON dbo.ENERGY_PRODUCTION
        ORDER (DateKey)
        ON PS_ENERGY_PRODUCTION_DateKey (DateKey);
END;
GO
