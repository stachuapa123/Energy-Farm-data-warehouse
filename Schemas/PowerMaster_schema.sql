/* =====================================================================
   EcoVolt - source system "PowerMaster" (relational, MS SQL Server)
   Process: Energy Production Monitoring
   Authors: Stanisław Apanasiewicz 198169, Kacper Neumann 203394

   Notes
   - All names are plain ASCII (no Polish diacritics: Gdansk, Bialystok,
     Zielona Gora, Poznan), so the data loads under any collation.
   - All DATETIME values are UTC (no daylight-saving gaps or duplicates).
   - ProductionLog: one row per unit per hour. LogDate is the START of the
     hour, EnergyProduced is the energy (kWh) produced during that hour.
     The row joins 1:1 with the Weather_Data CSV on
     (Unit.ZoneID, LogDate) = (ZoneID, Datetime).
   - Column names follow the ERD (LogDate, InstallationDate).
   ===================================================================== */

IF DB_ID(N'PowerMaster') IS NULL
    CREATE DATABASE PowerMaster COLLATE Polish_CI_AS;
GO

USE PowerMaster;
GO

/* drop in reverse dependency order, so the script can be re-run */
IF OBJECT_ID(N'dbo.ProductionLog', N'U') IS NOT NULL DROP TABLE dbo.ProductionLog;
IF OBJECT_ID(N'dbo.Unit',          N'U') IS NOT NULL DROP TABLE dbo.Unit;
IF OBJECT_ID(N'dbo.Model',         N'U') IS NOT NULL DROP TABLE dbo.Model;
IF OBJECT_ID(N'dbo.Zone',          N'U') IS NOT NULL DROP TABLE dbo.Zone;
IF OBJECT_ID(N'dbo.Manufacturer',  N'U') IS NOT NULL DROP TABLE dbo.Manufacturer;
GO

/* A company that produces energy generation equipment. */
CREATE TABLE dbo.Manufacturer (
    ManufacturerID  INT IDENTITY(1,1) NOT NULL,
    ManufacturerName VARCHAR(50)      NOT NULL,
    Country         VARCHAR(30)       NOT NULL,
    CONSTRAINT PK_Manufacturer PRIMARY KEY (ManufacturerID)
);

/* A specific type of equipment produced by a manufacturer. */
CREATE TABLE dbo.Model (
    ModelID               INT IDENTITY(1,1) NOT NULL,
    ManufacturerID        INT               NOT NULL,
    ModelName             VARCHAR(50)       NOT NULL,
    UnitType              VARCHAR(20)       NOT NULL,
    ExpectedLifespanYears INT               NOT NULL,
    MaxPowerCapacity      DECIMAL(8,2)      NOT NULL,   -- kW
    CONSTRAINT PK_Model PRIMARY KEY (ModelID),
    CONSTRAINT FK_Model_Manufacturer FOREIGN KEY (ManufacturerID)
        REFERENCES dbo.Manufacturer (ManufacturerID),
    CONSTRAINT CK_Model_UnitType CHECK (UnitType IN ('Solar', 'Wind')),
    CONSTRAINT CK_Model_Lifespan CHECK (ExpectedLifespanYears > 0),
    CONSTRAINT CK_Model_Capacity CHECK (MaxPowerCapacity > 0)
);

/* A geographical sector of the energy farm. */
CREATE TABLE dbo.Zone (
    ZoneID       INT IDENTITY(1,1) NOT NULL,
    ZoneName     VARCHAR(15)       NOT NULL,
    AreaSizeSqm  INT               NOT NULL,
    CONSTRAINT PK_Zone PRIMARY KEY (ZoneID),
    CONSTRAINT UQ_Zone_ZoneName UNIQUE (ZoneName),
    CONSTRAINT CK_Zone_Area CHECK (AreaSizeSqm > 0)
);

/* A single physical generation asset. UnitID is the business key
   shared with the ServiceDesk maintenance system. */
CREATE TABLE dbo.Unit (
    UnitID            VARCHAR(10) NOT NULL,
    ModelID           INT         NOT NULL,
    ZoneID            INT         NOT NULL,
    InstallationDate  DATETIME    NOT NULL,
    CONSTRAINT PK_Unit PRIMARY KEY (UnitID),
    CONSTRAINT FK_Unit_Model FOREIGN KEY (ModelID) REFERENCES dbo.Model (ModelID),
    CONSTRAINT FK_Unit_Zone  FOREIGN KEY (ZoneID)  REFERENCES dbo.Zone (ZoneID)
);

/* Hourly smart-meter reading of a unit. */
CREATE TABLE dbo.ProductionLog (
    ProductionLogID    INT IDENTITY(1,1) NOT NULL,
    UnitID             VARCHAR(10)       NOT NULL,
    LogDate            DATETIME          NOT NULL,
    EnergyProduced     DECIMAL(10,3)     NOT NULL,   -- kWh in the hour
    OperationalStatus  VARCHAR(15)       NOT NULL,
    CONSTRAINT PK_ProductionLog PRIMARY KEY (ProductionLogID),
    CONSTRAINT FK_ProductionLog_Unit FOREIGN KEY (UnitID) REFERENCES dbo.Unit (UnitID),
    CONSTRAINT CK_ProductionLog_Status
        CHECK (OperationalStatus IN ('Operating', 'Fault', 'Maintenance')),
    CONSTRAINT CK_ProductionLog_Energy CHECK (EnergyProduced >= 0)
);

CREATE UNIQUE INDEX UX_ProductionLog_Unit_Date ON dbo.ProductionLog (UnitID, LogDate);
GO
