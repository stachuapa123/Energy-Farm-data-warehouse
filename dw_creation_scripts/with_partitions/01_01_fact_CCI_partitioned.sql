-- Partitioned variant: creates EnergyProduction's CCI on PS_EnergyProduction_DateKey before loading; without_partitions uses an unpartitioned CCI.
USE EcoVoltDW_Part;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.EnergyProduction')
      AND name = N'CCI_EnergyProduction'
)
BEGIN
    CREATE CLUSTERED COLUMNSTORE INDEX CCI_EnergyProduction
        ON dbo.EnergyProduction
        ORDER (DateKey)
        ON PS_EnergyProduction_DateKey (DateKey);
END;
GO
